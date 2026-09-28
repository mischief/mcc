-- SPDX-License-Identifier: ISC
-- The builtins: bit counting, byte swaps, overflow checks, the __sync
-- and __atomic families, and float classes.

local tree = require "mcc.tree"
local buf = require "mcc.buf"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local bitcount = cf.bitcount
local fold = cf.fold
local isflt = cf.isflt
local isptr = cf.isptr
local isrec = cf.isrec
local reaches = cf.reaches

-- Counting bits.  Each one folds when its argument is a constant, which
-- is the only way a register field macro works out its shift; otherwise
-- it is a call under the name a compiler runtime gives it.  `w` is how
-- wide the argument is in bytes.
local BITFN = {
	ffs = {4, "__ffssi2"}, ffsl = {8, "__ffsdi2"},
	ffsll = {8, "__ffsdi2"},
	clz = {4, "__clzsi2"}, clzl = {8, "__clzdi2"},
	clzll = {8, "__clzdi2"},
	ctz = {4, "__ctzsi2"}, ctzl = {8, "__ctzdi2"},
	ctzll = {8, "__ctzdi2"},
	popcount = {4, "__popcountsi2"}, popcountl = {8, "__popcountdi2"},
	popcountll = {8, "__popcountdi2"},
	parity = {4, "__paritysi2"}, parityl = {8, "__paritydi2"},
	parityll = {8, "__paritydi2"},
}

local BUILTIN = {}
for _, k in ipairs{"__builtin_huge_val", "__builtin_huge_valf",
		   "__builtin_inf", "__builtin_inff", "__builtin_nan",
		   "__builtin_expect", "__builtin_fabs", "__builtin_fabsf",
		   "__builtin_sqrt", "__builtin_sqrtf", "__builtin_floor",
		   "__builtin_ceil", "__builtin_bswap16",
		   "__builtin_bswap32", "__builtin_bswap64",
		   "__builtin_abs", "__builtin_labs", "__builtin_llabs",
		   "__builtin_memcpy", "__builtin_memmove",
		   "__builtin_memset", "__builtin_memcmp",
		   "__builtin_strlen", "__builtin_strcmp",
		   "__builtin_strncmp",
		   "__builtin_strcpy", "__builtin_strncpy",
		   "__builtin_prefetch", "__builtin_alloca",
		   "__builtin_add_overflow", "__builtin_sub_overflow",
		   "__builtin_mul_overflow", "__builtin_object_size",
		   "__builtin_dynamic_object_size",
		   "__builtin_return_address",
		   "__builtin_extract_return_addr",
		   "__builtin_frob_return_addr",
		   "__builtin_frame_address",
		   "__builtin_wasm_memory_size",
		   "__builtin_wasm_memory_grow"} do
	BUILTIN[k] = true
end
-- Classifying a float is a test on its bit pattern, so it goes to the
-- runtime like the arithmetic does rather than to libm.
local FCLASS = {isnan = "isnan", isinf = "isinf", isfinite = "isfin",
		isinf_sign = "isinfs", signbit = "isneg",
		isnormal = "isnorm"}
local FCMP = {isgreater = "GT", isgreaterequal = "GE", isless = "LT",
	      islessequal = "LE", islessgreater = "LG", isunordered = "UN"}

-- A float classified from its bits, which needs no call.  The value goes
-- to a slot and is read back as an integer: the sign, a field of
-- exponent, and the fraction.  The x87 type writes its integer bit out,
-- so its fraction is the sixty-three bits below that.
local FBITS = {
	[4] = {bits = "u32", ebits = 8, fbits = 23},
	[8] = {bits = "u64", ebits = 11, fbits = 52},
}

function P:fclass(fc, a)
	local i32 = self.ty.i32
	local off = self:temp(a.ty)
	local ex, frac, neg, emax

	self.irno[off] = true
	local set = self:assignto(tree.auto(a.ty, off), a)
	if a.ty.x87 then
		self.irno[off + 8] = true
		local function se()
			return self:conv(tree.auto(self.ty.u16, off + 8), i32)
		end
		emax = 0x7fff
		ex = function()
			return self:arith("AND", se(), tree.const(i32, emax))
		end
		frac = function()
			return self:arith("AND", tree.auto(self.ty.u64, off),
				tree.const(self.ty.u64, 0x7fffffffffffffff))
		end
		neg = function()
			return self:arith("NE", self:arith("AND", se(),
				tree.const(i32, 0x8000)), tree.const(i32, 0))
		end
	else
		local l = FBITS[a.ty.size]
		local bt = self.ty[l.bits]
		local function b() return tree.auto(bt, off) end

		emax = (1 << l.ebits) - 1
		ex = function()
			return self:conv(self:arith("AND", self:arith("SHR", b(),
				tree.const(i32, l.fbits)), tree.const(bt, emax)),
				i32)
		end
		frac = function()
			return self:arith("AND", b(),
				tree.const(bt, (1 << l.fbits) - 1))
		end
		neg = function()
			return self:arith("NE", self:arith("SHR", b(),
				tree.const(i32, l.ebits + l.fbits)),
				tree.const(bt, 0))
		end
	end
	local function zero(t) return tree.const(t.ty, 0) end
	local function top()
		return self:arith("EQ", ex(), tree.const(i32, emax))
	end
	local function inf()
		local f = frac()

		return tree.node("ANDAND", i32, top(),
			self:arith("EQ", f, zero(f)))
	end
	local r

	if fc == "isnan" then
		local f = frac()

		r = tree.node("ANDAND", i32, top(), self:arith("NE", f, zero(f)))
	elseif fc == "isinf" then
		r = inf()
	elseif fc == "isfin" then
		r = self:arith("NE", ex(), tree.const(i32, emax))
	elseif fc == "isneg" then
		r = neg()
	elseif fc == "isnorm" then
		r = tree.node("ANDAND", i32,
			self:arith("NE", ex(), tree.const(i32, emax)),
			self:arith("NE", ex(), tree.const(i32, 0)))
	else
		-- isinf_sign: -1 or 1 for an infinity, else 0.
		r = self:arith("MUL", self:conv(inf(), i32),
			self:arith("SUB", tree.const(i32, 1),
				self:arith("MUL", tree.const(i32, 2),
					self:conv(neg(), i32))))
	end
	return tree.node("SEQ", i32, nil, nil, {arms = {set, r}})
end

-- x with the sign of y, in the bits.  The top byte holds the sign on
-- every format here, the x87 one included.
function P:copysign(x, y, ty)
	local sz = ty.x87 and 10 or ty.size
	local ox, oy = self:temp(ty), self:temp(ty)
	local u8 = self.ty.u8
	local at = sz - 1

	self.irno[ox] = true
	self.irno[oy] = true
	self.irno[ox + at] = true
	self.irno[oy + at] = true
	local function byte(o) return tree.auto(u8, o + at) end
	local sign = self:arith("AND", byte(oy), tree.const(self.ty.i32, 0x80))
	local rest = self:arith("AND", byte(ox), tree.const(self.ty.i32, 0x7f))

	return tree.node("SEQ", ty, nil, nil, {arms = {
		self:assignto(tree.auto(ty, ox), self:conv(x, ty)),
		self:assignto(tree.auto(ty, oy), self:conv(y, ty)),
		self:assignto(byte(ox), self:arith("OR", sign, rest)),
		tree.auto(ty, ox)}})
end

-- The `__sync_` family, which is older than C11 atomics and is what
-- a kernel driver written before them uses.  Each is sequentially
-- consistent, and each answers in the type the pointer points at.
-- The value is the operation the runtime is told to do, where one
-- takes it: and, or, exclusive or, and the negated and.
local SYNCOP = {fetch_and_add = "add", add_and_fetch = "add",
		fetch_and_sub = "sub", sub_and_fetch = "sub",
		fetch_and_and = 0, and_and_fetch = 0,
		fetch_and_or = 1, or_and_fetch = 1,
		fetch_and_xor = 2, xor_and_fetch = 2,
		fetch_and_nand = 3, nand_and_fetch = 3}
-- Which of them answer with the value after rather than before.
local SYNCAFTER = {}
-- The names that may carry the width of the operand on the end.  gcc
-- names the library entry point that way -- `__sync_add_and_fetch_8`
-- -- and takes the same spelling as a builtin, which is what the drm
-- code in openbsd writes.  The width there is the operand's, not the
-- pointer's, so it is passed along rather than worked out.
local SYNCBASE = {}
local SYNCWIDTH = {1, 2, 4, 8, 16}

for k in pairs(SYNCOP) do
	if k:find("_and_fetch$") then SYNCAFTER[k] = true end
	BUILTIN["__sync_" .. k] = true
	SYNCBASE[k] = true
end
for _, k in ipairs{"val_compare_and_swap", "bool_compare_and_swap",
		   "lock_test_and_set", "lock_release", "synchronize"} do
	BUILTIN["__sync_" .. k] = true
	if k ~= "synchronize" then SYNCBASE[k] = true end
end
for k in pairs(SYNCBASE) do
	for _, w in ipairs(SYNCWIDTH) do
		BUILTIN[("__sync_%s_%d"):format(k, w)] = true
	end
end

-- The `__atomic` family, which is what gcc says to write instead of
-- `__sync`: the memory order is an argument rather than always being
-- sequential consistency.  A name ending `_n` takes the value itself;
-- the one without takes its address, so that a value of any size can
-- be named.  The operation values are the same as SYNCOP's.
local ATOMOP = {fetch_add = "add", add_fetch = "add",
		fetch_sub = "sub", sub_fetch = "sub",
		fetch_and = 0, and_fetch = 0,
		fetch_or = 1, or_fetch = 1,
		fetch_xor = 2, xor_fetch = 2,
		fetch_nand = 3, nand_fetch = 3}
local ATOMAFTER = {}

for k in pairs(ATOMOP) do
	if k:find("_fetch$") then ATOMAFTER[k] = true end
	BUILTIN["__atomic_" .. k] = true
end
for _, k in ipairs{"load", "load_n", "store", "store_n",
		   "exchange", "exchange_n",
		   "compare_exchange", "compare_exchange_n",
		   "test_and_set", "clear",
		   "thread_fence", "signal_fence",
		   "always_lock_free", "is_lock_free"} do
	BUILTIN["__atomic_" .. k] = true
end

-- The spin-wait hint, one instruction on x86.
BUILTIN.__builtin_ia32_pause = true

for k in pairs(BITFN) do BUILTIN["__builtin_" .. k] = true end
for k in pairs(FCLASS) do BUILTIN["__builtin_" .. k] = true end
for k in pairs(FCMP) do BUILTIN["__builtin_" .. k] = true end
for _, k in ipairs{"fabs", "fabsf", "fabsl",
		   "sqrt", "sqrtf", "sqrtl",
		   "copysign", "copysignf", "copysignl",
		   "eh_return_data_regno"} do
	BUILTIN["__builtin_" .. k] = true
end
-- The overflow checks with the type in the name: s or u, then add, sub
-- or mul, then nothing, l or ll for int, long or long long.
local OVTYPE = {[""] = 32, l = "long", ll = 64}

for _, sg in ipairs{"s", "u"} do
	for _, op in ipairs{"add", "sub", "mul"} do
		for w in pairs(OVTYPE) do
			BUILTIN["__builtin_" .. sg .. op .. w .. "_overflow"] =
				true
		end
	end
end
-- Where __builtin_cpu_supports finds a feature: its bit in compiler_rt's
-- and libgcc's __cpu_model, then __cpu_features2.  The numbering is the
-- ABI value llvm's X86TargetParser.def gives each name.
local CPUFEAT = {
	cmov = 0, mmx = 1, popcnt = 2, sse = 3, sse2 = 4, sse3 = 5,
	ssse3 = 6, ["sse4.1"] = 7, ["sse4.2"] = 8, avx = 9, avx2 = 10,
	sse4a = 11, fma4 = 12, xop = 13, fma = 14, avx512f = 15, bmi = 16,
	bmi2 = 17, aes = 18, pclmul = 19, avx512vl = 20, avx512bw = 21,
	avx512dq = 22, avx512cd = 23, avx512vbmi = 26, avx512ifma = 27,
	avx512vpopcntdq = 30, avx512vbmi2 = 31, gfni = 32, vpclmulqdq = 33,
	avx512vnni = 34, avx512bitalg = 35, avx512bf16 = 36,
	avx512vp2intersect = 37, adx = 40, cldemote = 42, clflushopt = 43,
	clwb = 44, clzero = 45, cx16 = 46, enqcmd = 48, f16c = 49,
	fsgsbase = 50, sahf = 54, ["64bit"] = 55, lwp = 56, lzcnt = 57,
	movbe = 58, movdir64b = 59, movdiri = 60, mwaitx = 61, pconfig = 63,
	pku = 64, prfchw = 66, ptwrite = 67, rdpid = 68, rdrnd = 69,
	rdseed = 70, rtm = 71, serialize = 72, sgx = 73, sha = 74,
	shstk = 75, tbm = 76, tsxldtrk = 77, vaes = 78, waitpkg = 79,
	wbnoinvd = 80, xsave = 81, xsavec = 82, xsaveopt = 83, xsaves = 84,
	["amx-tile"] = 85, ["amx-int8"] = 86, ["amx-bf16"] = 87, uintr = 88,
	hreset = 89, kl = 90, widekl = 92, avxvnni = 93, avx512fp16 = 94,
	["x86-64"] = 95, ["x86-64-v2"] = 96, ["x86-64-v3"] = 97,
	["x86-64-v4"] = 98, avxifma = 99, avxvnniint8 = 100,
	avxneconvert = 101, cmpccxadd = 102, ["amx-fp16"] = 103,
	prefetchi = 104, raoint = 105, ["amx-complex"] = 106,
	avxvnniint16 = 107, sm3 = 108, sha512 = 109, sm4 = 110, apxf = 111,
	usermsr = 112, ["avx10.1"] = 114, ["avx10.2"] = 116,
	["amx-avx512"] = 117, ["amx-tf32"] = 118, ["amx-fp8"] = 120,
	movrs = 121, ["amx-movrs"] = 122,
}
BUILTIN.__builtin_cpu_supports = true
BUILTIN.__builtin_cpu_init = true

-- clang's C11 atomics: the __atomic builtins with the value forms and
-- an order for each outcome of a compare.
local C11 = {load = "load_n", store = "store_n", exchange = "exchange_n",
	     compare_exchange_strong = "compare_exchange_n",
	     compare_exchange_weak = "compare_exchange_n",
	     fetch_add = "fetch_add", fetch_sub = "fetch_sub",
	     fetch_and = "fetch_and", fetch_or = "fetch_or",
	     fetch_xor = "fetch_xor", fetch_nand = "fetch_nand",
	     thread_fence = "thread_fence", signal_fence = "signal_fence",
	     is_lock_free = "is_lock_free"}

for k in pairs(C11) do BUILTIN["__c11_atomic_" .. k] = true end
-- The ones that are a value rather than a calculation.
-- The values a header names rather than works out, at each width.
-- The stem cannot be read off the end of the name: huge_val ends in
-- the letter that would say long double.
local INFVAL = {}
-- The positive quiet NaN.  0.0 / 0.0 on x86 gives the negative one.
local QNAN = string.unpack("<d", string.pack("<I8", 0x7ff8000000000000))

for _, k in ipairs{"inf", "huge_val", "nan"} do
	local v = k == "nan" and "nan" or "inf"

	for _, w in ipairs{"", "f", "l"} do
		INFVAL["__builtin_" .. k .. w] = {v, w}
		BUILTIN["__builtin_" .. k .. w] = true
	end
end
-- Rounding to an integral value, at both widths.
for _, k in ipairs{"floor", "ceil", "trunc", "rint", "nearbyint"} do
	BUILTIN["__builtin_" .. k] = true
	BUILTIN["__builtin_" .. k .. "f"] = true
end

local OVOP = {add = "ADD", sub = "SUB", mul = "MUL"}

-- `__builtin_add_overflow(a, b, res)` and its two siblings.  The wrapped
-- value goes through `res`, and the answer says whether the true one fits
-- the type `res` points at.
--
-- The work happens in a type wide enough to hold both operands, chosen so
-- that neither changes value on the way in.  Two things can go wrong and
-- both are asked about: the operation itself may wrap in that type, and
-- the value may not fit the narrower type it is stored in.
function P:overflow(op, name, args)
	if #args ~= 3 then
		self:err(name .. " takes three arguments")
	end
	local pt = self.ty.decay(self:rvalue(args[3]).ty)
	local rt = isptr(pt) and pt.to

	if not rt or not self.ty.isint(rt) then
		self:err("the last argument of " .. name ..
			" must point at an integer")
		rt = self.ty.i32
	end
	local a, b = self:rvalue(args[1]), self:rvalue(args[2])

	for _, e in ipairs{a, b} do
		if not self.ty.isint(e.ty) then
			self:err(name .. " takes integer arguments")
		end
	end
	a, b = self:conv(a, self:promote(a.ty)),
		self:conv(b, self:promote(b.ty))
	-- Wide enough for both operands, and signed when either is: a
	-- signed operand beside an unsigned one of the same width needs
	-- twice the width to hold both.
	local sa, sb = a.ty.kind == "int", b.ty.kind == "int"
	-- A constant that is not negative is the same value read either
	-- way, so it takes the other operand's signedness and no wider
	-- type is needed to hold both.  `check_mul_overflow(sz, 2, &sz)`
	-- mixes a size with a literal and means what it says.
	local UNS = {[1] = self.ty.u8, [2] = self.ty.u16,
		     [4] = self.ty.u32, [8] = self.ty.u64}

	if sa ~= sb then
		local ka, kb = fold(a), fold(b)

		if sa and ka and ka >= 0 then
			a, sa = self:conv(a, UNS[a.ty.size]), false
		elseif sb and kb and kb >= 0 then
			b, sb = self:conv(b, UNS[b.ty.size]), false
		end
	end
	local w = a.ty.size > b.ty.size and a.ty.size or b.ty.size
	local wsig = sa

	if sa ~= sb then
		wsig = true
		if (sa and b.ty.size or a.ty.size) >= w then w = w * 2 end
	end
	if w < rt.size then w = rt.size end
	-- A signed operand beside an unsigned one of the same width has
	-- no type wide enough to hold both.  A sum or a difference still
	-- answers without one: the bits are worked out in the unsigned
	-- type and how far the true value sits from them is counted.
	local mixed = false

	if w > 8 then
		if op == "mul" then
			self:err(name .. " on these types needs more " ..
				"than eight bytes to work in")
		else
			mixed = true
			wsig = false
		end
		w = 8
	end
	local UT = {[1] = self.ty.u8, [2] = self.ty.u16, [4] = self.ty.u32,
		    [8] = self.ty.u64}
	local ST = {[1] = self.ty.i8, [2] = self.ty.i16, [4] = self.ty.i32,
		    [8] = self.ty.i64}
	local wt, ut, st = wsig and ST[w] or UT[w], UT[w], ST[w]
	local pre = {}
	-- Wrapping is only defined for the unsigned type, so the bits are
	-- worked out there and read back as signed where a test needs it.
	local au, sav = self:pin(self:conv(self:conv(a, wt), ut))
	local bu, sbv = self:pin(self:conv(self:conv(b, wt), ut))

	pre[#pre + 1], pre[#pre + 2] = sav, sbv
	local ru, srv = self:pin(self:arith(OVOP[op], au(), bu()))

	pre[#pre + 1] = srv
	local pp, spv = self:pin(self:conv(self:rvalue(args[3]), pt))

	pre[#pre + 1] = spv
	pre[#pre + 1] = self:assignto(tree.unary("INDIR", rt, pp()),
		self:conv(ru(), rt))

	local i32 = self.ty.i32
	local function as() return self:conv(au(), st) end
	local function bs() return self:conv(bu(), st) end
	local function rs() return self:conv(ru(), st) end
	-- Through arith, not tree.binary: a value wider than a register
	-- is compared by the runtime, and only arith knows that.
	local function cmp(o, x, y) return self:arith(o, x, y) end
	local function both(x, y) return tree.binary("ANDAND", i32, x, y) end
	local function either(x, y) return tree.binary("OROR", i32, x, y) end
	local test
	-- How many times the unsigned type wrapped: the true value is
	-- `ru` plus that many times two to the width.  Only zero and
	-- minus one leave anything a result type could hold.
	local function turns()
		local zero = tree.const(st, 0)
		local an = sa and cmp("LT", as(), zero) or
			tree.const(i32, 0)
		local bn = sb and cmp("LT", bs(), zero) or
			tree.const(i32, 0)
		local c = op == "add" and cmp("LT", ru(), au())
			or cmp("LT", au(), bu())

		if op == "add" then
			return tree.binary("SUB", i32,
				tree.binary("SUB", i32, c, an), bn)
		end
		return tree.binary("SUB", i32,
			tree.binary("SUB", i32, bn, c), an)
	end

	if mixed then
		local kp, skv = self:pin(self:conv(turns(), i32))

		pre[#pre + 1] = skv
		local bits = rt.size * 8
		local kz = cmp("EQ", kp(), tree.const(i32, 0))
		local km = cmp("EQ", kp(), tree.const(i32, -1))
		-- Wrapped once and nothing else: the answer is `ru` read
		-- as signed, which only reaches that far with the top
		-- bit set.
		local low

		if rt.kind == "uint" then
			low = km
		elseif rt.size == 8 then
			low = both(km, cmp("GE", rs(), tree.const(st, 0)))
		else
			low = both(km, either(
				cmp("GE", rs(), tree.const(st, 0)),
				cmp("LT", rs(),
					tree.const(st, -(1 << (bits - 1))))))
		end
		-- Did not wrap: the answer is `ru` read as unsigned.
		if not (rt.kind == "uint" and rt.size == 8) then
			local hi = rt.kind == "uint" and
				(1 << (bits - 1)) * 2 - 1
				or (1 << (bits - 1)) - 1

			low = either(low,
				both(kz, cmp("GT", ru(),
					tree.const(ut, hi))))
		end
		test = either(both(cmp("NE", kp(), tree.const(i32, 0)),
				cmp("NE", kp(), tree.const(i32, -1))), low)
	elseif op == "mul" then
		-- Dividing the answer back gives the other operand unless
		-- it overflowed.  Signed division traps on the one pair
		-- whose answer is the most negative value, so that pair
		-- is ruled out before the division is reached.
		if not wsig then
			test = both(self:test(au()),
				cmp("NE", self:arith("DIV", ru(), au()),
					bu()))
		else
			local m1 = tree.const(st, -1)
			local lo = tree.const(st, -(1 << (w * 8 - 2)) * 2)

			test = both(self:test(as()),
				either(both(cmp("EQ", as(), m1),
						cmp("EQ", bs(), lo)),
					both(cmp("NE", as(), m1),
						cmp("NE", self:arith("DIV",
							rs(), as()), bs()))))
		end
	elseif not wsig then
		-- A sum that came out below what went in wrapped, and a
		-- difference wraps when the first is the smaller.
		test = op == "add" and cmp("LT", ru(), au())
			or cmp("LT", au(), bu())
	else
		-- A signed sum overflows when the answer differs in sign
		-- from both operands; a difference when the operands
		-- differ from each other and the answer from the first.
		local x = op == "add" and self:arith("XOR", bu(), ru())
			or self:arith("XOR", au(), bu())
		local y = self:arith("XOR", au(), ru())

		test = cmp("LT", self:conv(self:arith("AND", x, y), st),
			tree.const(st, 0))
	end
	-- What fits the type it is worked out in may still not fit the one
	-- it is stored in.
	if not mixed and not reaches(wt, rt) then
		local bits = rt.size * 8
		local fit

		if rt.kind == "uint" then
			if wsig then fit = cmp("LT", rs(), tree.const(st, 0)) end
			if rt.size < w then
				local hi = (1 << (bits - 1)) * 2 - 1
				local c = wsig and cmp("GT", rs(),
						tree.const(st, hi))
					or cmp("GT", ru(), tree.const(ut, hi))

				fit = fit and either(fit, c) or c
			end
		else
			local hi = (1 << (bits - 1)) - 1

			if wsig then
				fit = either(cmp("LT", rs(),
						tree.const(st, -hi - 1)),
					cmp("GT", rs(), tree.const(st, hi)))
			else
				fit = cmp("GT", ru(), tree.const(ut, hi))
			end
		end
		if fit then test = either(test, fit) end
	end
	pre[#pre + 1] = self:conv(test, i32)
	return tree.node("SEQ", i32, nil, nil, {arms = pre})
end

-- Turn a value end for end, `size` bytes of it.  Shifts and masks, so
-- every target gets it without an instruction of its own.
function P:bswap(e, size)
	local ty = size == 8 and self.ty.u64 or self.ty.u32
	local v = self:conv(self:rvalue(e), ty)
	local read, pre

	-- The value is read once per byte, so anything that has to
	-- happen only once is worked out into a slot first.  A body
	-- built where it was called is written out in full at every
	-- read otherwise, labels and all, and runs that many times.
	if tree.effects(v) then
		read, pre = self:pin(v)
	else
		local lv, set = self:once(v)

		pre = set
		read = function() return tree.clone(lv) end
	end
	local out

	for i = 0, size - 1 do
		local from, to = i * 8, (size - 1 - i) * 8
		local b = self:arith("AND", read(),
			tree.const(ty, 0xff << from))

		if to > from then
			b = self:arith("SHL", b,
				tree.const(self.ty.i32, to - from))
		elseif from > to then
			b = self:arith("SHR", b,
				tree.const(self.ty.i32, from - to))
		end
		out = out and self:arith("OR", out, b) or b
	end
	if size == 2 then out = self:conv(out, self.ty.u16) end
	if not pre then return out end
	return tree.node("SEQ", out.ty, nil, nil, {arms = {pre, out}})
end

function P:special(name)
	self:expect("(")
	if name == "__builtin_unreachable" or name == "__builtin_trap" then
		self:expect(")")
		-- nothing to emit: the caller never looks at the answer,
		-- and nothing after it is reached
		local n = tree.const(self.ty.i32, 0)

		n.noret = true
		return n
	end
	if name == "__builtin_constant_p" then
		local m = tree.mark()
		local e = self:rvalue(self:assign())
		local v = fold(e) ~= nil

		-- Inside a body built where it was called, a parameter
		-- that still holds what the caller wrote is as constant
		-- as what the caller wrote.  A kernel picks which of two
		-- bit tests to use on the answer.
		if not v and self.inl then
			local a = self:inlsubst(e)

			v = a ~= nil and fold(a) ~= nil
		end
		tree.release(m)
		self:expect(")")
		return tree.const(self.ty.i32, v and 1 or 0)
	end
	-- gcc's type class of the argument, which is not evaluated:
	-- void 0, integer 1 (char, _Bool and enums too, as gcc answers
	-- for C), pointer 5, real 8, complex 9, record 12, union 13.  The argument
	-- decays as any rvalue does, so a string is a pointer.
	if name == "__builtin_classify_type" then
		local m = tree.mark()
		local sv, paused = self.g.sink, self.g:pause()

		self.g.sink = buf.new()
		local ty = self:rvalue(self:assign()).ty
		self.g.sink = sv
		self.g:resume(paused)
		tree.release(m)
		self:expect(")")
		local k, c = ty.kind, 1

		if k == "void" then c = 0
		elseif ty.complex then c = 9
		elseif k == "ptr" then c = 5
		elseif k == "float" then c = 8
		elseif k == "func" then c = 10
		elseif k == "struct" then c = 12
		elseif k == "union" then c = 13
		elseif k == "array" then c = 14
		end
		return tree.const(self.ty.i32, c)
	end
	if name == "__builtin_offsetof" then
		local ty = self:typename()

		self:expect(",")
		-- The first member is named without a dot; what may
		-- follow it is the same shape a designator has.
		if not isrec(ty) then
			self:err("offsetof needs a struct or union")
		end
		local nm = self:expect("name").text
		local m = ty.byname and ty.byname[nm]

		if not m then self:err("no member " .. nm) end
		local off, dyn = self:offsetpath(m.ty, m.off)

		self:expect(")")
		local k = tree.const(self.uword, off)
		if not dyn then return k end
		return self:arith("ADD", k, dyn)
	end
	if name == "__builtin_types_compatible_p" then
		local a = self:typename()

		self:expect(",")
		local b = self:typename()

		self:expect(")")
		return tree.const(self.ty.i32,
			self.ty.same(a, b) and 1 or 0)
	end
	-- __builtin_choose_expr
	local c = self:constexpr()

	self:expect(",")
	local taken, m
	if c ~= 0 then
		taken = self:assign()
		self:expect(",")
		m = tree.mark()
		self:assign()
		tree.release(m)
	else
		m = tree.mark()
		self:assign()
		tree.release(m)
		self:expect(",")
		taken = self:assign()
	end
	self:expect(")")
	return taken
end

-- The `__sync_` family, on the same runtime C11 atomics use.  Every
-- one of them is sequentially consistent, which is what the family
-- promised before there was a way to ask for less.
local SEQCST = 5

function P:syncop(what, args, width)
	local vp = self.ty.ptr(self.ty.void)
	local u64 = self.ty.u64
	local i32 = self.ty.i32
	local function num(v) return tree.const(i32, v) end

	if what == "synchronize" then
		return self:rtcall("__mcc_atomic_fence", self.ty.void,
			{num(SEQCST)})
	end
	if #args < 1 or not isptr(self.ty.decay(args[1].ty)) then
		self:err("__sync_" .. what .. " needs a pointer")
		return tree.const(i32, 0)
	end
	local et = self.ty.decay(args[1].ty).to

	-- A name that carries the width says what the operand is,
	-- whatever the pointer was declared to point at.  Where the two
	-- agree the declared type stands, so the answer keeps its sign.
	if width and et.size ~= width then
		et = self.ty["u" .. (width * 8)] or
			self:err("__sync_" .. what .. "_" .. width ..
				 " is not supported") or self.ty.u64
	end

	local w = num(width or et.size)
	local p = self:conv(args[1], vp)

	if what == "lock_release" then
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, tree.const(u64, 0), w, num(SEQCST)})
	end
	if what == "lock_test_and_set" then
		return self:conv(self:rtcall("__mcc_atomic_exchange", u64,
			{p, self:conv(args[2], u64), w, num(SEQCST)}), et)
	end
	if what == "val_compare_and_swap" or
	   what == "bool_compare_and_swap" then
		-- The runtime writes what it found back over the
		-- expected value, so that goes in a slot of its own.
		local off = self:temp(et)
		local slot = tree.auto(et, off)
		-- Through assignto rather than an ASGN node: a value
		-- wider than a register does not travel in one, and on
		-- i386 a long long is wider than a register.
		local pre = self:assignto(slot, self:conv(args[2], et))
		local call = self:rtcall("__mcc_atomic_cas", i32,
			{p, tree.unary("ADDR", vp, tree.clone(slot)),
			 self:conv(args[3], u64), w, num(SEQCST)})

		if what == "bool_compare_and_swap" then
			return tree.node("SEQ", i32, nil, nil,
				{arms = {pre, call}})
		end
		-- The value form answers with what was there, which is
		-- the slot either way.
		return tree.node("SEQ", et, nil, nil,
			{arms = {pre, call, tree.clone(slot)}})
	end
	local op = SYNCOP[what]

	if op == nil then
		self:err("__sync_" .. what .. " is not supported")
		return tree.const(i32, 0)
	end
	return self:atomrmw(op, SYNCAFTER[what], et, p, args[2], w,
			    num(SEQCST))
end

-- The `__atomic` family.  Everything lands on the same runtime the
-- `__sync` family and <stdatomic.h> use; what is different is that
-- the memory order comes from the caller and that the forms without
-- `_n` carry the value by address so that any size can be named.
function P:atomicop(what, args)
	local vp = self.ty.ptr(self.ty.void)
	local cvp = self.ty.ptr(self.ty.void)
	local u64 = self.ty.u64
	local i32 = self.ty.i32
	local function num(v) return tree.const(i32, v) end
	-- What a pointer points at, as an lvalue.  The generic forms
	-- carry their value by address.
	local function deref(e)
		local t = self.ty.decay(e.ty)

		if not isptr(t) then
			self:err("__atomic_" .. what ..
				 " needs a pointer here")
			return tree.const(self.ty.i32, 0)
		end
		return tree.unary("INDIR", t.to, self:rvalue(e))
	end
	local function want(n)
		if #args >= n then return true end
		self:err("__atomic_" .. what .. " wants " .. n ..
			 " arguments")
		return false
	end

	if what == "thread_fence" or what == "signal_fence" then
		if not want(1) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_fence", self.ty.void,
			{self:conv(args[1], i32)})
	end
	-- Whether one of this width is done in place rather than under a
	-- lock.  The answer has to be a constant, because a header tests
	-- it with #if-like code and a program branches on it.
	if what == "always_lock_free" or what == "is_lock_free" then
		if not want(1) then return tree.const(i32, 0) end

		local n = fold(args[1])
		local ok = n == 1 or n == 2 or n == 4 or n == 8

		return tree.const(i32, ok and 1 or 0)
	end
	if #args < 1 or not isptr(self.ty.decay(args[1].ty)) then
		self:err("__atomic_" .. what .. " needs a pointer")
		return tree.const(i32, 0)
	end
	local et = self.ty.decay(args[1].ty).to

	-- The pointer may be to a const or a _Atomic; what matters here
	-- is the width and what the value converts to.
	local w = num(et.size)
	local p = self:conv(args[1], vp)

	-- A flag is one byte whatever it is declared as: gcc says these
	-- two work on a byte.
	if what == "test_and_set" then
		if not want(2) then return tree.const(i32, 0) end
		return self:arith("NE", self:rtcall("__mcc_atomic_exchange",
			u64, {p, tree.const(u64, 1), num(1),
			      self:conv(args[2], i32)}), tree.const(u64, 0))
	end
	if what == "clear" then
		if not want(2) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, tree.const(u64, 0), num(1),
			 self:conv(args[2], i32)})
	end
	if what == "load_n" then
		if not want(2) then return tree.const(i32, 0) end
		return self:conv(self:rtcall("__mcc_atomic_load", u64,
			{p, w, self:conv(args[2], i32)}), et)
	end
	if what == "store_n" then
		if not want(3) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, self:conv(self:conv(args[2], et), u64), w,
			 self:conv(args[3], i32)})
	end
	if what == "exchange_n" then
		if not want(3) then return tree.const(i32, 0) end
		return self:conv(self:rtcall("__mcc_atomic_exchange", u64,
			{p, self:conv(self:conv(args[2], et), u64), w,
			 self:conv(args[3], i32)}), et)
	end
	-- The generic forms carry the value by address.  A read through
	-- the pointer is what turns one into the form above.
	if what == "load" then
		if not want(3) then return tree.const(i32, 0) end
		return self:assignto(deref(args[2]),
			self:conv(self:rtcall("__mcc_atomic_load", u64,
				{p, w, self:conv(args[3], i32)}), et))
	end
	if what == "store" then
		if not want(3) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, self:conv(deref(args[2]), u64), w,
			 self:conv(args[3], i32)})
	end
	if what == "exchange" then
		if not want(4) then return tree.const(i32, 0) end
		return self:assignto(deref(args[3]),
			self:conv(self:rtcall("__mcc_atomic_exchange", u64,
				{p, self:conv(deref(args[2]), u64), w,
				 self:conv(args[4], i32)}), et))
	end
	-- Compare and exchange takes the expected value by address in
	-- both spellings, and the runtime writes what it found back
	-- there, so nothing has to be copied into a slot first.  The
	-- weak flag changes nothing here: the runtime never fails
	-- spuriously.  The failure order is not used, which is allowed:
	-- a stronger order than asked for is always correct.
	if what == "compare_exchange_n" or what == "compare_exchange" then
		if not want(5) then return tree.const(i32, 0) end

		local des = what == "compare_exchange_n" and
			self:conv(args[3], et) or deref(args[3])

		return self:rtcall("__mcc_atomic_cas", i32,
			{p, self:conv(args[2], cvp), self:conv(des, u64), w,
			 self:conv(args[5], i32)})
	end
	local op = ATOMOP[what]

	if op == nil then
		self:err("__atomic_" .. what .. " is not supported")
		return tree.const(i32, 0)
	end
	if not want(3) then return tree.const(i32, 0) end
	return self:atomrmw(op, ATOMAFTER[what], et, p, args[2], w,
			    self:conv(args[3], i32))
end

-- One read-modify-write, for both families.  `et` is the type of the
-- value, `p` the pointer already converted, `raw` what the caller
-- wrote for the operand, `w` the width and `ord` the memory order.
function P:atomrmw(op, after, et, p, raw, w, ord)
	local u64 = self.ty.u64

	-- A pointer operand is worked on as if it were a uintptr_t: the
	-- value is not scaled by what the pointer points at, which is
	-- what gcc says and what a driver counts on.  So the arithmetic
	-- is done in an integer as wide as the pointer and the answer
	-- goes back to the pointer type at the end.
	local at = isptr(et) and (self.ty["u" .. (et.size * 8)] or u64)
		   or et
	local v = self:conv(raw, at)
	local pre = nil

	-- The forms that answer with the value after read the operand
	-- twice, so anything in it would happen twice -- and a body
	-- built where it was called would be built twice, which names
	-- its labels twice.  Once into a slot, then read from there.
	if after and tree.effects(v) then
		local voff = self:temp(at)

		pre = self:assignto(tree.auto(at, voff), v)
		v = tree.auto(at, voff)
	end
	local old

	if op == "add" or op == "sub" then
		local amount = tree.clone(v)

		if op == "sub" then
			amount = self:arith("SUB", self:conv(
				tree.const(at, 0), at), amount)
		end
		old = self:rtcall("__mcc_atomic_fetch_add", u64,
			{p, self:conv(amount, u64), w, ord})
	else
		old = self:rtcall("__mcc_atomic_fetch_bit", u64,
			{p, self:conv(tree.clone(v), u64), w, ord,
			 tree.const(self.ty.i32, op)})
	end
	old = self:conv(old, at)

	local function done(e)
		e = self:conv(e, et)
		if not pre then return e end
		return tree.node("SEQ", e.ty, nil, nil, {arms = {pre, e}})
	end

	if not after then return done(old) end
	-- The forms that answer with the value after do the operation
	-- once more on what was there.
	local BIT = {[0] = "AND", [1] = "OR", [2] = "XOR"}
	local rhs = tree.clone(v)

	if op == "add" then return done(self:arith("ADD", old, rhs)) end
	if op == "sub" then return done(self:arith("SUB", old, rhs)) end
	if op == 3 then
		return done(self:arith("XOR", self:arith("AND", old, rhs),
			self:conv(tree.const(at, -1), at)))
	end
	return done(self:arith(BIT[op], old, rhs))
end

-- The few compiler builtins the headers here reach for.
function P:builtin(name)
	self:expect("(")
	local args = {}
	if self.tok.kind ~= ")" then
		repeat
			args[#args + 1] = self:rvalue(self:assign())
		until not self:accept(",")
	end
	self:expect(")")
	if name == "__builtin_expect" then
		return args[1]
	end
	if name == "__builtin_ia32_pause" then
		if self.t.name ~= "amd64" and self.t.name ~= "i386" then
			self:err(name .. " is for x86 targets")
		end
		return tree.node("ASM", self.ty.void, nil, nil,
			{text = "pause", outs = {}, ins = {}, clob = {"memory"},
			 ext = true, labels = {}})
	end
	if name:sub(1, 9) == "__atomic_" then
		return self:atomicop(name:sub(10), args)
	end
	if name:sub(1, 13) == "__c11_atomic_" then
		local what = name:sub(14)

		-- The compare forms take no weak flag; the value forms
		-- here take one in the fourth place.
		if what:match("^compare_exchange") then
			table.insert(args, 4, tree.const(self.ty.i32,
				what == "compare_exchange_weak" and 1 or 0))
		end
		return self:atomicop(C11[what], args)
	end
	if name:sub(1, 7) == "__sync_" then
		local what = name:sub(8)
		local base, w = what:match("^(.-)_(%d+)$")

		if base and SYNCBASE[base] then
			return self:syncop(base, args, tonumber(w))
		end
		return self:syncop(what, args)
	end
	if name == "__builtin_prefetch" then
		return tree.const(self.ty.i32, 0)
	end
	-- wasm's two memory instructions, which the assembler writes
	-- in place of a call to these names.  There is one memory, so
	-- the index argument says nothing.
	if name == "__builtin_wasm_memory_size" then
		return self:rtcall("__wasm_memory_size", self.uword, {})
	end
	if name == "__builtin_wasm_memory_grow" then
		return self:rtcall("__wasm_memory_grow", self.uword,
			{self:conv(args[2], self.uword)})
	end
	if name == "__builtin_alloca" then
		if not self.t.alloca then
			self:err("alloca is not supported on this target")
		end
		local p = self.ty.ptr(self.ty.void)

		return tree.unary("ALLOCA", p,
			self:conv(args[1], self.uword))
	end
	local w = name:match("^__builtin_bswap(%d+)$")
	if w then
		return self:bswap(args[1], tonumber(w) // 8)
	end
	-- Where this function was called from, and where its frame is.
	-- Both walk the chain the prologue leaves behind: the register it
	-- points at the frame, the saved one beside it, and the return
	-- address at a fixed distance.  A kernel asks for the caller in
	-- every trace it prints.
	if name == "__builtin_return_address" or
	   name == "__builtin_frame_address" then
		local t = self.t

		if not t.frameptr then
			self:err(name .. " is not supported on " .. t.name)
			return tree.const(self.ty.ptr(self.ty.void), 0)
		end
		local n = args[1] and fold(args[1])

		if not n or n < 0 then
			self:err(name .. " takes a constant depth")
			n = 0
		end
		local vp = self.ty.ptr(self.ty.void)
		local cp = self.ty.ptr(self.plainchar)
		local e = tree.node("HARD", vp, nil, nil,
				    {hard = t.frameptr})

		-- One step out reads the frame pointer the prologue put
		-- away; the last step reads the return address beside it.
		local function step(p, off)
			local a = self:arith("ADD", self:conv(p, cp),
				tree.const(self.ty.i32, off))

			return tree.unary("INDIR", vp,
				self:conv(a, self.ty.ptr(vp)))
		end

		for _ = 1, n do e = step(e, t.prevframeoff) end
		if name == "__builtin_return_address" then
			e = step(e, t.retaddroff)
		end
		return e
	end

	-- How big the object behind a pointer is.  This compiler does not
	-- track that, and the builtin has an answer for exactly that
	-- case: all ones where it is asked for the most there could be,
	-- and zero where it is asked for the least.  A kernel guards a
	-- call to a name nothing defines with it.
	-- On every machine this compiler targets a return address is the
	-- address it says it is, so both of these hand it straight back.
	if name == "__builtin_extract_return_addr" or
	   name == "__builtin_frob_return_addr" then
		if #args ~= 1 then
			self:err(name .. " takes one argument")
		end
		return self:rvalue(args[1])
	end
	if name == "__builtin_object_size" then
		local kind = args[2] and fold(args[2]) or 0

		return tree.const(self.uword,
			(kind and kind >= 2) and 0 or -1)
	end
	if name == "__builtin_dynamic_object_size" then
		local kind = args[2] and fold(args[2]) or 0

		return tree.const(self.uword,
			(kind and kind >= 2) and 0 or -1)
	end
	local sg, op, w = name:match("^__builtin_([su])([a-z][a-z][a-z])(l?l?)_overflow$")

	if sg and OVOP[op] and OVTYPE[w] then
		local bits = OVTYPE[w]

		if bits == "long" then bits = self.t.ptrsize * 8 end
		local ty = self.ty[(sg == "u" and "u" or "i") .. bits]
		if #args ~= 3 then
			self:err(name .. " takes three arguments")
		end
		return self:overflow(op, name, {self:conv(self:rvalue(args[1]),
			ty), self:conv(self:rvalue(args[2]), ty), args[3]})
	end
	if name == "__builtin_cpu_init" then
		return self:abicall0("__cpu_indicator_init")
	end
	if name == "__builtin_cpu_supports" then
		local a = args[1]
		local str = a and (a.str or (a.left and a.left.str))
		local bit = str and CPUFEAT[str]

		if self.t.name ~= "amd64" and self.t.name ~= "i386" then
			self:err(name .. " is only for x86")
		end
		if not bit then
			self:err("unknown cpu feature " .. tostring(str))
			return tree.const(self.ty.i32, 0)
		end
		-- The first 32 are the last word of __cpu_model, after
		-- the vendor, type and subtype; the rest __cpu_features2.
		local u32 = self.ty.u32
		local sym, off = "__cpu_model", 12

		if bit >= 32 then
			sym, off = "__cpu_features2", (bit - 32) // 32 * 4
		end
		local pu = self.ty.ptr(u32)
		local base = tree.unary("ADDR", self.ty.ptr(u32),
			tree.name(u32, sym))
		local word = tree.unary("INDIR", u32, tree.binary("ADD", pu,
			base, tree.const(self.uword, off)))

		return self:arith("NE", self:arith("AND", word,
			tree.const(u32, 1 << (bit % 32))), tree.const(u32, 0))
	end
	if name == "__builtin_eh_return_data_regno" then
		local n = fold(args[1] or tree.const(self.ty.i32, 0))
		local r = self.t.ehregs and self.t.ehregs[(n or 0) + 1]

		if not r then self:err(name .. " is not known here") end
		return tree.const(self.ty.i32, r or 0)
	end
	local cs = name:match("^__builtin_copysign([fl]?)$")

	if cs then
		local ty = cs == "f" and self.ty.f32 or
			(cs == "l" and self.ty.ldouble or self.ty.f64)

		return self:copysign(self:rvalue(args[1]),
			self:rvalue(args[2]), ty)
	end
	local ov = name:match("^__builtin_([a-z]+)_overflow$")

	if ov == "add" or ov == "sub" or ov == "mul" then
		return self:overflow(ov, name, args)
	end
	-- The magnitude of a float is its bits with the sign cleared,
	-- which is no call at all.  A header that writes
	-- `fabs(x) { return __builtin_fabs(x); }` would otherwise call
	-- itself.
	local ab = name:match("^__builtin_fabs([fl]?)$")

	if ab then
		local a = self:rvalue(args[1])
		local fty = ab == "f" and self.ty.f32 or
			(ab == "l" and self.ty.ldouble or self.ty.f64)

		if isflt(a.ty) and a.ty.size == 4 then fty = self.ty.f32 end
		a = self:conv(a, fty)
		local uty = fty.size == 4 and self.ty.u32 or self.ty.u64
		local mask = fty.size == 4 and 0x7fffffff
			or 0x7fffffffffffffff
		local k = fold(a)

		-- A float constant is its bit pattern here, so clearing
		-- the sign is the whole of it.
		if fty.x87 and a.op == "CONST" then
			local c = tree.clone(a)

			c.hi = a.hi & 0x7fff
			c.fnum = a.fnum and math.abs(a.fnum)
			return c
		end
		if k and not fty.x87 then return tree.const(fty, k & mask) end
		if self.t.hwfloat then return tree.unary("FABS", fty, a) end
		-- One slot, read both ways: the float goes in and the
		-- bits come out, which is the cast C has no spelling for.
		local off = self:alloc(fty)
		local fv = tree.auto(fty, off)
		local bits = tree.auto(uty, off)

		return tree.node("SEQ", fty, nil, nil, {arms = {
			self:assignto(fv, a),
			self:assignto(tree.clone(bits),
				self:arith("AND", tree.clone(bits),
					tree.const(uty, mask))),
			tree.clone(fv)}})
	end
	-- The square root: one instruction where the machine has floating
	-- point, and the soft float runtime where it has not.  The name
	-- differs from the library's, so a header that writes
	-- `sqrt(x) { return __builtin_sqrt(x); }` does not call itself.
	local sq = name:match("^__builtin_sqrt([fl]?)$")

	if sq then
		local a = self:rvalue(args[1])
		local fty = sq == "f" and self.ty.f32 or self.ty.f64

		a = self:conv(a, fty)
		if self.t.hwfloat then return tree.unary("SQRT", fty, a) end
		return self:rtcall("__" .. self:fprefix(fty) .. "sqrt",
			fty, {a})
	end
	-- Rounding to an integral value.  The name differs from the
	-- library's, so a header that writes
	-- `floor(x) { return __builtin_floor(x); }` does not call
	-- itself, and no machine here has one instruction for all of
	-- them anyway.
	for _, nm in ipairs{"floor", "ceil", "trunc", "rint",
			    "nearbyint"} do
		if name == "__builtin_" .. nm or
		   name == "__builtin_" .. nm .. "f" then
			local f32 = name:sub(-1) == "f"
			local fty = f32 and self.ty.f32 or self.ty.f64
			local a = self:conv(self:rvalue(args[1]), fty)
			local stem = nm == "nearbyint" and "rint" or nm

			-- A double that does not fit a register is named
			-- by its address, as the rest of its arithmetic is.
			if self:iswide(fty) then
				return self:wcall("__w_d" .. stem,
					{self:waddr(a)}, fty)
			end
			return self:rtcall("__" .. (f32 and "f" or "d") ..
				stem, fty, {a})
		end
	end
	-- The values a header names rather than works out.
	local iv = INFVAL[name]

	if iv then
		local fty = self.ty.f64

		if iv[2] == "f" then fty = self.ty.f32
		elseif iv[2] == "l" then fty = self.ty.ldouble end
		-- The argument of __builtin_nan is a payload this
		-- compiler does not carry; the quiet one answers.
		return self:fconst(iv[1] == "nan" and QNAN
			or math.huge, fty)
	end
	-- The comparisons that are false, not unordered, for a NaN.
	-- glibc's math.h spells isgreater and the rest with these.
	local rel = FCMP[name:sub(11)]
	if rel then
		local a, b = self:rvalue(args[1]), self:rvalue(args[2])
		local ty = self.ty.f32

		for _, e in ipairs{a, b} do
			if e.ty.x87 or e.ty == self.ty.ldouble then
				ty = self.ty.ldouble
			elseif ty ~= self.ty.ldouble and
			       (not isflt(e.ty) or e.ty.size == 8) then
				ty = self.ty.f64
			end
		end
		local oa, ob = self:temp(ty), self:temp(ty)
		local function x() return tree.auto(ty, oa) end
		local function y() return tree.auto(ty, ob) end
		local i32 = self.ty.i32
		local r

		if rel == "UN" then
			r = tree.node("OROR", i32, self:arith("NE", x(), x()),
				self:arith("NE", y(), y()))
		elseif rel == "LG" then
			r = tree.node("OROR", i32, self:arith("LT", x(), y()),
				self:arith("GT", x(), y()))
		else
			r = self:arith(rel, x(), y())
		end
		return tree.node("SEQ", i32, nil, nil, {arms = {
			self:assignto(x(), self:conv(a, ty)),
			self:assignto(y(), self:conv(b, ty)), r}})
	end
	local fc = FCLASS[name:sub(11)]
	if fc then
		local a = self:rvalue(args[1])

		if not isflt(a.ty) then a = self:conv(a, self.ty.f64) end
		if a.ty.half then a = self:conv(a, self.ty.f32) end
		if a.ty.x87 or (FBITS[a.ty.size] and
		   a.ty.size <= self.t.ptrsize) then
			return self:fclass(fc, a)
		end
		return self:rtcall("__" .. self:fprefix(a.ty) .. fc,
			self.ty.i32, {a})
	end
	-- `strcmp` and `strlen` over literals answer here.  A kernel
	-- picks an operation by name in a macro and calls a function
	-- nobody defines on the arm that cannot be reached, so the
	-- comparison has to fold or the link fails saying so.
	local function litstr(e)
		while e do
			if e.str then return e.str end
			if e.op == "ADDR" or e.op == "CVT" then
				e = e.left
			else
				return nil
			end
		end
	end

	if name == "__builtin_strlen" and #args == 1 then
		local a = litstr(args[1])

		if a then return tree.const(self.uword, #a) end
	end
	-- The answer is the sign of the difference, and C says only
	-- the sign.
	local function sign(a, b)
		if a < b then return -1 end
		if a > b then return 1 end
		return 0
	end

	if name == "__builtin_strcmp" and #args == 2 then
		local a, b = litstr(args[1]), litstr(args[2])

		if a and b then return tree.const(self.ty.i32, sign(a, b)) end
	end
	if (name == "__builtin_strncmp" or name == "__builtin_memcmp") and
	   #args == 3 then
		local a, b = litstr(args[1]), litstr(args[2])
		local n = fold(args[3])

		-- memcmp reads every one of the bytes it was given, so
		-- both literals have to be that long; strncmp stops at
		-- the end of either.
		if a and b and n and n >= 0 then
			local long = name == "__builtin_memcmp"

			if not long or (#a >= n and #b >= n) then
				if long then
					a, b = a:sub(1, n), b:sub(1, n)
				else
					a = (a .. "\0"):sub(1, n)
					b = (b .. "\0"):sub(1, n)
				end
				return tree.const(self.ty.i32, sign(a, b))
			end
		end
	end
	local bf = BITFN[name:sub(11)]
	if bf then
		local ty = bf[1] == 8 and self.ty.u64 or self.ty.u32
		local a = self:conv(args[1], ty)
		local v = fold(a)

		if v then
			return tree.const(self.ty.i32,
				bitcount(name:sub(11), v, bf[1]))
		end
		local n = self:rtcall(bf[2], self.ty.i32, {a})

		n.soft = nil
		return n
	end
	-- the rest are the library function of the same name, called the way
	-- the target calls anything else
	local fn = name:gsub("^__builtin_", "")

	-- Except inside that function, where it would be a call to
	-- itself.  A header writes `sqrt(x) { return __builtin_sqrt(x); }`
	-- expecting an instruction, and getting a call there is an
	-- infinite recursion no diagnostic would otherwise name.
	if fn == self.fname then
		self:err(name .. " is not a builtin this compiler has, " ..
			"so it is a call to " .. fn .. " from inside " ..
			fn)
	end
	local rty = args[1] and args[1].ty or self.word
	-- The arguments go over as the library's own declaration says,
	-- and with none, as C promotes them: a char length handed raw to
	-- memcpy was read as four bytes, three of them whatever the stack
	-- held.  OpenBSD's cache_lookup does that with a char field.
	local g = self.globals and self.globals[fn]
	local fty = g and g.ty

	if fty and fty.kind == "func" and not fty.noproto then
		for i, p in ipairs(fty.params) do
			if args[i] and not isrec(p) then
				args[i] = self:conv(args[i], p)
			end
		end
		if fty.ret ~= self.ty.void then rty = fty.ret end
	end
	for i = (fty and fty.kind == "func" and not fty.noproto and
		 #fty.params or 0) + 1, #args do
		local t = args[i].ty

		if isflt(t) and t.size < 8 then
			args[i] = self:conv(args[i], self.ty.f64)
		elseif t.kind == "int" or t.kind == "uint" then
			args[i] = self:conv(args[i], self:promote(t))
		end
	end
	local n = self:rtcall(fn, rty, args)
	n.soft = nil
	return n
end

return {
	BUILTIN = BUILTIN,
}
