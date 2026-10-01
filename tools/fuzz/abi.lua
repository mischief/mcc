-- SPDX-License-Identifier: ISC
-- Random calls between gcc and mcc.  Callers and callees go in two files,
-- each callee prints a hash of every argument, and the four builds (gcc
-- or mcc on each side) must print the same thing.  Commands: gen TARGET
-- SEED DIR, one TARGET SEED, check TARGET DIR, reduce TARGET DIR.
-- WORK holds failures and the runtime, MCCFLAGS goes to mcc, and
-- VALIST=1 also hands a va_list from one side to the other.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = os.getenv("MCC_ROOT") or
	io.popen("cd " .. here .. "/../.. && pwd"):read("l")
local WORK = os.getenv("WORK") or (os.getenv("HOME") .. "/.cache/mcc-abifuzz")
local MCCFLAGS = os.getenv("MCCFLAGS") or ""

local TOOL = {
	amd64   = {cc = "gcc", run = "", bits = 64},
	i386    = {cc = "gcc -m32 -msse2 -mfpmath=sse", run = "", bits = 32},
	arm64   = {cc = "aarch64-linux-gnu-gcc -static", run = "qemu-aarch64 ",
		   bits = 64},
	riscv64 = {cc = "riscv64-linux-gnu-gcc -static", run = "qemu-riscv64 ",
		   bits = 64},
}

local function sh(cmd)
	local p = io.popen("(" .. cmd .. ") 2>&1")
	local out = p:read("a")
	local ok = p:close()
	return ok, out
end

local function readfile(path)
	local f = io.open(path)
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

local function writefile(path, s)
	local f = assert(io.open(path, "w"))
	f:write(s)
	f:close()
end

-- ---- scalar types ----

-- What each scalar is called, how a value of it is written and hashed.
-- `kind` is int, ptr, flt or cplx; `fw` is the float part's width.
local SCALAR = {
	char = {c = "char", kind = "int", bits = 8, signed = true},
	schar = {c = "signed char", kind = "int", bits = 8, signed = true},
	uchar = {c = "unsigned char", kind = "int", bits = 8},
	short = {c = "short", kind = "int", bits = 16, signed = true},
	ushort = {c = "unsigned short", kind = "int", bits = 16},
	int = {c = "int", kind = "int", bits = 32, signed = true},
	uint = {c = "unsigned", kind = "int", bits = 32},
	long = {c = "long", kind = "int", bits = "long", signed = true},
	ulong = {c = "unsigned long", kind = "int", bits = "long"},
	llong = {c = "long long", kind = "int", bits = 64, signed = true},
	ullong = {c = "unsigned long long", kind = "int", bits = 64},
	bool = {c = "_Bool", kind = "int", bits = 1},
	i128 = {c = "__int128", kind = "int", bits = 128, signed = true},
	u128 = {c = "unsigned __int128", kind = "int", bits = 128},
	ptr = {c = "void *", kind = "ptr"},
	iptr = {c = "int *", kind = "ptr"},
	float = {c = "float", kind = "flt", fw = 4},
	double = {c = "double", kind = "flt", fw = 8},
	ldouble = {c = "long double", kind = "flt", fw = 10, fsz = 16},
	cfloat = {c = "float _Complex", kind = "cplx", fw = 4, fsz = 4,
		  part = "float"},
	cdouble = {c = "double _Complex", kind = "cplx", fw = 8, fsz = 8,
		   part = "double"},
	cldouble = {c = "long double _Complex", kind = "cplx", fw = 10,
		    fsz = 16, part = "long double"},
}

-- Which scalars a target has that both compilers lay out alike.  mcc's
-- long double is the x87 type only on amd64; elsewhere it is a double.
local function scalars(target)
	local s = {"char", "schar", "uchar", "short", "ushort", "int", "uint",
		   "long", "ulong", "llong", "ullong", "bool", "ptr", "iptr",
		   "float", "double", "cfloat", "cdouble"}
	if TOOL[target].bits == 64 then
		s[#s + 1] = "i128"
		s[#s + 1] = "u128"
	end
	if target == "amd64" then
		s[#s + 1] = "ldouble"
		s[#s + 1] = "cldouble"
	end
	return s
end

-- What a variadic argument of a scalar type arrives as.
local PROMOTE = {char = "int", schar = "int", uchar = "int", short = "int",
		 ushort = "int", bool = "int", float = "double"}

-- ---- the random program ----

local R = math.random

local function pick(t) return t[R(#t)] end

-- A type is {s = name} for a scalar or {r = index} for a record.
-- A record is {union = bool, members = {{ty, dims, align}}, active}.
local function gen(target, seed)
	math.randomseed(seed)
	local sc = scalars(target)
	local ints, flts = {}, {}
	for _, n in ipairs(sc) do
		if SCALAR[n].kind == "flt" or SCALAR[n].kind == "cplx" then
			flts[#flts + 1] = n
		else
			ints[#ints + 1] = n
		end
	end
	local spec = {target = target, seed = seed, recs = {}, funcs = {}}
	local recs = spec.recs

	local function scalar()
		if R() < 0.35 then return {s = pick(flts)} end
		return {s = pick(ints)}
	end

	local function dims()
		local x = R()
		if x < 0.7 then return nil end
		if x < 0.73 then return {0} end
		if x < 0.9 then return {R(4)} end
		if x < 0.95 then return {R(3), R(3)} end
		return {R(17)}
	end

	local function member(depth)
		if #recs > 0 and depth > 0 and R() < 0.3 then
			return {r = R(#recs)}
		end
		return scalar()
	end

	local function newrec()
		local r = {members = {}}
		local m = r.members
		local style = R()
		if style < 0.15 then
			-- one float type, up to five of it in all
			local b = pick({"float", "double", "float", "double",
					"cfloat", "cdouble"})
			local left = R(5)
			while left > 0 do
				local n = R(left)
				m[#m + 1] = {ty = {s = b},
					     dims = (n > 1 or R() < 0.2) and {n} or nil}
				left = left - n
			end
		elseif style < 0.35 then
			-- floats and integers side by side
			for i = 1, R(2, 4) do
				m[#m + 1] = {ty = {s = (i + R(0, 1)) % 2 == 0 and
					pick(flts) or pick(ints)}}
			end
		elseif style < 0.45 then
			-- bytes, an odd number of them
			local c = pick({"char", "uchar", "short"})
			m[1] = {ty = {s = c}, dims = {R(33)}}
			if R() < 0.4 then m[2] = {ty = {s = "char"}} end
		elseif style < 0.48 then
			-- nothing at all, or a zero-length array
			if R() < 0.5 then m[1] = {ty = {s = "int"}, dims = {0}} end
		elseif style < 0.55 and #recs > 0 then
			-- a wrapper around another record
			m[1] = {ty = {r = R(#recs)}}
			if R() < 0.3 then m[1].dims = {R(2)} end
		else
			for _ = 1, R(6) do
				m[#m + 1] = {ty = member(2), dims = dims()}
			end
		end
		if R() < 0.15 and #m > 1 then
			r.union = true
			r.active = R(#m)
		end
		if R() < 0.05 and #m > 0 then
			m[R(#m)].align = pick({8, 16})
		end
		return r
	end

	for _ = 1, R(3, 10) do recs[#recs + 1] = newrec() end

	local function argtype()
		if R() < 0.45 then return {r = R(#recs)} end
		return scalar()
	end

	local valist = os.getenv("VALIST") == "1"
	for _ = 1, R(4, 10) do
		local f = {params = {}}
		local x = R()
		if x < 0.15 then f.ret = nil
		elseif x < 0.5 then f.ret = scalar()
		else f.ret = {r = R(#recs)} end
		local n = R() < 0.5 and R(0, 8) or R(0, 20)
		for i = 1, n do f.params[i] = argtype() end
		if n > 0 and R() < 0.3 then
			f.va = {}
			for i = 1, R(0, 10) do f.va[i] = argtype() end
			if valist and R() < 0.3 then f.valist = true end
		end
		spec.funcs[#spec.funcs + 1] = f
	end
	return spec
end

-- ---- writing it out ----

local function tname(ty)
	if ty.s then return SCALAR[ty.s].c end
	return (ty.u and "union" or "struct") .. " S" .. ty.r
end

-- Every scalar a value is made of, as a path from the value and the
-- scalar's name: struct members, array elements and a union's active
-- member, but never padding.
local function leaves(spec, ty, path, out)
	if ty.s then
		out[#out + 1] = {path = path, s = ty.s}
		return out
	end
	local rec = spec.recs[ty.r]
	for i, m in ipairs(rec.members) do
		if not rec.union or rec.active == i then
			local function elem(p, d)
				if not m.dims or d > #m.dims then
					leaves(spec, m.ty, p, out)
					return
				end
				for k = 0, m.dims[d] - 1 do
					elem(p .. "[" .. k .. "]", d + 1)
				end
			end
			elem(path .. ".m" .. (i - 1), 1)
		end
	end
	return out
end

-- A deterministic value for a key, so a spec writes the same program
-- each time and a reduced one keeps its values where it can.
local function hashkey(key)
	local h = 0xcbf29ce484222325
	for i = 1, #key do
		h = (h ~ key:byte(i)) * 0x100000001b3
	end
	h = h ~ (h >> 29)
	h = h * 0xbf58476d1ce4e5b9
	return h ~ (h >> 32)
end

-- A float literal of the given width: an integer times a power of two,
-- written in hex so that both compilers read the same bits.
local function fltlit(h, fw)
	local mant, suf = 20, "f"
	if fw == 8 then mant, suf = 50, "" end
	if fw == 10 then mant, suf = 62, "L" end
	local m = (h >> 2) & ((1 << mant) - 1)
	if mant == 62 then m = (h >> 2) & 0x3fffffffffffffff end
	local e = -((h >> 1) % 40) - mant // 2
	local sign = (h & 1) == 1 and "-" or ""
	return ("%s0x%xp%d%s"):format(sign, m, e, suf)
end

local function intlit(h, s, bits)
	if s == "bool" then return tostring(h & 1) end
	if bits == "long" then bits = 64 end
	if bits == 128 then
		return ("(((%s)0x%xULL << 64) | 0x%xULL)")
			:format(SCALAR[s].c, h, hashkey(tostring(h)))
	end
	local v = bits == 64 and h or h & ((1 << bits) - 1)
	return ("(%s)0x%xULL"):format(SCALAR[s].c, v)
end

-- The statements that set every leaf of the value at `path`.
local function fill(spec, ty, path, key, out, ind)
	for i, l in ipairs(leaves(spec, ty, path, {})) do
		local h = hashkey(key .. ":" .. i)
		local s = SCALAR[l.s]
		if s.kind == "int" then
			out[#out + 1] = ("%s%s = %s;"):format(ind, l.path,
				intlit(h, l.s, s.bits))
		elseif s.kind == "ptr" then
			out[#out + 1] = ("%s%s = (%s)0x%xUL;"):format(ind,
				l.path, s.c, (h & 0x7ffffff0))
		elseif s.kind == "flt" then
			out[#out + 1] = ("%s%s = %s;"):format(ind, l.path,
				fltlit(h, s.fw))
		else
			out[#out + 1] = ("%s((%s *)&%s)[0] = %s;"):format(ind,
				s.part, l.path, fltlit(h, s.fw))
			out[#out + 1] = ("%s((%s *)&%s)[1] = %s;"):format(ind,
				s.part, l.path, fltlit(hashkey(tostring(h)), s.fw))
		end
	end
end

-- The expression that hashes the scalar at `path` into h.
local function hashleaf(s, path)
	local sd = SCALAR[s]
	if sd.kind == "int" then
		if sd.bits == 128 then
			return ("h = hmix(hmix(h, (unsigned long long)%s), " ..
				"(unsigned long long)(%s >> 64));"):format(path, path)
		end
		return ("h = hmix(h, (unsigned long long)%s);"):format(path)
	elseif sd.kind == "ptr" then
		return ("h = hmix(h, (unsigned long)%s);"):format(path)
	elseif sd.kind == "flt" then
		return ("h = hb(h, &%s, %d);"):format(path, sd.fw)
	end
	return ("h = hb(h, &%s, %d); h = hb(h, (const char *)&%s + %d, %d);")
		:format(path, sd.fw, path, sd.fsz, sd.fw)
end

local function hashcall(ty, var)
	if ty.s then return hashleaf(ty.s, var) end
	return ("h = h_S%d(h, &%s);"):format(ty.r, var)
end

-- Which records a spec still uses, and each record's union flag on its
-- types, so tname can say union.
local function prepare(spec)
	local function mark(ty)
		if ty and ty.r then ty.u = spec.recs[ty.r].union or nil end
	end
	for _, r in ipairs(spec.recs) do
		for _, m in ipairs(r.members) do mark(m.ty) end
	end
	for _, f in ipairs(spec.funcs) do
		mark(f.ret)
		for _, p in ipairs(f.params) do mark(p) end
		for _, p in ipairs(f.va or {}) do mark(p) end
	end
end

local function proto(f, i, name)
	local ps = {}
	for k, p in ipairs(f.params) do
		ps[k] = tname(p) .. " a" .. (k - 1)
	end
	if f.valist then ps[#ps + 1] = "va_list ap"
	elseif f.va then ps[#ps + 1] = "..." end
	if #ps == 0 then ps[1] = "void" end
	return ("%s %s%d(%s)"):format(f.ret and tname(f.ret) or "void",
		name or "f", i, table.concat(ps, ", "))
end

-- The variadic type a value of `ty` is read back as.
local function vatype(ty)
	if ty.s and PROMOTE[ty.s] then return {s = PROMOTE[ty.s]} end
	return ty
end

local function emit(spec, dir)
	prepare(spec)
	local h = {"/* abi fuzz: target " .. spec.target .. ", seed " ..
		   spec.seed .. " */", "#include <stdarg.h>",
		   "void abi_out(int f, int a, unsigned long long h);",
		   "static unsigned long long hmix(unsigned long long h, " ..
		   "unsigned long long v)",
		   "{\n\treturn (h ^ v) * 0x100000001b3ULL;\n}",
		   "static unsigned long long hb(unsigned long long h, " ..
		   "const void *p, int n)",
		   "{\n\tconst unsigned char *c = p;\n\n\twhile (n-- > 0)\n" ..
		   "\t\th = hmix(h, *c++);\n\treturn h;\n}"}
	for i, r in ipairs(spec.recs) do
		local b = {(r.union and "union" or "struct") .. " S" .. i .. " {"}
		for k, m in ipairs(r.members) do
			local d = ""
			for _, n in ipairs(m.dims or {}) do d = d .. "[" .. n .. "]" end
			b[#b + 1] = ("\t%s m%d%s%s;"):format(tname(m.ty), k - 1, d,
				m.align and (" __attribute__((aligned(" ..
					m.align .. ")))") or "")
		end
		b[#b + 1] = "};"
		h[#h + 1] = table.concat(b, "\n")
		local fn = {("static unsigned long long h_S%d(unsigned long " ..
			"long h, const %s *p)\n{"):format(i, tname({r = i,
			u = r.union}))}
		for _, l in ipairs(leaves(spec, {r = i}, "(*p)", {})) do
			fn[#fn + 1] = "\t" .. hashleaf(l.s, l.path)
		end
		fn[#fn + 1] = "\treturn h;\n}"
		h[#h + 1] = table.concat(fn, "\n")
	end
	for i, f in ipairs(spec.funcs) do
		h[#h + 1] = proto(f, i) .. ";"
	end
	writefile(dir .. "/t.h", table.concat(h, "\n") .. "\n")

	-- callees
	local c = {'#include "t.h"'}
	for i, f in ipairs(spec.funcs) do
		c[#c + 1] = proto(f, i) .. "\n{\n\tunsigned long long h;"
		if f.va and not f.valist then c[#c + 1] = "\tva_list ap;" end
		for k, p in ipairs(f.params) do
			c[#c + 1] = "\th = 0xcbf29ce484222325ULL;\n\t" ..
				hashcall(p, "a" .. (k - 1)) ..
				("\n\tabi_out(%d, %d, h);"):format(i, k - 1)
		end
		if f.va then
			if not f.valist then
				c[#c + 1] = "\tva_start(ap, a" .. (#f.params - 1) .. ");"
			end
			for k, p in ipairs(f.va) do
				local vt = vatype(p)
				c[#c + 1] = ("\t{\n\t\t%s v = va_arg(ap, %s);\n\n" ..
					"\t\th = 0xcbf29ce484222325ULL;\n\t\t%s\n" ..
					"\t\tabi_out(%d, %d, h);\n\t}")
					:format(tname(vt), tname(vt), hashcall(vt, "v"),
						i, 100 + k - 1)
			end
			if not f.valist then c[#c + 1] = "\tva_end(ap);" end
		end
		if f.ret then
			c[#c + 1] = "\t{\n\t\t" .. tname(f.ret) .. " r;\n"
			local out = {}
			fill(spec, f.ret, "r", "r" .. i, out, "\t\t")
			c[#c + 1] = table.concat(out, "\n")
			c[#c + 1] = "\t\treturn r;\n\t}"
		end
		c[#c + 1] = "}"
	end
	writefile(dir .. "/callee.c", table.concat(c, "\n") .. "\n")

	-- callers
	c = {'#include "t.h"'}
	for i, f in ipairs(spec.funcs) do
		if f.valist then
			-- a variadic wrapper here hands its list to the callee
			local ps, as = {}, {}
			for k, p in ipairs(f.params) do
				ps[k] = tname(p) .. " a" .. (k - 1)
				as[k] = "a" .. (k - 1)
			end
			as[#as + 1] = "ap"
			c[#c + 1] = ("static %s w%d(%s, ...)\n{\n\tva_list ap;\n")
				:format(f.ret and tname(f.ret) or "void", i,
					table.concat(ps, ", "))
			if f.ret then
				c[#c + 1] = "\t" .. tname(f.ret) .. " r;\n"
			end
			c[#c + 1] = ("\tva_start(ap, a%d);\n\t%sf%d(%s);\n" ..
				"\tva_end(ap);"):format(#f.params - 1,
				f.ret and "r = " or "", i, table.concat(as, ", "))
			if f.ret then c[#c + 1] = "\treturn r;" end
			c[#c + 1] = "}"
		end
	end
	c[#c + 1] = "int main(void)\n{"
	for i, f in ipairs(spec.funcs) do
		local b, as = {"\t{"}, {}
		for k, p in ipairs(f.params) do
			b[#b + 1] = ("\t\t%s a%d;"):format(tname(p), k - 1)
			as[k] = "a" .. (k - 1)
		end
		for k, p in ipairs(f.va or {}) do
			b[#b + 1] = ("\t\t%s v%d;"):format(tname(p), k - 1)
			as[#as + 1] = "v" .. (k - 1)
		end
		if f.ret then b[#b + 1] = "\t\t" .. tname(f.ret) .. " r;" end
		b[#b + 1] = "\t\tunsigned long long h = 0xcbf29ce484222325ULL;\n"
		for k, p in ipairs(f.params) do
			fill(spec, p, "a" .. (k - 1), i .. "a" .. k, b, "\t\t")
		end
		for k, p in ipairs(f.va or {}) do
			fill(spec, p, "v" .. (k - 1), i .. "v" .. k, b, "\t\t")
		end
		b[#b + 1] = ("\t\t%s%s%d(%s);"):format(f.ret and "r = " or "",
			f.valist and "w" or "f", i, table.concat(as, ", "))
		if f.ret then
			b[#b + 1] = "\t\t" .. hashcall(f.ret, "r")
		end
		b[#b + 1] = ("\t\tabi_out(%d, -1, h);\n\t}"):format(i)
		c[#c + 1] = table.concat(b, "\n")
	end
	c[#c + 1] = "\treturn 0;\n}"
	writefile(dir .. "/caller.c", table.concat(c, "\n") .. "\n")

	writefile(dir .. "/helper.c", [[
#include <stdio.h>
void abi_out(int f, int a, unsigned long long h)
{
	printf("f%d a%d %016llx\n", f, a, h);
}
]])
end

-- ---- the spec on disk ----

local function ser(v, ind)
	ind = ind or ""
	if type(v) ~= "table" then
		return type(v) == "string" and ("%q"):format(v) or tostring(v)
	end
	local keys, b = {}, {}
	for k in pairs(v) do
		if k ~= "u" then keys[#keys + 1] = k end
	end
	table.sort(keys, function(a, c)
		if type(a) == type(c) then return a < c end
		return type(a) == "number"
	end)
	for _, k in ipairs(keys) do
		local ks = type(k) == "number" and "[" .. k .. "]" or k
		b[#b + 1] = ind .. "  " .. ks .. " = " .. ser(v[k], ind .. "  ")
	end
	return "{\n" .. table.concat(b, ",\n") .. "\n" .. ind .. "}"
end

local function save(spec, dir)
	writefile(dir .. "/spec.lua", "return " .. ser(spec) .. "\n")
end

local function load_spec(dir)
	return assert(load(readfile(dir .. "/spec.lua")))()
end

-- ---- building and running ----

-- The runtime mcc's code calls into, built once per target by its gcc.
local function rtlib(target)
	local lib = WORK .. "/" .. target .. "/rt.a"
	if readfile(lib) then return lib end
	local d = WORK .. "/" .. target .. "/rt.tmp" .. os.time() .. math.random(1e6)
	os.execute("mkdir -p " .. d)
	local objs = {}
	for _, f in ipairs({"softfp", "varargs", "bits", "atomic", "half",
			    "wide", "widefp"}) do
		local ok, out = sh(("%s -w -O2 -c %s/rt/%s.c -o %s/%s.o")
			:format(TOOL[target].cc, root, f, d, f))
		if not ok then error("runtime: " .. out) end
		objs[#objs + 1] = d .. "/" .. f .. ".o"
	end
	sh("ar rcs " .. d .. "/rt.a " .. table.concat(objs, " ") ..
	   " && mv " .. d .. "/rt.a " .. lib .. " && rm -rf " .. d)
	return lib
end

-- Build and run the four combinations in dir, or the reference and the
-- one build `only` names.  Answers the reference output (nil when gcc
-- alone fails) and, for each mcc build, "ok" or what went wrong.
local function check(target, dir, only)
	local t = TOOL[target]
	local lib = rtlib(target)
	local cc = t.cc .. " -w -Wno-psabi -O2 -fno-strict-aliasing"
	local function try(cmd)
		local ok, out = sh("cd " .. dir .. " && " .. cmd)
		return ok, out
	end
	local ok, out = try(cc .. " -c helper.c && " .. cc ..
		" -c caller.c -o caller.g.o && " .. cc ..
		" -c callee.c -o callee.g.o")
	if not ok then return nil, "gcc: " .. out end
	local mcc = ("lua5.4 %s/cc.lua -t %s %s -I%s/include"):format(root,
		target, MCCFLAGS, root)
	local mok = {}
	for k, f in ipairs({"caller", "callee"}) do
		if not only or only:sub(k, k) == "m" then
			ok, out = try(("%s %s.c -o %s.m.s && " ..
				"%s -c %s.m.s -o %s.m.o")
				:format(mcc, f, f, t.cc, f, f))
			mok[f] = ok or out
		end
	end
	local res, ref = {}, nil
	for _, b in ipairs(only and {"gg", only} or {"gg", "mg", "gm", "mm"}) do
		local a = b:sub(1, 1) == "m" and "caller.m.o" or "caller.g.o"
		local e = b:sub(2, 2) == "m" and "callee.m.o" or "callee.g.o"
		local bad = (b:sub(1, 1) == "m" and mok.caller ~= true and
			     mok.caller) or
			    (b:sub(2, 2) == "m" and mok.callee ~= true and
			     mok.callee)
		if bad then
			res[b] = {what = "build", out = bad}
		else
			ok, out = try(("%s -w helper.o %s %s %s -lm -o %s")
				:format(t.cc, a, e, lib, b))
			if not ok then
				res[b] = {what = "link", out = out}
			else
				local rok
				rok, out = try("timeout 30 " .. t.run .. "./" .. b)
				res[b] = {what = rok and "ok" or "crash", out = out}
			end
		end
		if b == "gg" then
			if res.gg.what ~= "ok" then return nil, res.gg.out end
			ref = res.gg.out
		elseif res[b].what == "ok" and res[b].out ~= ref then
			res[b].what = "diff"
		end
	end
	res.gg = nil
	return ref, res
end

-- The first line where a build's output leaves the reference.
local function firstdiff(ref, out)
	local a, b = {}, {}
	for l in ref:gmatch("[^\n]*") do a[#a + 1] = l end
	for l in out:gmatch("[^\n]*") do b[#b + 1] = l end
	for i = 1, math.max(#a, #b) do
		if a[i] ~= b[i] then return a[i], b[i] end
	end
end

-- A one-line verdict: the builds that fail and how.
local function verdict(res)
	local v = {}
	for _, b in ipairs({"mg", "gm", "mm"}) do
		if res[b].what ~= "ok" then v[#v + 1] = b .. ":" .. res[b].what end
	end
	return #v == 0 and "ok" or table.concat(v, " ")
end

-- ---- reducing ----

local function copy(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = copy(x) end
	return t
end

-- Drop records nothing uses, and number the rest from one again.
local function prune(spec)
	local used = {}
	local function use(ty)
		if ty and ty.r and not used[ty.r] then
			used[ty.r] = true
			for _, m in ipairs(spec.recs[ty.r].members) do use(m.ty) end
		end
	end
	for _, f in ipairs(spec.funcs) do
		use(f.ret)
		for _, p in ipairs(f.params) do use(p) end
		for _, p in ipairs(f.va or {}) do use(p) end
	end
	local map, recs = {}, {}
	for i, r in ipairs(spec.recs) do
		if used[i] then recs[#recs + 1] = r; map[i] = #recs end
	end
	local function ren(ty) if ty and ty.r then ty.r = map[ty.r] end end
	for _, r in ipairs(recs) do
		for _, m in ipairs(r.members) do ren(m.ty) end
	end
	for _, f in ipairs(spec.funcs) do
		ren(f.ret)
		for _, p in ipairs(f.params) do ren(p) end
		for _, p in ipairs(f.va or {}) do ren(p) end
	end
	spec.recs = recs
	return spec
end

-- Every smaller spec one step away from this one.
local function candidates(spec)
	local out = {}
	local function add(fn)
		local s = copy(spec)
		if fn(s) ~= false then out[#out + 1] = s end
	end
	for i = 1, #spec.funcs do
		if #spec.funcs > 1 then
			add(function(s) table.remove(s.funcs, i) end)
		end
	end
	-- Half a long parameter list at a time, before one at a time.
	for i, f in ipairs(spec.funcs) do
		local n = #f.params
		if n >= 4 then
			local h = n // 2
			add(function(s)
				for _ = 1, h do table.remove(s.funcs[i].params) end
				if f.va and #s.funcs[i].params == 0 then
					return false
				end
			end)
			add(function(s)
				for _ = 1, h do table.remove(s.funcs[i].params, 1) end
			end)
		end
	end
	for i, f in ipairs(spec.funcs) do
		if f.va then
			add(function(s) s.funcs[i].va = nil; s.funcs[i].valist = nil end)
			for k = #f.va, 1, -1 do
				add(function(s) table.remove(s.funcs[i].va, k) end)
			end
		end
		for k = #f.params, 1, -1 do
			if not (f.va and #f.params == 1) then
				add(function(s) table.remove(s.funcs[i].params, k) end)
			end
		end
		if f.ret then
			add(function(s) s.funcs[i].ret = nil end)
		end
		local function simpler(get, set)
			local ty = get()
			if ty.r then
				local rec = spec.recs[ty.r]
				-- a record that holds one value becomes that value
				if #rec.members == 1 and not rec.members[1].dims then
					add(function(s) set(s, copy(rec.members[1].ty)) end)
				end
			end
			if not (ty.s == "int") then
				add(function(s) set(s, {s = "int"}) end)
			end
		end
		if f.ret then
			simpler(function() return f.ret end,
				function(s, t) s.funcs[i].ret = t end)
		end
		for k, p in ipairs(f.params) do
			simpler(function() return p end,
				function(s, t) s.funcs[i].params[k] = t end)
		end
		for k, p in ipairs(f.va or {}) do
			simpler(function() return p end,
				function(s, t) s.funcs[i].va[k] = t end)
		end
	end
	for i, r in ipairs(spec.recs) do
		for k, m in ipairs(r.members) do
			add(function(s)
				local rr = s.recs[i]
				table.remove(rr.members, k)
				if rr.union then
					if rr.active == k then return false end
					if rr.active > k then rr.active = rr.active - 1 end
				end
			end)
			if m.dims then
				add(function(s) s.recs[i].members[k].dims = nil end)
				for d, n in ipairs(m.dims) do
					if n > 1 then
						add(function(s)
							s.recs[i].members[k].dims[d] = n // 2
						end)
					end
				end
			end
			if m.align then
				add(function(s) s.recs[i].members[k].align = nil end)
			end
			if m.ty.r then
				local sub = spec.recs[m.ty.r]
				if #sub.members == 1 and not sub.members[1].dims then
					add(function(s)
						s.recs[i].members[k].ty =
							copy(sub.members[1].ty)
					end)
				end
			elseif m.ty.s ~= "int" and m.ty.s ~= "char" then
				add(function(s) s.recs[i].members[k].ty = {s = "char"} end)
			end
		end
		if r.union then
			add(function(s)
				s.recs[i].union = nil
				s.recs[i].active = nil
			end)
		end
	end
	return out
end

-- Shrink the spec in dir while the same builds still fail the same way.
local function reduce(target, dir)
	local spec = load_spec(dir)
	local ref0, res = check(target, dir)
	local want = ref0 and verdict(res) or "ok"
	if want == "ok" then
		print("does not fail")
		return
	end
	-- The reduction keeps the first build that fails failing the
	-- same way, and runs only that one.
	local key
	for _, b in ipairs({"mg", "gm", "mm"}) do
		if res[b].what ~= "ok" then key = key or b end
	end
	local what = res[key].what
	local function same(c)
		prune(c)
		emit(c, dir .. "/try")
		local ref, r = check(target, dir .. "/try", key)
		return ref and r[key].what == what
	end
	local tmp = dir .. "/try"
	os.execute("mkdir -p " .. tmp)
	-- First try the one function whose output goes wrong on its own.
	for _, b in ipairs({"mg", "gm", "mm"}) do
		local a = firstdiff(ref0, res[b].out or "")
		local fn = a and tonumber(a:match("^f(%d+)"))
		if res[b].what ~= "ok" and fn and #spec.funcs > 1 then
			local c = copy(spec)
			c.funcs = {c.funcs[fn]}
			if same(c) then spec = c end
			break
		end
	end
	local progress = true
	while progress do
		progress = false
		for _, c in ipairs(candidates(spec)) do
			if same(c) then
				spec = c
				progress = true
				break
			end
		end
	end
	os.execute("rm -rf " .. tmp)
	local red = dir .. "/reduced"
	os.execute("mkdir -p " .. red)
	emit(spec, red)
	save(spec, red)
	local ref, r = check(target, red)
	local f = {"verdict: " .. want}
	for _, b in ipairs({"mg", "gm", "mm"}) do
		if r[b].what == "diff" or r[b].what == "crash" then
			local a, x = firstdiff(ref, r[b].out)
			f[#f + 1] = ("%s: gcc %s, got %s"):format(b, tostring(a),
				tostring(x))
		elseif r[b].what ~= "ok" then
			f[#f + 1] = b .. ": " .. r[b].out:sub(1, 400)
		end
	end
	writefile(red .. "/verdict", table.concat(f, "\n") .. "\n")
	print(table.concat(f, "\n"))
end

-- ---- commands ----

local cmd, target = arg[1], arg[2]
if not TOOL[target or ""] then
	io.stderr:write("usage: abi.lua gen|one|check|reduce TARGET ...\n")
	os.exit(2)
end

if cmd == "gen" then
	local seed, dir = tonumber(arg[3]), arg[4]
	os.execute("mkdir -p " .. dir)
	local spec = gen(target, seed)
	save(spec, dir)
	emit(spec, dir)
elseif cmd == "check" then
	local dir = arg[3]
	emit(load_spec(dir), dir)
	local ref, res = check(target, dir)
	if not ref then print("reference fails: " .. tostring(res)); os.exit(1) end
	print(verdict(res))
	for _, b in ipairs({"mg", "gm", "mm"}) do
		if res[b].what ~= "ok" then
			local a, x = firstdiff(ref, res[b].out)
			print(("%s %s: gcc %s, got %s"):format(b, res[b].what,
				tostring(a), tostring(x)))
		end
	end
elseif cmd == "one" then
	local seed = tonumber(arg[3])
	local dir = io.popen("mktemp -d"):read("l")
	local spec = gen(target, seed)
	save(spec, dir)
	emit(spec, dir)
	local ref, res = check(target, dir)
	local v = ref and verdict(res) or "skip"
	print(seed .. " " .. v)
	if v ~= "ok" and v ~= "skip" then
		local keep = WORK .. "/" .. target .. "/fail/" .. seed
		os.execute("rm -rf " .. keep .. " && mkdir -p " .. keep ..
			" && cp " .. dir .. "/spec.lua " .. dir .. "/*.c " ..
			dir .. "/t.h " .. keep)
	elseif v == "skip" then
		io.stderr:write(seed .. " reference: " ..
			tostring(res):sub(1, 300) .. "\n")
	end
	os.execute("rm -rf " .. dir)
elseif cmd == "reduce" then
	reduce(target, arg[3])
else
	io.stderr:write("no command " .. tostring(cmd) .. "\n")
	os.exit(2)
end
