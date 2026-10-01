-- SPDX-License-Identifier: ISC
-- Machine description: the table format and its compiler.
--
-- A target supplies, per context and per operator, a list of alternatives.
-- The matcher takes the first alternative whose operand shapes the tree can
-- satisfy.  This module turns the readable form into something the matcher
-- and the emitter walk without reparsing.
--
-- Operand shape:  <class>[<size>][*]
--   class  z 4   the constant zero      size  b 1   byte
--          c 8   any constant                 w 2   word
--          i 12  a name or address            l 4   long
--          a 16  addressable, no register     q 8   quad
--          e 20  fits the registers left      p     pointer
--          n 63  anything
--   p            a pointer; a size letter beside it names the pointee,
--                so "nbp" is any pointer to a byte
--   s u          signed or unsigned, where the instruction differs; beside
--                p it is the pointee's sign, so "nbsp" is any pointer to a
--                signed byte
--   r            a local the body keeps in a register, so the operand
--                is the register and nothing has to be loaded to reach
--                it.  Only meaningful beside the classes that already
--                take a name.
--   v            through a widening conversion of the same sign: the
--                rest of the shape describes what was converted, so
--                an instruction may read it at its own width
--   *            the node must be an indirection
--
-- Evaluation list `ev`, space separated, run before the template:
--   L R T      left, right, this node, into the current register
--   L1 R1      into the next register
--   L* R*      an indirection's pointer instead of its value
--   Ls Rs      onto the stack
--   Lc Rc      into the condition codes
--
-- Template `asm`, where % is an escape only before these:
--   %A %A1 %A2   address text of this node, left, right
--   %R %R1       register name, sized for the node's type, or for an
--                operand's when the alternative sets rz = 1 or 2
--   %P %P1       the same register at pointer size, for addressing
--   %W %W1       the same register at 32 bits, for extension
--   %C1 %C2      an operand's literal number: its value or its frame offset
--   %N1 %N2      the same, negated
--   %z %z1 %z2   size suffix
--   %I           mnemonic for this operator, from target.mnem(node, alt)
--   %L0 %L1      fresh labels, stable within one expansion
--   %S           the top of the target's own spill area, taken off it
--   %%           a literal percent
-- Anything else after % is literal, so AT&T register names pass through.
--
-- An alternative may also carry:
--   f            the operand is a float, which on a machine with a
--                file of its own means it is named with %F.  Beside p it
--                is the pointee that is the float, as s and u are.
--   m            the operand must be one the machine can address, which
--                rules out a constant even where the class allows one
--   t            sixteen bytes, which only the extended float is
--   rz = 1 | 2   size %R from that operand instead of from the node
--   imm = true   a flag the target's mnem can read, for addi against add
--   clob = {i}   allocation-order registers the template destroys.  Any of
--                them still holding a value, meaning an index below the
--                current register, is saved and restored around it.
--   pred = f     f(left, right, node) has the last word after the shapes
--                fit, for what a shape cannot say: a constant's range.

local md = {}

local CLASS = {z = 4, c = 8, i = 12, a = 16, e = 20, n = 63}
local SIZE  = {b = 1, w = 2, l = 4, q = 8, t = 16}

-- Shapes are read only, so alternatives that spell one the same way share
-- one table.
local SHAPES = {}

function md.shape(s)
	local sh = SHAPES[s]
	if sh then return sh end
	sh = {max = CLASS[s:sub(1, 1)]}
	local sign
	if not sh.max then
		error("bad operand class in shape '" .. s .. "'")
	end
	for i = 2, #s do
		local c = s:sub(i, i)
		if c == "*" then
			sh.deref = true
		elseif SIZE[c] then
			sh.size = SIZE[c]
		elseif c == "p" then
			sh.kind = "ptr"
		elseif c == "f" then
			sign = "float"
		elseif c == "m" then
			sh.nocon = true
		elseif c == "r" then
			sh.pin = true
		elseif c == "v" then
			sh.thru = true
		elseif c == "s" then
			sign = "int"
		elseif c == "u" then
			sign = "uint"
		else
			error("bad shape letter '" .. c .. "' in '" .. s .. "'")
		end
	end
	-- beside p, a sign letter is the pointee's, not the pointer's
	if sign then
		if sh.kind == "ptr" then sh.pkind = sign else sh.kind = sign end
	end
	SHAPES[s] = sh
	return sh
end

local SEL = {L = "left", R = "right", T = "this"}
local CTX = {s = "stack", c = "cc", e = "eff"}

function md.ev(s)
	local list = {}
	for tok in (s or ""):gmatch("%S+") do
		local sel = SEL[tok:sub(1, 1)]
		if not sel then
			error("bad ev selector in '" .. tok .. "'")
		end
		local step = {sel = sel, ctx = "reg", bump = 0}
		for i = 2, #tok do
			local c = tok:sub(i, i)
			if c == "1" then
				step.bump = 1
			elseif c == "*" then
				step.deref = true
			elseif CTX[c] then
				step.ctx = CTX[c]
			else
				error("bad ev flag '" .. c .. "' in '" .. tok .. "'")
			end
		end
		list[#list + 1] = step
	end
	return list
end

-- F is R for a machine that keeps floats in a file of their own: the
-- same depth, a different set of registers.  T is the same again for a
-- machine whose widest float lives in a frame slot rather than a
-- register, which is what an x87 stack amounts to.
local ESC = {A = true, R = true, P = true, W = true, C = true,
	     N = true, z = true, I = true, L = true, S = true,
	     F = true, T = true}

-- The parts are pairs in one flat list: an escape letter and its operand
-- number or false, or false and the literal text.
function md.template(s)
	local out, lit, i = {}, {}, 1
	local function flush()
		if #lit > 0 then
			out[#out + 1] = false
			out[#out + 1] = table.concat(lit)
			lit = {}
		end
	end
	while i <= #s do
		local c = s:sub(i, i)
		if c ~= "%" then
			lit[#lit + 1] = c
			i = i + 1
		elseif s:sub(i + 1, i + 1) == "%" then
			lit[#lit + 1] = "%"
			i = i + 2
		else
			local k = s:sub(i + 1, i + 1)
			if not ESC[k] then
				lit[#lit + 1] = c
				i = i + 1
			else
				local d = s:sub(i + 2, i + 2)
				local arg = tonumber(d)
				flush()
				out[#out + 1] = k
				out[#out + 1] = arg or false
				i = i + (arg and 3 or 2)
			end
		end
	end
	flush()
	return out
end

-- The parsed forms of `ev` and `asm`, built on first use and kept.  A whole
-- target parsed up front costs more than the table itself; most files reach
-- only a few alternatives.  They are read only, and kept by the text, so
-- alternatives that spell one the same way share it.
local STEPS, PARTS = {}, {}

function md.steps(a)
	local e = a.ev or ""
	local s = STEPS[e]
	if not s then
		s = md.ev(e)
		STEPS[e] = s
	end
	return s
end

function md.parts(a)
	local t = a.asm or ""
	local p = PARTS[t]
	if not p then
		p = md.template(t)
		PARTS[t] = p
	end
	return p
end

-- Compile one target description.  Every alternative is checked here, so a
-- malformed table fails at load rather than at the first tree that hits it.
-- The checked forms of ev and asm are dropped; md.steps and md.parts rebuild
-- them when a tree actually reaches the alternative.
-- What a header is entitled to ask the compiler about the types, derived
-- from the two sizes that tell the rest apart.  A target that says
-- something different keeps its own answer.
local function typemacros(spec)
	local ws = spec.ptrsize
	local long = ws == 8 and "long int" or "int"
	local ulong = ws == 8 and "long unsigned int" or "unsigned int"
	local i64 = ws == 8 and "long int" or "long long int"
	local u64 = ws == 8 and "long unsigned int" or
		"long long unsigned int"
	local lmax = ws == 8 and "9223372036854775807L" or "2147483647L"
	local umax = ws == 8 and "18446744073709551615UL" or "4294967295U"
	local d = {
		__SIZE_TYPE__ = ulong,
		__PTRDIFF_TYPE__ = long,
		__INTPTR_TYPE__ = long,
		__UINTPTR_TYPE__ = ulong,
		__WCHAR_TYPE__ = "int",
		__WINT_TYPE__ = "unsigned int",
		__CHAR16_TYPE__ = "short unsigned int",
		__CHAR32_TYPE__ = "unsigned int",
		__SIG_ATOMIC_TYPE__ = "int",
		__INTMAX_TYPE__ = i64,
		__UINTMAX_TYPE__ = u64,
		__INT8_TYPE__ = "signed char",
		__UINT8_TYPE__ = "unsigned char",
		__INT16_TYPE__ = "short int",
		__UINT16_TYPE__ = "short unsigned int",
		__INT32_TYPE__ = "int",
		__UINT32_TYPE__ = "unsigned int",
		__INT64_TYPE__ = i64,
		__UINT64_TYPE__ = u64,
		__INT_LEAST8_TYPE__ = "signed char",
		__UINT_LEAST8_TYPE__ = "unsigned char",
		__INT_LEAST16_TYPE__ = "short int",
		__UINT_LEAST16_TYPE__ = "short unsigned int",
		__INT_LEAST32_TYPE__ = "int",
		__UINT_LEAST32_TYPE__ = "unsigned int",
		__INT_LEAST64_TYPE__ = i64,
		__UINT_LEAST64_TYPE__ = u64,
		__INT_FAST8_TYPE__ = "signed char",
		__UINT_FAST8_TYPE__ = "unsigned char",
		__INT_FAST16_TYPE__ = long,
		__UINT_FAST16_TYPE__ = ulong,
		__INT_FAST32_TYPE__ = long,
		__UINT_FAST32_TYPE__ = ulong,
		__INT_FAST64_TYPE__ = i64,
		__UINT_FAST64_TYPE__ = u64,
		__SCHAR_MAX__ = "127",
		__SHRT_MAX__ = "32767",
		__INT_MAX__ = "2147483647",
		__LONG_MAX__ = lmax,
		__LONG_LONG_MAX__ = "9223372036854775807LL",
		__INTMAX_MAX__ = "9223372036854775807L",
		__UINTMAX_MAX__ = "18446744073709551615UL",
		__SIZE_MAX__ = umax,
		__PTRDIFF_MAX__ = lmax,
		__INTPTR_MAX__ = lmax,
		__UINTPTR_MAX__ = umax,
		__WCHAR_MAX__ = "2147483647",
		__WCHAR_MIN__ = "(-2147483647 - 1)",
		__WINT_MAX__ = "4294967295U",
		__WINT_MIN__ = "0U",
		__SIG_ATOMIC_MAX__ = "2147483647",
		__SIG_ATOMIC_MIN__ = "(-2147483647 - 1)",
		__INT8_MAX__ = "127",
		__INT16_MAX__ = "32767",
		__INT32_MAX__ = "2147483647",
		__INT64_MAX__ = "9223372036854775807L",
		__UINT8_MAX__ = "255",
		__UINT16_MAX__ = "65535",
		__UINT32_MAX__ = "4294967295U",
		__UINT64_MAX__ = "18446744073709551615UL",
		__CHAR_BIT__ = "8",
		__SIZEOF_POINTER__ = tostring(ws),
		__SIZEOF_SIZE_T__ = tostring(ws),
		__SIZEOF_PTRDIFF_T__ = tostring(ws),
		__SIZEOF_LONG__ = tostring(ws),
		__SIZEOF_INT__ = "4",
		__SIZEOF_SHORT__ = "2",
		__SIZEOF_LONG_LONG__ = "8",
		__SIZEOF_WCHAR_T__ = "4",
		__SIZEOF_WINT_T__ = "4",
		__SIZEOF_FLOAT__ = "4",
		__SIZEOF_DOUBLE__ = "8",
		__SIZEOF_LONG_DOUBLE__ = "8",
		__BIGGEST_ALIGNMENT__ = "16",
		-- What <float.h> says, in the spelling a header or a
		-- program reads straight from the compiler.  A target
		-- whose long double is the x87 type says so itself and
		-- these stand in for the rest.
		__FLT_RADIX__ = "2",
		__FLT_EVAL_METHOD__ = "0",
		__FLT_MANT_DIG__ = "24",
		__FLT_DIG__ = "6",
		__FLT_DECIMAL_DIG__ = "9",
		__FLT_MIN_EXP__ = "(-125)",
		__FLT_MAX_EXP__ = "128",
		__FLT_MIN_10_EXP__ = "(-37)",
		__FLT_MAX_10_EXP__ = "38",
		__FLT_EPSILON__ = "1.19209289550781250000000000000000000e-7F",
		__FLT_MIN__ = "1.17549435082228750796873653722224568e-38F",
		__FLT_MAX__ = "3.40282346638528859811704183484516925e+38F",
		__FLT_NORM_MAX__ = "3.40282346638528859811704183484516925e+38F",
		__FLT_DENORM_MIN__ = "1.40129846432481707092372958328991613e-45F",
		__FLT_HAS_DENORM__ = "1",
		__FLT_HAS_INFINITY__ = "1",
		__FLT_HAS_QUIET_NAN__ = "1",
		__DBL_MANT_DIG__ = "53",
		__DBL_DIG__ = "15",
		__DBL_DECIMAL_DIG__ = "17",
		__DBL_MIN_EXP__ = "(-1021)",
		__DBL_MAX_EXP__ = "1024",
		__DBL_MIN_10_EXP__ = "(-307)",
		__DBL_MAX_10_EXP__ = "308",
		__DBL_EPSILON__ = "((double)2.22044604925031308084726333618164062e-16L)",
		__DBL_MIN__ = "((double)2.22507385850720138309023271733240406e-308L)",
		__DBL_MAX__ = "((double)1.79769313486231570814527423731704357e+308L)",
		__DBL_NORM_MAX__ = "((double)1.79769313486231570814527423731704357e+308L)",
		__DBL_DENORM_MIN__ = "((double)4.94065645841246544176568792868221372e-324L)",
		__DBL_HAS_DENORM__ = "1",
		__DBL_HAS_INFINITY__ = "1",
		__DBL_HAS_QUIET_NAN__ = "1",
		__LDBL_MANT_DIG__ = "53",
		__LDBL_DIG__ = "15",
		__LDBL_DECIMAL_DIG__ = "17",
		__LDBL_MIN_EXP__ = "(-1021)",
		__LDBL_MAX_EXP__ = "1024",
		__LDBL_MIN_10_EXP__ = "(-307)",
		__LDBL_MAX_10_EXP__ = "308",
		__LDBL_EPSILON__ = "2.22044604925031308084726333618164062e-16L",
		__LDBL_MIN__ = "2.22507385850720138309023271733240406e-308L",
		__LDBL_MAX__ = "1.79769313486231570814527423731704357e+308L",
		__LDBL_NORM_MAX__ = "1.79769313486231570814527423731704357e+308L",
		__LDBL_DENORM_MIN__ = "4.94065645841246544176568792868221372e-324L",
		__LDBL_HAS_DENORM__ = "1",
		__LDBL_HAS_INFINITY__ = "1",
		__LDBL_HAS_QUIET_NAN__ = "1",
		-- The GNU C extensions this compiler implements are the
		-- ones a header asks about by this name: typeof, statement
		-- expressions, attributes, case ranges, __builtin_bswap.
		__GNUC__ = "8",
		__GNUC_MINOR__ = "5",
		__GNUC_PATCHLEVEL__ = "0",
		__GNUC_STDC_INLINE__ = "1",
		__VERSION__ = '"mcc 0.3"',
		__STDC_HOSTED__ = "1",
		__STDC_UTF_16__ = "1",
		__STDC_UTF_32__ = "1",
		__STDC_IEC_559__ = "1",
		__GCC_IEC_559 = "2",
		__NO_INLINE__ = "1",
		__PRAGMA_REDEFINE_EXTNAME = "1",
		-- The memory orders the `__atomic` builtins take, in the
		-- numbering gcc gives them, which is also the order of
		-- the memory_order enum in <stdatomic.h>.
		__ATOMIC_RELAXED = "0",
		__ATOMIC_CONSUME = "1",
		__ATOMIC_ACQUIRE = "2",
		__ATOMIC_RELEASE = "3",
		__ATOMIC_ACQ_REL = "4",
		__ATOMIC_SEQ_CST = "5",
		__GCC_ATOMIC_BOOL_T_LOCK_FREE = "2",
		__GCC_ATOMIC_CHAR_T_LOCK_FREE = "2",
		__GCC_ATOMIC_CHAR16_T_LOCK_FREE = "2",
		__GCC_ATOMIC_CHAR32_T_LOCK_FREE = "2",
		__GCC_ATOMIC_WCHAR_T_LOCK_FREE = "2",
		__GCC_ATOMIC_SHORT_T_LOCK_FREE = "2",
		__GCC_ATOMIC_INT_T_LOCK_FREE = "2",
		__GCC_ATOMIC_LONG_T_LOCK_FREE = "2",
		__GCC_ATOMIC_LLONG_T_LOCK_FREE = "2",
		__GCC_ATOMIC_POINTER_T_LOCK_FREE = "2",
	}
	if not spec.charsigned then
		d.__CHAR_UNSIGNED__ = "1"
	end
	spec.predef = spec.predef or {}
	for k, v in pairs(d) do
		if spec.predef[k] == nil then spec.predef[k] = v end
	end
end

-- Find the one table that says the same as `a`, by a walk down `trie`
-- through the value of each field in `keys`, or of a[1] to a[#a] when
-- there is no `keys`.  No strings are made, so the string table does not
-- grow for a key that is thrown away.
local NIL = {}

local function intern(trie, a, keys)
	local node = trie
	for i = 1, keys and #keys or #a do
		local v = a[keys and keys[i] or i]
		if v == nil then v = NIL end
		local nx = node[v]
		if not nx then
			nx = {}
			node[v] = nx
		end
		node = nx
	end
	local got = node[NIL]
	if not got then
		got = a
		node[NIL] = a
	end
	return got
end

function md.target(spec)
	assert(spec.name and spec.ptrsize and spec.nreg, "target lacks name/ptrsize/nreg")
	assert(spec.regname and spec.addr and spec.suffix, "target lacks regname/addr/suffix")
	-- Alternatives and lists that say the same thing become one table,
	-- so the copies a target builds in a loop are left for the collector.
	local fields, seen = {}, {}
	for _, ops in pairs(spec.code) do
		for _, alts in pairs(ops) do
			for _, a in ipairs(alts) do
				for k in pairs(a) do
					if not seen[k] then
						seen[k] = true
						fields[#fields + 1] = k
					end
				end
			end
		end
	end
	local same, samelist, sameclob = {}, {}, {}
	for ctx, ops in pairs(spec.code) do
		for op, alts in pairs(ops) do
			for i, a in ipairs(alts) do
				local where = spec.name .. "." .. ctx .. "." .. op .. "[" .. i .. "]"
				local ok, err = pcall(function()
					-- The shapes replace their strings in place, so
					-- the alternative grows no new fields.  One
					-- table may appear under two contexts.
					for k = 1, 2 do
						if type(a[k]) == "string" then
							a[k] = md.shape(a[k])
						end
					end
					md.ev(a.ev)
					if type(a.asm) ~= "function" then
						md.template(a.asm or "")
					end
					if a.clob then
						assert(spec.save and spec.restore,
						 "target lacks save/restore")
					end
				end)
				if not ok then
					error(where .. ": " .. tostring(err), 0)
				end
			end
			-- A clobber list is found by its contents first.
			for i, a in ipairs(alts) do
				if a.clob then a.clob = intern(sameclob, a.clob) end
				alts[i] = intern(same, a, fields)
			end
			ops[op] = intern(samelist, alts)
		end
	end
	typemacros(spec)
	return spec
end

-- Argument classification, shared by the parser's parameter placement and
-- the target's call.  Each item says whether it is floating point and how
-- wide it is; the answer says where it goes.  Three target facts decide it:
--
--   nfltreg   how many floating point argument registers there are, zero on
--             a target whose ABI carries a double in an ordinary register
--   vafloat   whether a variadic argument may use one of them
--   fltspill  whether a float that finds the float file full falls back to
--             the integer file rather than to the stack
--
-- nfixed is the number of named parameters when the callee is variadic, and
-- nil otherwise.
-- How a record travels: a list of pieces, each with the offset it is read
-- from, how wide it is, and which register file it goes in.  Answers nil
-- for a record that travels in memory instead.
--
-- Splitting a record into fixed-width pieces is the rule each of these
-- ABIs follows; where they differ is in which pieces are floating point,
-- so a target with its own answer writes its own classifier.

-- Pieces of a fixed width, none of them floating point.
function md.pieces(size, width, flt)
	local out = {}

	for i = 1, (size + width - 1) // width do
		out[i] = {off = (i - 1) * width,
			  size = math.min(width, size - (i - 1) * width),
			  flt = flt or false}
	end
	return out
end

-- The SysV rule: anything too big goes in memory, and an empty record
-- takes no register at all.  What is left is split
-- into eight-byte pieces, and a piece holds floating point only if
-- everything in it is floating point.  Anything else in the piece and
-- the whole piece travels in an integer register.  The x87 type sends
-- the record to memory, and answers "x87" too when it is all there is.
function md.eightbytes(ty, limit)
	if ty.size > (limit or 16) then return nil end
	local cls = {}

	-- The psABI merge: integer wins, then x87 makes it memory.
	local function merge(k, c)
		local o = cls[k]

		if o == nil or o == c then cls[k] = c
		elseif o == "int" or c == "int" then cls[k] = "int"
		elseif o == "sse" and c == "sse" then cls[k] = "sse"
		else cls[k] = "mem" end
	end

	local function walk(t, off)
		if t.kind == "array" then
			for i = 0, (t.n or 0) - 1 do
				walk(t.of, off + i * t.of.size)
			end
		elseif t.members then
			for _, m in ipairs(t.members) do
				walk(m.ty, off + m.off)
			end
		else
			local k = off // 8 + 1

			if t.x87 then
				merge(k, "x87")
				merge(k + 1, "x87up")
			elseif t.kind == "float" then
				merge(k, "sse")
			else
				merge(k, "int")
			end
		end
	end

	walk(ty, 0)
	if cls[1] == "x87" and cls[2] == "x87up" then return nil, "x87" end
	local out = md.pieces(ty.size, 8)
	for i, p in ipairs(out) do
		if cls[i] == "mem" or cls[i] == "x87" or cls[i] == "x87up" then
			return nil
		end
		p.flt = cls[i] == "sse"
	end
	return out
end

-- A record of up to `most` members that are all the same floating point
-- type travels in that many vector registers.  This is the AAPCS
-- homogeneous float aggregate, and RISC-V has the same idea for two.
-- The members of a union overlap, so what counts is the places a float
-- sits: every one the same width, filling the record without a gap.
function md.floatrec(ty, most)
	local base, at, ok = nil, {}, true

	local function walk(t, off)
		if not ok then return end
		if t.kind == "array" then
			for i = 0, (t.n or 0) - 1 do
				walk(t.of, off + i * t.of.size)
			end
		elseif t.members then
			for _, m in ipairs(t.members) do walk(m.ty, off + m.off) end
		elseif t.kind == "float" and (not base or base == t.size) then
			base = t.size
			at[off] = true
		else
			ok = false
		end
	end

	walk(ty, 0)
	if not ok or not base then return nil end
	local n = ty.size // base
	if n < 1 or n > most or base * n ~= ty.size then return nil end
	for i = 0, n - 1 do
		if not at[i * base] then return nil end
	end
	return md.pieces(ty.size, base, true)
end

-- `hidden` says the callee takes the address of its record result ahead of
-- everything else, in the first integer argument register.
-- `nar` overrides how many argument registers there are, for a
-- function that named a convention of its own.
function md.classify(t, items, nfixed, hidden, nar)
	local nflt = t.nfltreg or 0
	local ws = t.ptrsize
	-- Whether a value twice the register width takes an even aligned
	-- pair.  Most of these ABIs say so; the i386 one does not.
	local pairal = t.pairalign ~= false
	-- How many argument registers there are here.  A convention that
	-- sends everything to the stack once the callee is variadic says
	-- so, and then there are none: `-mregparm` on i386 is that.
	nar = nar or t.nargreg or 0
	if nfixed and t.varstack then nar = 0 end
	-- `shadow` is the room the caller leaves below the stacked
	-- arguments for the callee to spill its register ones into, which
	-- the Microsoft convention asks for and System V does not.
	local out, gp, fp, stk = {}, 0, 0, t.shadow or 0
	-- The hidden pointer takes the first argument register, or the
	-- first stack word on a machine that has none.
	if hidden then
		if nar > 0 then gp = 1 else stk = stk + 1 end
	end
	for i, it in ipairs(items) do
		local named = not nfixed or i <= nfixed

		-- Under a positional convention an argument's place is its
		-- position, whichever file it lands in: a double second
		-- takes the second float register and spends the second
		-- integer one.
		if t.positional then
			gp = gp > fp and gp or fp
			fp = gp
		end
		local flt = it.flt and nflt > 0 and (named or t.vafloat)
		local words = (it.size + ws - 1) // ws
		local d = {flt = flt, size = it.size, words = words}
		if it.rec then
			-- A record travels in pieces or in memory, and it
			-- is all or nothing: one that would need more
			-- registers than are left goes whole in memory.
			-- How a record splits for an argument, where a
			-- machine splits one differently there than it
			-- does for a result.
			local how = t.argpieces or t.eightbytes
			local cls = how and how(it.rec, named)
			local ni, nf = 0, 0

			for _, p in ipairs(cls or {}) do
				if p.flt then nf = nf + 1
				else ni = ni + 1 end
			end
			if cls and gp + ni <= nar and fp + nf <= nflt
			then
				d.pieces = {}
				for k, p in ipairs(cls) do
					local r
					if p.flt then r, fp = fp, fp + 1
					else r, gp = gp, gp + 1 end
					d.pieces[k] = {flt = p.flt, r = r,
						       off = p.off,
						       size = p.size}
				end
			elseif t.recref and not cls then
				-- Too big for any register: the caller
				-- makes a copy and hands over its address,
				-- which is one word.
				d.ref, d.words = true, 1
				if gp < nar then
					d.reg, gp = gp, gp + 1
				else
					d.stk, stk = stk, stk + 1
				end
			else
				d.mem = true
				-- On the stack a record keeps an alignment
				-- past the word, as the ABIs other than
				-- i386's ask.
				local al = (it.rec.align or 1) // ws
				if pairal and al > 1 and stk % al ~= 0 then
					stk = stk + al - stk % al
				end
				d.stk, stk = stk, stk + words
				if t.regstop then gp = nar end
			end
		elseif it.x87 then
			-- The extended float is always in memory: no
			-- register of either file holds one.
			d.flt = false
			d.x87 = true
			if pairal and stk % 2 == 1 then stk = stk + 1 end
			d.stk, stk = stk, stk + words
		elseif words > 1 then
			-- A value twice the register width takes an even
			-- aligned pair.  When a pair is not left it goes
			-- whole on the stack, where the ABI would split it;
			-- that costs a word and nothing else.
			if pairal and gp % 2 == 1 then gp = gp + 1 end
			if gp + words <= nar then
				d.reg, gp = gp, gp + words
			else
				if pairal and stk % 2 == 1 then
					stk = stk + 1
				end
				d.stk, stk = stk, stk + words
				-- A convention that stops handing out
				-- registers at the first argument that
				-- does not fit: gcc's -mregparm.
				if t.regstop then gp = nar end
			end
		elseif flt and fp < nflt then
			d.reg, fp = fp, fp + 1
		elseif not flt and gp < nar then
			d.reg, gp = gp, gp + 1
		elseif it.flt and t.fltspill and gp < nar then
			d.reg, gp, d.flt = gp, gp + 1, false
		else
			d.stk, stk = stk, stk + 1
		end
		out[i] = d
	end
	return out, gp, fp, stk
end

return md
