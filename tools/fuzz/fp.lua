-- SPDX-License-Identifier: ISC
-- Floating point test generator: t.c holds the tests, m.c the main that
-- the system compiler builds.  tN_c reads constants (the folder answers);
-- tN_v reads volatiles and parameters (the code answers).  -k keeps one.
--
--   lua5.4 tools/fuzz/fp.lua -t TARGET -s SEED -o DIR [-n COUNT] [-k NAME]

local target, seed, outdir, count, keep = "amd64", 1, ".", 40, nil
local i = 1
while i <= #arg do
	local a = arg[i]
	if a == "-t" then target = arg[i + 1]; i = i + 1
	elseif a == "-s" then seed = tonumber(arg[i + 1]); i = i + 1
	elseif a == "-o" then outdir = arg[i + 1]; i = i + 1
	elseif a == "-n" then count = tonumber(arg[i + 1]); i = i + 1
	elseif a == "-k" then keep = arg[i + 1]; i = i + 1
	else error("fp.lua: no option " .. a) end
	i = i + 1
end

-- What each target has.  Only amd64 has a long double that matches the
-- system compiler's; elsewhere mcc makes it a double.
local TGT = {
	amd64 = {ld = true, i128 = true, long = 64},
	i386 = {ld = false, i128 = false, long = 32},
	arm64 = {ld = false, i128 = true, long = 64},
	riscv64 = {ld = false, i128 = true, long = 64},
}
local tg = assert(TGT[target], "no target " .. target)

math.randomseed(seed)
local function rnd(n) return math.random(n) end
local function pick(t) return t[math.random(#t)] end
local function chance(p) return math.random() < p end

-- Float types: significand bits with the leading one, exponent range.
local FT = {
	F = {name = "float", sfx = "f", p = 24, emin = -126, emax = 127,
	     rank = 1, pr = "pf"},
	D = {name = "double", sfx = "", p = 53, emin = -1022, emax = 1023,
	     rank = 2, pr = "pd"},
	L = {name = "long double", sfx = "L", p = 64, emin = -16382,
	     emax = 16383, rank = 3, pr = "pl"},
}
local FLIST = tg.ld and {"F", "D", "L"} or {"F", "D"}

-- Integer types: width and signedness.
local IT = {
	sc = {name = "signed char", n = 8, s = true},
	uc = {name = "unsigned char", n = 8},
	ss = {name = "short", n = 16, s = true},
	us = {name = "unsigned short", n = 16},
	si = {name = "int", n = 32, s = true},
	ui = {name = "unsigned", n = 32},
	sl = {name = "long", n = tg.long, s = true},
	ul = {name = "unsigned long", n = tg.long},
	sx = {name = "long long", n = 64, s = true},
	ux = {name = "unsigned long long", n = 64},
	so = {name = "__int128", n = 128, s = true},
	uo = {name = "unsigned __int128", n = 128},
}
local ILIST = {"sc", "uc", "ss", "us", "si", "ui", "sl", "ul", "sx", "ux"}
if tg.i128 then ILIST[#ILIST + 1] = "so"; ILIST[#ILIST + 1] = "uo" end

-- ---- values ----

-- A float literal of type t: m * 2^e, m a non-negative integer.
local function hexlit(t, neg, m, e)
	return ("%s0x%xp%d%s"):format(neg and "-" or "", m, e, FT[t].sfx)
end

-- Decimal literals near the edges, which exercise the literal reader.
local DEC = {
	F = {"0.1f", "1e-45f", "7e-46f", "1.4e-45f", "1.17549435e-38f",
	     "1.1754942e-38f", "3.4028235e38f", "3.40282357e38f",
	     "3.4028236e38f", "3.4028237e38f", "1.000000059604644775390625f",
	     "1.000000059604644775390626f", "16777217.0f", "16777219.0f",
	     "2147483647.0f", "0.3333333333f", "1e10f", "1e-10f"},
	D = {"0.1", "4.9e-324", "2.4703282292062327e-324",
	     "2.4703282292062328e-324", "2.2250738585072014e-308",
	     "2.2250738585072011e-308", "1.7976931348623157e308",
	     "1.7976931348623158e308", "1.7976931348623159e308",
	     "9007199254740993.0", "9007199254740995.0",
	     "1.00000000000000011102230246251565404236316680908203125",
	     "1.00000000000000011102230246251565404236316680908203126",
	     "9223372036854775807.0", "18446744073709551615.0", "1e23",
	     "8.98846567431158e307", "0.3333333333333333333"},
	L = {"0.1L", "3.6e-4951L", "3.65e-4951L", "1.8e-4951L",
	     "3.3621031431120935063e-4932L", "1.18973149535723176502e4932L",
	     "1.18973149535723176508e4932L", "1e4933L",
	     "18446744073709551617.0L", "18446744073709551615.0L",
	     "9223372036854775807.0L", "1e23L", "0.1e-4940L"},
}

-- Edge values for a float type, as literals.
local function fedge(t)
	local f = FT[t]
	local p, emin, emax = f.p, f.emin, f.emax
	local one = 1 << (p - 1)
	local top = p == 64 and -1 or (1 << p) - 1
	local c = {
		hexlit(t, false, 0, 0), hexlit(t, true, 0, 0),
		hexlit(t, false, 1, emin - p + 1),
		hexlit(t, false, one - 1, emin - p + 1),
		hexlit(t, false, 1, emin),
		hexlit(t, false, top, emax - p + 1),
		hexlit(t, false, 1, 0), hexlit(t, false, one + 1, -(p - 1)),
		hexlit(t, false, top, -p),
		-- half an ulp above one, both ways of breaking the tie
		hexlit(t, false, 2 * one + 1, -p),
		hexlit(t, false, 2 * one + 3, -p),
		hexlit(t, false, 3, -1), hexlit(t, false, 3, 0),
		hexlit(t, false, 1, 7), hexlit(t, false, 1, 15),
		hexlit(t, false, 1, 31), hexlit(t, false, 1, 32),
		hexlit(t, false, 1, 63), hexlit(t, false, 1, 64),
		hexlit(t, false, 1, 127),
		hexlit(t, false, top, 63 - p), hexlit(t, false, top, 64 - p),
		hexlit(t, false, top, 31 - p), hexlit(t, false, top, 32 - p),
		hexlit(t, true, 1, 63), hexlit(t, true, 1, 31),
		hexlit(t, false, 5, -1), hexlit(t, true, 5, -1),
		hexlit(t, false, 7, -1),
	}
	if p < 64 then
		-- a value of the integer limits rounded the other way
		c[#c + 1] = hexlit(t, false, (1 << p) + 1, 63 - p)
		c[#c + 1] = hexlit(t, false, (1 << (p + 1)) - 1, 63 - p)
	end
	return c
end

local FSPECIAL = {
	F = {"__builtin_inff()", "(-__builtin_inff())", "__builtin_nanf(\"\")"},
	D = {"__builtin_inf()", "(-__builtin_inf())", "__builtin_nan(\"\")"},
	L = {"__builtin_infl()", "(-__builtin_infl())", "__builtin_nanl(\"\")"},
}

local FEDGE = {}
for _, t in ipairs(FLIST) do FEDGE[t] = fedge(t) end

-- A random significand of p bits and an exponent in a place where
-- something happens.
local function frandom(t)
	local f = FT[t]
	local p = f.p
	local m
	if p == 64 then
		m = math.random(math.mininteger, math.maxinteger) |
			math.mininteger
	else
		m = math.random(0, (1 << (p - 1)) - 1) | (1 << (p - 1))
	end
	-- Low bits clear, all set, or one set make ties and carries.
	local r = rnd(4)
	if r == 1 then
		m = m & ~((1 << rnd(p - 1)) - 1)
	elseif r == 2 then
		m = m | ((1 << rnd(p - 1)) - 1)
	end
	local e
	r = rnd(6)
	if r == 1 then e = rnd(20) - 10 - p
	elseif r == 2 then e = pick{7, 8, 15, 16, 31, 32, 53, 63, 64, 127, 128}
		- p + rnd(3) - 2
	elseif r == 3 then e = f.emin - p + rnd(p + 2)
	elseif r == 4 then e = f.emax - p + 1 - rnd(3) + 1
	else e = rnd(40) - 20 - p end
	-- An extra bit or two that the literal must round away.
	if chance(0.2) and p < 63 then
		local x = rnd(2)
		m = (m << x) | math.random(0, (1 << x) - 1)
		e = e - x
	end
	return hexlit(t, chance(0.3), m, e)
end

local function fvalue(t)
	local r = rnd(10)
	if r <= 4 then return pick(FEDGE[t])
	elseif r <= 5 then return pick(DEC[t])
	elseif r <= 6 then return pick(FSPECIAL[t])
	else return frandom(t) end
end

-- Integer values as {hi, lo}, a 128-bit two's complement pair.
local function v64(x) return {x < 0 and -1 or 0, x} end
local function uv64(x) return {0, x} end
local IEDGE = {}
for _, x in ipairs{0, 1, 2, 3, 7, 100, 127, 128, 255, 256, 32767, 32768,
		   65535, 65536, (1 << 24) - 1, 1 << 24, (1 << 24) + 1,
		   (1 << 24) + 3, 0x7fffffc0, 0x7fffff80, 0x7fffffff,
		   0x80000000, 0x80000080, 0xffffff80, 0xffffffff,
		   1 << 32, (1 << 53) - 1, 1 << 53, (1 << 53) + 1,
		   (1 << 53) + 2, (1 << 53) + 3, (1 << 54) + 2,
		   (1 << 54) + 6, math.maxinteger, math.maxinteger - 511,
		   math.maxinteger - 512, math.maxinteger - 1535,
		   0x7ffffffffffffdff, 0x7ffffe0000000000,
		   0x7fffff8000000000} do
	IEDGE[#IEDGE + 1] = uv64(x)
	IEDGE[#IEDGE + 1] = v64(-x)
end
for _, x in ipairs{math.mininteger, -1, math.mininteger + 1024,
		   math.mininteger + 1023, math.mininteger | 0x400,
		   math.mininteger | 0x401, -1025, -1024, -2048,
		   0x8000008000000000, 0x8000018000000000,
		   math.mininteger | 0x600} do
	IEDGE[#IEDGE + 1] = uv64(x)
end
-- Half an ulp of float and of double above a power of two, exact, just
-- under, and just over.  Only the bits below the half say which way.
for _, t in ipairs{30, 31, 62, 63} do
	for _, p in ipairs{24, 53} do
		if t >= p then
			local b, h = 1 << t, 1 << (t - p)
			for _, x in ipairs{b + h, b + h - 1, b + h + 1,
					   b + 3 * h, b + 3 * h - 1} do
				IEDGE[#IEDGE + 1] = uv64(x)
				if t < 63 then IEDGE[#IEDGE + 1] = v64(-x) end
			end
		end
	end
end
for _, t in ipairs{64, 100, 126, 127} do
	for _, p in ipairs{24, 53, 64} do
		local s = t - p
		local hh = s >= 64 and 1 << (s - 64) or 0
		local hl = s < 64 and 1 << s or 0
		local bh = 1 << (t - 64)
		IEDGE[#IEDGE + 1] = {bh | hh, hl}
		IEDGE[#IEDGE + 1] = {bh | hh, hl | 1}
		IEDGE[#IEDGE + 1] = {bh | (hl == 0 and hh - 1 or hh),
				     hl == 0 and -1 or hl - 1}
	end
end
for _, hl in ipairs{{1, 0}, {1, 1}, {1, 0x800}, {1, 0x801}, {1, 0x1800},
		    {1 << 49, 0}, {1 << 49, 1}, {(1 << 49) - 1, -1},
		    {math.maxinteger, -1}, {math.mininteger, 0},
		    {-1, 0}, {0x7fffff8000000000, 0},
		    {0x7fffff0000000000, 1}, {0xffffff, -1}} do
	IEDGE[#IEDGE + 1] = hl
	-- and the negation
	local hi, lo = ~hl[1], ~hl[2]
	lo = lo + 1
	if lo == 0 then hi = hi + 1 end
	IEDGE[#IEDGE + 1] = {hi, lo}
end

local function fits(it, v)
	local t = IT[it]
	local hi, lo = v[1], v[2]
	if t.n == 128 then return t.s or true end
	if t.s then
		if hi ~= (lo < 0 and -1 or 0) then return false end
		if t.n == 64 then return true end
		local h = 1 << (t.n - 1)
		return lo >= -h and lo < h
	end
	if hi ~= 0 then return false end
	if t.n == 64 then return true end
	return lo >= 0 and lo < (1 << t.n)
end

local function ivalue(it)
	local t = IT[it]
	for _ = 1, 50 do
		local v = pick(IEDGE)
		if chance(0.15) then
			v = {chance(0.5) and math.random(math.mininteger,
				math.maxinteger) or 0,
			     math.random(math.mininteger, math.maxinteger)}
			if t.n < 64 then
				local m = (1 << t.n) - 1
				v = {0, v[2] & m}
				if t.s and v[2] >= (1 << (t.n - 1)) then
					v = {-1, v[2] - (1 << t.n)}
				end
			end
			if t.n == 64 then
				v = t.s and v64(v[2]) or uv64(v[2])
			end
		end
		if fits(it, v) then return v end
	end
	return {0, 1}
end

local function ilit(it, v)
	local t = IT[it]
	if t.n == 128 then
		return ("((%s)(((unsigned __int128)0x%xULL << 64) | 0x%xULL))")
			:format(t.name, v[1], v[2])
	end
	if t.s then
		if v[2] == math.mininteger then
			return ("((%s)(-0x7fffffffffffffffLL - 1))"):format(t.name)
		end
		return ("((%s)%dLL)"):format(t.name, v[2])
	end
	return ("((%s)0x%xULL)"):format(t.name, v[2])
end

-- ---- expressions ----

local function ftype_of(a, b)
	local ra = a.ft and FT[a.ft].rank or 0
	local rb = b.ft and FT[b.ft].rank or 0
	return ra >= rb and a.ft or b.ft
end

local genf, geni

-- A leaf: one value, read as the mode asks.
local function fleaf(t)
	return {k = "leaf", ft = t, ty = FT[t].name, lit = fvalue(t)}
end

local function ileaf(it)
	return {k = "leaf", it = it, ty = IT[it].name,
		lit = ilit(it, ivalue(it))}
end

-- Helpers t.c defines and m.c defines: each answers one of its
-- arguments, so a value crosses the argument and return registers.
local helpers = {}
local function helper(rt)
	for _, h in ipairs(helpers) do
		if h.ft == rt and chance(0.6) then return h end
	end
	local n = rnd(chance(0.3) and 14 or 4)
	local args = {}
	local fpos = {}
	for j = 1, n do
		if chance(0.75) then
			args[j] = {ft = pick(FLIST)}
			fpos[#fpos + 1] = j
		else
			local it = pick(ILIST)
			args[j] = {it = IT[it].n == 128 and "sx" or it}
		end
	end
	if #fpos == 0 then
		args[1] = {ft = pick(FLIST)}
		fpos[1] = 1
	end
	local h = {ft = rt, args = args, ret = pick(fpos),
		   name = "h" .. #helpers, ext = chance(0.5)}
	helpers[#helpers + 1] = h
	return h
end

local OPS = {"+", "-", "*", "/"}
local CMPS = {"==", "!=", "<", "<=", ">", ">=", "isgreater",
	      "isgreaterequal", "isless", "islessequal", "islessgreater",
	      "isunordered"}

function genf(t, d)
	if d <= 0 or chance(0.2) then return fleaf(t) end
	local r = rnd(20)
	if r <= 6 then
		-- operands that convert to t under the usual rules
		local ta, tb = t, t
		if chance(0.4) then
			ta = pick(FLIST)
			if FT[ta].rank > FT[t].rank then ta = t end
		end
		if chance(0.4) then
			tb = pick(FLIST)
			if FT[tb].rank > FT[t].rank then tb = t end
		end
		if ta ~= t and tb ~= t then
			if chance(0.5) then ta = t else tb = t end
		end
		-- With an integer operand the float one sets the type.
		local b = chance(0.15) and geni(pick(ILIST), d - 1) or nil
		local a = genf(b and t or ta, d - 1)

		b = b or genf(tb, d - 1)
		if chance(0.5) then a, b = b, a end
		return {k = "bin", ft = t, op = pick(OPS), a = a, b = b}
	elseif r <= 7 then
		return {k = "neg", ft = t, a = genf(t, d - 1)}
	elseif r <= 10 then
		return {k = "cvt", ft = t, a = genf(pick(FLIST), d - 1)}
	elseif r <= 13 then
		return {k = "cvt", ft = t, a = geni(pick(ILIST), d - 1)}
	elseif r <= 15 then
		local tc = pick(FLIST)
		return {k = "cond", ft = t,
			c = {k = "cmp", it = "si", op = pick(CMPS),
			     a = genf(tc, d - 1), b = genf(pick(FLIST), d - 1)},
			a = genf(t, d - 1), b = genf(t, d - 1)}
	elseif r <= 17 then
		local h = helper(t)
		local args = {}
		for j, a in ipairs(h.args) do
			args[j] = a.ft and genf(a.ft, j == h.ret and d - 1 or 0)
				or geni(a.it, 0)
		end
		return {k = "call", ft = t, h = h, args = args}
	elseif r <= 18 then
		-- through a variadic function, which promotes a float
		local vt = t == "L" and "L" or "D"
		local n = rnd(10)
		local args = {}
		for j = 1, n do
			args[j] = genf(vt == "L" and "L" or pick{"F", "D"},
				j == n and d - 1 or 0)
		end
		return {k = "cvt", ft = t,
			a = {k = "va", ft = vt, args = args, n = n}}
	else
		local rhs = chance(0.2) and geni(pick(ILIST), d - 1) or
			genf(pick(FLIST), d - 1)
		return {k = "cas", ft = t, op = pick(OPS),
			init = genf(t, d - 1), rhs = rhs}
	end
end

function geni(it, d)
	if d <= 0 or chance(0.3) then return ileaf(it) end
	local r = rnd(10)
	if r <= 6 then
		return {k = "f2i", it = it, a = genf(pick(FLIST), d - 1)}
	elseif r <= 7 then
		return {k = "bool", it = it, a = genf(pick(FLIST), d - 1)}
	elseif r <= 8 and IT[it].n >= 32 and IT[it].s and IT[it].n <= 64 then
		return {k = "icas", it = it, op = pick{"+", "-"},
			init = {k = "leaf", it = it, ty = IT[it].name,
				lit = ilit(it, v64(rnd(2001) - 1001))},
			rhs = genf(pick(FLIST), d - 1)}
	else
		return {k = "cmp", it = it, op = pick(CMPS),
			a = genf(pick(FLIST), d - 1),
			b = chance(0.2) and geni(pick(ILIST), d - 1) or
				genf(pick(FLIST), d - 1)}
	end
end

-- ---- rendering ----

-- One function's worth of state: what it reads and what it declares.
local function newfn(mode)
	return {mode = mode, pre = {}, params = {}, args = {}, ntmp = 0}
end

local globals = {}

local function tmp(fn, ty, init)
	fn.ntmp = fn.ntmp + 1
	local v = "v" .. fn.ntmp
	fn.pre[#fn.pre + 1] = ("\t%s %s = %s;"):format(ty, v, init)
	return v
end

local function typeof(n)
	return n.ft and FT[n.ft].name or IT[n.it].name
end

local render

local function leaf(fn, n)
	if fn.mode == "c" then return n.lit end
	local r = rnd(3)
	if r == 1 then
		local g = "g" .. (#globals + 1)
		globals[#globals + 1] = ("static volatile %s %s = %s;")
			:format(n.ty, g, n.lit)
		return g
	elseif r == 2 then
		fn.ntmp = fn.ntmp + 1
		local v = "v" .. fn.ntmp
		fn.pre[#fn.pre + 1] = ("\tvolatile %s %s = %s;")
			:format(n.ty, v, n.lit)
		return v
	elseif n.it and IT[n.it].n == 128 then
		-- How a 128-bit argument travels is the ABI fuzzer's
		-- business; here it is read from memory.
		local g = "g" .. (#globals + 1)
		globals[#globals + 1] = ("static volatile %s %s = %s;")
			:format(n.ty, g, n.lit)
		return g
	else
		local p = "p" .. (#fn.params + 1)
		fn.params[#fn.params + 1] = n.ty .. " " .. p
		fn.args[#fn.args + 1] = n.lit
		return p
	end
end

-- A float value read twice, or once into a temporary when it is long.
local function twice(fn, n)
	local x = render(fn, n)
	if #x > 160 then x = tmp(fn, typeof(n), x) end
	return x
end

function render(fn, n)
	local k = n.k
	if k == "leaf" then return leaf(fn, n)
	elseif k == "bin" then
		return ("(%s %s %s)"):format(render(fn, n.a), n.op,
			render(fn, n.b))
	elseif k == "neg" then
		return ("(-(%s))"):format(render(fn, n.a))
	elseif k == "cvt" then
		return ("((%s)%s)"):format(FT[n.ft].name, render(fn, n.a))
	elseif k == "cond" then
		return ("(%s ? %s : %s)"):format(render(fn, n.c),
			render(fn, n.a), render(fn, n.b))
	elseif k == "cmp" then
		local a, b = render(fn, n.a), render(fn, n.b)
		if n.op:sub(1, 2) == "is" then
			return ("__builtin_%s(%s, %s)"):format(n.op, a, b)
		end
		return ("(%s %s %s)"):format(a, n.op, b)
	elseif k == "call" then
		local a = {}
		for j, x in ipairs(n.args) do a[j] = render(fn, x) end
		return ("%s%s(%s)"):format(n.h.ext and "x" or "",
			n.h.name, table.concat(a, ", "))
	elseif k == "va" then
		local a = {}
		for j, x in ipairs(n.args) do a[j] = render(fn, x) end
		return ("va%s(%d, %s)"):format(n.ft, n.n,
			table.concat(a, ", "))
	elseif k == "cas" then
		local init = render(fn, n.init)
		local rhs = render(fn, n.rhs)
		local v = tmp(fn, FT[n.ft].name, init)
		fn.pre[#fn.pre + 1] = ("\t%s %s= %s;"):format(v, n.op, rhs)
		return v
	elseif k == "icas" then
		-- The sum stays well inside the integer's range.
		local x = twice(fn, n.rhs)
		local s = FT[n.rhs.ft].sfx
		local g = ("((%s > -0x1p20%s && %s < 0x1p20%s) ? %s : 0)")
			:format(x, s, x, s, x)
		local v = tmp(fn, IT[n.it].name, render(fn, n.init))
		fn.pre[#fn.pre + 1] = ("\t%s %s= %s;"):format(v, n.op, g)
		return v
	elseif k == "f2i" then
		-- Only a value whose integer part fits is converted.
		local x = twice(fn, n.a)
		local t = IT[n.it]
		local s = n.a.ft == "L" and "L" or ""
		local lo, hi
		if t.s then
			lo = ("%s >= -0x1p%d%s"):format(x, t.n - 1, s)
			hi = ("%s < 0x1p%d%s"):format(x, t.n - 1, s)
		else
			lo = ("%s > -1.0%s"):format(x, s)
			hi = ("%s < 0x1p%d%s"):format(x, t.n, s)
		end
		return ("((%s && %s) ? (%s)%s : (%s)0)"):format(lo, hi,
			t.name, x, t.name)
	elseif k == "bool" then
		return ("((%s)(_Bool)%s)"):format(IT[n.it].name,
			render(fn, n.a))
	end
	error("render " .. k)
end

-- ---- output ----

local tests = {}
for j = 1, count do
	local root
	if chance(0.75) then
		root = genf(pick(FLIST), rnd(4))
	else
		root = geni(pick(ILIST), rnd(4))
	end
	for _, mode in ipairs{"c", "v"} do
		local name = ("t%d_%s"):format(j, mode)
		local fn = newfn(mode)
		local body = render(fn, root)
		tests[#tests + 1] = {name = name, fn = fn, body = body,
			ty = typeof(root), ft = root.ft, it = root.it}
	end
end

local function ctype(a) return a.ft and FT[a.ft].name or IT[a.it].name end

local function proto(h, name)
	local p = {}
	for j, a in ipairs(h.args) do p[j] = ctype(a) .. " a" .. j end
	return ("%s %s(%s)"):format(FT[h.ft].name, name, table.concat(p, ", "))
end

local function out(path, s)
	local f = assert(io.open(outdir .. "/" .. path, "w"))
	f:write(s)
	f:close()
end

local t = {"/* fp fuzz: target " .. target .. ", seed " .. seed .. " */",
	   "#include <stdarg.h>", ""}
for _, h in ipairs(helpers) do
	t[#t + 1] = proto(h, "x" .. h.name) .. ";"
	t[#t + 1] = "static " .. proto(h, h.name)
	t[#t + 1] = ("{\n\treturn a%d;\n}"):format(h.ret)
end
t[#t + 1] = [[
static double vaD(int n, ...)
{
	va_list ap;
	double r = 0;
	int i;

	va_start(ap, n);
	for (i = 0; i < n; i++)
		r = va_arg(ap, double);
	va_end(ap);
	return r;
}
]]
if tg.ld then
	t[#t + 1] = [[
static long double vaL(int n, ...)
{
	va_list ap;
	long double r = 0;
	int i;

	va_start(ap, n);
	for (i = 0; i < n; i++)
		r = va_arg(ap, long double);
	va_end(ap);
	return r;
}
]]
end
for _, g in ipairs(globals) do t[#t + 1] = g end
t[#t + 1] = ""

local m = {"#include <stdio.h>", "#include <string.h>", [[
static void pd(const char *n, double x)
{
	if (x != x) printf("%s nan\n", n);
	else printf("%s %a\n", n, x);
}

static void pf(const char *n, float x) { pd(n, x); }

static void pl(const char *n, long double x)
{
	unsigned char b[sizeof x];
	int i;

	if (x != x) { printf("%s nan\n", n); return; }
	memcpy(b, &x, sizeof x);
	printf("%s ", n);
	for (i = 9; i >= 0; i--) printf("%02x", b[i]);
	printf("\n");
}

static void ps(const char *n, long long x) { printf("%s %lld\n", n, x); }
static void pu(const char *n, unsigned long long x)
{
	printf("%s %llu\n", n, x);
}
]]}
if tg.i128 then
	m[#m + 1] = [[
static void po(const char *n, unsigned __int128 x)
{
	printf("%s 0x%016llx%016llx\n", n, (unsigned long long)(x >> 64),
	       (unsigned long long)x);
}
]]
end
for _, h in ipairs(helpers) do
	m[#m + 1] = proto(h, "x" .. h.name)
	m[#m + 1] = ("{\n\treturn a%d;\n}"):format(h.ret)
end
local calls = {}
for _, x in ipairs(tests) do
	if not keep or keep == x.name then
		t[#t + 1] = ("%s %s(%s)\n{"):format(x.ty, x.name,
			#x.fn.params > 0 and table.concat(x.fn.params, ", ")
			or "void")
		for _, s in ipairs(x.fn.pre) do t[#t + 1] = s end
		t[#t + 1] = "\treturn " .. x.body .. ";\n}\n"
		local pp = {}
		for j, p in ipairs(x.fn.params) do
			pp[j] = p:gsub(" p%d+$", "")
		end
		m[#m + 1] = ("%s %s(%s);"):format(x.ty, x.name,
			#pp > 0 and table.concat(pp, ", ") or "void")
		local pr
		if x.ft then pr = FT[x.ft].pr
		elseif IT[x.it].n == 128 then pr = "po"
		else pr = IT[x.it].s and "ps" or "pu" end
		calls[#calls + 1] = ("\t%s(\"%s\", %s(%s));"):format(pr, x.name,
			x.name, table.concat(x.fn.args, ", "))
	end
end
m[#m + 1] = "\nint main(void)\n{"
for _, c in ipairs(calls) do m[#m + 1] = c end
m[#m + 1] = "\treturn 0;\n}"

out("t.c", table.concat(t, "\n") .. "\n")
out("m.c", table.concat(m, "\n") .. "\n")
