-- SPDX-License-Identifier: ISC
-- The 80-bit extended format and the two-byte formats, read and written
-- in integers.  A program that uses neither loads none of this.

local P = require "mcc.parse.base"

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
function P.dec80(text)
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
	e = e + 16383
	if e <= 0 then
		-- Below the smallest normal the exponent stops and the
		-- significand slides, which is what the zero exponent
		-- field means: this format writes its leading bit out.
		-- The bits slid out join the ones below.
		local sh = 1 - e

		if sh > 64 then return 0, 0 end
		lo = (sh == 64 and sig or sig << (64 - sh)) |
			(lo ~= 0 and 1 or 0)
		sig, e = sh == 64 and 0 or sig >> sh, 0
	end
	-- One rounding, at the end, from the hundred and twenty-eight
	-- bits carried through to the sixty-four the format holds.  An
	-- exact half goes to the even neighbor.
	if lo < 0 and (lo ~= math.mininteger or sig & 1 == 1) then
		sig = sig + 1
		if sig == 0 then sig, e = 1 << 63, e + 1 end
		-- a subnormal that rounds up into the smallest normal
		if e == 0 and sig < 0 then e = 1 end
	end
	if e >= 32767 then return 0x8000000000000000, 0x7fff end
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
function P.enc80(v)
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
function P.enchalf(v, fmt)
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

function P.dechalf(bits, fmt)
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

local function bitlen(x)
	local n = 0

	while x ~= 0 do x, n = x >> 1, n + 1 end
	return n
end

-- A hexadecimal literal rounded once to p bits, ties to even, with no
-- bit below 2^(emin - p + 1): the value is m * 2^e.  Answers nil past
-- the largest finite value.
function P.hexround(text, p, emin, emax)
	local ip, fp, ex = text:match("^0[xX](%x*)%.?(%x*)[pP]([-+]?%d+)")

	if not ip then return nil end
	local bits = {}

	for c in (ip .. fp):gmatch("%x") do
		local d = tonumber(c, 16)

		for b = 3, 0, -1 do bits[#bits + 1] = (d >> b) & 1 end
	end
	local e = math.tointeger(tonumber(ex)) - 4 * #fp
	local first = 1

	while first <= #bits and bits[first] == 0 do first = first + 1 end
	local n = #bits - first + 1

	if n <= 0 then return 0, 0 end
	-- The place of the last bit kept: p below the top, and never
	-- below the smallest subnormal.
	local low = math.max(e + n - p, emin - p + 1)
	local keep = math.min(n, n - (low - e))
	local m = 0

	for i = first, first + keep - 1 do m = (m << 1) | bits[i] end
	if low > e then
		local g, sticky = 0, keep < 0

		if keep >= 0 then
			g = bits[first + keep] or 0
			for i = first + keep + 1, #bits do
				if bits[i] == 1 then sticky = true break end
			end
		end
		if g == 1 and (sticky or m & 1 == 1) then
			m = m + 1
			if m == (p == 64 and 0 or 1 << p) then
				m, low = 1 << (p - 1), low + 1
			end
		end
		e = low
	end
	if m ~= 0 and e + bitlen(m) - 1 > emax then return nil end
	return m, e
end

-- Big naturals in base 10^7, least significant limb first, for
-- comparing a decimal literal with a binary value exactly.
local BASE = 10000000

local function bmul(a, k)
	local c = 0

	for i = 1, #a do
		local v = a[i] * k + c

		a[i], c = v % BASE, v // BASE
	end
	while c > 0 do a[#a + 1], c = c % BASE, c // BASE end
end

local function bcmp(a, b)
	while #a > 1 and a[#a] == 0 do a[#a] = nil end
	while #b > 1 and b[#b] == 0 do b[#b] = nil end
	if #a ~= #b then return #a < #b and -1 or 1 end
	for i = #a, 1, -1 do
		if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
	end
	return 0
end

local function bpow(a, k, n)
	for _ = 1, n do bmul(a, k) end
end

-- A decimal literal's value against m * 2^e: -1, 0 or 1.
local function deccmp(text, m, e)
	local body = text:match("^(.-)[fFlL]*$")
	local mant, ex = body:match("^([%d.]+)[eE]([-+]?%d+)$")

	if not mant then mant, ex = body, "0" end
	local ip, fp = mant:match("^(%d*)%.?(%d*)$")
	local k = math.tointeger(tonumber(ex)) - #fp
	local a, b = {0}, {0}

	for c in (ip .. fp):gmatch("%d") do
		bmul(a, 10)
		a[1] = a[1] + tonumber(c)
	end
	b[1] = m % BASE
	b[2] = m // BASE
	bmul(a, 1)
	bmul(b, 1)
	if k >= 0 then bpow(a, 10, k) else bpow(b, 10, -k) end
	if e >= 0 then bpow(b, 2, e) else bpow(a, 2, -e) end
	return bcmp(a, b)
end

-- A decimal float literal, given the double nearest it.  Rounding that
-- double again is right unless it falls halfway between two floats;
-- there the decimal itself says which way.
function P.decf32(text, d)
	local x = string.unpack("<i8", string.pack("<d", d))
	local be = (x >> 52) & 0x7ff

	if be == 0 or be == 0x7ff then return d end
	local m = (x & ((1 << 52) - 1)) | (1 << 52)
	local e = be - 1075
	local lsb = math.max(be - 1023 - 23, -149)
	local s = lsb - e

	if s <= 0 or s > 53 or m & ((1 << s) - 1) ~= 1 << (s - 1) then
		return d
	end
	local c = deccmp(text, m, e)

	if c == 0 then return d end
	return d + c * 2.0 ^ (lsb - 1)
end

return {}
