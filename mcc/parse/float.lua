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
	-- initializer may say `1.0f / 255.0f`.  The extended type is
	-- worked in its own precision.  A divide by zero is left to run.
	if rt.x87 and FOP[op] and a.op == "CONST" and b.op == "CONST" and
	   not (op == "DIV" and b.val == 0 and b.hi & 0x7fff == 0) then
		local lo, se = self.op80(op, a.val, a.hi, b.val, b.hi)

		return tree.node("CONST", rt, nil, nil,
			{val = lo, hi = se, fnum = self.dbl80(lo, se)})
	end
	if rt.x87 and FCMP[op] and a.op == "CONST" and b.op == "CONST" then
		local r = self.cmp80(a.val, a.hi, b.val, b.hi)
		local v = (op == "NE" and r ~= 0) or (op == "EQ" and r == 0) or
			((op == "LT" or op == "LE") and r == -1) or
			((op == "GT" or op == "GE") and r == 1) or
			((op == "LE" or op == "GE") and r == 0)

		return tree.const(self.ty.i32, v and 1 or 0)
	end
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

local function bitlen(x)
	local n = 0

	while x ~= 0 do x, n = x >> 1, n + 1 end
	return n
end

-- An integer constant as a float constant, rounded once to nearest even.
-- The magnitude is (hi:lo), both unsigned, so a 128-bit one fits too.
-- Going through a double first rounds twice.
function P:intfconst(neg, hi, lo, ty)
	local p = ty.x87 and 64 or ty.size == 8 and 53 or 24
	local n = hi ~= 0 and 64 + bitlen(hi) or bitlen(lo)
	local m, e = lo, 0

	if n == 0 then return self:fconst(0.0, ty) end
	if n > p then
		local s = n - p
		local function bit(k)
			if k >= 64 then return (hi >> (k - 64)) & 1 end
			return (lo >> k) & 1
		end
		local low

		m = s >= 64 and hi >> (s - 64) or (lo >> s) | (hi << (64 - s))
		if s - 1 >= 64 then
			low = lo | (hi & ((1 << (s - 1 - 64)) - 1))
		else
			low = lo & ((1 << (s - 1)) - 1)
		end
		if bit(s - 1) == 1 and (low ~= 0 or m & 1 == 1) then
			m = m + 1
			if m == (p == 64 and 0 or 1 << p) then
				m, s = 1 << (p - 1), s + 1
			end
		end
		e = s
	end
	return self:mkflt(neg, m, e, ty)
end

-- The constant m * 2^e, which the type holds exactly unless it is past
-- the largest value.  m is unsigned and has at most the type's bits.
function P:mkflt(neg, m, e, ty)
	if ty.x87 then
		local k = bitlen(m)

		if k == 0 then return self:fconst(neg and -0.0 or 0.0, ty) end
		-- The significand with its leading bit written out, or
		-- for a subnormal, the bits where the zero exponent puts
		-- them.
		local sig, ex = m << (64 - k), e + k - 1 + 16383

		if ex <= 0 then sig, ex = m << (e + 16445), 0 end
		local v = ((m >> 11) * 1.0) * 2.0 ^ (e + 11) +
			((m & 0x7ff) * 1.0) * 2.0 ^ e

		return tree.node("CONST", ty, nil, nil,
			{val = sig, hi = (neg and 0x8000 or 0) | ex,
			 fnum = neg and -v or v})
	end
	local v = (m * 1.0) * 2.0 ^ e

	if ty.size == 4 and v >= 2.0 ^ 128 then v = math.huge end
	return self:fconst(neg and -v or v, ty)
end

return {}
