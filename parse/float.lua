-- SPDX-License-Identifier: ISC
-- Floating point constants: reading a literal, folding arithmetic on
-- constants, and the 80-bit extended format, all in integers.

local tree = require "tree"
local P = require "parse.base"
local cf = require "parse.fold"
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

-- Sixty-four by sixty-four to a hundred and twenty-eight, in halves,
-- because Lua's integers are sixty-four bits and the extended format
-- wants the top of the product.
local function mul128(a, b)
	local a0, a1 = a & 0xffffffff, (a >> 32) & 0xffffffff
	local b0, b1 = b & 0xffffffff, (b >> 32) & 0xffffffff
	local p00, p01, p10, p11 = a0 * b0, a0 * b1, a1 * b0, a1 * b1
	local mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff)

	return p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32),
	       (p00 & 0xffffffff) | (mid << 32)
end

-- Add, and say whether the word ran over.
local function addc(x, y)
	local t = x + y

	return t, math.ult(t, x) and 1 or 0
end

-- The top hundred and twenty-eight bits of the product of two of
-- them, and the sixty-four below that, which decide the rounding.
local function mul256(ah, al, bh, bl)
	local t3, t2 = mul128(ah, bh)
	local u1, u0 = mul128(ah, bl)
	local v1, v0 = mul128(al, bh)
	local w1 = mul128(al, bl)
	local l1, c1 = addc(w1, u0)
	local c2, c3, c4, c5

	l1, c2 = addc(l1, v0)
	local l2

	l2, c3 = addc(t2, u1)
	l2, c4 = addc(l2, v1)
	l2, c5 = addc(l2, c1 + c2)
	return t3 + c3 + c4 + c5, l2, l1
end

-- A value is (hi:lo) * 2^(e - 127), with the top bit of hi set.  The
-- extra sixty-four bits are what keep a power of ten good enough that
-- rounding the answer once, at the end, lands where gcc lands.
local function xmul(ah, al, ea, bh, bl, eb)
	local h, l, g = mul256(ah, al, bh, bl)

	if h < 0 then return h, l, ea + eb + 1 end
	return (h << 1) | (l >> 63), (l << 1) | (g >> 63), ea + eb
end

-- Ten times a hundred and twenty-eight bit integer, and a digit.
local function mul10(h, l, d)
	local hi, lo = mul128(l, 10)
	local nl, c = addc(lo, d)

	return h * 10 + hi + c, nl
end

-- Ten, or a tenth, to the power k.
local function pow10(k)
	local h, l, e = 1 << 63, 0, 0
	local bh, bl, be = 0xa000000000000000, 0, 3

	if k < 0 then
		k = -k
		bh, bl, be = 0xcccccccccccccccc, 0xcccccccccccccccd, -4
	end
	while k > 0 do
		if k & 1 == 1 then h, l, e = xmul(h, l, e, bh, bl, be) end
		k = k >> 1
		if k > 0 then bh, bl, be = xmul(bh, bl, be, bh, bl, be) end
	end
	return h, l, e
end

-- A decimal literal as an extended value.  A double is not a way
-- station here: the extended exponent reaches past ten to the four
-- thousandth, where a double is already infinite.
local function dec80(text)
	local body = text:match("^(.-)[fFlL]*$")
	local mant, ex = body:match("^([%d.]+)[eE]([-+]?%d+)$")

	if not mant then mant, ex = body, "0" end
	local ip, fp = mant:match("^(%d*)%.?(%d*)$")
	if not ip or (ip == "" and fp == "") then return nil end
	local k = math.tointeger(tonumber(ex))

	if not k then return nil end
	k = k - #fp
	local digits = (ip .. fp):gsub("^0+", "")
	local m, used = 0, 0

	-- Thirty-eight digits is what a hundred and twenty-eight bits
	-- hold, and the next one decides whether the last rounds up.
	-- Nineteen is not enough: a literal written to twenty digits,
	-- as the smallest normal of this type is, turns on the last.
	local ml = 0

	for i = 1, #digits do
		if used < 38 then
			m, ml = mul10(m, ml, digits:byte(i) - 48)
			used = used + 1
		else
			if used == 38 and digits:byte(i) >= 53 then
				local c

				ml, c = addc(ml, 1)
				m = m + c
			end
			used = 39
			k = k + 1
		end
	end
	if m == 0 and ml == 0 then return 0, 0 end
	local sig, lo, e = m, ml, 127

	while (sig & (1 << 63)) == 0 do
		sig, lo, e = (sig << 1) | (lo >> 63), lo << 1, e - 1
	end
	if k ~= 0 then
		local ph, pl, pe = pow10(k)

		sig, lo, e = xmul(sig, lo, e, ph, pl, pe)
	end
	-- One rounding, at the end, from the hundred and twenty-eight
	-- bits carried through to the sixty-four the format holds.
	if lo < 0 then
		sig = sig + 1
		if sig == 0 then sig, e = 1 << 63, e + 1 end
	end
	e = e + 16383
	if e >= 32767 then return 0x8000000000000000, 0x7fff end
	if e <= 0 then
		-- Below the smallest normal the exponent stops and the
		-- significand slides, which is what the zero exponent
		-- field means: this format writes its leading bit out.
		local sh = 1 - e

		if sh > 64 then return 0, 0 end
		return (sig >> sh) + ((sig >> (sh - 1)) & 1), 0
	end
	return sig, e
end

-- The x87 extended format, built from a double.  Widening is exact:
-- fifty-three bits of significand go into sixty-four with room to
-- spare, and so does the exponent.  Answers the low eight bytes, which
-- are the significand with its leading bit written out, and the word
-- above them, which holds the sign and the exponent.
--
-- A decimal literal is read as a double first, so the bits past the
-- fifty-third are zero where gcc would have carried them.
local function enc80(v)
	if v ~= v then return 0xc000000000000000, 0x7fff end
	local se = 0.0

	if v < 0.0 or (v == 0.0 and 1.0 / v < 0.0) then
		se, v = 0x8000, -v
	end
	se = math.tointeger(se) or 0
	if v == math.huge then
		return 0x8000000000000000, se | 0x7fff
	end
	if v == 0.0 then return 0, se end
	local m, e = math.frexp(v)

	return math.tointeger(m * 9007199254740992.0) << 11,
	       se | (e - 1 + 16383)
end

-- The two-byte formats: bits of exponent and of fraction.
local HALF = {hf = {5, 10}, bf = {8, 7}}

-- A double rounded to a two-byte format, to nearest and ties to even,
-- worked on the double's own bits.  A NaN stays quiet.
local function enchalf(v, fmt)
	local eb, mb = HALF[fmt][1], HALF[fmt][2]
	local d = string.unpack("<i8", string.pack("<d", v))
	local sign = (d >> 63) << (eb + mb)
	local e = (d >> 52) & 0x7ff
	local m = d & ((1 << 52) - 1)
	local top = (1 << eb) - 1

	if e == 0x7ff then
		if m ~= 0 then
			return sign | (top << mb) | (1 << (mb - 1)) |
				(m >> (52 - mb))
		end
		return sign | (top << mb)
	end
	if e == 0 then return sign end
	m = m | (1 << 52)
	local te = e - 1023 + (top >> 1)
	local shift = 52 - mb

	if te < 1 then shift = shift + 1 - te end
	if shift > 60 then return sign end
	local keep = m >> shift
	local rem = m & ((1 << shift) - 1)
	local half = 1 << (shift - 1)

	if rem > half or (rem == half and keep & 1 == 1) then
		keep = keep + 1
	end
	-- A subnormal carries into the smallest normal on its own; a
	-- normal one that carries out takes the next exponent.
	if te < 1 then return sign | keep end
	if keep >> (mb + 1) ~= 0 then
		keep = keep >> 1
		te = te + 1
	end
	if te >= top then return sign | (top << mb) end
	return sign | (te << mb) | (keep & ((1 << mb) - 1))
end

local function dechalf(bits, fmt)
	local eb, mb = HALF[fmt][1], HALF[fmt][2]
	local top = (1 << eb) - 1
	local e = (bits >> mb) & top
	local m = bits & ((1 << mb) - 1)
	local s = (bits >> (eb + mb)) & 1 == 1 and -1.0 or 1.0
	local bias = top >> 1

	if e == top then
		if m ~= 0 then return 0.0 / 0.0 end
		return s * math.huge
	end
	if e == 0 then return s * m * 2.0 ^ (1 - bias - mb) end
	return s * ((1 << mb) + m) * 2.0 ^ (e - bias - mb)
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
		local lo, se = enc80(n.fnum or 0.0)

		if lo == n.val and se == n.hi then return n.fnum end
		return nil
	end
	if n.ty.half then return dechalf(n.val & 0xffff, n.ty.half) end
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
		local lo, se = enc80(v)

		return tree.node("CONST", ty, nil, nil,
			{val = lo, hi = se, fnum = v})
	end
	if ty.half then return tree.const(ty, enchalf(v, ty.half)) end
	local fmt = ty.size == 8 and "<d" or "<f"
	local ifmt = ty.size == 8 and "<i8" or "<i4"
	local bits = string.unpack(ifmt, string.pack(fmt, v))
	return tree.const(ty, bits)
end

return {
	dec80 = dec80,
}
