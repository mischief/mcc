-- SPDX-License-Identifier: ISC
-- Floating point constants: folding arithmetic on constants, and making
-- a constant of a number.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local fold = cf.fold
local isflt = cf.isflt
local isptr = cf.isptr

-- Floating point is lowered to calls.  The compiler never puts a float in a
-- float register, which is what a target without an FPU needs anyway, and
-- what lets a target that has one add table entries later.
local FOP = {ADD = "add", SUB = "sub", MUL = "mul", DIV = "div"}

-- __dcmp answers -1, 0, 1, or 2 when the two are unordered.
local FCMP = {
	EQ = {"EQ", 0}, NE = {"NE", 0},
	LT = {"EQ", -1}, GT = {"EQ", 1},
	LE = {"LE", 0}, GE = {"ULE", 1},
}

-- Two constants make a constant.  Without this `1 << 3` is a load and
-- a shift, and a kernel header writes little else; `fold` already
-- knows how to read the whole node, so this only has to ask.
--
-- A divide by zero and a shift past the width are both undefined, and
-- what the machine does with them is not what folding them would say,
-- so those are left as they are.
local function konst(n)
	local rop = n.right and n.right.op

	if n.op == "DIV" or n.op == "MOD" then
		if rop ~= "CONST" or n.right.val == 0 then return n end
	elseif n.op == "SHL" or n.op == "SHR" then
		local w = (n.left and n.left.ty.size or 4) * 8

		if rop ~= "CONST" or not n.right.val or
		   n.right.val < 0 or n.right.val >= w then
			return n
		end
	end
	local v = fold(n)

	if v == nil then return n end
	return tree.const(n.ty, v)
end

function P:arith(op, a, b)
	a, b = self:rvalue(a), self:rvalue(b)
	if a.ty.complex or (b and b.ty.complex) then
		if op == "ADD" or op == "SUB" or op == "MUL" or
		   op == "DIV" or op == "EQ" or op == "NE" then
			return self:cplxarith(op, a, b)
		end
		self:err(op .. " on _Complex is not supported")
	end
	if op == "ADD" or op == "SUB" then
		-- A pointer stepped by nothing is the pointer: `p[0]`.
		if isptr(a.ty) and not isptr(b.ty) then
			local s = self:scale(self:conv(b, self.aword), a.ty.to)

			if s.op == "CONST" and s.val == 0 then return a end
			return tree.binary(op, a.ty, a, s)
		end
		if isptr(b.ty) and op == "ADD" then
			local s = self:scale(self:conv(a, self.aword), b.ty.to)

			if s.op == "CONST" and s.val == 0 then return b end
			return tree.binary(op, b.ty, b, s)
		end
		if isptr(a.ty) and isptr(b.ty) and op == "SUB" then
			local d = tree.binary("SUB", self.aword, a, b)
			if a.ty.to.size == 1 then return d end
			return tree.binary("DIV", self.aword, d,
				tree.const(self.aword, a.ty.to.size))
		end
	end
	-- A shift takes its type from its left side alone; the two sides do
	-- not meet.
	if op == "SHL" or op == "SHR" then
		local rt = self:promote(a.ty)
		if self:iswide(rt) then
			return self:wideop(op, self:conv(a, rt), b, rt)
		end
		return konst(tree.binary(op, rt, self:conv(a, rt),
			self:conv(b, self:promote(b.ty))))
	end
	local rt = self:usual(a.ty, b.ty)
	if self:iswide(rt) then
		return self:wideop(op, self:conv(a, rt), self:conv(b, rt), rt)
	end
	if isflt(rt) then return self:floatop(op, a, b, rt) end
	-- A comparison answers an int whatever it compared.  The operands
	-- keep the type the comparison is made in, which is where the
	-- instruction reads the signedness from.
	local out = tree.ops[op] and tree.ops[op].rel and self.ty.i32 or rt

	return konst(tree.binary(op, out, self:conv(a, rt),
		self:conv(b, rt)))
end

-- The number a float constant stands for.  A float travels as its bit
-- pattern, so reading one back is an unpacking.
function P:fvalue(n)
	if n.op ~= "CONST" or not isflt(n.ty) then return nil end
	-- An extended constant carries the number it was made from, but
	-- only where a double holds the same value.  Past that -- and
	-- the type reaches a long way past it -- there is no number to
	-- answer with and the arithmetic has to be done by the machine.
	if n.ty.x87 then
		local lo, se = self.enc80(n.fnum or 0.0)

		if lo == n.val and se == n.hi then return n.fnum end
		return nil
	end
	if n.ty.half then return self.dechalf(n.val & 0xffff, n.ty.half) end
	local fmt = n.ty.size == 8 and "<d" or "<f"
	local ifmt = n.ty.size == 8 and "<I8" or "<I4"
	local mask = n.ty.size == 8 and -1 or 0xffffffff
	return (string.unpack(fmt, string.pack(ifmt, n.val & mask)))
end

function P:floatop(op, a, b, rt)
	rt = self:promote(rt)
	a, b = self:conv(a, rt), self:conv(b, rt)
	if self:iswide(rt) then return self:wideop(op, a, b, rt) end
	-- Two constants make a third, which is the only way a static
	-- initializer may say `1.0f / 255.0f`.
	local x, y = self:fvalue(a), self:fvalue(b)
	if x and y and FOP[op] then
		local v
		if op == "ADD" then v = x + y
		elseif op == "SUB" then v = x - y
		elseif op == "MUL" then v = x * y
		elseif y ~= 0.0 then v = x / y end
		if v then return self:fconst(v, rt) end
	end
	-- A comparison of two constants is a constant too, and NaN sorts
	-- the same way in Lua as it does in C.
	if x and y and FCMP[op] then
		local v
		if op == "EQ" then v = x == y
		elseif op == "NE" then v = x ~= y
		elseif op == "LT" then v = x < y
		elseif op == "LE" then v = x <= y
		elseif op == "GT" then v = x > y
		elseif op == "GE" then v = x >= y end
		if v ~= nil then
			return tree.const(self.ty.i32, v and 1 or 0)
		end
	end
	-- A machine with floating point instructions needs no runtime: the
	-- node goes to the code tables as an integer one does.
	if self.t.hwfloat then
		if FOP[op] then return tree.binary(op, rt, a, b) end
		if not FCMP[op] then
			self:err(op .. " is not defined on floating point")
		end
		return tree.binary(op, self.ty.i32, a, b)
	end
	local p = self:fprefix(rt)
	if FOP[op] then
		return self:rtcall("__" .. p .. FOP[op], rt, {a, b})
	end
	local c = FCMP[op]
	if not c then self:err(op .. " is not defined on floating point") end
	local r = self:rtcall("__" .. p .. "cmp", self.ty.i32, {a, b})
	if c[1] == "ULE" then
		r.ty = self.ty.u32
		return tree.binary("LE", self.ty.i32, r,
			tree.const(self.ty.u32, c[2]))
	end
	return tree.binary(c[1], self.ty.i32, r, tree.const(self.ty.i32, c[2]))
end

function P:fconst(v, ty)
	if ty.x87 then
		local lo, se = self.enc80(v)

		return tree.node("CONST", ty, nil, nil,
			{val = lo, hi = se, fnum = v})
	end
	if ty.half then return tree.const(ty, self.enchalf(v, ty.half)) end
	local fmt = ty.size == 8 and "<d" or "<f"
	local ifmt = ty.size == 8 and "<i8" or "<i4"
	local bits = string.unpack(ifmt, string.pack(fmt, v))
	return tree.const(ty, bits)
end

return {}
