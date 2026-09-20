-- SPDX-License-Identifier: ISC
-- Declarations, statements and expressions.
--
-- One pass: a statement is parsed, generated and released before the next is
-- read.  Nothing whole-function is kept except the symbol table for the
-- scopes that are open and the assembly already written.

local tree  = require "tree"
local gen   = require "gen"
local types = require "types"
local md    = require "md"
local buf   = require "buf"
local peep  = require "peep"

local P = {}
P.__index = P

local BIN = {
	["||"] = {1, "OROR"},  ["&&"] = {2, "ANDAND"},
	["|"]  = {3, "OR"},    ["^"]  = {4, "XOR"},   ["&"] = {5, "AND"},
	["=="] = {6, "EQ"},    ["!="] = {6, "NE"},
	["<"]  = {7, "LT"},    ["<="] = {7, "LE"},
	[">"]  = {7, "GT"},    [">="] = {7, "GE"},
	["<<"] = {8, "SHL"},   [">>"] = {8, "SHR"},
	["+"]  = {9, "ADD"},   ["-"]  = {9, "SUB"},
	["*"]  = {10, "MUL"},  ["/"]  = {10, "DIV"}, ["%"] = {10, "MOD"},
}

local OPASSIGN = {
	["+="] = "ADD", ["-="] = "SUB", ["*="] = "MUL", ["/="] = "DIV",
	["%="] = "MOD", ["&="] = "AND", ["|="] = "OR",  ["^="] = "XOR",
	["<<="] = "SHL", [">>="] = "SHR",
}

-- Tokens that can begin a declaration.
local DECLKW = {}
for _, k in ipairs{"char", "short", "int", "long", "unsigned", "signed",
		   "_Bool",
		   "void", "float", "double",
		   "struct", "union", "enum", "const", "volatile",
		   "static", "extern", "register", "inline", "typedef"} do
	DECLKW[k] = true
end
local QUAL = {const = true, volatile = true, register = true}
-- `register` is a qualifier here, but at file scope beside an asm name
-- it binds the name to a machine register, so its presence is recorded.
-- C11 _Atomic, which is a qualifier on its own and a specifier with a
-- type in parentheses.  An atomic object has the layout of the type
-- under it here, and <stdatomic.h> does the work, so both forms only
-- have to be read and let through.
local ATOMICKW = {_Atomic = true, __Atomic = true}

-- Spellings that carry no meaning here.  They are ordinary identifiers to
-- the lexer, so the parser has to know them by name.
local IGNORE = {}
for _, k in ipairs{"_Noreturn", "restrict", "__restrict", "__restrict__",
		   "__signed__", "__const",
		   "__volatile", "__volatile__", "__extension__"} do
	IGNORE[k] = true
end

-- The other spellings of `inline`, which mean the same thing.
local INLINEKW = {__inline = true, __inline__ = true}
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

local function bitcount(op, v, w)
	local bits = w * 8

	if w < 8 then v = v & ((1 << bits) - 1) end
	if op:sub(1, 3) == "ffs" then
		if v == 0 then return 0 end
		local n = 1

		while v & 1 == 0 do v, n = v >> 1, n + 1 end
		return n
	end
	if op:sub(1, 3) == "clz" then
		-- what gcc leaves undefined for zero: the whole width
		local n = 0

		while n < bits and (v >> (bits - 1 - n)) & 1 == 0 do
			n = n + 1
		end
		return n
	end
	if op:sub(1, 3) == "ctz" then
		if v == 0 then return bits end
		local n = 0

		while v & 1 == 0 do v, n = v >> 1, n + 1 end
		return n
	end
	local n = 0

	for _ = 1, bits do
		n = n + (v & 1)
		v = v >> 1
	end
	if op:sub(1, 6) == "parity" then return n & 1 end
	return n
end

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
		   "__builtin_strcpy", "__builtin_strncpy",
		   "__builtin_prefetch", "__builtin_alloca",
		   "__builtin_add_overflow", "__builtin_sub_overflow",
		   "__builtin_mul_overflow", "__builtin_object_size",
		   "__builtin_dynamic_object_size",
		   "__builtin_return_address",
		   "__builtin_extract_return_addr",
		   "__builtin_frob_return_addr",
		   "__builtin_frame_address"} do
	BUILTIN[k] = true
end
-- Classifying a float is a test on its bit pattern, so it goes to the
-- runtime like the arithmetic does rather than to libm.
local FCLASS = {isnan = "isnan", isinf = "isinf", isfinite = "isfin",
		isinf_sign = "isinfs", signbit = "isneg",
		isnormal = "isnorm"}

for k in pairs(BITFN) do BUILTIN["__builtin_" .. k] = true end
for k in pairs(FCLASS) do BUILTIN["__builtin_" .. k] = true end
for _, k in ipairs{"fabs", "fabsf", "fabsl",
		   "sqrt", "sqrtf", "sqrtl"} do
	BUILTIN["__builtin_" .. k] = true
end
-- The ones that are a value rather than a calculation.
-- The values a header names rather than works out, at each width.
-- The stem cannot be read off the end of the name: huge_val ends in
-- the letter that would say long double.
local INFVAL = {}
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
-- Builtins whose answer is a property of the program text, not a value
-- to work out.  The arm __builtin_choose_expr does not take is parsed
-- and thrown away, which is what its whole point is.
local SPECIAL = {__builtin_constant_p = true,
		 __builtin_choose_expr = true,
		 __builtin_types_compatible_p = true,
		 __builtin_offsetof = true,
		 __builtin_unreachable = true, __builtin_trap = true}
-- GNU C answers to `__attribute` as well as `__attribute__`.
local ATTRKW = {__attribute__ = true, __attribute = true}
-- C99 spells it one way and GNU C two others.
local COMPLEXKW = {_Complex = true, __complex__ = true,
		   __complex = true}
-- GNU C names the halves of a complex value with these.
local CPLXHALF = {__real__ = "re", __real = "re",
		  __imag__ = "im", __imag = "im"}
local PARENED = {__attribute__ = true, __attribute = true, __asm__ = true,
		 asm = true, __declspec = true}
-- _Alignas, which says what an object is aligned to, not what it is.
local ALIGNAS = {_Alignas = true, alignas = true}
-- The names a compiler answers to for the type a variadic walker is.
local VALIST = {__builtin_va_list = true, __gnuc_va_list = true}
-- The named floating point types of TS 18661-3.  The glibc headers take
-- these for keywords once the compiler says it is GCC 7 or later.
local FLOATN = {_Float32 = "f32", _Float32x = "f64", _Float64 = "f64",
		_Float64x = "f64", _Float128 = "f128",
		__float128 = "f128", __ieee128 = "f128"}
-- _Alignof, and the names a compiler that predates it answers to.
local ALIGNOF = {_Alignof = true, __alignof = true, __alignof__ = true}
-- A compile time assertion, in either spelling.
local STATICASSERT = {_Static_assert = true, static_assert = true}

-- The names GNU C answers to for a 128-bit integer.
local INT128 = {__int128 = true, __int128_t = true,
		__uint128_t = "unsigned"}

-- GNU __auto_type: a declaration whose type is its initializer's.  It
-- stands for a type until the initializer has been read.
local AUTOTYPE = {kind = "auto", size = 0, align = 1, name = "__auto_type"}

-- GNU typeof, which names the type of a type name or of an expression.
local TYPEOF = {typeof = true, __typeof = true, __typeof__ = true}
local STORAGE = {static = true, extern = true, typedef = true}
-- C11 and GNU spell thread storage two ways.  It stands beside static
-- or extern rather than in place of one.
local TLSKW = {_Thread_local = true, __thread = true}
local ASMKW = {asm = true, __asm = true, __asm__ = true}
-- What a string or character literal may be prefixed with.
local STRPREFIX = {u8 = true, u = true, U = true, L = true}
-- The keywords that begin a statement rather than an expression.
local STMTKW = {}
for _, k in ipairs{"if", "while", "for", "do", "switch", "case",
		   "default", "break", "continue", "return", "goto",
		   "{", ";"} do
	STMTKW[k] = true
end
-- The name of the function being compiled, which C99 says is a string
-- declared at the top of every body.
local FUNCNAME = {__func__ = true, __FUNCTION__ = true,
		  __PRETTY_FUNCTION__ = true}

-- Constant arithmetic.  Lua's integers are 64 bits, which is exactly the
-- width this has to answer for.
-- Forward: constant folding is defined with the expression parser, and
-- the type rules above it ask whether something is a constant zero.
local fold
-- What a test settles to, which is more than `fold` answers: an
-- operand may decide on its own.  Defined with the statements.
local settle
-- Forward: a pointer into a named object, as a symbol and a byte offset.
local symoff

local function foldbin(o, a, b, uns)
	local lt = uns and math.ult or function(x, y) return x < y end
	if o == "ADD" then return a + b end
	if o == "SUB" then return a - b end
	if o == "MUL" then return a * b end
	if o == "AND" then return a & b end
	if o == "OR"  then return a | b end
	if o == "XOR" then return a ~ b end
	if o == "SHL" then return a << b end
	if o == "EQ"  then return a == b and 1 or 0 end
	if o == "NE"  then return a ~= b and 1 or 0 end
	if o == "LT"  then return lt(a, b) and 1 or 0 end
	if o == "LE"  then return not lt(b, a) and 1 or 0 end
	if o == "GT"  then return lt(b, a) and 1 or 0 end
	if o == "GE"  then return not lt(a, b) and 1 or 0 end
	-- Lua's >> is logical, and its // is a floor divide, which is what
	-- an arithmetic shift right means.
	if o == "SHR" then
		if uns then return a >> b end
		return b >= 64 and (a < 0 and -1 or 0) or a // (1 << b)
	end
	if b == 0 then return 0 end
	-- Lua has no unsigned divide, and a value past the sign bit is
	-- exactly what a limit like UINT64_MAX is.
	if uns then
		if o ~= "DIV" and o ~= "MOD" then return nil end
		local q

		if b < 0 then
			q = math.ult(a, b) and 0 or 1
		elseif a >= 0 then
			q = a // b
		else
			-- halve, divide, double, then fix the remainder
			q = ((a >> 1) // b) << 1
			if not math.ult(a - q * b, b) then q = q + 1 end
		end
		if o == "DIV" then return q end
		return a - q * b
	end
	if o == "DIV" then
		local q = a // b
		-- C truncates towards zero where Lua floors
		if q < 0 and q * b ~= a then q = q + 1 end
		return q
	end
	if o == "MOD" then return a - foldbin("DIV", a, b, uns) * b end
	return nil
end

function P.new(lx, target, emit, opt)
	local p = setmetatable({lx = lx, t = target, emit = emit}, P)
	-- An eight-byte scalar does not fit a four-byte register, so on a
	-- 32-bit target it lives in memory and its operations are calls.
	-- WIDE=1 forces the same treatment on a 64-bit one, which is how it
	-- is tested against a compiler that has the type natively.
	p.widen = target.ptrsize == 4 or (opt and opt.wide) or false
	-- Only a machine whose registers are narrower than the value needs
	-- the two-register calling convention for one.
	-- reach a symbol another unit may replace through the table the
	-- loader fills in, which is what a shared object needs
	p.pic = (opt and opt.pic) or false
	-- The stack protector: "all", "strong", or true for the plain one,
	-- which only guards a function with a buffer on its frame.
	p.ssp = opt and opt.ssp or nil
	-- What -fvisibility said, which every definition without an
	-- attribute of its own takes.
	p.visibility = opt and opt.visibility or nil
	-- Labels a block declared with GNU __label__, by the name the
	-- source gave them.
	p.labelmap = {}
	-- How many loops enclose what is being read.
	p.loopdepth = 0
	p.revived = 0
	p.konsts, p.regions, p.nregion = {}, {}, 0
	-- The peephole runs only when asked for: -O0 is what a debugger
	-- and a bug report want.
	if opt and (opt.opt or 0) > 0 then p.peep = target.peep end
	local T = types.new(target)
	p.ty = T
	p.word = target.ptrsize == 8 and T.i64 or T.i32
	p.uword = target.ptrsize == 8 and T.u64 or T.u32
	-- Address arithmetic is never wide: a pointer fits a register by
	-- definition.  On a 32-bit target the word is already narrow; on a
	-- 64-bit one under the forced mode this keeps offsets out of the
	-- memory path.
	p.aword = target.ptrsize == 8 and
		{kind = "int", size = 8, align = 8, name = "long",
		 addr = true} or p.word
	p.fbits = target.ptrsize	-- unused, kept for symmetry
	-- Plain char is signed on x86 and unsigned on RISC-V, and a program
	-- that uses it to index a table can tell.
	p.plainchar = target.charsigned == false and T.u8 or T.i8
	p.base = {
		char = p.plainchar, uchar = T.u8, short = T.i16, ushort = T.u16,
		int = T.i32, uint = T.u32, long = p.word, ulong = p.uword,
		void = T.void,
	}
	p.out, p.data, p.sdata = buf.new(), buf.new(), buf.new()
	p.g = gen.new(target, p.out, opt)
	p.dg = p.data
	-- String literals land in their own buffer, because an initializer
	-- may make one while its own data is being written.
	p.sg = p.sdata
	p.globals, p.scopes, p.tags, p.nstr = {}, {}, {{}}, 0
	-- Definitions put aside until the unit says whether it wants them.
	p.deferred = {}
	if os.getenv("MEM") then rawset(_G, "__parser", p) end
	p.marks, p.nlocals, p.maxlocals = {}, 0, 0
	p:adv()
	return p
end

function P:err(msg)
	local t = self.tok
	error(("%s:%d: %s"):format((t and t.file) or self.lx.name or "-",
		(t and t.line) or 0, msg), 0)
end

local function copytok(t)
	return {kind = t.kind, text = t.text, val = t.val, line = t.line,
		file = t.file, pfx = t.pfx}
end

function P:adv()
	if self.ahead then
		self.tok = self.ahead
		self.ahead = nil
	else
		self.tok = copytok(self.lx:next())
	end
	return self.tok
end

function P:peek()
	if not self.ahead then
		self.ahead = copytok(self.lx:next())
	end
	return self.ahead
end

-- A token list read the way the lexer is read, so a body put aside can
-- be parsed later without being preprocessed again.
--
-- The tokens are kept flat, six slots to a token, rather than as a list
-- of tables.  A body of a hundred tokens then costs about five kilobytes
-- instead of twenty, and a header full of `static inline` functions
-- nothing calls is what this is for.
local Replay = {}
Replay.__index = Replay

local NFIELD = 6

function Replay:next()
	local i = self.i
	local f = self.f

	-- The count is kept, not asked for: a token whose text or value
	-- is nothing leaves a hole, and a table with one has no length.
	if i > self.n then
		return {kind = "eof", line = self.line, file = self.file}
	end
	self.i = i + NFIELD
	return {kind = f[i], text = f[i + 1], val = f[i + 2],
		line = f[i + 3], file = f[i + 4], pfx = f[i + 5]}
end

-- Where a name is written, by the token that stands beside it.  The
-- answer is the last such place, which is all a label needs: what it
-- has to forget is a value a later write could change.
local WROTE = {["="] = true, ["+="] = true, ["-="] = true,
	       ["*="] = true, ["/="] = true, ["%="] = true,
	       ["&="] = true, ["|="] = true, ["^="] = true,
	       ["<<="] = true, [">>="] = true,
	       ["++"] = true, ["--"] = true}

local function scanwrites(f, n)
	local w, g, any, wv = {}, {}, false, {}

	for i = 1, n, NFIELD do
		if f[i] == "name" then
			local nm = f[i + 1]
			local nx = f[i + NFIELD]
			local pv = i > NFIELD and f[i - NFIELD] or nil

			-- `x = `, `x += `, `x++`; and `++x`, and `&x`,
			-- whose holder may write through it.
			if WROTE[nx or ""] or WROTE[pv or ""] or
			   pv == "&" then
				w[nm] = i
				-- `x = <one thing>;` is a write whose
				-- value can be read off the tokens, and
				-- one that writes what is already there
				-- changes nothing.
				local v = nx == "=" and
					f[i + 2 * NFIELD] ~= nil and
					f[i + 3 * NFIELD] == ";" and
					{kind = f[i + 2 * NFIELD],
					 text = f[i + 2 * NFIELD + 1],
					 val = f[i + 2 * NFIELD + 2]} or false

				local l = wv[nm]

				if not l then l = {}; wv[nm] = l end
				l[#l + 1] = {at = i, v = v}
			end
			-- The first jump to a label is the earliest
			-- place a run can arrive from.
			if pv == "goto" and not g[nm] then g[nm] = i end
		end
		-- `goto *e` can arrive at any label whose address was
		-- taken, and which one is not written down.
		if f[i] == "goto" and f[i + NFIELD] == "*" then
			any = true
		end
	end
	return {w = w, g = g, any = any, wv = wv}
end

-- The tokens of a function body, the brace that opens it to the one
-- that closes it, taken off the input.
-- The names of the builtin that takes a block off the stack.
local ALLOCA = {alloca = true, __builtin_alloca = true}

function P:capture()
	local f, depth, n = {}, 0, 0
	local once = false

	while true do
		local t = self.tok

		if t.kind == "eof" then self:err("unterminated body") end
		f[n + 1], f[n + 2], f[n + 3] = t.kind, t.text, t.val
		f[n + 4], f[n + 5], f[n + 6] = t.line, t.file, t.pfx
		n = n + NFIELD
		-- One object shared by every call, or a block taken off
		-- the stack: building the body twice would make two.
		if t.kind == "static" or ALLOCA[t.text or ""] then
			once = true
		end
		if t.kind == "{" then
			depth = depth + 1
		elseif t.kind == "}" then
			depth = depth - 1
			if depth == 0 then
				self:adv()
				break
			end
		end
		self:adv()
	end
	-- A body that is one `return` is worth building where it was
	-- called however many tokens it holds: the kernel writes its
	-- configuration tests that way, and most of what makes them
	-- long -- a `_Generic` on the type, a `sizeof` on the width --
	-- settles to nothing at all.
	local nsemi, depth = 0, 0

	for i = 1, n, NFIELD do
		local k = f[i]

		if k == "{" then depth = depth + 1
		elseif k == "}" then depth = depth - 1
		elseif k == ";" and depth == 1 then nsemi = nsemi + 1
		end
	end
	local single = nsemi == 1 and f[1] == "{" and
		f[1 + NFIELD] == "return"
	return {f = f, n = n, name = self.lx.name, ntok = n // NFIELD,
		once = once, single = single or nil,
		line = f[n - 2], file = f[n - 1]}
end

-- A reader over a captured body.  One is made for each pass over it,
-- so a body may be replayed at every place that calls it.
function P:reader(rec)
	return setmetatable({f = rec.f, i = 1, n = rec.n, name = rec.name,
			     line = rec.line, file = rec.file}, Replay)
end

-- Parse something out of a list of tokens taken earlier.  The input the
-- parser was reading is put back afterwards.
function P:replay(rec, f, ...)
	local olx, otok, oahead = self.lx, self.tok, self.ahead

	self.lx, self.ahead = self:reader(rec), nil
	self:adv()
	f(self, ...)
	self.lx, self.tok, self.ahead = olx, otok, oahead
end

function P:accept(k)
	if self.tok.kind == k then
		local t = self.tok
		self:adv()
		return t
	end
end

function P:expect(k)
	return self:accept(k) or self:err("expected " .. k .. ", found " ..
		(self.tok.text or self.tok.kind))
end

-- scopes ---------------------------------------------------------------

-- Frame slots are reused once a block ends.  A long function with many
-- disjoint blocks, which is what a virtual machine's dispatch loop is,
-- would otherwise want a slot for every local it ever names.
function P:push()
	self.scopes[#self.scopes + 1] = {}
	self.tags[#self.tags + 1] = {}
	self.marks[#self.marks + 1] = self.nlocals
end

function P:pop()
	self.scopes[#self.scopes] = nil
	self.tags[#self.tags] = nil
	self.nlocals = self.marks[#self.marks] or self.nlocals
	-- The extended float area is handed out once and never given
	-- back: the generator holds its offsets for the whole function.
	if self.x87floor and self.nlocals < self.x87floor then
		self.nlocals = self.x87floor
	end
	self.marks[#self.marks] = nil
end

-- Where the extended floats of this function live: eight slots of
-- sixteen bytes, indexed by the same depth a register would be, and
-- taken from the frame the first time one is wanted.
function P:x87base()
	if not self.x87at then
		self.nlocals = self.nlocals + 16
		if self.nlocals > self.maxlocals then
			self.maxlocals = self.nlocals
		end
		self.x87at = self.t.slot(self.nlocals)
		self.x87floor = self.nlocals
	end
	return self.x87at
end

function P:find(name)
	for i = #self.scopes, 1, -1 do
		local s = self.scopes[i][name]
		if s then return s end
	end
	return self.globals[name]
end

-- A definition put aside is built once something needs one out of
-- line: a call this compiler will not inline, or the address of it.
local function wantbody(e, dead)
	local g = e and e.fn

	-- An inline definition is not built because this unit uses it:
	-- C says the external one lives wherever a declaration asked
	-- for it.  A `static inline` has nowhere else to live, so using
	-- it is what builds it; a GNU `extern inline` always has one
	-- somewhere else.
	if not g then return end
	-- A call nothing can reach is not a use.  The kernel guards a
	-- whole family of calls with a test that settles, and the body
	-- behind one of those names things this configuration left out.
	if dead then return end
	-- A call may come before the body: the kernel declares a syscall
	-- handler, calls it, and defines it after.  Remember that this
	-- unit used it, and the definition asks when it arrives.
	g.used = true
	if g.pending and not g.c99 and not g.gnuextern then
		g.wanted = true
	end
end

function P:findtag(name)
	for i = #self.tags, 1, -1 do
		local s = self.tags[i][name]
		if s then return s end
	end
	return nil
end

function P:addtag(name, st)
	self.tags[#self.tags][name] = st
end

function P:declare(name, s)
	if #self.scopes > 0 then
		self.scopes[#self.scopes][name] = s
	else
		self.globals[name] = s
	end
	return s
end

-- An array takes as many word slots as it needs; its name stands for the
-- address of its first element, which is the lowest slot.
function P:alloc(ty)
	local words = math.max(1, (ty.size + self.t.ptrsize - 1) //
			       self.t.ptrsize)
	self.nlocals = self.nlocals + words
	if self.nlocals > self.maxlocals then
		self.maxlocals = self.nlocals
	end
	-- How far a body built where it was called reached, which is
	-- how many slots it has to keep.
	if self.hiwater and self.nlocals > self.hiwater then
		self.hiwater = self.nlocals
	end
	-- The answer is the lowest address of the object, wherever the
	-- target grows its frame from.
	local off = self.t.upward and self.t.slot(self.nlocals - words + 1)
		or self.t.slot(self.nlocals)

	-- A slot handed out again is a different object: what the last
	-- one held says nothing about this one.
	if self.konsts then
		for i = 0, words - 1 do
			self.konsts[self.t.slot(self.nlocals - i)] = nil
		end
		self.konsts[off] = nil
	end
	return off
end

-- types ----------------------------------------------------------------

-- Names that can only stand in front of a declaration, never an
-- expression, so seeing one settles which this is.
local DECLONLY = {__attribute__ = true, __attribute = true,
		  __declspec = true,
		  _Alignas = true, alignas = true}

-- Whether this token could begin a type.  The statement parser asks about
-- the token in hand and the cast parser about the one after a `(`, so it
-- takes the token rather than reading it.
function P:typetok(tk)
	if DECLKW[tk.kind] then return true end
	if tk.kind ~= "name" then return false end
	if TYPEOF[tk.text] then return true end
	if ATOMICKW[tk.text] then return true end
	if TLSKW[tk.text] then return true end
	if FLOATN[tk.text] then return true end
	if VALIST[tk.text] then return true end
	if DECLONLY[tk.text] then return true end
	if tk.text == "__auto_type" then return true end
	if INT128[tk.text] then return true end
	if COMPLEXKW[tk.text] then return true end
	local s = self:find(tk.text)
	return s ~= nil and s.kind == "typedef"
end

function P:istype()
	if self.tok.kind == "[" and self:peek().kind == "[" then
		return true
	end
	return self:typetok(self.tok)
end

-- GNU typeof: a type name gives itself, and anything else gives the type
-- the expression is declared with.  An array stays an array and a
-- function stays a function; neither decays.  Nothing is emitted for the
-- expression; only its type is wanted.
function P:typeofspec()
	self:adv()
	self:expect("(")
	local t
	if self:istype() then
		t = self:typename()
	else
		t = self:expression().ty
	end
	self:expect(")")
	return t
end

-- A C23 attribute, `[[...]]`, which this compiler reads and ignores.  It
-- may appear where a declaration or a statement may.
function P:attrs()
	while self.tok.kind == "[" and self:peek().kind == "[" do
		self:adv()
		self:adv()
		local depth = 0

		while self.tok.kind ~= "eof" do
			if self.tok.kind == "[" then depth = depth + 1
			elseif self.tok.kind == "]" then
				if depth == 0 then break end
				depth = depth - 1
			end
			self:adv()
		end
		self:expect("]")
		self:expect("]")
	end
end

-- Skip a balanced parenthesised group, for __attribute__ and its kin.
-- What an attribute says, for the few that change what this compiler
-- does.  The rest are read and dropped: they say something about the
-- program that this compiler does not act on.
--
-- Both spellings of a name mean the same thing, so the underscores go.
local function attrname(s)
	return (s:gsub("^__", ""):gsub("__$", ""))
end

-- `__attribute__((a, b(1), c("x")))`, or the C23 `[[...]]` spelling.
-- Answers a table of what was named, which a caller looks in for the
-- ones it cares about.
-- Attributes whose argument is a constant expression, not a token to skip.
local NUMATTR = {aligned = true, alloc_size = true, vector_size = true}

function P:attrlist(into)
	local a = into or {}

	self:expect("(")
	self:expect("(")
	local depth = 1

	while depth > 0 and self.tok.kind ~= "eof" do
		if self.tok.kind == "name" then
			local name = attrname(self.tok.text)

			self:adv()
			if self.tok.kind == "(" then
				-- the argument, when it is one string or a
				-- constant an attribute here acts on;
				-- anything else is skipped
				local save = self:peek()

				self:adv()
				if save.kind == "str" then
					a[name] = save.text
					self:adv()
				elseif NUMATTR[name] then
					local m = tree.mark()

					a[name] = fold(self:ternary())
					tree.release(m)
				elseif save.kind == "num" then
					a[name] = save.val
					self:adv()
				end
				-- an argument nests, as `aligned(sizeof(x))`
				local d = 1
				while d > 0 and self.tok.kind ~= "eof" do
					if self.tok.kind == "(" then
						d = d + 1
					elseif self.tok.kind == ")" then
						d = d - 1
						if d == 0 then break end
					end
					self:adv()
				end
				self:expect(")")
			else
				a[name] = a[name] == nil and true or a[name]
			end
		elseif self.tok.kind == "(" then
			depth = depth + 1
			self:adv()
		elseif self.tok.kind == ")" then
			depth = depth - 1
			self:adv()
		else
			self:adv()
		end
	end
	self:expect(")")
	return a
end

-- Skip a parenthesised group, answering with the one string inside it
-- if that is all it holds: `__asm__("name")` after a declarator says
-- what the object is really called.
-- C11 _Static_assert, which is a declaration and so may stand wherever
-- one may: at file scope, among the members of a record, and in a block.
function P:staticassert()
	local at = copytok(self.tok)

	self:adv()
	self:expect("(")
	local v = self:constexpr()
	local why

	if self:accept(",") then
		why = self.tok.kind == "str" and self.tok.text or nil
		self:expect("str")
	end
	self:expect(")")
	self:accept(";")
	if v == 0 then
		-- the assertion is reported where it was written, not
		-- where the parser has reached by the end of it
		self.tok = at
		self:err("static assertion failed" ..
			(why and (": " .. why) or ""))
	end
end

function P:skipparens()
	if self.tok.kind ~= "(" then return end
	local depth, only, n = 0, nil, 0
	repeat
		if self.tok.kind == "(" then depth = depth + 1
		elseif self.tok.kind == ")" then depth = depth - 1
		elseif self.tok.kind == "eof" then self:err("unbalanced (")
		elseif self.tok.kind == "str" then
			only = (only or "") .. self.tok.text
			n = n + 1
		else
			n = n + 1
		end
		self:adv()
	until depth == 0
	return only
end

-- Qualifiers and the spellings that mean nothing to this compiler.
function P:quals(into)
	while true do
		local k = self.tok.kind
		if QUAL[k] then
			if k == "register" then self.sawreg = true end
			self:adv()
		elseif k == "name" and (IGNORE[self.tok.text] or
		   ATOMICKW[self.tok.text]) then
			self:adv()
		elseif k == "name" and ATTRKW[self.tok.text] then
			self:adv()
			local a = self:attrlist(into or self.declattrs)

			-- The calling convention sticks to the declarator
			-- it stands in, as in `R (EFIAPI *f)(void)`.
			if a and a.ms_abi then self.msabi = true end
		elseif k == "name" and PARENED[self.tok.text] then
			local isasm = ASMKW[self.tok.text]

			self:adv()
			local text = self:skipparens()

			-- `__asm__("name")` after a declarator says what
			-- the object answers to, which is how a header
			-- points one name at another.
			if isasm and text then self.asmname = text end
		else
			return
		end
	end
end

-- struct or union, named or not, defined here or referred to.
-- Attributes may stand between `struct` and its tag, and again after
-- the closing brace.  None of them changes what this compiler does.
function P:skipattrs(into)
	while true do
		local k = self.tok.kind

		if k == "[" and self:peek().kind == "[" then
			self:attrs()
		elseif k == "name" and ATTRKW[self.tok.text] then
			self:adv()
			self:attrlist(into)
		elseif k == "name" and PARENED[self.tok.text] then
			self:adv()
			self:skipparens()
		elseif k == "name" and IGNORE[self.tok.text] then
			self:adv()
		else
			return
		end
	end
end

function P:record(kind)
	local attrs = {}

	self:skipattrs(attrs)
	local tag
	if self.tok.kind == "name" then
		tag = self.tok.text
		self:adv()
	end
	local st
	-- A definition names a type in the block it stands in.  One of
	-- the same tag further out is a different type, so only a tag
	-- already in this block is the one being completed.
	local defining = self.tok.kind == "{"

	if tag and defining then
		st = self.tags[#self.tags][tag]
	elseif tag then
		st = self:findtag(tag)
	end
	if not st or (st.kind ~= kind) then
		st = self.ty.record(kind, tag)
		if tag then self:addtag(tag, st) end
	end
	if self:accept("{") then
		local members = {}
		while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
			-- An assertion may stand among the members, which
			-- is how a macro checks a value inside a sizeof.
			if self.tok.kind == "name" and
			   STATICASSERT[self.tok.text] then
				self:staticassert()
				goto nextmember
			end
			local mbase = self:declspec()

			if self:accept(";") then
				-- A struct or union with no name after it
				-- puts its own members in this one.
				if mbase and (mbase.kind == "struct" or
					      mbase.kind == "union") then
					members[#members + 1] = {ty = mbase}
				end
			else
				repeat
					local name, wrap = self:dcl(false)
					local bits
					if self:accept(":") then
						bits = self:constexpr()
					end
					local mty = wrap(mbase)
					if bits and (bits < 0 or
						     bits > mty.size * 8) then
						self:err("a bit-field of " ..
							bits .. " bits")
					end
					members[#members + 1] =
						{name = name, ty = mty,
						 bits = bits}
				until not self:accept(",")
				self:expect(";")
			end
			::nextmember::
		end
		self:expect("}")
		self:skipattrs(attrs)
		self.ty.complete(st, members, attrs)
		return st
	end
	-- After a tag with no body the attribute belongs to what is being
	-- declared, not to the type: `struct s __section(".ref.text") *f()`
	-- is how a kernel says which section the function goes in.
	self:skipattrs(self.declattrs)
	return st
end

function P:enumspec()
	self:skipattrs()
	local tag
	if self.tok.kind == "name" then
		tag = self.tok.text
		self:adv()
	end
	local ty = self.ty.i32

	-- `enum e` on its own names one already declared, and a packed
	-- one is not an int.
	if tag and self.tok.kind ~= "{" then
		local had = self:findtag(tag)

		if had then return had end
	end
	if self:accept("{") then
		local next_ = 0
		local lo, hi = 0, 0

		while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
			local name = self:expect("name").text
			if self:accept("=") then next_ = self:constexpr() end
			self:declare(name, {kind = "const", ty = self.ty.i32,
					    val = next_})
			if next_ < lo then lo = next_ end
			if next_ > hi then hi = next_ end
			next_ = next_ + 1
			if not self:accept(",") then break end
		end
		self:expect("}")
		-- `enum e { ... } __attribute__((packed))` asks for the
		-- narrowest type that holds every value, which a kernel
		-- counts on when it lays a structure out.
		local a = {}

		while self.tok.kind == "name" and ATTRKW[self.tok.text] do
			self:adv()
			self:attrlist(a)
		end
		if a.packed then ty = self:enumfit(lo, hi) end
	end
	if tag then self:addtag(tag, ty) end
	return ty
end

-- The narrowest integer type that holds every value of an enumeration.
function P:enumfit(lo, hi)
	local T = self.ty

	if lo >= 0 then
		if hi <= 255 then return T.u8 end
		if hi <= 65535 then return T.u16 end
		if hi <= 4294967295 then return T.u32 end
		return T.u64
	end
	if lo >= -128 and hi <= 127 then return T.i8 end
	if lo >= -32768 and hi <= 32767 then return T.i16 end
	if lo >= -2147483648 and hi <= 2147483647 then return T.i32 end
	return T.i64
end

-- The specifiers before a declarator.  Returns the base type and the
-- storage class.
function P:declspec()
	local storage, sign, longs, base = nil, nil, 0, nil
	local size, inl, align, tls, cplx
	self.alignas = nil
	-- What the attributes on this declaration said, for the few that
	-- change what is emitted.
	self.declattrs = {}
	while true do
		local k = self.tok.kind
		if k == "[" and self:peek().kind == "[" then
			self:attrs()
		elseif QUAL[k] then
			if k == "register" then self.sawreg = true end
			self:adv()
		elseif k == "name" and IGNORE[self.tok.text] then
			self:adv()
		elseif k == "name" and ATTRKW[self.tok.text] then
			self:adv()
			self:attrlist(self.declattrs)
		elseif k == "name" and PARENED[self.tok.text] then
			self:adv()
			self:skipparens()
		elseif k == "name" and ATOMICKW[self.tok.text] then
			self:adv()
			if self.tok.kind == "(" and not base and not size
			   then
				self:adv()
				base = self:typename()
				self:expect(")")
			end
		elseif k == "name" and VALIST[self.tok.text] and not base
		   and not size then
			base = self:valist()
			self:adv()
		elseif k == "name" and COMPLEXKW[self.tok.text] then
			cplx = true
			self:adv()
		elseif k == "name" and FLOATN[self.tok.text] and not base
		   and not size then
			base = self.ty[FLOATN[self.tok.text]]
			self:adv()
		elseif k == "name" and INT128[self.tok.text] and not size then
			if INT128[self.tok.text] == "unsigned" then
				sign = "unsigned"
			end
			size = "__int128"
			self:adv()
		elseif k == "name" and self.tok.text == "__auto_type"
		   and not base and not size then
			-- GNU C: the type is whatever the initializer is.
			-- The declaration works it out when it gets there.
			base = AUTOTYPE
			self:adv()
		elseif k == "name" and ALIGNAS[self.tok.text] then
			self:adv()
			self:expect("(")
			local a
			if self:istype() then
				a = self:typename().align
			else
				a = self:constexpr()
			end
			self:expect(")")
			if a and a > (align or 0) then align = a end
		elseif k == "name" and TYPEOF[self.tok.text] and not base
		   and not size then
			base = self:typeofspec()
		elseif k == "inline" or
		       (k == "name" and INLINEKW[self.tok.text]) then
			inl = true
			self:adv()
		elseif STORAGE[k] then
			storage = k
			self:adv()
		elseif k == "name" and TLSKW[self.tok.text] then
			tls = true
			self:adv()
		elseif k == "signed" or k == "unsigned" then
			sign = k
			self:adv()
		elseif k == "long" then
			longs = longs + 1
			self:adv()
		elseif k == "short" then
			size = "short"
			self:adv()
		elseif k == "int" then
			-- `int` only fills out a width that short or long
			-- has already named, so `short unsigned int` is
			-- still a short.
			if size ~= "short" then size = k end
			self:adv()
		elseif k == "char" or k == "void" or k == "_Bool" then
			size = k
			self:adv()
		elseif k == "float" then
			size = "float"
			self:adv()
		elseif k == "double" then
			size = "double"
			self:adv()
		elseif k == "struct" or k == "union" then
			self:adv()
			base = self:record(k)
		elseif k == "enum" then
			self:adv()
			base = self:enumspec()
		elseif k == "name" and not base and not size and longs == 0
		   and not sign then
			local s = self:find(self.tok.text)
			if s and s.kind == "typedef" then
				base = s.ty
				self:adv()
			else
				break
			end
		else
			break
		end
	end
	self.alignas = align
	self.tls = tls
	if base then
		if cplx then base = self.ty.complex(base) end
		return base, storage, inl
	end
	local t
	if size == "__int128" then
		t = sign == "unsigned" and self.ty.u128 or self.ty.i128
	elseif size == "_Bool" then
		t = self.ty.bool
	elseif size == "float" then
		t = self.ty.f32
	elseif size == "double" then
		t = longs > 0 and self.ty.ldouble or self.ty.f64
	elseif size == "void" then
		t = self.ty.void
	elseif size == "char" then
		t = sign and (sign == "unsigned" and self.ty.u8 or self.ty.i8)
			or self.plainchar
	elseif size == "short" then
		t = sign == "unsigned" and self.ty.u16 or self.ty.i16
	elseif longs > 1 then
		-- long long is sixty-four bits everywhere, which on a 32-bit
		-- target is wider than a register
		t = sign == "unsigned" and self.ty.u64 or self.ty.i64
	elseif longs > 0 then
		t = sign == "unsigned" and self.uword or self.word
	elseif size or sign then
		t = sign == "unsigned" and self.ty.u32 or self.ty.i32
	elseif cplx then
		-- `_Complex` on its own is `double _Complex`
		t = self.ty.f64
	else
		return nil, storage, inl
	end
	if cplx then t = self.ty.complex(t) end
	return t, storage, inl
end

-- The parameters of a function type.  The fourth result says the list was
-- empty: C leaves such a function unprototyped, so a call to it is not
-- checked against anything.
function P:params()
	local list, variadic = {}, false
	if self.tok.kind == ")" then return list, variadic, nil, true end
	if self.tok.kind == "void" and self:peek().kind == ")" then
		self:adv()
		return list, variadic
	end
	local names
	repeat
		if self:accept("...") then
			variadic = true
			break
		end
		local b = self:declspec() or self.ty.i32
		self.vmdim = true
		local name, wrap = self:dcl(true)
		list[#list + 1] = self.ty.decay(wrap(b))
		if name then
			names = names or {}
			names[#list] = name
		end
	until not self:accept(",")
	return list, variadic, names
end

-- A declarator, read inside out.  Returns the name, which may be nil for an
-- abstract one, and a function that wraps the base type.
function P:dcl(abstract)
	-- Only the outermost array of a parameter decays to a pointer, so
	-- only that one may have a size the compiler cannot work out.
	local vm = self.vmdim
	self.vmdim = nil
	self.msabi = nil
	-- Each parameter is a declaration of its own and starts a fresh
	-- attribute table.  Keep the one this declaration is filling, so
	-- that an attribute written after the parameter list still lands
	-- where the caller reads it.
	local outer = self.declattrs
	self:quals()
	local nstar = 0
	while self:accept("*") do
		self:quals()
		nstar = nstar + 1
	end

	local name, innerwrap
	local sfx = {}

	if self.tok.kind == "(" then
		self:adv()
		local k = self.tok.kind
		-- An attribute here belongs to the declarator inside the
		-- parentheses, as in `EFI_STATUS (EFIAPI *f)(void)`.
		local att = k == "name" and (ATTRKW[self.tok.text] or
			PARENED[self.tok.text])

		if k == "*" or k == "(" or k == "[" or att or
		   (k == "name" and not self:istype()) then
			name, innerwrap = self:dcl(abstract)
			self:expect(")")
		else
			-- Read before the parameters: each of those is a
			-- declarator of its own and clears the flag.
			local ms = self.msabi or
				(self.declattrs and self.declattrs.ms_abi)
			local ps, va, nm, np = self:params()

			self:expect(")")
			sfx[#sfx + 1] = function(t)
				local f = self.ty.func(t, ps, va, nm)

				f.noproto = np
				f.msabi = ms or nil
				return f
			end
		end
	elseif self.tok.kind == "name" then
		name = self.tok.text
		self:adv()
	end

	while true do
		if self:accept("[") then
			local n, vlen, vexpr
			-- `[restrict]` and `[static 4]` say something about
			-- the parameter, not about the size
			self:quals()
			if self.tok.kind == "static" then
				self:adv()
				self:quals()
			end
			-- An array reached through a pointer or through a
			-- declarator in parentheses is not the outermost
			-- type, so it keeps its bound: `struct e (*p)[256]`
			-- is a pointer to an array, not an array.
			if self.tok.kind ~= "]" and
			   vm and nstar == 0 and #sfx == 0 and
			   not innerwrap then
				-- C99 lets this name an earlier parameter,
				-- and glibc's regex.h does.  The array is
				-- about to become a pointer, so the size
				-- says nothing.
				local depth = 0

				while self.tok.kind ~= "eof" do
					if self.tok.kind == "[" then
						depth = depth + 1
					elseif self.tok.kind == "]" then
						if depth == 0 then break end
						depth = depth - 1
					end
					self:adv()
				end
			elseif self.tok.kind ~= "]" then
				local mk = tree.mark()

				-- A bound the compiler cannot work out.  A
				-- declaration that reserves nothing can
				-- stand with one, which is how an assertion
				-- macro writes a check meant to fold away.
				local ex = self:ternary()

				n = fold(ex)
				vlen = n == nil
				-- A real one keeps its expression: the
				-- declaration works the size out where it
				-- stands.
				if vlen then vexpr = ex else tree.release(mk) end
				-- A build-time assertion is written as an
				-- array whose bound goes negative when the
				-- claim is false, so this has to be an
				-- error and not a shrug.
				if n and n < 0 then
					self:err("array bound is negative")
				end
			end
			self:expect("]")

			sfx[#sfx + 1] = function(t)
				local a = self.ty.array(t, n)

				if vlen then a.vlen, a.vexpr = true, vexpr end
				return a
			end
		elseif self:accept("(") then
			-- Read before the parameters: each of those is a
			-- declarator of its own and clears the flag.
			local ms = self.msabi or
				(self.declattrs and self.declattrs.ms_abi)
			local ps, va, nm, np = self:params()

			self:expect(")")
			sfx[#sfx + 1] = function(t)
				local f = self.ty.func(t, ps, va, nm)

				f.noproto = np
				f.msabi = ms or nil
				return f
			end
		else
			break
		end
	end
	self.declattrs = outer
	self:quals()

	local function wrap(t)
		for _ = 1, nstar do t = self.ty.ptr(t) end
		for i = #sfx, 1, -1 do t = sfx[i](t) end
		if innerwrap then t = innerwrap(t) end
		return t
	end
	return name, wrap
end

-- A type name, as in a cast or in sizeof.
function P:typename()
	local b = self:declspec()
	if not b then return nil end
	local _, wrap = self:dcl(true)
	return wrap(b)
end

-- expressions ----------------------------------------------------------

-- Nodes whose code does not depend on the signedness of their own type, so
-- a conversion that only reinterprets the bits can change it in place.
local RETYPABLE = {CONST = true, AUTO = true, NAME = true, INDIR = true,
		   ADDR = true, CALL = true}

local function isptr(t) return t.kind == "ptr" end
local function isrec(t) return t.kind == "struct" or t.kind == "union" end
local function isflt(t) return t.kind == "float" end

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

-- `__attribute__((vector_size(n)))` makes a type n bytes wide, holding
-- as many of what it was written as will fit.  This compiler has no
-- vector arithmetic, so what it offers is the shape: the size, the
-- alignment and the elements.  A header that only declares such a type
-- compiles, and code that tries to add two of them does not, which is
-- the honest answer.
function P:vectored(ty, attrs)
	local n = attrs and attrs.vector_size

	if type(n) ~= "number" or n <= 0 or ty.kind == "array" or
	   ty.size == 0 or n % ty.size ~= 0 then
		return ty
	end
	local a = self.ty.array(ty, n // ty.size)

	-- A vector is aligned to its width, but no wider than the widest
	-- vector the machine loads in one go, which is 16 bytes on every
	-- target here.  An explicit `aligned` overrides it either way:
	-- that is how the unaligned spellings are said.
	if type(attrs.aligned) == "number" then
		a.align = attrs.aligned
	else
		a.align = n < 16 and n or 16
	end
	return a
end

-- The character type of a string literal.  A prefix says how wide its
-- characters are.  u8 and no prefix are both plain char, and a character
-- above 127 in a wide literal keeps its source byte: this compiler does
-- not decode the source encoding.
function P:strelem(pfx)
	if pfx == "L" then return self.ty.i32 end
	if pfx == "u" then return self.ty.u16 end
	if pfx == "U" then return self.ty.u32 end
	return self.plainchar
end

-- _Complex, as a pair the target already knows how to carry: the type
-- is a record of two members, so a value of one lives in a frame slot
-- and its halves are the two slots inside it.
--
-- `cplxparts` answers the real half, the imaginary half, and the code
-- that has to run before either is read.  A real value has an
-- imaginary half of zero and needs no slot of its own.
function P:cplxparts(e, elem, pre)
	local half = elem.size

	if not e.ty.complex then
		return self:conv(self:rvalue(e), elem),
			self:fconst(0.0, elem)
	end
	local src = e

	if src.op ~= "AUTO" then
		local off = self:alloc(src.ty)

		pre[#pre + 1] = self:assignto(tree.auto(src.ty, off), src)
		src = tree.auto(src.ty, off)
	end
	local se = src.ty.complex
	local re = self:conv(tree.auto(se, src.off), elem)
	local im = self:conv(tree.auto(se, src.off + se.size), elem)

	if se == elem then return re, im end
	-- A conversion between element types needs somewhere to put the
	-- answer, because each half is read twice by the code that uses
	-- it and a conversion is not free.
	local off = self:alloc(self.ty.complex(elem))

	pre[#pre + 1] = self:assignto(tree.auto(elem, off), re)
	pre[#pre + 1] = self:assignto(tree.auto(elem, off + half), im)
	return tree.auto(elem, off), tree.auto(elem, off + half)
end

-- A complex value built out of its two halves, in a slot of its own.
function P:cplxmake(elem, re, im, pre)
	local cty = self.ty.complex(elem)
	local off = self:alloc(cty)

	pre[#pre + 1] = self:assignto(tree.auto(elem, off), re)
	pre[#pre + 1] = self:assignto(tree.auto(elem, off + elem.size), im)
	pre[#pre + 1] = tree.auto(cty, off)
	return tree.node("SEQ", cty, nil, nil, {arms = pre})
end

-- Which element type two operands of an arithmetic operation share.
function P:cplxelem(a, b)
	local ea = a.ty.complex or a.ty
	local eb = b and (b.ty.complex or b.ty) or ea

	if not isflt(ea) then ea = self.ty.f64 end
	if not isflt(eb) then eb = self.ty.f64 end
	return self:usual(ea, eb)
end

-- The multiply and the divide go to the runtime, under the names every
-- other compiler gives them, because the divide needs a test to keep
-- its range and this compiler builds no branches inside an expression.
-- The float and double helpers wear the names every compiler on the
-- platform gives them, because their pair travels the same way in
-- both.  The extended ones do not: the ABI returns that pair on the
-- x87 stack and this compiler hands over a pointer, so they are named
-- apart rather than made to look interchangeable.
local CPLXFN = {MUL = {[4] = "__mulsc3", [8] = "__muldc3",
		       [16] = "__mcc_mulxc3"},
		DIV = {[4] = "__divsc3", [8] = "__divdc3",
		       [16] = "__mcc_divxc3"}}

function P:cplxcall(name, cty, args)
	local n = tree.node("CALL", cty,
		tree.name(self.ty.func(cty, {}, true), name), nil,
		{args = args, direct = true})

	n.retrec = cty
	n.retslot = self:temp(cty)
	return tree.node("SEQ", cty, nil, nil,
		{arms = {n, tree.auto(cty, n.retslot)}})
end

function P:cplxarith(op, a, b)
	local elem = self:cplxelem(a, b)
	local pre = {}
	local ar, ai = self:cplxparts(a, elem, pre)

	if op == "NEG" then
		return self:cplxmake(elem, self:arith("SUB",
			self:fconst(0.0, elem), ar),
			self:arith("SUB", self:fconst(0.0, elem), ai), pre)
	end
	if op == "CONJ" then
		return self:cplxmake(elem, ar,
			self:arith("SUB", self:fconst(0.0, elem), ai), pre)
	end
	local br, bi = self:cplxparts(b, elem, pre)

	if op == "ADD" or op == "SUB" then
		return self:cplxmake(elem, self:arith(op, ar, br),
			self:arith(op, ai, bi), pre)
	end
	if op == "EQ" or op == "NE" then
		local same = tree.binary("ANDAND", self.ty.i32,
			self:test(self:arith("EQ", ar, br)),
			self:test(self:arith("EQ", ai, bi)))

		if op == "NE" then
			same = tree.unary("LNOT", self.ty.i32, same)
		end
		pre[#pre + 1] = same
		return tree.node("SEQ", self.ty.i32, nil, nil, {arms = pre})
	end
	local fn = CPLXFN[op] and CPLXFN[op][elem.size]

	if not fn then
		self:err("_Complex has no " .. op)
		return self:cplxmake(elem, ar, ai, pre)
	end
	local call = self:cplxcall(fn, self.ty.complex(elem),
		{ar, ai, br, bi})

	if #pre == 0 then return call end
	pre[#pre + 1] = call
	return tree.node("SEQ", call.ty, nil, nil, {arms = pre})
end

function P:rtcall(name, rty, args)
	-- soft: the runtime takes bit patterns in ordinary registers, whatever
	-- the target's calling convention does with a float.
	local n = tree.node("CALL", rty,
		tree.name(self.ty.func(rty, {}, true), name), nil,
		{args = args, direct = true, soft = true})
	if not self:widepass(rty) then return n end
	if not self.t.wideargs then
		self:err("a " .. (rty.name or "wide") ..
			" result is not supported on " .. self.t.name)
	end
	local slot = self:temp(rty)
	n.retslot, n.ty = slot, self.word
	return tree.node("SEQ", rty, nil, nil,
		{arms = {n, tree.auto(rty, slot)}})
end

function P:fprefix(t)
	if t.size > 8 then
		self:err("binary128 arithmetic is not supported")
	end
	return t.size == 8 and "d" or "f"
end

-- `narrow` is set by the step below, so that the byte it makes is not
-- taken for another value in need of a comparison.
function P:conv(n, ty, narrow)
	if n.ty == ty then return n end
	if ty.complex then
		-- To _Complex: the real half is the value converted and
		-- the imaginary half is zero, or both halves when it was
		-- complex already.
		local pre = {}
		local re, im = self:cplxparts(n, ty.complex, pre)

		return self:cplxmake(ty.complex, re, im, pre)
	end
	if n.ty.complex then
		-- From _Complex: the value is the real half.  C says so,
		-- and <complex.h> spells creal as exactly this cast.
		local pre = {}
		local src = n

		if src.op ~= "AUTO" then
			local off = self:alloc(src.ty)

			pre[#pre + 1] = self:assignto(
				tree.auto(src.ty, off), src)
			src = tree.auto(src.ty, off)
		end
		local re = self:conv(tree.auto(src.ty.complex, src.off), ty)

		if #pre == 0 then return re end
		pre[#pre + 1] = re
		return tree.node("SEQ", ty, nil, nil, {arms = pre})
	end
	if isrec(ty) or isrec(n.ty) then return n end
	-- Anything at all becomes 0 or 1, which is what makes _Bool a
	-- different type from unsigned char.
	if ty.isbool and not narrow and not n.ty.isbool then
		local t = self:test(n)

		if not (tree.ops[t.op] and tree.ops[t.op].rel) then
			t = tree.binary("NE", self.ty.i32, t,
				tree.const(t.ty, 0))
		end
		return self:conv(t, ty, true)
	end
	if self:iswide(ty) or self:iswide(n.ty) then
		return self:wconv(n, ty)
	end
	if isflt(ty) or isflt(n.ty) then
		local from, to = n.ty, ty
		-- A constant converts here and now, which is the only way a
		-- static initializer may hold one.  An integer side may
		-- still be a tree, as `0.92 * (1 << 11)` is, so fold it.
		if n.op ~= "CONST" and not isflt(from) and not isptr(from) then
			local v = fold(n)
			if v then n = tree.const(from, v) end
		end
		local kv = isflt(from) and self:fvalue(n) or n.val

		if n.op == "CONST" and kv ~= nil then
			local v = kv

			if isflt(to) then
				if not isflt(from) and from.kind == "uint" and
				   v < 0 then
					v = v + 18446744073709551616.0
				end
				return self:fconst(v + 0.0, to)
			end
			-- C truncates towards zero, and a value the integer
			-- type cannot hold is undefined, so leave that one
			-- to the runtime.
			local i = v < 0 and math.ceil(v) or math.floor(v)
			if math.tointeger(i) then
				return self:conv(tree.const(self.word,
					math.tointeger(i)), to)
			end
		end
		-- The instruction and the runtime call want the same
		-- shape: a whole word on the integer side, so that nothing
		-- above the value is left to chance.
		local hw = self.t.hwfloat

		if isflt(from) and isflt(to) then
			if hw then return tree.unary("CVT", to, n) end
			return self:rtcall("__" .. self:fprefix(from) .. "2" ..
				self:fprefix(to), to, {n})
		end
		if isflt(to) then
			if isptr(from) then self:err("pointer to float") end
			local w = from
			if w.size < self.word.size then
				w = w.kind == "uint" and self.uword or self.word
			end
			n = self:conv(n, w)
			if hw then return tree.unary("CVT", to, n) end
			return self:rtcall("__" ..
				(w.kind == "uint" and "u" or "i") .. "2" ..
				self:fprefix(to), to, {n})
		end
		local want = to
		if want.size < self.word.size then
			want = want.kind == "uint" and self.uword or self.word
		end
		local c = hw and tree.unary("CVT", want, n)
			or self:rtcall("__" .. self:fprefix(from) .. "2" ..
				(want.kind == "uint" and "u" or "i"), want, {n})
		return self:conv(c, to)
	end
	if n.ty.size == ty.size and n.ty.kind == ty.kind then
		n.ty = ty
		return n
	end
	if n.ty.size == ty.size then
		-- Retyping in place is only safe where nothing about the
		-- instruction follows from the type's signedness.  A divide,
		-- a remainder and a right shift all choose on it, so those
		-- take a conversion node instead.
		if RETYPABLE[n.op] then
			n.ty = ty
			return n
		end
		return tree.unary("CVT", ty, n)
	end
	return tree.unary("CVT", ty, n)
end

-- Integer promotion.  Anything narrower than int becomes int, because int
-- holds every value of a narrower type on every target here.  Leaving this
-- out makes `someInt >= someByte` an unsigned comparison.
function P:promote(t)
	if (t.kind == "int" or t.kind == "uint") and t.size < 4 then
		return self.ty.i32
	end
	return t
end

function P:usual(a, b)
	if isptr(a) then return a end
	if isptr(b) then return b end
	a, b = self:promote(a), self:promote(b)
	if isflt(a) or isflt(b) then
		if isflt(a) and isflt(b) then
			return a.size >= b.size and a or b
		end
		return isflt(a) and a or b
	end
	if a.kind == b.kind then
		return a.size >= b.size and a or b
	end
	-- One signed, one unsigned.  The unsigned type wins unless the signed
	-- one is wider, in which case it holds every value of the other.
	local u = a.kind == "uint" and a or b
	local i = a.kind == "uint" and b or a
	if u.size >= i.size then return u end
	return i
end

function P:scale(n, to)
	if to.size == 1 then return n end
	return tree.binary("MUL", n.ty, n, tree.const(n.ty, to.size))
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
		if isptr(a.ty) and not isptr(b.ty) then
			return tree.binary(op, a.ty, a,
				self:scale(self:conv(b, self.aword), a.ty.to))
		end
		if isptr(b.ty) and op == "ADD" then
			return tree.binary(op, b.ty, b,
				self:scale(self:conv(a, self.aword), b.ty.to))
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
		return tree.binary(op, rt, self:conv(a, rt),
			self:conv(b, self:promote(b.ty)))
	end
	local rt = self:usual(a.ty, b.ty)
	if self:iswide(rt) then
		return self:wideop(op, self:conv(a, rt), self:conv(b, rt), rt)
	end
	if isflt(rt) then return self:floatop(op, a, b, rt) end
	return tree.binary(op, rt, self:conv(a, rt), self:conv(b, rt))
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
	local fmt = n.ty.size == 8 and "<d" or "<f"
	local ifmt = n.ty.size == 8 and "<I8" or "<I4"
	local mask = n.ty.size == 8 and -1 or 0xffffffff
	return (string.unpack(fmt, string.pack(ifmt, n.val & mask)))
end

function P:floatop(op, a, b, rt)
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

-- A float used as a truth value is compared against zero.
function P:test(e)
	-- Every truth value passes through here, so this is where a
	-- slot known to hold one number becomes that number.
	e = self:subkonst(self:rvalue(e))
	-- a comparison is already a truth value, whatever width it compared
	if tree.ops[e.op] and tree.ops[e.op].rel then return e end
	if self:iswide(e.ty) then
		local z = isflt(e.ty) and self:fconst(0.0, e.ty)
			or tree.const(e.ty, 0)
		return self:wideop("NE", e, z, e.ty)
	end
	if isflt(e.ty) then
		return self:floatop("NE", e, self:fconst(0.0, e.ty), e.ty)
	end
	return e
end

function P:fconst(v, ty)
	if ty.x87 then
		local lo, se = enc80(v)

		return tree.node("CONST", ty, nil, nil,
			{val = lo, hi = se, fnum = v})
	end
	local fmt = ty.size == 8 and "<d" or "<f"
	local ifmt = ty.size == 8 and "<i8" or "<i4"
	local bits = string.unpack(ifmt, string.pack(fmt, v))
	return tree.const(ty, bits)
end

-- A label or a string this unit made, which no other can replace.
function P:ownsym(sym)
	if sym:sub(1, 2) == ".L" then return true end
	local s = self.globals[sym]
	return s ~= nil and s.static == true
end

-- A global, as an expression.  Position independent code cannot reach one
-- another unit may replace by its name: the loader writes the address into
-- a table, and the code reads it from there.  A static is this unit's own
-- and stays a plain reference.
function P:global(ty, sym, static, tls)
	if tls then
		-- Every thread has its own copy, so the address is worked
		-- out at each use rather than written into the code.
		if not self.t.tls then
			self:err("__thread is not supported on this target")
		end
		return tree.unary("INDIR", ty,
			tree.unary("TLS", self.ty.ptr(ty),
				tree.name(ty, sym)))
	end
	if not self.pic or static or self:ownsym(sym) then
		return tree.name(ty, sym)
	end
	local n = tree.name(ty, sym)

	n.got = true
	return tree.unary("INDIR", ty,
		tree.unary("GOT", self.ty.ptr(ty), n))
end

-- The address of an lvalue.  Taking the address of an indirection is the
-- indirection's own operand, which is what keeps &p->x from building a tree
-- no table can match.
function P:addrof(e)
	if e.bf then self:err("a bit-field has no address") end
	-- `&f` and `f` are the same address, so a function goes the one
	-- way: under pic, one another object may own is read from the
	-- table rather than worked out from here.
	if e.ty.kind == "func" then return self:rvalue(e) end
	-- Whoever holds the address may write through it.
	self:inlkill(e)
	-- A frame slot whose address escapes is one an overflow can be
	-- aimed at, which is what the stronger stack protector looks for.
	if e.op == "AUTO" then self.tookaddr = true end
	if e.op == "INDIR" then return e.left end
	-- The address of an array is the address of its first element,
	-- but it points at the whole array, not at one element: `&a + 1`
	-- steps over all of it.
	if e.ty.kind == "array" then
		return tree.unary("ADDR", self.ty.ptr(e.ty), e)
	end
	-- A value built rather than stored is named by where it was left.
	if e.op == "SEQ" or e.op == "COPY" or e.op == "COND" then
		return self:recaddr(e)
	end
	return tree.unary("ADDR", self.ty.ptr(e.ty), e)
end

-- The address of a whole record.  An lvalue has one already; anything
-- else is copied into a temporary, and the address of that is the answer.
function P:recaddr(e)
	local pt = self.ty.ptr(e.ty)
	if e.op == "INDIR" then return e.left end
	if e.op == "AUTO" or e.op == "NAME" then
		return tree.unary("ADDR", pt, e)
	end
	if e.op == "SEQ" then
		local arms = {}
		for i = 1, #e.arms - 1 do arms[i] = e.arms[i] end
		arms[#e.arms] = self:recaddr(e.arms[#e.arms])
		return tree.node("SEQ", pt, nil, nil, {arms = arms})
	end
	-- An assignment already wrote a record somewhere: say where.
	if e.op == "COPY" then
		return tree.node("SEQ", pt, nil, nil,
			{arms = {e, tree.clone(e.left)}})
	end
	-- Anything else: each arm of a conditional writes the same
	-- temporary, and the address of that temporary is the answer.
	local t = tree.auto(e.ty, self:temp(e.ty))
	if e.op == "COND" then
		local arms = {}
		for i, a in ipairs(e.arms) do
			arms[i] = tree.node("COPY", e.ty,
				tree.unary("ADDR", pt, tree.clone(t)),
				self:recaddr(a), {val = e.ty.size})
		end
		local c = tree.node("COND", e.ty, e.left, nil, {arms = arms})
		return tree.node("SEQ", pt, nil, nil,
			{arms = {c, tree.unary("ADDR", pt, t)}})
	end
	self:err("a record value with no address")
end

-- An array or a function used in an expression becomes a pointer.
function P:rvalue(n)
	-- The value of `(f(), x)` is the value of x, so a bit-field there
	-- still has to be read out and an array there still decays.  The
	-- sequence itself carries neither.
	if n.op == "SEQ" and n.arms and #n.arms > 0 then
		local last = n.arms[#n.arms]
		local v = self:rvalue(last)

		if v == last then return n end
		local arms = {}

		for i = 1, #n.arms do arms[i] = n.arms[i] end
		arms[#arms] = v
		return tree.node("SEQ", v.ty, nil, nil, {arms = arms})
	end
	if n.bf then return self:bfget(n) end
	if n.ty.kind == "func" then
		if n.op == "INDIR" then return n.left end
		-- The address of a function needs the function, so a
		-- definition put aside has to be built after all, and
		-- whoever holds the address may call it with anything.
		wantbody(n, self.dead)
		if n.fn then n.fn.same, n.fn.nosame = nil, true end
		if self.pic and n.op == "NAME" and not self:ownsym(n.sym) then
			n.got = true
			return tree.unary("GOT", self.ty.ptr(n.ty), n)
		end
		return tree.unary("ADDR", self.ty.ptr(n.ty), n)
	end
	if n.ty.kind == "array" then
		local p = self.ty.ptr(n.ty.of)
		if n.op == "INDIR" then
			local a = n.left
			a.ty = p
			return a
		end
		return tree.unary("ADDR", p, n)
	end
	return n
end

function P:member(base, name, arrow)
	local st
	if arrow then
		if not isptr(base.ty) or not isrec(base.ty.to) then
			self:err("-> needs a pointer to a struct or union")
		end
		st = base.ty.to
	else
		if not isrec(base.ty) then
			self:err(". needs a struct or union")
		end
		st = base.ty
	end
	if st.incomplete then self:err(st.name .. " is incomplete") end
	local m = st.byname[name]
	if not m then self:err("no member " .. name .. " in " .. st.name) end
	if not m.off then
		self:err("member " .. name .. " of " .. st.name ..
			" has no place")
	end
	if not arrow and base.op == "AUTO" and not base.off then
		self:err("a " .. st.name .. " with no place of its own")
	end

	if not arrow and base.op == "AUTO" then
		local n = tree.auto(m.ty, base.off + m.off)
		n.bf = m.bits and m or nil
		-- A slot of its own is one object; a member of one is a
		-- piece of another, and the address of the whole reaches
		-- it without naming it.
		n.part = true
		return n
	end
	-- The address has to carry the member's type, because an operand
	-- shape reads the pointee to pick the load.
	local pt = self.ty.ptr(m.ty)
	local addr = arrow and base or self:addrof(base)
	if m.off ~= 0 then
		addr = tree.binary("ADD", pt, addr,
			tree.const(self.word, m.off))
	elseif addr.ty ~= pt then
		-- retype a copy: the node it came from may be used again
		addr = tree.clone(addr)
		addr.ty = pt
	end
	local n = tree.unary("INDIR", m.ty, addr)
	n.bf = m.bits and m or nil
	return n
end

-- Bit-fields ------------------------------------------------------------
--
-- A bit-field is named by the lvalue of the unit that holds it, tagged
-- with where inside that unit it sits.  Reading one shifts it to the top
-- of a register and back down, which brings the sign with it; writing one
-- puts the unit back together around it.

-- The type the shifting is done in, and the type the value comes out as.
function P:bftypes(m)
	local w = self:promote(m.ty)
	if self:iswide(m.ty) or m.ty.size > w.size then w = m.ty end
	local uns = m.ty.kind == "uint" or m.ty.isbool
	local shift = uns and (w.size == 8 and self.ty.u64 or self.ty.u32)
		or (w.size == 8 and self.ty.i64 or self.ty.i32)
	local out = shift
	if m.bits < 32 then out = self.ty.i32 end
	return shift, out
end

function P:bfget(n)
	local m = n.bf
	local shift, out = self:bftypes(m)
	local w = shift.size * 8
	local raw = tree.clone(n)

	raw.bf = nil
	raw = self:conv(raw, shift)
	if w - m.bit - m.bits > 0 then
		raw = self:arith("SHL", raw,
			tree.const(self.ty.i32, w - m.bit - m.bits))
	end
	raw = self:arith("SHR", raw, tree.const(self.ty.i32, w - m.bits))
	return self:conv(raw, out)
end

function P:bfset(lv, rhs)
	local m = lv.bf
	-- The place is named three times below -- read, written, read
	-- back -- so an address that costs anything to work out is
	-- worked out once.  A body built where it was called costs a
	-- great deal: three copies of it would run three times.
	local pre

	lv, pre = self:once(lv)
	lv.bf = m
	local shift = self:bftypes(m)
	local uns = shift.size == 8 and self.ty.u64 or self.ty.u32
	local mask = m.bits >= 64 and -1 or ((1 << m.bits) - 1)
	local unit = tree.clone(lv)

	unit.bf = nil
	local old = tree.clone(unit)
	old.bf = nil
	local keep = self:arith("AND", self:conv(old, uns),
		tree.const(uns, ~(mask << m.bit)))
	local put = self:arith("AND", self:conv(self:rvalue(rhs), uns),
		tree.const(uns, mask))
	if m.bit > 0 then
		put = self:arith("SHL", put, tree.const(self.ty.i32, m.bit))
	end
	local set = tree.binary("ASGN", m.ty, unit,
		self:conv(self:arith("OR", keep, put), m.ty))
	local back = tree.clone(lv)

	back.bf = m
	local out = tree.node("SEQ", self:bftypes(m), nil, nil,
		{arms = {set, self:bfget(back)}})

	if not pre then return out end
	return tree.node("SEQ", out.ty, nil, nil, {arms = {pre, out}})
end

function P:primary()
	local tk = self.tok
	-- A literal may wear a prefix saying what its characters are.
	-- This compiler has one kind of character, so the prefix is read
	-- and dropped.
	if tk.kind == "name" and STRPREFIX[tk.text] then
		local n = self:peek()

		-- a character constant reaches the parser as a number
		if n.kind == "str" or n.kind == "num" then
			self:adv()
			tk = self.tok
		end
	end
	if self:accept("(") then
		if self.tok.kind == "{" then return self:stmtexpr() end
		local e = self:expression()
		self:expect(")")
		return e
	end
	if tk.kind == "num" then
		if tk.val == nil then
			self:err("bad number " .. tostring(tk.text))
		end
		self:adv()
		if math.type(tk.val) == "float" then
			-- `1.0fi` is the imaginary unit of <complex.h>.  The
			-- letter is read off the text rather than carried
			-- on the token, which a body put aside and read
			-- again would lose.
			local imag = tk.text and
				tk.text:match("[iIjJ][fFlL]*$") ~= nil
			local suf = tk.text and (imag and
				tk.text:match("[fFlL]") or
				tk.text:match("[fFlL]$"))
			local ty = self.ty.f64

			if suf == "f" or suf == "F" then
				ty = self.ty.f32
			elseif suf then
				ty = self.ty.ldouble
			end
			-- A decimal literal of the extended type is read
			-- in that type: a double would lose the range.
			if ty.x87 and tk.text and
			   not tk.text:match("^0[xX]") then
				local lo, se = dec80(tk.text)

				if lo then
					return tree.node("CONST", ty, nil,
						nil, {val = lo, hi = se,
						      fnum = tk.val})
				end
			end
			-- `1.0fi` is the imaginary unit of <complex.h>: the
			-- value is the imaginary half and the real half is
			-- zero.
			if imag then
				return self:cplxmake(ty,
					self:fconst(0.0, ty),
					self:fconst(tk.val, ty), {})
			end
			return self:fconst(tk.val, ty)
		end
		return tree.const(self:constty(tk.val, tk.text), tk.val)
	end
	if tk.kind == "str" then
		self:adv()
		self.nstr = self.nstr + 1
		local label = ".Lstr" .. self.nstr
		local ety = self:strelem(tk.pfx)

		self.t.data.stringdef(self.sg, label, tk.text, ety.size)
		-- An array, so that sizeof sees the characters rather than
		-- a pointer.  Every other use decays through rvalue.
		return tree.name(self.ty.array(ety, #tk.text + 1), label)
	end
	if tk.kind == "name" and tk.text == "__builtin_va_start" then
		self:adv()
		return self:vastart()
	end
	if tk.kind == "name" and tk.text == "__builtin_va_arg" then
		self:adv()
		return self:vaarg()
	end
	-- Nothing has to be taken down at the end of a walk over the
	-- arguments, and copying one list to another is a copy of the
	-- object.  A libc that spells these as builtins gets them here.
	if tk.kind == "name" and tk.text == "__builtin_va_end" then
		self:adv()
		self:expect("(")
		local e = self:assign()

		self:expect(")")
		return tree.node("SEQ", self.ty.void, nil, nil,
			{arms = {e, tree.const(self.ty.i32, 0)}})
	end
	if tk.kind == "name" and tk.text == "__builtin_va_copy" then
		self:adv()
		self:expect("(")
		local d = self:assign()

		self:expect(",")
		local v = self:assign()

		self:expect(")")
		-- A va_list is an array of one, so the copy is of the
		-- object rather than an assignment.  As a parameter it has
		-- already decayed, and then the pointer is the address to
		-- copy from rather than something to take the address of:
		-- this is what every vfprintf in a library does with the
		-- va_list it was handed.
		local da, n = self:valistat(d)
		local va = self:valistat(v)

		return tree.node("COPY", d.ty, da, va, {val = n})
	end
	if tk.kind == "name" and tk.text == "_Generic" then
		self:adv()
		return self:generic()
	end
	-- These three decide at compile time what the rest of the
	-- expression even is, so they are read here rather than called.
	if tk.kind == "name" and SPECIAL[tk.text] then
		self:adv()
		return self:special(tk.text)
	end
	if tk.kind == "name" and BUILTIN[tk.text] then
		self:adv()
		return self:builtin(tk.text)
	end
	if tk.kind == "name" then
		self:adv()
		local s = self:find(tk.text)
		if not s and self.tok.kind == "(" then
			-- A builtin this compiler does not know is the
			-- library function of that name, which is what
			-- gcc does with one.  Its own declaration is
			-- taken where the program made one, so the
			-- result type is right.
			local lib = tk.text:match("^__builtin_(.+)$")
			local d = lib and self:find(lib)

			if d and d.kind == "func" then
				s = d
			else
				-- an undeclared name called as a function
				s = {kind = "func", sym = lib or tk.text,
				     ty = self.ty.func(self.word, {}, true)}
				self.globals[tk.text] = s
			end
		end
		if not s and FUNCNAME[tk.text] then
			return self:funcname(tk.text)
		end
		if not s then self:err("undeclared " .. tk.text) end
		if FUNCNAME[tk.text] and not s then
			return self:funcname(tk.text)
		end
		if s.kind == "func" then
			-- a call names it directly; only its address has
			-- to come from the table
			local e = tree.name(s.ty, s.sym)

			-- What the name was declared as, which is how a
			-- call finds the body if there is one here.
			e.fn = s
			return e
		end
		if s.kind == "const" then
			return tree.const(self.word, s.val)
		end
		if s.kind == "hardglobal" then
			return tree.node("HARD", s.ty, nil, nil,
					 {hard = s.reg})
		end
		if s.kind == "local" then
			-- A body built where it was called need not be
			-- handed an argument it never looks at.
			local fr = self.inl

			while fr do
				local slot = fr.byoff[s.off]

				if slot then slot.read = true break end
				fr = fr.up
			end
			if s.hard then
				local e = tree.auto(s.ty, s.off)

				e.hard = s.hard
				return e
			end
			if s.vla then
				-- the pointer itself, which is what the
				-- array would have decayed to
				local e = tree.auto(s.vlaty, s.off)

				e.vlasize = s.vla
				return e
			end
			return tree.auto(s.ty, s.off)
		end
		return self:global(s.ty, s.sym or tk.text, s.static, s.tls)
	end
	self:err("unexpected " .. (tk.text or tk.kind))
end

-- An unnamed object with an initialiser.  Inside a function it lives in
-- the frame and is set up where it is written; outside one it is static,
-- like any other object with no name to give it.
function P:compound(ty)
	if self.fname then
		local sym = {kind = "local", ty = ty}

		self:initlocal(sym, ty)
		return tree.auto(sym.ty, sym.off)
	end
	self.nstr = self.nstr + 1
	local lbl = ".Lcompound" .. self.nstr

	return tree.name(self:initobject(lbl, ty, true), lbl)
end

-- The old way of writing a definition, where the names come first and
-- their types follow:
--
--	strsep(stringp, delim)
--		char **stringp;
--		const char *delim;
--	{
--
-- The list this compiler already read gave every name the type int, which
-- is what C says an undeclared one has.  These declarations say otherwise,
-- and the type is rebuilt around them.
function P:oldparams(ty)
	if self.tok.kind == "{" or not self:istype() then return ty end
	if not ty.pnames then
		self:err("a declaration where a body was expected")
	end
	local said = {}

	while self.tok.kind ~= "{" and self.tok.kind ~= "eof" do
		local base, storage = self:declspec()

		if not base then break end
		if self.tok.kind ~= ";" then
			repeat
				local nm, wrap = self:dcl(true)

				if not nm then
					self:err("a parameter needs a name")
				end
				said[nm] = self.ty.decay(wrap(base))
			until not self:accept(",")
		end
		self:expect(";")
	end
	local params = {}

	for i, nm in pairs(ty.pnames) do
		params[i] = said[nm] or ty.params[i]
	end
	for i = 1, #ty.params do
		params[i] = params[i] or ty.params[i]
	end
	return self.ty.func(ty.ret, params, ty.variadic, ty.pnames)
end

-- C99 declares this at the top of every body: the name of the function
-- being compiled, as a string.
function P:funcname()
	local name = self.fname or "top level"

	self.nstr = self.nstr + 1
	local label = ".Lstr" .. self.nstr
	self.t.data.stringdef(self.sg, label, name)
	return tree.name(self.ty.array(self.plainchar, #name + 1), label)
end

-- A call on anything: a name is called directly, anything else through the
-- pointer it evaluates to.
-- inlining --------------------------------------------------------------
--
-- A `static inline` this unit has the body of may be built where it is
-- called rather than called.  That is what linux's `rip_rel_ptr` needs:
-- it hands its own parameter to an `"i"` constraint, which only holds a
-- constant, and only the caller has one.
--
-- The tokens are already here: a `static inline` is put aside when it is
-- read and built at the end of the unit if anything wants it.  So the
-- expansion costs a reader over the same array and a frame of its own,
-- both of which go when it ends.

-- How deep one expansion may sit inside another, and how long a body
-- may be.  Past either, the call stays a call.
--
-- `__attribute__((always_inline))` means what it says, and a kernel
-- leans on it: a function that reads a table in .init.rodata is
-- written that way so that the reference lands in its caller, which
-- is in .init.text.  Left out of line it would be a reference from
-- .text to .init, which the kernel's own checker refuses.  So the
-- length does not apply to one, and the depth is far enough not to
-- be reached by anything a person writes.
local INLDEPTH, INLTOKENS, INLALWAYS = 4, 160, 24
-- What a body that is one `return` is allowed to hold.
local INLONERET = 600

function P:inlinable(g, args)
	local p = g and g.pending

	-- A body written without `inline` waits only to be let go of,
	-- not to be built where it was called.
	if not p or not p.lx then return false end
	-- A body put in a section by name was put there on purpose, and
	-- building it somewhere else moves it out of that section.
	if p.sec then return false end

	if (self.inldepth or 0) >= (p.always and INLALWAYS or INLDEPTH) then
		return false
	end
	if not p.always and
	   p.lx.ntok > (p.lx.single and INLONERET or INLTOKENS) then
		return false
	end
	if p.lx.once then return false end
	local ty = p.ty

	if ty.variadic or ty.noproto then return false end
	if #args ~= #ty.params then return false end
	-- A function of no arguments names none, so there is nothing to
	-- ask about; one with arguments has to name every one of them.
	if #ty.params > 0 and not ty.pnames then return false end
	for i = 1, #ty.params do
		local t = ty.params[i]

		-- A wide value travels by other means; keep to what a
		-- slot and an assignment can carry.  A small record can:
		-- the kernel passes pmd_t and pud_t by value everywhere,
		-- and a body that never looks at one still has to be
		-- built where it was called for its answer to settle.
		if not (ty.pnames[i] and ty.pnames[i] ~= "") then
			return false
		end
		if t.kind == "array" or self:widepass(t) or
		   (isrec(t) and (t.complex or t.size > 16)) then
			return false
		end
	end
	local r = ty.ret

	if r ~= self.ty.void and (isrec(r) or self:byparts(r) or
	    r.kind == "array" or self:widepass(r)) then
		return false
	end
	return true
end

-- Build the body where it was called.  The code goes to a buffer of its
-- own and travels in the tree, the way a statement expression's does, so
-- an arm of `?:` takes its own with it.
function P:inline(g, args)
	local p = g.pending
	local ty = p.ty
	local saved = self.g.sink
	local blk = buf.new()

	self.g.sink = blk
	-- The answer outlives the block that fills it: the slot is taken
	-- before the scope opens, so the scope closing does not hand it
	-- to the next expansion while the value is still wanted.
	local res = ty.ret ~= self.ty.void and self:alloc(ty.ret) or nil
	-- A name in the body means what it meant where the body was
	-- written, not what it means here.  The blocks around the call
	-- go out of sight: what is left is the file, whose names are
	-- global and whose tags are the outermost level.  Without this a
	-- caller with a local called `apic` changes what a header's
	-- `apic->read` reads.
	local oscopes, otags = self.scopes, self.tags

	self.scopes, self.tags = {}, {self.tags[1]}
	self:push()
	-- Each parameter is a slot of its own, written once before the
	-- body runs.  Beside it the argument is kept, so an operand that
	-- must be a constant can read what the caller wrote as long as
	-- nothing has changed the parameter yet.
	local frame = {byoff = {}, up = self.inl}

	-- Each write goes to a buffer of its own, so that one the body
	-- never reads can be left out: `__apply_fineibt` takes five
	-- arguments and looks at none of them, and two of the five are
	-- names this configuration does not define.
	local pres = {}

	for i, pt in ipairs(ty.params) do
		local off = self:alloc(pt)
		local a = self:conv(args[i], pt)
		local one = buf.new()
		local sv = self.g.sink

		self.g.sink = one
		self.g:expr(self:assignto(tree.auto(pt, off), a), "eff")
		self.g.sink = sv
		self:declare(ty.pnames[i], {kind = "local", ty = pt,
					    off = off})
		frame.byoff[off] = {arg = a, live = true,
				    depth = self.loopdepth}
		pres[#pres + 1] = {off = off, out = one,
				   eff = tree.effects(a)}
	end
	local rty = ty.ret
	local void = rty == self.ty.void
	local orty, oend, olab, ofn = self.rty, self.endlabel,
		self.labelmap, self.fname
	local ores, orec = self.inlres, self.recret
	local ires

	-- A label inside the body belongs to this expansion alone, so a
	-- body built twice does not name the same label twice.
	self.rty = void and self.word or rty
	self.endlabel = self.g:newlabel()
	self.labelmap = {}
	-- A label written out by name carries the function's, so each
	-- expansion needs one of its own.
	self.ninline = (self.ninline or 0) + 1
	self.fname = ("%s.i%d"):format(ofn or "f", self.ninline)
	-- The body returns nothing a record return would carry, so the
	-- caller's arrangements for one are out of the way.
	self.recret = nil
	self.inlres = res and {off = res, ty = rty, n = 0} or nil
	self.inl = frame
	self.inldepth = (self.inldepth or 0) + 1
	-- A return in the body leaves the body, not the function it was
	-- built into, so what follows the expansion is reachable again.
	local odead, oret = self.dead, self.retused
	-- A label inside a body built where it was called is reached
	-- only from inside it, so it says nothing about the code around
	-- the call.
	local orev, omark = self.revived, self.deadmark
	local owrites = self.writes
	-- Every slot this body touches has to outlive it, so how far it
	-- reached is counted rather than where it ended.
	local ohi = self.hiwater

	self.hiwater = self.nlocals
	-- A body built where nothing can reach the call is itself out
	-- of reach.
	self.retused, self.deadmark = false, nil
	self.writes = scanwrites(p.lx.f, p.lx.n)
	self:replay(p.lx, P.block)
	local used = self.hiwater

	self.hiwater = ohi and (ohi > used and ohi or used) or nil
	-- Nothing comes back from a body that ended with nothing
	-- reachable and never returned: the label at its end is where a
	-- return would have gone, and there was none.
	local noway = self.dead and not self.retused

	self.g:putlabel(self.endlabel)
	self.dead, self.retused = odead, oret
	self.revived, self.deadmark = orev, omark
	self.writes = owrites
	self.inldepth = self.inldepth - 1
	self.inl = frame.up
	self.rty, self.endlabel, self.labelmap, self.fname =
		orty, oend, olab, ofn
	ires, self.inlres, self.recret = self.inlres, ores, orec
	-- The slots this body used are not handed back.  Its code
	-- travels in the tree and runs later, beside whatever was built
	-- after it: an argument worked out here and a parameter written
	-- there would otherwise take turns in one slot, and the second
	-- one would land on the first.  Raising the mark keeps them
	-- until the block ends, which costs a few words at a site that
	-- is rare.
	self.marks[#self.marks] = used
	self:pop()
	self.scopes, self.tags = oscopes, otags
	self.g.sink = saved

	-- Which return ran decides what the slot holds, so what one of
	-- them wrote is not what the expansion answers.
	if res then self.konsts[res] = nil end
	-- The writes the body had a use for, and then the body.
	local head = buf.new()

	for _, one in ipairs(pres) do
		if one.eff or frame.byoff[one.off].read then
			one.out:move(head)
		end
	end
	blk:move(head)
	local text = tree.node("TEXT", self.ty.void, nil, nil,
			       {text = head:text()})
	-- A body with one return of a settled value is that value, so a
	-- test on it -- `enabled() && handler()` where enabled answers
	-- false -- settles too.
	local konst = ires and ires.n == 1 and ires.konst or nil
	local v = void and tree.const(self.ty.i32, 0)
		or (konst and tree.const(rty, konst))
		or tree.auto(rty, res)

	-- What the body said about the answer travels with it: a test on
	-- a value behind a mask settles even when the value does not.
	if ires and ires.n == 1 and ires.mask and v.op == "AUTO" then
		v.mask = ires.mask
	end

	local n = tree.node("SEQ", v.ty, nil, nil, {arms = {text, v}})

	n.noret = (noway or g.noreturn) and true or nil
	return n
end

-- What the caller wrote for a parameter, while the parameter still
-- holds it.  Only an operand that has to be a constant asks.
function P:inlarg(e)
	if e == nil or e.op ~= "AUTO" then return nil end
	local f = self.inl

	while f do
		local s = f.byoff[e.off]

		if s then
			if not s.live or s.depth < self.loopdepth then
				return nil
			end
			if s.konst then
				return tree.const(s.kty, s.konst)
			end
			return s.arg
		end
		f = f.up
	end
	return nil
end

-- The same tree with every parameter that still holds what the caller
-- wrote replaced by what the caller wrote, so an operand built out of
-- one -- `1 << (bit & 7)` -- can be worked out here.  Answers nothing
-- when no parameter is named, so the ordinary path is not disturbed.
function P:inlsubst(e, depth)
	if e == nil or (depth or 0) > 16 then return nil end
	if e.op == "AUTO" then
		local a = self:inlarg(e)

		-- What the caller handed over may itself be a parameter
		-- of whatever built the caller, so this goes all the way
		-- out.
		if not a then return nil end
		return self:inlsubst(a, (depth or 0) + 1) or a
	end
	local l = self:inlsubst(e.left, (depth or 0) + 1)
	local r = self:inlsubst(e.right, (depth or 0) + 1)
	local arms, any = nil, l ~= nil or r ~= nil

	if e.arms then
		for i, a in ipairs(e.arms) do
			local b = self:inlsubst(a, (depth or 0) + 1)

			if b then
				arms = arms or {table.unpack(e.arms)}
				arms[i] = b
				any = true
			end
		end
	end
	if not any then return nil end
	local c = tree.clone(e)

	c.left, c.right = l or e.left, r or e.right
	if arms then c.arms = arms end
	return tree.reneed(c)
end

-- A label may be jumped to from anywhere, so nothing a slot held
-- before it can be trusted after it.
-- Whether every write to a name from here on puts back the number it
-- already holds.  The kernel writes `can_reclaim_pt = false` inside a
-- loop below the label, over a slot that was false to begin with.
function P:samewrites(list, at, k)
	if not list then return false end
	for _, one in ipairs(list) do
		if one.at >= at then
			local v = one.v

			if not v then return false end
			if v.kind == "num" then
				if v.val ~= k.konst then return false end
			elseif v.kind == "name" then
				local sym = self:find(v.text)

				if not sym or sym.kind ~= "const" or
				   sym.val ~= k.konst then
					return false
				end
			else
				return false
			end
		end
	end
	return true
end

-- What a label does to the values slots are known to hold.  `from` is
-- the earliest place a run can arrive from, and `at` is where the
-- label stands.  A slot is no longer known when something writes it
-- after the label -- the run may come back round -- or when the write
-- that gave it its value stands after that earliest arrival, because
-- a run that jumped here never passed through it.
function P:inlclear(from, at)
	local f = self.inl
	local sc = self.writes

	at = at or (self.lx and self.lx.i)
	if sc and at then
		for off, k in pairs(self.konsts) do
			local last = k.name and sc.w[k.name]

			if not k.name or not k.at or
			   (last and last >= at and
			    not self:samewrites(sc.wv[k.name], at, k)) or
			   (from and k.at > from) then
				self.konsts[off] = nil
			end
		end
	else
		self.konsts = {}
	end
	while f do
		for _, s in pairs(f.byoff) do s.live = false end
		f = f.up
	end
end

-- A slot of a body built where it was called, given a value settled
-- where it stands.  The number is kept rather than the tree: the arena
-- hands the nodes of a statement back at the end of it, and this has
-- to last until the slot is written or the body ends.
-- Which bits a value may have set, when that is written down: a mask
-- says so, a body that answers one carries it, and widening keeps
-- it.  Answers nil when anything else could be in there.
local function bitsof(n, depth)
	if n == nil or (depth or 0) > 8 then return nil end
	if n.mask then return n.mask end
	if n.op == "CVT" and n.left and n.ty and n.left.ty and
	   not isflt(n.ty) and not isflt(n.left.ty) then
		local m = bitsof(n.left, (depth or 0) + 1)
		-- A narrower type keeps the low bits, so the mask still
		-- holds as long as it fits in what is left.
		local bits = 8 * n.ty.size -
			(n.ty.kind == "int" and 1 or 0)

		if m == nil then return nil end
		if bits >= 63 or m < (1 << bits) then return m end
		return nil
	end
	if n.op ~= "AND" then return nil end
	local m = fold(n.right) or fold(n.left)

	if m == nil or m < 0 then return nil end
	return m
end

-- Whether a tree reads a given slot.
local function mentions(n, off, depth)
	if n == nil or (depth or 0) > 24 then return false end
	if n.op == "AUTO" and n.off == off then return true end
	if mentions(n.left, off, (depth or 0) + 1) then return true end
	if mentions(n.right, off, (depth or 0) + 1) then return true end
	if n.arms then
		for _, a in ipairs(n.arms) do
			if mentions(a, off, (depth or 0) + 1) then
				return true
			end
		end
	end
	return false
end

function P:notekonst(off, e, ty, hard, was)
	if self.dead or hard or isrec(ty) or self:iswide(ty) then
		return
	end
	if not self.ty.isint(ty) and not isptr(ty) then return end
	-- `x = x + 1` in a loop writes a different number every turn.
	if self.loopdepth > 0 and mentions(e, off) then
		return
	end
	local k = fold(e)

	-- A copy of a slot that holds one number holds the same one.
	-- A statement expression hands its value over that way, and an
	-- operand may decide the answer on its own.
	if k == nil then k = settle(self:unseq(self:subkonst(e))) end
	if k == nil then return end
	k = fold(self:conv(tree.const(e.ty, k), ty))
	if k == nil then return end
	-- A write that puts back what was already there changes
	-- nothing, so the slot keeps the answer it had and the run it
	-- was written in.  The kernel sets a flag false again inside a
	-- loop over a flag that was false to begin with.
	if was and was.konst == k and was.kty == ty then
		self.konsts[off] = was
		return
	end
	-- Where the write stands: the arm of the `if` or the turn of the
	-- loop it is in.  A read outside that arm may not have passed
	-- through it, and one on a later turn of the loop may be reading
	-- what the turn before wrote.
	local d = #self.regions

	self.konsts[off] = {konst = k, kty = ty,
			    name = self.slotname and self.slotname[off],
			    at = self.lx and self.lx.i,
			    depth = self.loopdepth,
			    region = d, id = self.regions[d]}
end

-- What a slot holds, when it is the same number wherever the read
-- stands.
function P:knownkonst(off)
	local s = self.konsts[off]

	if not s then return nil end
	if s.depth < self.loopdepth then return nil end
	if s.region > 0 and self.regions[s.region] ~= s.id then
		return nil
	end
	return s
end

-- Each arm of a test and each body of a loop is a run of its own.
function P:pushregion()
	self.nregion = self.nregion + 1
	self.regions[#self.regions + 1] = self.nregion
end

function P:popregion()
	self.regions[#self.regions] = nil
end

-- Whatever is written to is no longer what the caller wrote.
function P:inlkill(e)
	if e == nil then return end
	if e.op == "INDIR" or e.op == "ADDR" then e = e.left end
	if e == nil or e.op ~= "AUTO" then return end
	-- A write nothing can reach leaves the slot as it was.
	if not self.dead then self.konsts[e.off] = nil end
	local f = self.inl

	while f do
		local s = f.byoff[e.off]

		if s then s.live = false return end
		f = f.up
	end
end

function P:call(callee)
	local direct = callee.op == "NAME" and callee.ty.kind == "func"
	local fty = callee.ty
	if not direct then
		callee = self:rvalue(callee)
		fty = callee.ty
	end
	if fty.kind == "ptr" then fty = fty.to end

	local args = {}
	if self.tok.kind ~= ")" then
		repeat
			args[#args + 1] = self:rvalue(self:assign())
		until not self:accept(",")
	end
	self:expect(")")

	if fty.kind == "func" and not fty.noproto then
		local want = #fty.params

		if #args < want or (#args > want and not fty.variadic) then
			self:err(("call takes %d argument%s, %d given")
				:format(want, want == 1 and "" or "s", #args))
		end
	end
	-- A body this unit has may be built here rather than called.
	if direct and self:inlinable(callee.fn, args) then
		return self:inline(callee.fn, args)
	end
	wantbody(callee, self.dead)
	-- What this unit hands over. A name of its own, called with the
	-- same number everywhere, reads that number inside its body.
	if direct and not self.dead and callee.fn and callee.fn.pending and
	   not callee.fn.nosame then
		local g = callee.fn
		local same = g.same

		-- A call read while the bodies are being built may come
		-- after the one it calls was built, so nothing read then
		-- can be counted on.
		if self.settling then
			g.same, g.nosame = nil, true
			same = nil
		end
		if same == nil and not g.nosame then
			same = {}
			g.same = same
		end
		if same and not g.sameset then
			g.sameset = true
			for i = 1, #args do
				same[i] = settle(self:unseq(
					self:subkonst(args[i])))
			end
			same.n = #args
		elseif same then
			if same.n ~= #args then same.n = -1 end
			for i = 1, #args do
				local k = settle(self:unseq(
					self:subkonst(args[i])))

				if same[i] ~= k then same[i] = nil end
			end
		end
	end
	local rty = fty.kind == "func" and fty.ret or self.word
	local retrec = (isrec(rty) or self:byparts(rty)) and rty or nil
	if rty == self.ty.void or isrec(rty) or rty.kind == "array" then
		rty = self.word
	end
	-- convert to the declared parameter types where they are known
	local named = 0
	if fty.kind == "func" then
		named = #fty.params
		for i, p in ipairs(fty.params) do
			if args[i] and not isrec(p) then
				args[i] = self:conv(args[i], p)
			end
		end
	end
	-- A wide argument is handed over as its address; only the target
	-- knows how many registers the two words take.
	local wide
	-- The default argument promotions apply to the rest: a float travels
	-- as a double, and anything narrower than int as an int.
	for i = named + 1, #args do
		local t = args[i].ty
		if isflt(t) and t.size < 8 then
			args[i] = self:conv(args[i], self.ty.f64)
		elseif t.kind == "int" or t.kind == "uint" then
			args[i] = self:conv(args[i], self:promote(t))
		end
	end
	-- A record argument is handed over as its address; only the target
	-- knows whether it then travels in registers or in memory.
	local recs
	for i, a in ipairs(args) do
		if isrec(a.ty) then
			if not self.t.recabi then
				self:err("a struct or union argument is " ..
					"not supported on " .. self.t.name)
			end
			recs = recs or {}
			recs[i] = a.ty
			local ad = self:recaddr(a)
			local pt = self.ty.ptr(a.ty)

			-- A record too big for any register travels as a
			-- pointer, and the callee may write through it, so
			-- what it gets is a copy of our own.
			if self.t.recref and not (self.t.eightbytes and
						  self.t.eightbytes(a.ty))
			then
				local t = tree.auto(a.ty, self:temp(a.ty))
				local cp = tree.node("COPY", a.ty,
					tree.unary("ADDR", pt, t), ad,
					{val = a.ty.size})
				ad = tree.node("SEQ", pt, nil, nil,
					{arms = {cp, tree.unary("ADDR", pt,
						tree.clone(t))}})
			end
			args[i] = ad
		end
	end
	for i, a in ipairs(args) do
		if self:widepass(a.ty) then
			if self:byparts(a.ty) then
				recs = recs or {}
				recs[i] = a.ty
			elseif self.t.wideargs then
				wide = wide or {}
				wide[i] = a.ty.size
			else
				self:err("a " .. (a.ty.name or "wide") ..
					" argument is not supported on " ..
					self.t.name)
			end
			args[i] = self:waddr(a)
		end
	end
	-- The target needs the named count to classify a variadic call.
	local n = tree.node("CALL", rty, callee, nil,
		{args = args, direct = direct, wide = wide, recs = recs,
		 msabi = fty.kind == "func" and fty.msabi or nil,
		 noret = callee.fn and callee.fn.noreturn or nil,
		 nfixed = fty.kind == "func" and fty.variadic and
			  #fty.params or nil})
	-- A record result lands in a slot of ours, either because the
	-- callee was handed its address or because the target puts the
	-- return registers there.  The value of the call is that slot.
	if retrec then
		n.retrec = retrec
		n.retslot = self:temp(retrec)
		return tree.node("SEQ", retrec, nil, nil,
			{arms = {n, tree.auto(retrec, n.retslot)}})
	end
	if not self:widepass(rty) then return n end
	if not self.t.wideargs then
		self:err("a " .. (rty.name or "wide") ..
			" result is not supported on " .. self.t.name)
	end
	-- A wide result comes back in two registers; the target drops them
	-- into a slot of ours, and the value of the call is that slot.
	local slot = self:temp(rty)
	n.retslot = slot
	n.ty = self.word
	return tree.node("SEQ", rty, nil, nil,
		{arms = {n, tree.auto(rty, slot)}})
end

function P:postfix(e)
	while true do
		if self:accept("[") then
			local i = self:expression()
			self:expect("]")
			local p = self:arith("ADD", e, i)
			e = tree.unary("INDIR", p.ty.to, p)
		elseif self:accept(".") then
			e = self:member(e, self:expect("name").text, false)
		elseif self:accept("->") then
			e = self:member(self:rvalue(e),
				self:expect("name").text, true)
		elseif self:accept("(") then
			e = self:call(e)
		elseif self.tok.kind == "++" or self.tok.kind == "--" then
			local step = self.tok.kind == "++" and 1 or -1
			self:adv()
			self:inlkill(e)
			if isptr(e.ty) then step = step * e.ty.to.size end
			if self:iswide(e.ty) then
				-- the old value has to be kept, because the
				-- step writes over it, and the place it
				-- lives is worked out once however many
				-- times it is named
				local lv, pre = self:once(e)
				local t = self:wtemp(e.ty)
				local arms = {}

				if pre then arms[#arms + 1] = pre end
				arms[#arms + 1] = tree.node("COPY", e.ty,
					self:waddr(tree.clone(t)),
					self:waddr(tree.clone(lv)),
					{val = e.ty.size})
				arms[#arms + 1] = self:assignto(
					tree.clone(lv),
					self:arith("ADD", tree.clone(lv),
						tree.const(self.ty.i32,
							step)))
				arms[#arms + 1] = t
				e = tree.node("SEQ", e.ty, nil, nil,
					{arms = arms})
			elseif e.bf then
				-- the old value has to be kept, because the
				-- step writes over it
				local lv, pre = self:once(e)
				local old = self:bfget(tree.clone(lv))
				local t = tree.auto(old.ty, self:temp(old.ty))
				local arms = {}

				if pre then arms[#arms + 1] = pre end
				arms[#arms + 1] = tree.binary("ASGN", old.ty,
					t, old)
				arms[#arms + 1] = self:assignto(
					tree.clone(lv),
					self:arith("ADD", tree.clone(lv),
						tree.const(self.ty.i32, step)))
				arms[#arms + 1] = tree.clone(t)
				e = tree.node("SEQ", old.ty, nil, nil,
					{arms = arms})
			elseif isflt(e.ty) then
				-- A float steps through the runtime, so
				-- the old value is kept in a temporary
				-- rather than left in a register.
				local lv, pre = self:once(e)
				local t = tree.auto(e.ty, self:temp(e.ty))
				local arms = {}

				if pre then arms[#arms + 1] = pre end
				arms[#arms + 1] = self:assignto(
					tree.clone(t), tree.clone(lv))
				arms[#arms + 1] = self:assignto(
					tree.clone(lv),
					self:arith("ADD", tree.clone(lv),
						self:fconst(step + 0.0,
							e.ty)))
				arms[#arms + 1] = tree.clone(t)
				e = tree.node("SEQ", e.ty, nil, nil,
					{arms = arms})
			else
				self:inlkill(e)
				e = tree.node("POSTADD", e.ty, e, nil,
					{val = step})
			end
		else
			return e
		end
	end
end

-- The type of an integer constant, by the rule in C: the first type that
-- holds the value, from a list a suffix can shorten.  A hexadecimal or
-- octal constant may also land on an unsigned type, where a decimal one
-- goes straight to the next signed one.
function P:constty(v, text)
	local T = self.ty
	if not text then return T.i32 end	-- a character constant
	local suf = text:match("[uUlL]*$") or ""
	local uns = suf:find("[uU]") ~= nil
	local longs = select(2, suf:gsub("[lL]", ""))
	local hexoct = text:match("^0[xX]") or text:match("^0%d")

	local function holds(t, x)
		if t.size == 4 then
			if t.kind == "uint" then
				return x >= 0 and x <= 4294967295
			end
			return x >= -2147483648 and x <= 2147483647
		end
		if t.kind == "uint" then return true end
		-- a literal too large for a signed word has wrapped round
		return x >= 0
	end

	-- The candidates, in the order C tries them.  A decimal constant
	-- keeps to the signed types; a hexadecimal or octal one may land on
	-- an unsigned one.  `l` removes the candidates narrower than long,
	-- `ll` those narrower than eight bytes.
	local cands
	if uns then
		cands = {T.u32, self.uword, T.u64}
	elseif hexoct then
		cands = {T.i32, T.u32, self.word, self.uword, T.i64, T.u64}
	else
		cands = {T.i32, self.word, T.i64}
	end
	local least = longs >= 2 and 8 or
		(longs >= 1 and self.word.size or 4)
	for _, t in ipairs(cands) do
		if t.size >= least and holds(t, v) then return t end
	end
	return uns and T.u64 or T.i64
end

function P:unary()
	local k = self.tok.kind
	-- GNU __extension__ says only "do not warn about what follows".
	while k == "name" and self.tok.text == "__extension__" do
		self:adv()
		k = self.tok.kind
	end
	if k == "sizeof" then
		self:adv()
		if self.tok.kind == "(" then
			self:adv()
			if self:istype() then
				local t = self:typename()
				self:expect(")")
				return tree.const(self.uword, t.size)
			end
			local e = self:expression()
			self:expect(")")
			e = self:postfix(e)
			if e.vlasize then
				return tree.auto(self.uword, e.vlasize)
			end
			return tree.const(self.uword, e.ty.size)
		end
		local e = self:unary()
		if e.vlasize then
			return tree.auto(self.uword, e.vlasize)
		end
		return tree.const(self.uword, e.ty.size)
	elseif k == "name" and ALIGNOF[self.tok.text] then
		-- _Alignof, which C11 spells with an underscore and
		-- <stdalign.h> gives the plain name to.
		self:adv()
		self:expect("(")
		local a
		if self:istype() then
			a = self:typename().align
		else
			a = self:rvalue(self:expression()).ty.align
		end
		self:expect(")")
		return tree.const(self.uword, a)
	elseif k == "(" and self:peek() and self.ahead and
	    self:typetok(self.ahead) then
		self:adv()
		local t = self:typename()
		self:expect(")")
		-- `(struct t){ ... }` is not a cast: it makes an unnamed
		-- object and the expression is that object.
		if self.tok.kind == "{" then
			return self:postfix(self:compound(t))
		end
		local e = self:rvalue(self:unary())
		if t == self.ty.void then return e end
		-- A cast to a record is a cast in name only, except for
		-- _Complex, where it converts each half and may build
		-- the pair from a real.
		if isrec(t) and not t.complex then
			e.ty = t
			return e
		end
		return self:conv(e, t)
	elseif k == "-" then
		self:adv()
		local e = self:rvalue(self:unary())
		if e.ty.complex then
			return self:cplxarith("NEG", e)
		end
		if e.op == "CONST" and isflt(e.ty) then
			-- flipping the sign bit is exact, and keeps a negative
			-- literal usable as a constant
			if e.ty.x87 then
				-- the sign is a bit of its own, and the
				-- number beside it cannot hold the value
				local c = tree.clone(e)

				c.hi = e.hi ~ 0x8000
				c.fnum = -e.fnum
				return c
			end
			return tree.const(e.ty,
				e.val ~ (1 << (e.ty.size * 8 - 1)))
		end
		if isflt(e.ty) then
			if self:iswide(e.ty) then
				return self:wcall("__w_dneg",
					{self:waddr(e)}, e.ty)
			end
			if self.t.hwfloat then
				return tree.unary("NEG", e.ty, e)
			end
			return self:rtcall("__" .. self:fprefix(e.ty) ..
				"neg", e.ty, {e})
		end
		if self:iswide(e.ty) then
			if e.op == "CONST" then
				return tree.const(e.ty, -e.val)
			end
			return self:wcall("__w_neg", {self:waddr(e)}, e.ty)
		end
		return tree.unary("NEG", self:promote(e.ty), e)
	elseif k == "+" then
		self:adv()
		return self:unary()
	elseif k == "~" then
		self:adv()
		local e = self:rvalue(self:unary())
		if self:iswide(e.ty) then
			if e.op == "CONST" then
				return tree.const(e.ty, ~e.val)
			end
			return self:wcall("__w_not", {self:waddr(e)}, e.ty)
		end
		return tree.unary("NOT", self:promote(e.ty), e)
	elseif k == "!" then
		self:adv()
		return tree.unary("LNOT", self.ty.i32,
			self:test(self:unary()))
	elseif k == "*" then
		self:adv()
		local e = self:rvalue(self:unary())
		if not isptr(e.ty) then self:err("not a pointer") end
		return self:postfix(tree.unary("INDIR", e.ty.to, e))
	elseif k == "&&" then
		-- GNU labels as values: the address of a label, which
		-- `goto *` jumps to.
		self:adv()
		local name = self:expect("name").text

		self.taken = self.taken or {}
		self.taken[name] = true
		return tree.unary("ADDR", self.ty.ptr(self.ty.void),
			tree.name(self.ty.i8, self:userlabel(name)))
	elseif k == "name" and CPLXHALF[self.tok.text] then
		-- GNU C: the two halves of a complex value, and of a real
		-- one, where the imaginary half is zero.
		local want = CPLXHALF[self.tok.text]

		self:adv()
		local e = self:rvalue(self:unary())
		local elem = e.ty.complex or e.ty

		if not e.ty.complex then
			if want == "im" then
				return self:fconst(0.0, isflt(elem) and elem
					or self.ty.f64)
			end
			return e
		end
		local pre = {}
		local re, im = self:cplxparts(e, elem, pre)
		local v = want == "im" and im or re

		if #pre == 0 then return v end
		pre[#pre + 1] = v
		return tree.node("SEQ", elem, nil, nil, {arms = pre})
	elseif k == "&" then
		self:adv()
		return self:addrof(self:unary())
	elseif k == "++" or k == "--" then
		self:adv()
		local e = self:unary()

		self:inlkill(e)
		local step = k == "++" and 1 or -1
		-- The operand is named twice but evaluated once, so
		-- `++*p++` steps p one time, not two.
		local lv, pre = self:once(e)
		local asg = self:assignto(tree.clone(lv),
			self:arith("ADD", lv, tree.const(self.ty.i32, step)))

		if not pre then return asg end
		return tree.node("SEQ", asg.ty, nil, nil, {arms = {pre, asg}})
	end
	return self:postfix(self:primary())
end

function P:binary(minp)
	local a = self:unary()
	while true do
		local b = BIN[self.tok.kind]
		if not b or b[1] < minp then return a end
		self:adv()
		local short = b[2] == "ANDAND" or b[2] == "OROR"
		local odead, ruled = self.dead, false

		if short then
			self:pushregion()
			-- An operand the left one rules out never runs,
			-- so a call in it is not a use: the kernel
			-- guards a whole family of calls this way.
			ruled = self:constcond(a) == (b[2] == "OROR")
			if ruled then self.dead = true end
		end
		local rhs = self:binary(b[1] + 1)

		if short then
			self:popregion()
			self.dead = odead
		end
		if ruled then
			-- The left decides, so the right is left out of
			-- the tree.  What the left does still happens.
			local v = tree.const(self.ty.i32,
				b[2] == "OROR" and 1 or 0)

			a = tree.effects(a) and
				tree.node("SEQ", self.ty.i32, nil, nil,
					{arms = {a, v}}) or v
		elseif short then
			a = tree.binary(b[2], self.ty.i32,
				self:test(a), self:test(rhs))
		else
			a = self:arith(b[2], a, rhs)
		end
	end
end

-- A null pointer constant: zero, whatever it was cast to on the way.
local function isnull(n)
	if not n then return false end
	if isptr(n.ty) and n.ty.to.kind ~= "void" then return false end
	return fold(n) == 0
end

-- The type of `c ? a : b`.  A null pointer constant takes the other
-- side's type; otherwise two pointers, one of them to void, give a
-- pointer to void, which is what tells a _Generic on the answer which
-- of the two the operand was.
function P:condtype(x, y)
	local a, b = x.ty, y.ty

	if isptr(a) and isnull(y) then return a end
	if isptr(b) and isnull(x) then return b end
	if isptr(a) and isptr(b) then
		if a.to.kind == "void" or b.to.kind == "void" then
			return self.ty.ptr(self.ty.void)
		end
		return a
	end
	if isptr(a) then return a end
	if isptr(b) then return b end
	return self:usual(a, b)
end

function P:ternary()
	local c = self:binary(1)
	if not self:accept("?") then return c end
	-- `a ?: b` is `a ? a : b` without saying a twice.  The value is
	-- needed in both places, so it goes in a frame slot when working it
	-- out has any effect of its own.
	if self.tok.kind == ":" then
		self:adv()
		c = self:rvalue(c)
		self:pushregion()
		local b = self:rvalue(self:ternary())

		self:popregion()
		local rt = self:condtype(c, b)

		if not tree.effects(c) then
			return tree.node("COND", rt,
				self:test(tree.clone(c)), nil,
				{arms = {self:conv(c, rt),
					 self:conv(b, rt)}})
		end
		if self:iswide(c.ty) then
			self:err("?: with no middle needs a narrower value")
		end
		-- it is named twice and must happen once, so it goes to a
		-- frame slot first
		local slot = tree.auto(c.ty, self:temp(c.ty))
		local set = tree.binary("ASGN", c.ty, tree.clone(slot), c)

		return tree.node("SEQ", rt, nil, nil, {arms = {set,
			tree.node("COND", rt,
				self:test(tree.clone(slot)), nil,
				{arms = {self:conv(tree.clone(slot), rt),
					 self:conv(b, rt)}})}})
	end
	c = self:test(c)
	-- An arm the condition rules out is not compiled at all.  A
	-- header writes `__builtin_constant_p(x) ? <only right for a
	-- constant> : <the general way>`, and the first does not
	-- compile when x is not one -- and a body built where it was
	-- called writes its code as it is read, so leaving the arm out
	-- of the tree afterwards is too late.
	if fold(c) == 0 and not tree.effects(c) then
		local depth, q = 0, 0

		while self.tok.kind ~= "eof" do
			local k = self.tok.kind

			if k == "(" or k == "[" or k == "{" then
				depth = depth + 1
			elseif k == ")" or k == "]" or k == "}" then
				if depth == 0 then break end
				depth = depth - 1
			elseif depth == 0 and k == "?" then
				q = q + 1
			elseif depth == 0 and k == ":" then
				if q == 0 then break end
				q = q - 1
			end
			self:adv()
		end
		self:expect(":")
		self:pushregion()
		local only = self:rvalue(self:ternary())

		self:popregion()
		return only
	end
	-- Each arm runs only when the condition picks it, so a write in
	-- one says nothing after the whole, and a call in the one the
	-- condition rules out is not a use.
	local pick, odead = self:constcond(c), self.dead

	self:pushregion()
	if pick == false then self.dead = true end
	local a = self:expression()

	self:popregion()
	self.dead = odead
	self:expect(":")
	self:pushregion()
	if pick == true then self.dead = true end
	local b = self:ternary()

	self:popregion()
	self.dead = odead
	a, b = self:rvalue(a), self:rvalue(b)
	local rt = self:condtype(a, b)
	-- A condition the compiler can settle picks the arm here, and
	-- the other one is never generated.  `__builtin_constant_p(x) ?
	-- <only right for a constant> : <the general way>` is how a
	-- header asks for exactly that, and the arm not taken holds
	-- things that would not compile.
	-- A condition that settles picks the arm here, and the other one
	-- is left out of the tree.  What the condition does still
	-- happens, so it travels with the arm when it does anything.
	if pick ~= nil then
		local only = self:conv(pick and a or b, rt)

		if not tree.effects(c) then return only end
		return tree.node("SEQ", rt, nil, nil, {arms = {c, only}})
	end
	return tree.node("COND", rt, c, nil,
		{arms = {self:conv(a, rt), self:conv(b, rt)}})
end

-- A whole record moves as bytes.
function P:assignto(lhs, rhs)
	local was = lhs.op == "AUTO" and self.konsts[lhs.off] or nil

	-- Once a slot is written it no longer holds what the caller put
	-- there, so an operand that must be a constant cannot read it.
	self:inlkill(lhs)
	if lhs.bf then return self:bfset(lhs, rhs) end
	if self:iswide(lhs.ty) then
		local r = self:conv(self:rvalue(rhs), lhs.ty)
		local cp = tree.node("COPY", lhs.ty, self:waddr(lhs),
			self:waddr(r), {val = lhs.ty.size})
		return tree.node("SEQ", lhs.ty, nil, nil,
			{arms = {cp, tree.clone(lhs)}})
	end
	if isrec(lhs.ty) then
		-- A _Complex is a record, but unlike a struct it takes a
		-- value of another type: a real, or a complex of another
		-- element.  That conversion builds the pair.
		if lhs.ty.complex then
			rhs = self:conv(self:rvalue(rhs), lhs.ty)
		end
		return tree.node("COPY", lhs.ty, self:recaddr(lhs),
			self:recaddr(rhs), {val = lhs.ty.size})
	end
	local n = tree.binary("ASGN", lhs.ty, lhs,
		self:conv(self:rvalue(rhs), lhs.ty))

	-- After the write, which is what put the value there.
	if lhs.op == "AUTO" and not lhs.hard and not lhs.part then
		self:notekonst(lhs.off, n.right, lhs.ty, nil, was)
	end
	return n
end

function P:assign()
	local a = self:ternary()
	local k = self.tok.kind
	if k == "=" then
		self:adv()
		return self:assignto(a, self:assign())
	end
	local op = OPASSIGN[k]
	if op then
		self:adv()
		local rhs = self:assign()
		local lv, pre = self:once(a)
		local asg = self:assignto(tree.clone(lv),
			self:arith(op, lv, rhs))
		if not pre then return asg end
		return tree.node("SEQ", asg.ty, nil, nil, {arms = {pre, asg}})
	end
	return a
end

-- An lvalue the caller may evaluate twice.  A variable already is one.  An
-- indirection through an expression with a side effect is not, so its
-- address goes into a frame temporary first; the second result is the
-- assignment that fills the temporary, to be evaluated before the rest.
function P:once(a)
	if a.op ~= "INDIR" or not tree.effects(a.left) then
		return a, nil
	end
	local ty = self.ty.ptr(a.ty)
	local off = self:temp()
	local set = tree.binary("ASGN", ty, tree.auto(ty, off),
		self:conv(a.left, ty))
	local lv = tree.unary("INDIR", a.ty, tree.auto(ty, off))
	lv.bf = a.bf
	return lv, set
end

-- A frame slot for the compiler's own use.  It lives as long as any local
-- of the enclosing block, which is longer than it needs to but costs one
-- word at a site that is rare.
function P:temp(ty)
	return self:alloc(ty or self.ty.ptr(self.ty.i8))
end

-- Eight-byte scalars on a four-byte machine -----------------------------
--
-- A value twice the register width cannot sit in a register, and every tree
-- node here gets one.  So on a 32-bit target such a value always lives in
-- memory, is named by its address, and every operation on it is a call into
-- `rt/wide.c`.  That is the same trade the floating point runtime makes,
-- one step further along.

-- Whether a wide value has to travel by address.  It does when it is
-- wider than a register: that is the only reason the calling convention
-- needs the wide path at all.
function P:widepass(ty)
	return self:iswide(ty) and ty.size > self.t.ptrsize
end

-- A value this wide crosses a call the way a record of the same size
-- does, when the machine classifies a record into registers at all.
-- Half of a wide value, which is the width the runtime hands one over
-- in: four bytes for an eight-byte value, eight for a sixteen-byte one.
function P:widehalf(ty, uns)
	if ty.size >= 16 then
		return uns and self.ty.u64 or self.ty.i64
	end
	return uns and self.ty.u32 or self.ty.i32
end

function P:byparts(ty)
	if not self:widepass(ty) or self.t.wideargs then return false end
	return self.t.recabi and self.t.eightbytes ~= nil and
		self.t.eightbytes(ty) ~= nil
end

function P:iswide(ty)
	if ty.addr then return false end
	local k = ty.kind

	if self.widen and ty.size == 8 and
	   (k == "int" or k == "uint" or k == "float") then
		return true
	end
	-- A value twice the register width lives in memory and reaches the
	-- runtime by address, whether that is eight bytes on a 32-bit
	-- machine or sixteen on a 64-bit one.
	return ty.size == 2 * self.t.ptrsize and (k == "int" or k == "uint")
end

-- The address of a wide value.  An lvalue has one; a computed value is a
-- sequence whose last arm is the temporary it was left in.
function P:waddr(e)
	local pt = self.ty.ptr(e.ty)
	if e.op == "INDIR" then
		return self:conv(e.left, pt)
	end
	if e.op == "AUTO" or e.op == "NAME" then
		return tree.unary("ADDR", pt, e)
	end
	if e.op == "SEQ" then
		local arms = {}
		for i = 1, #e.arms - 1 do arms[i] = e.arms[i] end
		arms[#e.arms] = self:waddr(e.arms[#e.arms])
		return tree.node("SEQ", pt, nil, nil, {arms = arms})
	end
	if e.op == "CONST" then
		return tree.unary("ADDR", pt, self:wconst(e.val, e.ty))
	end
	if e.op == "COND" then
		-- each arm writes the same temporary, and the address of
		-- that temporary is the answer
		local t = self:wtemp(e.ty)
		local arms = {}
		for i, a in ipairs(e.arms) do
			arms[i] = tree.node("COPY", e.ty,
				self:waddr(tree.clone(t)), self:waddr(a),
				{val = e.ty.size})
		end
		local c = tree.node("COND", self.word, e.left, nil,
			{arms = arms})
		return tree.node("SEQ", pt, nil, nil,
			{arms = {c, self:waddr(t)}})
	end
	if not self:widepass(e.ty) then
		-- the register is wide enough to hold it, so it can simply
		-- be put in a temporary and that named
		local t = self:wtemp(e.ty)
		local set = tree.binary("ASGN", e.ty, tree.clone(t), e)
		return tree.node("SEQ", pt, nil, nil,
			{arms = {set, tree.unary("ADDR", pt, tree.clone(t))}})
	end
	self:err("a wide value must be addressable, not " .. e.op)
end

-- A wide constant goes to read-only data; there is no instruction that can
-- carry one.
function P:wconst(v, ty)
	self.nstr = self.nstr + 1
	local label = ".Lwide" .. self.nstr
	self.t.data.obj(self.sg, label, 8, true, false)
	self.t.data.item(self.sg, 4, tostring(v & 0xffffffff))
	self.t.data.item(self.sg, 4, tostring((v >> 32) & 0xffffffff))
	return tree.name(ty, label)
end

-- A fresh temporary holding the result of a wide operation, and the call
-- that fills it.  The value of the whole is the temporary.
function P:wtemp(ty)
	return tree.auto(ty, self:temp(ty))
end

function P:wcall(name, args, ty, dst)
	dst = dst or self:wtemp(ty)
	local all = {self:waddr(dst)}
	for _, a in ipairs(args) do all[#all + 1] = a end
	local call = self:rtcall(name, self.word, all)
	return tree.node("SEQ", ty, nil, nil, {arms = {call, dst}})
end

-- Give a node another name for the same bits.
function P:retype(n, ty)
	local c = tree.clone(n)
	c.ty = ty
	return c
end

function P:wconv(n, ty)
	local from = n.ty
	local fw, tw = self:iswide(from), self:iswide(ty)
	if fw and tw then
		if isflt(from) == isflt(ty) then
			if n.op ~= "SEQ" then return self:retype(n, ty) end
			local arms = {}
			for i = 1, #n.arms do arms[i] = n.arms[i] end
			arms[#arms] = self:retype(arms[#arms], ty)
			return tree.node("SEQ", ty, nil, nil, {arms = arms})
		end
		if isflt(ty) then
			return self:wcall(from.kind == "uint" and "__w_ul2d"
				or "__w_l2d", {self:waddr(n)}, ty)
		end
		return self:wcall(ty.kind == "uint" and "__w_d2ul"
			or "__w_d2l", {self:waddr(n)}, ty)
	end
	if tw then
		-- a constant widens here when Lua's own integers are wide
		-- enough to hold the answer, rather than in a call
		if n.op == "CONST" and ty.size <= 8 and
		   not isflt(from) and not isflt(ty) then
			local v = n.val
			if from.kind == "uint" and from.size < 8 then
				v = v & ((1 << (from.size * 8)) - 1)
			end
			return tree.const(ty, v)
		end
		if n.op == "CONST" and ty.size <= 8 and
		   not isflt(from) and isflt(ty) then
			return self:fconst(n.val + 0.0, ty)
		end
		if isflt(from) then
			if isflt(ty) then
				return self:wcall("__w_f2d", {n}, ty)
			end
			return self:wconv(self:conv(n, self.ty.f64), ty)
		end
		local half = self:widehalf(ty, from.kind == "uint")
		local w = from.size < half.size and half or from

		if isptr(w) then w = self.uword end
		n = self:conv(n, w)
		if isflt(ty) then
			return self:wcall(w.kind == "uint" and "__w_u2d"
				or "__w_i2d", {n}, ty)
		end
		return self:wcall(w.kind == "uint" and "__w_extu"
			or "__w_exts", {n}, ty)
	end
	-- wide to narrow
	if isflt(from) then
		if isflt(ty) then
			return self:rtcall("__w_d2f", ty, {self:waddr(n)})
		end
		local want = ty.size < 4 and self.ty.i32 or ty
		if isptr(want) then want = self.uword end
		return self:conv(self:rtcall(want.kind == "uint" and "__w_d2u"
			or "__w_d2i", want, {self:waddr(n)}), ty)
	end
	if isflt(ty) then
		-- A wide integer reaches a narrow float through a double:
		-- its low half alone is not the value, and taking it
		-- loses the sign.
		return self:conv(self:wconv(n, self.ty.f64), ty)
	end
	return self:conv(self:rtcall("__w_lo", self:widehalf(from, true),
		{self:waddr(n)}), ty)
end

local WOP = {ADD = "add", SUB = "sub", MUL = "mul", AND = "and",
	     OR = "or", XOR = "xor"}
local WDIV = {DIV = "div", MOD = "mod"}
local WREL = {EQ = {"EQ", 0}, NE = {"NE", 0}, LT = {"EQ", -1},
	      GT = {"EQ", 1}, LE = {"LE", 0}, GE = {"GE", 0}}

-- An operation on two wide values.  Floating point keeps its own names,
-- because the runtime for it is not the same code.
function P:wideop(op, a, b, rt)
	local flt = isflt(rt)
	-- Two constants fold here, where Lua's own integers are wide enough;
	-- an initializer has no other way to reach a value.
	if not flt and a.op == "CONST" and b.op == "CONST" then
		local v = foldbin(op, a.val, b.val, rt.kind == "uint")
		if v then return tree.const(rt, v) end
	end
	local pre = flt and ("__w_" .. self:fprefix(rt)) or "__w_"
	if WOP[op] and not flt then
		return self:wcall(pre .. WOP[op],
			{self:waddr(a), self:waddr(b)}, rt)
	end
	if flt and (WOP[op] or op == "DIV") then
		return self:wcall(pre .. (WOP[op] or "div"),
			{self:waddr(a), self:waddr(b)}, rt)
	end
	if WDIV[op] then
		return self:wcall(pre .. WDIV[op] ..
			(rt.kind == "uint" and "u" or "s"),
			{self:waddr(a), self:waddr(b)}, rt)
	end
	if op == "SHL" or op == "SHR" then
		local n = self:conv(self:rvalue(b), self.ty.i32)
		local name = op == "SHL" and "__w_shl" or
			(rt.kind == "uint" and "__w_shru" or "__w_shrs")
		return self:wcall(name, {self:waddr(a), n}, rt)
	end
	local c = WREL[op]
	if not c then self:err(op .. " is not defined on a wide value") end
	local name = flt and (pre .. "cmp") or
		("__w_cmp" .. (rt.kind == "uint" and "u" or "s"))
	local r = self:rtcall(name, self.ty.i32,
		{self:waddr(a), self:waddr(b)})
	-- an unordered floating point compare answers 2, which is not less,
	-- not equal and not greater
	if flt and (op == "LE" or op == "GE" or op == "LT" or op == "GT") then
		local m = {LT = {"EQ", -1}, GT = {"EQ", 1},
			   LE = {"LE", 0}, GE = {"ULE", 1}}
		local d = m[op]
		if d[1] == "ULE" then
			r.ty = self.ty.u32
			return tree.binary("LE", self.ty.i32, r,
				tree.const(self.ty.u32, d[2]))
		end
		return tree.binary(d[1], self.ty.i32, r,
			tree.const(self.ty.i32, d[2]))
	end
	return tree.binary(c[1], self.ty.i32, r, tree.const(self.ty.i32, c[2]))
end

-- The comma operator builds a node rather than emitting its left side on
-- the spot: a for statement parses its increment before the body and emits
-- it after, so nothing here may reach the generator early.
function P:expression()
	local e = self:assign()
	if self.tok.kind ~= "," then return e end
	local arms = {e}
	while self:accept(",") do
		arms[#arms + 1] = self:assign()
	end
	return tree.node("SEQ", arms[#arms].ty, nil, nil, {arms = arms})
end

-- A float constant travels as its bit pattern, so integer arithmetic on
-- one gives a wrong answer.  Float folding belongs to floatop, which has
-- already run by the time anything asks here.
local function fltn(n) return n ~= nil and n.ty ~= nil and isflt(n.ty) end

-- A pointer to a fixed place in a named object, as a symbol and a byte
-- offset.  Two of these into the same object subtract to a constant,
-- which is what an assertion in a header asks for.
function symoff(n)
	if not n then return nil end
	if n.op == "CVT" then return symoff(n.left) end
	if n.op == "ADDR" then
		if n.left.op == "NAME" then return n.left.sym, 0 end
		if n.left.op == "INDIR" then return symoff(n.left.left) end
		return nil
	end
	if n.op == "ADD" or n.op == "SUB" then
		local sym, off = symoff(n.left)
		local k = off and fold(n.right)

		if not k then return nil end
		return sym, n.op == "ADD" and off + k or off - k
	end
	return nil
end

function fold(n)
	if not n then return nil end
	if n.op == "CONST" then return n.val end
	if n.op == "SUB" then
		local sa, oa = symoff(n.left)
		local sb, ob = symoff(n.right)

		if sa and sa == sb then return oa - ob end
	end
	if n.op == "NEG" then
		if fltn(n.left) then return nil end
		local a = fold(n.left)
		return a and -a
	end
	if n.op == "NOT" then
		local a = fold(n.left)
		return a and ~a
	end
	if n.op == "LNOT" then
		if fltn(n.left) then return nil end
		local a = fold(n.left)
		return a and (a == 0 and 1 or 0)
	end
	if n.op == "CVT" then
		if fltn(n) ~= fltn(n.left) then return nil end
		return fold(n.left)
	end
	-- `a ? b : c` is a constant expression when all three are, which is
	-- how a C library writes a table of bits.
	if n.op == "COND" then
		local c = fold(n.left)

		if not c then return nil end
		return fold(n.arms[c ~= 0 and 1 or 2])
	end
	if n.op == "ANDAND" or n.op == "OROR" then
		local x = fold(n.left)

		if not x then return nil end
		if n.op == "ANDAND" and x == 0 then return 0 end
		if n.op == "OROR" and x ~= 0 then return 1 end
		local y = fold(n.right)

		return y and (y ~= 0 and 1 or 0)
	end
	if fltn(n.left) or fltn(n.right) then return nil end
	local a, b = fold(n.left), fold(n.right)
	if not a or not b then return nil end
	return foldbin(n.op, a, b, n.ty and n.ty.kind == "uint")
end

-- Every value of `at` reaches `rt` unchanged.
local function reaches(at, rt)
	if at.size < rt.size then
		return rt.kind == "int" or at.kind == "uint"
	end
	return at.size == rt.size and at.kind == rt.kind
end

-- Keep a value in a slot of our own, so the tree may read it twice.
function P:pin(e)
	local off = self:temp(e.ty)
	local slot = function() return tree.auto(e.ty, off) end

	return slot, self:assignto(slot(), e)
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
	if w > 8 then
		self:err(name .. " on these types needs more than eight " ..
			"bytes to work in")
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
	local function cmp(o, x, y) return tree.binary(o, i32, x, y) end
	local function both(x, y) return tree.binary("ANDAND", i32, x, y) end
	local function either(x, y) return tree.binary("OROR", i32, x, y) end
	local test

	if op == "mul" then
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
	if not reaches(wt, rt) then
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
	local lv, pre = self:once(self:conv(self:rvalue(e), ty))
	local out

	for i = 0, size - 1 do
		local from, to = i * 8, (size - 1 - i) * 8
		local b = self:arith("AND", tree.clone(lv),
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

-- C11 _Generic: the association whose type is the controlling
-- expression's is the value, and the rest are parsed and thrown away.
-- A qualifier is not part of a type here, so two associations that
-- differ only in const are the same one and the first wins.
function P:generic()
	self:expect("(")
	local m = tree.mark()
	local ty = self.ty.decay(self:rvalue(self:assign()).ty)

	tree.release(m)
	self:expect(",")
	local taken, fallback
	repeat
		local want
		if self.tok.kind == "default" then
			self:adv()
		else
			want = self:typename()
		end
		self:expect(":")
		local mk = tree.mark()
		local e = self:assign()

		if want and not taken and self.ty.same(want, ty) then
			taken = e
		elseif not want and not fallback then
			fallback = e
		else
			tree.release(mk)
		end
	until not self:accept(",")
	self:expect(")")
	local got = taken or fallback
	if not got then
		self:err("no _Generic association for " .. ty.name)
	end
	return got
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
	if name == "__builtin_prefetch" then
		return tree.const(self.ty.i32, 0)
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
		local fty = ab == "f" and self.ty.f32 or self.ty.f64

		if isflt(a.ty) and a.ty.size == 4 then fty = self.ty.f32 end
		a = self:conv(a, fty)
		local uty = fty.size == 4 and self.ty.u32 or self.ty.u64
		local mask = fty.size == 4 and 0x7fffffff
			or 0x7fffffffffffffff
		local k = fold(a)

		-- A float constant is its bit pattern here, so clearing
		-- the sign is the whole of it.
		if k then return tree.const(fty, k & mask) end
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
		return self:fconst(iv[1] == "nan" and 0.0 / 0.0
			or math.huge, fty)
	end
	local fc = FCLASS[name:sub(11)]
	if fc then
		local a = self:rvalue(args[1])

		if not isflt(a.ty) then a = self:conv(a, self.ty.f64) end
		return self:rtcall("__" .. self:fprefix(a.ty) .. fc,
			self.ty.i32, {a})
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
	local n = self:rtcall(fn, rty, args)
	n.soft = nil
	return n
end

-- The type a variadic walker is.  gcc has it as a name the compiler
-- knows, used by headers that never include <stdarg.h>, and va_start
-- reaches into it by member name, so the compiler owns the layout and
-- <stdarg.h> takes its own va_list from here.
function P:valist()
	if self.vatype then return self.vatype end
	local T = self.ty
	local cp = T.ptr(T.i8)

	-- A target whose system has a va_list of its own must use that one,
	-- or a va_list cannot cross between this compiler's code and the
	-- system library's vprintf.
	if self.t.vaabi == "sysv" then
		local tag = T.record("struct", "__va_list_tag")

		T.complete(tag, {
			{name = "gp_offset", ty = T.u32},
			{name = "fp_offset", ty = T.u32},
			{name = "overflow_arg_area", ty = cp},
			{name = "reg_save_area", ty = cp},
		})
		self.vatype = T.array(tag, 1)
		return self.vatype
	end
	local st = T.record("struct", "__va_state")

	T.complete(st, {
		{name = "left", ty = self.word},
		{name = "fleft", ty = self.word},
		{name = "regs", ty = self.word},
		{name = "reg", ty = cp},
		{name = "freg", ty = cp},
		{name = "stk", ty = cp},
	})
	self.vatype = T.array(st, 1)
	return self.vatype
end

-- The address of the state a va_list names, and how big it is.  An
-- array of one gives its own address; one that has decayed to a
-- pointer, which is what a parameter is, gives its value.
function P:valistat(e)
	local t = e.ty

	if t.kind == "array" then
		return self:addrof(e), t.of.size
	end
	if isptr(t) and isrec(t.to) then
		return self:rvalue(e), t.to.size
	end
	self:err("va_copy needs a va_list")
end

-- Only the compiler knows where the argument save area is, so va_start is
-- built here rather than in a header.
function P:vastart()
	self:expect("(")
	local ap = self:rvalue(self:assign())
	self:expect(",")
	self:assign()			-- the last named parameter, unused
	self:expect(")")
	if not self.vabase then
		self:err("va_start outside a variadic function")
	end
	if not isptr(ap.ty) or not isrec(ap.ty.to) then
		self:err("va_start needs a va_list")
	end

	local ps = self.t.ptrsize
	local nreg = self.t.nargreg
	local nflt = self.t.vafloat and (self.t.nfltreg or 0) or 0
	local cp = self.ty.ptr(self.ty.i8)

	local function set(field, value)
		local lv = self:member(ap, field, true)
		return tree.binary("ASGN", lv.ty, lv, self:conv(value, lv.ty))
	end
	local function area(off)
		return tree.unary("ADDR", cp, tree.auto(self.ty.i8, off))
	end
	-- The System V save area is one block: six integer registers, then
	-- eight floating point ones two words apart.  An offset into it
	-- says how much of each file the named parameters took.
	if self.t.vaabi == "sysv" then
		return tree.node("SEQ", self.word, nil, nil, {arms = {
			set("gp_offset",
				tree.const(self.word, self.vagp * 8)),
			set("fp_offset",
				tree.const(self.word,
					nreg * 8 + self.vafp * 16)),
			set("overflow_arg_area",
				area(self.t.stackargs + self.vastk * ps)),
			set("reg_save_area", area(self.vabase)),
		}})
	end
	-- The named parameters have already used up part of each file; the
	-- walker starts where they stopped.
	return tree.node("SEQ", self.word, nil, nil, {arms = {
		set("left", tree.const(self.word,
			math.max(0, nreg - self.vagp))),
		set("fleft", tree.const(self.word,
			math.max(0, nflt - self.vafp))),
		set("regs", tree.const(self.word, nreg)),
		set("reg", area(self.vabase + self.vagp * ps)),
		set("freg", area(self.vabase + (nreg + self.vafp) * ps)),
		set("stk", self.t.vastkslot
			and tree.binary("ADD", cp,
				tree.auto(cp, self.vabase + (nreg + nflt) * ps),
				tree.const(self.word, self.vastk * ps))
			or area(self.t.stackargs + self.vastk * ps)),
	}})
end

-- va_arg needs the type, so it is a builtin too: only the compiler can say
-- which register file the value arrived in.
function P:vaarg()
	self:expect("(")
	local ap = self:rvalue(self:assign())
	self:expect(",")
	local ty = self:typename()
	if not ty then self:err("va_arg needs a type") end
	self:expect(")")
	-- 0 an ordinary word, 1 the float file, 2 the extended type,
	-- which is never in a register and is aligned on the stack.
	local flt = 0

	if ty.x87 then
		flt = 2
	elseif self.t.vafloat and (self.t.nfltreg or 0) > 0 and isflt(ty)
	then
		flt = 1
	end
	local p = self.t.vaabi == "sysv" and self:vasysv(ap, ty, flt)

	if not p then
		p = self:rtcall("__va_next", self.ty.ptr(ty), {
			ap,
			tree.const(self.word, ty.size),
			tree.const(self.word, flt),
		})
		p.soft = nil
	end
	return tree.unary("INDIR", ty, p)
end

-- Where the next argument sits, worked out here rather than in a call
-- to the runtime: the size and the register file are both known where
-- the walk is written, so what is left is one test and two additions.
--
-- The System V save area is six integer registers and then eight
-- floating point ones sixteen bytes apart.  An offset past the end of
-- a file means that file is used up and the rest comes off the
-- caller's stack.
local GPEND, FPEND = 48, 176

function P:vasysv(ap, ty, flt)
	local cp = self.ty.ptr(self.ty.i8)
	local pre = {}
	-- The list is named several times and must be worked out once.
	local slot, set = self:pin(self:conv(ap, self.ty.decay(ap.ty)))

	pre[#pre + 1] = set
	local function field(name)
		return self:member(slot(), name, true)
	end
	local words = (ty.size + 7) // 8
	local step = tree.const(self.word, words * 8)
	-- Where the answer goes, so that both arms hand back the same
	-- slot and the caller reads it once.
	local tmp = self:temp(cp)
	local function at() return tree.auto(cp, tmp) end
	local function setat(e)
		return tree.binary("ASGN", cp, at(), self:conv(e, cp))
	end
	local function bump(fld, by)
		local lv = field(fld)

		return tree.binary("ASGN", lv.ty, lv,
			self:conv(tree.binary("ADD", self.word,
				self:conv(field(fld), self.word), by),
				lv.ty))
	end
	-- Off the caller's stack, which is where anything too big for a
	-- register file goes and where the extended type always goes.
	local function stack(align, by)
		local a = field("overflow_arg_area")

		if align then
			a = tree.binary("AND", cp,
				tree.binary("ADD", cp, a,
					tree.const(self.word, 15)),
				tree.const(self.word, ~15))
		end
		return tree.node("SEQ", cp, nil, nil, {arms = {
			setat(a),
			tree.binary("ASGN", cp, field("overflow_arg_area"),
				tree.binary("ADD", cp, at(), by or step)),
			at()}})
	end
	-- A record too big for two registers is handed over in memory,
	-- and so is anything whose class the target cannot work out.
	local mem = isrec(ty) and (self.t.eightbytes == nil or
		self.t.eightbytes(ty) == nil)

	if flt == 2 then
		pre[#pre + 1] = stack(true, tree.const(self.word, 16))
	elseif mem then
		pre[#pre + 1] = stack(ty.align >= 16, step)
	else
		local off = flt == 1 and "fp_offset" or "gp_offset"
		local last = flt == 1 and FPEND - 16 or GPEND - words * 8
		local by = flt == 1 and tree.const(self.word, 16) or step
		-- A file is used up when the next value would run past
		-- the end of it.
		local fits = tree.binary("LE", self.ty.i32,
			self:conv(field(off), self.word),
			tree.const(self.word, last))
		local inreg = tree.node("SEQ", cp, nil, nil, {arms = {
			setat(tree.binary("ADD", cp,
				field("reg_save_area"),
				self:conv(field(off), self.word))),
			bump(off, by),
			at()}})

		pre[#pre + 1] = tree.node("COND", cp, fits, nil,
			{arms = {inreg, stack(false, step)}})
	end
	return tree.node("SEQ", self.ty.ptr(ty), nil, nil,
		{arms = {tree.node("SEQ", cp, nil, nil, {arms = pre}),
			 self:conv(at(), self.ty.ptr(ty))}})
end

-- initializers ---------------------------------------------------------

-- The text of an address constant: a symbol, or a symbol and an offset.
local function addrtext(n)
	if not n then return nil end
	local v = fold(n)
	if v then return tostring(v) end
	if n.op == "CVT" then return addrtext(n.left) end
	-- A slot in data holds the address itself, whatever a reference
	-- from code would go through, so the loader fills it in directly.
	if n.op == "GOT" and n.left.op == "NAME" then
		n.left.got = nil
		return n.left.sym
	end
	if n.op == "ADDR" and n.left.op == "NAME" then return n.left.sym end
	if n.op == "NAME" then return nil end
	-- `c ? &a : &b` with a constant condition is one of the two, which
	-- is how a table of device operations names a driver or a stub.
	if n.op == "COND" then
		local c = fold(n.left)

		if c then return addrtext(n.arms[c ~= 0 and 1 or 2]) end
	end
	if n.op == "ADD" or n.op == "SUB" then
		-- One symbol and one offset, so the assembler never sees
		-- more than `sym+n` to work out.
		local sym, off = symoff(n)

		if sym then
			if off == 0 then return sym end
			return sym .. (off > 0 and "+" or "-") ..
				math.abs(off)
		end
		local a, b = addrtext(n.left), addrtext(n.right)
		if a and b then
			return a .. (n.op == "ADD" and "+" or "-") .. b
		end
	end
	return nil
end

-- Reinterpret a value as the bits of a floating type.
function P:tofbits(v, from, to)
	if from and isflt(from) then
		local f = from.size == 8 and "<d" or "<f"
		-- The bits, not a number: a pattern with the top bit set
		-- is a perfectly good float and no kind of overflow.
		local i = from.size == 8 and "<I8" or "<I4"
		local mask = from.size == 8 and -1 or 0xffffffff
		v = string.unpack(f, string.pack(i, v & mask))
	end
	local f = to.size == 8 and "<d" or "<f"
	local i = to.size == 8 and "<i8" or "<i4"
	return string.unpack(i, string.pack(f, v + 0.0))
end

-- Build the list of data items for one initializer.  Returns how many
-- elements were given, which is what an array with no bound needs.
-- Gather an initializer into a flat list of items, each one a string of
-- bytes, a run of zeros, or a value of a given width.  `dyn` allows an item
-- whose value is not a constant, which only a local can have; it comes back
-- as an expression on the item, for the caller to store after the constant
-- part is in place.
function P:initlist(ty, out, dyn)
	if ty.kind == "array" and self.tok.kind == "str" and
	   ty.of.size == self:strelem(self.tok.pfx).size then
		local str = self.tok.text
		local w = ty.of.size

		self:adv()
		out[#out + 1] = {str = str, width = w}
		local n = #str + 1
		if ty.n and ty.n > n then
			out[#out + 1] = {zero = (ty.n - n) * w}
		end
		return n
	end

	if self:accept("{") then
		-- A string in braces initialises the whole array, which
		-- is how a table of characters is often written.
		if ty.kind == "array" and self.tok.kind == "str" and
		   ty.of.size == self:strelem(self.tok.pfx).size then
			local n = self:initlist(ty, out, dyn)

			self:accept(",")
			self:expect("}")
			return n
		end
		if ty.kind == "array" then
			return self:initarray(ty, out, dyn)
		end
		if isrec(ty) then
			return self:initrec(ty, out, dyn)
		end
		local n = self:initlist(ty, out, dyn)
		self:accept(",")
		self:expect("}")
		return n
	end

	-- `(struct s){ ... }` says the same as writing the braces here,
	-- which is how a macro hands over a whole object.
	if isrec(ty) and self.tok.kind == "(" then
		local depth = 0

		-- A macro may leave parentheses around the literal, and
		-- the drivers nest them two deep.
		while self.tok.kind == "(" do
			self:adv()
			depth = depth + 1
			if self:istype() then break end
		end
		-- Not a literal after all: parentheses around an
		-- ordinary expression, which for a record is a copy.
		-- The macros that hand one over wrap it twice.
		if not self:istype() then
			local text, e = self:initscalar(ty, dyn)

			for _ = 1, depth do self:expect(")") end
			out[#out + 1] = {size = ty.size, text = text or "0",
					 expr = e, ety = ty}
			return 1
		end
		self:typename()
		self:expect(")")
		local n = self:initlist(ty, out, dyn)

		for _ = 2, depth do self:expect(")") end
		return n
	end

	local text, e, x87 = self:initscalar(ty, dyn)
	out[#out + 1] = {size = ty.size, text = text or "0", expr = e,
			 ety = ty, x87 = x87}
	return 1
end

-- Lay the pieces out in order, padding the gaps a designator leaves.  Each
-- piece is the item list for one element, indexed by where it belongs.
-- An initialiser is a set of pieces placed at byte offsets.  Keeping the
-- offset rather than the member number is what lets a designator reach a
-- member of a member: `.u.basic.issigned = s` is one piece, placed deep.
--
-- Two pieces at the same offset are the same object written twice, and the
-- last one wins, which is what C says.  Within a struct or an array any two
-- offsets are disjoint, so nothing else can overlap; a union written twice
-- at two widths is the one case this leaves alone.
local function flatten(out, map, total)
	local byoff = {}
	local offs = {}

	for _, p in ipairs(map) do
		if byoff[p.off] == nil then offs[#offs + 1] = p.off end
		byoff[p.off] = p
	end
	table.sort(offs)
	local off = 0

	for _, a in ipairs(offs) do
		local p = byoff[a]

		if a >= off then
			if a > off then out[#out + 1] = {zero = a - off} end
			for _, it in ipairs(p.items) do
				out[#out + 1] = it
			end
			off = a + p.size
		end
	end
	if total > off then out[#out + 1] = {zero = total - off} end
end

-- A designator names a place inside the object being initialised, and may
-- name a place inside that.  This answers with where it is and what it is.
function P:designator(ty, off)
	local last
	while true do
		if self:accept(".") then
			if not isrec(ty) then
				self:err(". needs a struct or union")
			end
			local nm = self:expect("name").text
			local m = ty.byname and ty.byname[nm]

			if not m then self:err("no member " .. nm) end
			ty, off, last = m.ty, off + m.off, m
		elseif self:accept("[") then
			if ty.kind ~= "array" then
				self:err("[ needs an array")
			end
			local k = fold(self:ternary())

			if not k then self:err("a constant is required here") end
			self:expect("]")
			ty, off, last = ty.of, off + k * ty.of.size, nil
		else
			return ty, off, last
		end
	end
end

-- The same walk a designator makes, except that an array index here may
-- be an expression: GNU offsetof takes one.  Returns the constant part
-- and, when there is one, a tree for the rest.
function P:offsetpath(ty, off)
	local dyn
	while true do
		if self:accept(".") then
			if not isrec(ty) then
				self:err(". needs a struct or union")
			end
			local nm = self:expect("name").text
			local m = ty.byname and ty.byname[nm]

			if not m then self:err("no member " .. nm) end
			ty, off = m.ty, off + m.off
		elseif self:accept("[") then
			if ty.kind ~= "array" then
				self:err("[ needs an array")
			end
			local e = self:ternary()
			local k = fold(e)

			self:expect("]")
			if k then
				off = off + k * ty.of.size
			else
				local t = self:arith("MUL",
					self:conv(self:rvalue(e), self.uword),
					tree.const(self.uword, ty.of.size))

				dyn = dyn and self:arith("ADD", dyn, t) or t
			end
			ty = ty.of
		else
			return off, dyn
		end
	end
end

function P:initarray(ty, out, dyn)
	local map, i, n = {}, 1, 0
	local w = ty.of.size

	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		local ety, off = ty.of, (i - 1) * w

		-- `[a ... b] = v` gives every element from a to b the
		-- same value, which is how a table of mostly one thing
		-- is written.
		local rep = 1

		if self.tok.kind == "[" then
			self:accept("[")
			local k = fold(self:ternary())

			if not k then self:err("a constant is required here") end
			local hi = k

			if self.tok.kind == "..." then
				self:adv()
				hi = fold(self:ternary())
				if not hi then
					self:err("a constant is required here")
				end
				if hi < k then
					self:err("an empty range")
				end
			end
			self:expect("]")
			i = hi + 1
			ety, off = self:designator(ty.of, k * w)
			self:expect("=")
			rep = hi - k + 1
		end
		local items = {}

		self:initlist(ety, items, dyn)
		for r = 0, rep - 1 do
			map[#map + 1] = {off = off + r * ety.size,
					 size = ety.size, items = items}
		end
		if i > n then n = i end
		i = i + 1
		if not self:accept(",") then break end
	end
	self:expect("}")
	if ty.n and ty.n > n then n = ty.n end
	flatten(out, map, n * w)
	return n
end

function P:initrec(ty, out, dyn)
	local members = ty.members or {}
	local map, i = {}, 1
	-- Several bit-fields share one unit, so they are gathered into one
	-- value and written once.  `bits` indexes those units by offset.
	local bits, order = {}, {}

	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		local mty, off, mem

		if self.tok.kind == "." then
			mty, off, mem = self:designator(ty, 0)
			self:expect("=")
			-- what follows without a designator carries on from
			-- the member this one named
			for k, m in ipairs(members) do
				if m.off <= off and
				   off < m.off + m.ty.size then
					i = k + 1
				end
			end
		else
			mem = members[i]

			if not mem then break end
			mty, off = mem.ty, mem.off
			i = i + 1
		end
		if mem and mem.bits then
			local u = bits[off]

			if not u then
				u = {off = off, hi = 0, val = 0, dyn = {}}
				bits[off] = u
				order[#order + 1] = u
			end
			if mem.bit + mem.bits > u.hi then
				u.hi = mem.bit + mem.bits
			end
			local e = self:rvalue(self:assign())
			local v = fold(e)
			local mask = mem.bits >= 64 and -1 or
				((1 << mem.bits) - 1)

			if v then
				u.val = (u.val & ~(mask << mem.bit)) |
					((v & mask) << mem.bit)
			elseif dyn then
				u.dyn[#u.dyn + 1] = {m = mem, expr = e}
			else
				self:err("a constant is required here")
			end
		else
			local items = {}

			self:initlist(mty, items, dyn)
			map[#map + 1] = {off = off, size = mty.size,
					 items = items}
		end
		if ty.kind == "union" and self.tok.kind ~= "," then break end
		if not self:accept(",") then break end
	end
	for _, u in ipairs(order) do
		-- Only the bytes the bit-fields reach: an ordinary member
		-- may sit in the rest of the unit.
		local w = (u.hi + 7) // 8
		local items = {}

		for k = 0, w - 1 do
			items[k + 1] = {size = 1,
				text = tostring((u.val >> (k * 8)) & 0xff)}
		end
		items[1].bfdyn = #u.dyn > 0 and u.dyn or nil
		map[#map + 1] = {off = u.off, size = w, items = items}
	end
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		self:adv()
	end
	self:expect("}")
	flatten(out, map, ty.size)
	return 1
end

function P:initscalar(ty, dyn)
	local m = tree.mark()
	local e = self:rvalue(self:assign())
	local text
	if ty.x87 then
		local c = e

		-- One already of this type carries bits no number here
		-- can hold, so it is taken as it stands.
		if c.op ~= "CONST" or not c.ty.x87 then
			local v = isflt(e.ty) and self:fvalue(e) or fold(e)

			-- not v + 0.0: that would turn a negative zero
			-- back into a positive one
			if v and math.type(v) == "integer" then
				v = v * 1.0
			end
			c = v and self:fconst(v, ty) or nil
		end
		if c then
			tree.release(m)
			-- ten bytes of value in a sixteen byte slot
			return nil, nil, {lo = c.val, se = c.hi}
		end
	elseif isflt(ty) then
		local v = fold(e)
		if v then
			text = tostring(self:tofbits(v,
				isflt(e.ty) and e.ty or nil, ty))
		end
	else
		-- A float value has to cross to an integer before it is
		-- read as one, and conv folds that crossing.
		if isflt(e.ty) then e = self:conv(e, ty) end
		local v = fold(e)
		text = v and tostring(v) or addrtext(e)
	end
	if text then
		tree.release(m)
		return text
	end
	if not dyn then self:err("a constant is required here") end
	return nil, self:conv(e, ty)
end

function P:emitinit(name, ty, out, static, align, sec, vis, tls)
	self.t.data.obj(self.dg, name, math.max(align or 0, ty.align),
		static, false, sec, vis, tls)
	for _, it in ipairs(out) do
		if it.str then
			self.t.data.string(self.dg, it.str, it.width)
		elseif it.zero then
			self.t.data.zero(self.dg, it.zero)
		elseif it.x87 then
			self.t.data.item(self.dg, 8, tostring(it.x87.lo))
			self.t.data.item(self.dg, 2, tostring(it.x87.se))
			self.t.data.zero(self.dg, it.size - 10)
		else
			self.t.data.item(self.dg, it.size, it.text)
		end
	end
end

-- Parse an initializer for an object of type `ty`, and emit it.  Returns the
-- type, which for an array with no bound is now complete.
function P:initobject(name, ty, static, align, sec, vis, tls)
	local out = {}
	local n = self:initlist(ty, out)
	if ty.kind == "array" and not ty.n then
		ty = self.ty.array(ty.of, n)
	end
	self:emitinit(name, ty, out, static, align, sec, vis, tls)
	return ty
end

-- How many bytes an item covers.
local function itemsize(it)
	if it.str then return #it.str + 1 end
	return it.zero or it.size
end

-- A local aggregate is initialized from a hidden copy in read-only data, so
-- the value is rebuilt on every entry rather than kept between calls.  An
-- element whose value is not a constant leaves a zero in that copy and is
-- stored over it afterwards.
function P:initlocal(sym, ty)
	local lbl = ".Linit" .. self.nstr
	self.nstr = self.nstr + 1
	local out = {}
	-- The place comes first where the size is already known: an
	-- initializer may name the object it is initializing, which the
	-- queue macros do.
	local sized = ty.kind ~= "array" or ty.n ~= nil

	if sized then sym.off = self:alloc(ty) end
	local n = self:initlist(ty, out, true)

	if ty.kind == "array" and not ty.n then
		ty = self.ty.array(ty.of, n)
		sym.ty = ty
	end
	if not sized then sym.off = self:alloc(ty) end
	self:emitinit(lbl, ty, out, true)
	local dst = tree.unary("ADDR", self.ty.ptr(ty), tree.auto(ty, sym.off))
	local src = tree.unary("ADDR", self.ty.ptr(ty), tree.name(ty, lbl))
	self.g:expr(tree.node("COPY", ty, dst, src, {val = ty.size}), "eff")
	local off = 0
	for _, it in ipairs(out) do
		if it.expr then
			local lv = tree.auto(it.ety, sym.off + off)
			self.g:expr(self:assignto(lv, it.expr), "eff")
		end
		-- A bit-field the constant image could not hold is stored
		-- over it, the same way any other one is written.
		for _, b in ipairs(it.bfdyn or {}) do
			local lv = tree.auto(b.m.ty, sym.off + b.m.off)

			lv.bf = b.m
			self.g:expr(self:assignto(lv, b.expr), "eff")
		end
		off = off + itemsize(it)
	end
end

-- inline assembly ------------------------------------------------------



-- The subset a kernel actually writes: a literal template, operands tied to
-- a register, to memory or to an immediate, and a clobber list.  Nothing
-- here has to satisfy a register allocator, because an asm statement is a
-- statement, and at a statement boundary this compiler holds every value in
-- its frame slot: no scratch register is live when one is reached.
function P:asmstmt()
	self:adv()
	local isgoto = false

	-- `asm inline (...)` says the template is smaller than it looks,
	-- which is a hint to an inliner this compiler does not have.
	while self.tok.kind == "volatile" or self.tok.kind == "goto" or
	      self.tok.kind == "inline" or
	      (self.tok.kind == "name" and (IGNORE[self.tok.text] or
					    INLINEKW[self.tok.text])) do
		if self.tok.kind == "goto" then isgoto = true end
		self:adv()
	end
	self:expect("(")
	local text = self:expect("str").text
	local outs, ins, clob = {}, {}, {}

	local function operands(list)
		if self.tok.kind == ":" or self.tok.kind == ")" then return end
		repeat
			local nm
			if self:accept("[") then
				nm = self:expect("name").text
				self:expect("]")
			end
			local c = self:expect("str").text
			self:expect("(")
			local e = self:expression()

			-- An array named as a memory operand is the place
			-- it sits, not a pointer to its first element,
			-- which is what a kernel writes for a bitmap.
			if not (c:find("m", 1, true) and
				e.ty.kind == "array") then
				e = self:rvalue(e)
			end
			self:expect(")")
			-- An immediate operand may be an address as well as
			-- a number: `"i" (func)` hands the template a
			-- symbol, which is what an alternative calls.
			-- An operand that has to be a constant may read
			-- what the caller handed a parameter, so long as
			-- nothing has written the parameter since.
			local k = fold(e) or addrtext(e)

			if not k and c:find("[inN]") and self.inl then
				local a = self:inlsubst(e)

				k = a and (fold(a) or addrtext(a)) or nil
			end
			list[#list + 1] = {c = c, e = e, name = nm,
					   const = k}
		until not self:accept(",")
	end

	-- A template with any colon after it is the extended form, where
	-- `%%` spells a per cent sign even when no operand follows.
	local ext = self.tok.kind == ":"

	local labels = {}

	if self:accept(":") then
		operands(outs)
		if self:accept(":") then
			operands(ins)
			if self:accept(":") then
				while self.tok.kind == "str" do
					clob[#clob + 1] = self.tok.text
					self:adv()
					if not self:accept(",") then break end
				end
				-- `asm goto` names the labels the template
				-- may jump to in a fourth group.
				if self:accept(":") then
					repeat
						local nm =
							self:expect("name").text

						labels[#labels + 1] = {
							name = nm,
							sym = self:userlabel(nm)}
					until not self:accept(",")
				end
			end
		end
	end
	if isgoto and #labels == 0 then
		self:err("asm goto needs a label")
	end
	self:expect(")")

	-- An output needs somewhere safe to land: the template leaves it in a
	-- register, and storing it straight into its lvalue could need a
	-- second register and destroy another output.
	for _, o in ipairs(outs) do
		if o.e.op ~= "AUTO" and o.e.op ~= "NAME" and
		   o.e.op ~= "HARD" and o.e.op ~= "INDIR" then
			self:err("an asm output must be an lvalue")
		end
		-- An output the template writes to memory is already
		-- where it belongs and needs no landing place.
		if not o.c:find("m", 1, true) and o.e.op ~= "HARD" then
			o.tmp = self:temp()
		end
	end
	-- The outputs are written after the inputs are read, which is
	-- what lets `asm("..." : "=r"(p) : "i"(p))` see the caller's
	-- value on the way in.
	for _, o in ipairs(outs) do self:inlkill(o.e) end
	return tree.node("ASM", self.ty.void, nil, nil,
		{text = text, outs = outs, ins = ins, clob = clob,
		 ext = ext, labels = labels})
end

-- statements -----------------------------------------------------------

-- What this function keeps on its frame, for the stack protector to
-- decide whether the function is worth a canary.
function P:notebuf(ty)
	if ty.kind ~= "array" then return end
	self.hasarray = true
	-- The plain protector guards a byte buffer big enough to reach
	-- past the frame, which is what a string lands in.
	if ty.of.size == 1 and (ty.n or 0) >= 8 then self.hasbuf = true end
end

-- A variable length array.  Two slots: one for how many bytes it
-- turned out to be, which is what sizeof answers with, and one for
-- where they are.  The name stands for the pointer, so every use of it
-- is already the decay C asks for.
--
-- The room is taken with alloca, so it lasts to the end of the
-- function rather than the end of the block: one written inside a loop
-- takes more each time round.
function P:vladecl(name, ty, storage)
	if storage == "static" then
		self:err("a static variable length array is not supported")
	end
	if not self.fname then
		self:err("a variable length array must be inside a function")
	end
	local el = ty.of

	if el.vlen then
		self:err("only the outermost bound of an array may be " ..
			"worked out at run time")
	end
	if el.size == 0 or el.incomplete then
		self:err("a variable length array of an incomplete type")
	end
	if not self.t.alloca then
		self:err("a variable length array is not supported on " ..
			self.t.name)
	end
	local pt = self.ty.ptr(el)
	local zoff = self:alloc(self.uword)
	local poff = self:alloc(pt)
	local count = self:conv(self:rvalue(ty.vexpr), self.uword)
	local bytes = self:arith("MUL", count,
		tree.const(self.uword, el.size))

	self.g:expr(self:assignto(tree.auto(self.uword, zoff), bytes), "eff")
	self.g:expr(self:assignto(tree.auto(pt, poff),
		tree.unary("ALLOCA", pt, tree.auto(self.uword, zoff))),
		"eff")
	self:declare(name, {kind = "local", ty = ty, off = poff,
			    vla = zoff, vlaty = pt})
	self:notebuf(ty)
end

function P:localdecl()
	local base, storage = self:declspec()
	if not base then return false end
	-- A static in a block is an object like any other: what the
	-- declaration said about which section it belongs in holds here
	-- too.  A kernel writes `static struct q k __initdata = {...}`
	-- inside the function that registers it.
	local attrs = self.declattrs or {}
	local asked = self.alignas
	local tls = self.tls
	if self:accept(";") then return true end
	repeat
		self.asmname = nil
		local name, wrap = self:dcl(false)
		local ty = self:vectored(wrap(base), self.declattrs or {})
		local sym = self.asmname or name
		-- GNU C: `register long r __asm__("r10")` binds the name
		-- to a machine register.  It keeps a frame slot like any
		-- other local; what the binding decides is which register
		-- an inline asm operand naming it uses.
		local hard = storage ~= "static" and storage ~= "extern"
			and self.asmname or nil

		self.asmname = nil
		-- Every frame slot is a word wide and a word aligned, so
		-- that much is free; more than that this compiler cannot
		-- give, and saying so beats laying it out wrong.
		if asked and asked > self.t.ptrsize and
		   storage ~= "static" and storage ~= "extern" then
			self:err("_Alignas of " .. asked ..
				" on a local is not supported")
		end
		-- __auto_type: read the initializer, then the type is
		-- what it turned out to be.
		if ty == AUTOTYPE then
			if storage ~= nil and storage ~= "static" then
				self:err("__auto_type takes no storage class")
			end
			self:expect("=")
			local e = self:rvalue(self:assign())

			ty = self.ty.decay(e.ty)
			if storage == "static" then
				self:err("a static __auto_type is not " ..
					"supported")
			end
			local s = self:declare(name, {kind = "local",
						      ty = ty})

			s.off = self:alloc(ty)
			self.slotname[s.off] = name
			self.g:expr(self:assignto(tree.auto(ty, s.off), e),
				"eff")
			self:notebuf(ty)
			goto nextdecl
		end
		-- A bound worked out at run time: the room comes off the
		-- stack where the declaration stands, and the name is the
		-- pointer to it.
		if ty.vlen and storage ~= "extern" and
		   storage ~= "typedef" and ty.kind ~= "func" then
			self:vladecl(name, ty, storage)
			goto nextdecl
		end
		if storage == "typedef" then
			self:declare(name, {kind = "typedef", ty = ty})
		elseif ty.kind == "func" then
			self:declare(name, {kind = "func", ty = ty,
					    sym = sym})
		elseif storage == "extern" then
			-- An object another unit owns, named here in a
			-- block.  It is a global like any other, and
			-- under pic its address comes from the table:
			-- calling it a function skipped all of that.
			self:declare(name, {kind = "global", ty = ty,
					    sym = sym})
		elseif storage == "static" or tls then
			local lbl = ".Lstatic" .. self.nstr
			self.nstr = self.nstr + 1
			-- The name is in scope inside its own
			-- initializer, which is how a list head points
			-- at itself.  What it stands for may still grow
			-- an array bound, so the entry is written to
			-- again below.
			local d = self:declare(name, {kind = "global",
				ty = ty, sym = lbl, tls = tls})

			if self:accept("=") then
				ty = self:initobject(lbl, ty, true, asked,
					attrs.section, nil, tls)
			else
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
				end
				self.t.data.obj(self.dg, lbl,
					math.max(asked or 0, ty.align),
					true, true, attrs.section, nil, tls)
				self.t.data.zero(self.dg, ty.size)
			end
			d.ty = ty
		else
			-- The frame slot waits for the initializer, which is
			-- what gives an array without a bound its size.
			local s = self:declare(name, {kind = "local", ty = ty,
						      hard = hard})
			if self:accept("=") then
				if self.tok.kind == "{" or
				   (ty.kind == "array" and
				    self.tok.kind == "str" and
				    ty.of.size ==
				    self:strelem(self.tok.pfx).size) then
					self:initlocal(s, ty)
				else
					local e = self:assign()

					s.off = self:alloc(ty)
					self.slotname[s.off] = name
					self.g:expr(self:assignto(
						tree.auto(ty, s.off),
						e), "eff")
				end
			else
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
					s.ty = ty
				end
				s.off = self:alloc(ty)
			end
			self.slotname[s.off] = name
			self:notebuf(s.ty or ty)
		end
		::nextdecl::
	until not self:accept(",")
	self:expect(";")
	return true
end

-- GNU statement expression, `({ ... })`.  The value is the last
-- statement of the block, which has to be an expression.
--
-- The block's code travels in the tree rather than being written where
-- it stood, so one in an operand that may not run -- an arm of ?:, the
-- right of && or || -- runs only when that operand does.
function P:stmtexpr()
	-- The block's code is written to a buffer of its own and carried
	-- in the tree, so an operand that does not always run takes its
	-- block with it.
	local saved = self.g.sink
	local blk = buf.new()

	self.g.sink = blk
	self:expect("{")
	self:push()
	local odead = self.dead

	self.dead = false
	local val
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		if self:istype() then
			self:localdecl()
		elseif self.tok.kind == "name" and
		   self:peek().kind == ":" then
			-- A label here is not the end of the block: what
			-- follows it may still be the value.
			local nm = self.tok.text

			self:adv()
			self:adv()
			self.g:putlabel(self:userlabel(nm))
			self.g:landing()
			self:inlclear(self.writes and
				(self.writes.any and 0 or self.writes.g[nm]))
		elseif not self:startsexpr() then
			-- anything that is not an expression cannot be
			-- the value, so it takes the ordinary path
			self:stmt()
		else
			local e = self:expression()

			self:expect(";")
			-- the last statement of the block is its value
			if self.tok.kind == "}" then
				val = e
			else
				self.g:expr(e, "eff")
			end
		end
	end
	self:expect("}")
	self:expect(")")
	local function done(e)
		self.g.sink = saved
		self.dead = odead
		local text = blk:text()

		self:pop()
		if text == "" then return e end
		return tree.node("SEQ", e.ty, nil, nil,
			{arms = {tree.node("TEXT", self.ty.void, nil, nil,
				{text = text}), e}})
	end
	if not val then
		return done(tree.const(self.ty.i32, 0))
	end
	-- The value outlives the block it was written in, so it goes to a
	-- slot above the block's own.  Raising the mark keeps `pop` from
	-- giving that slot back -- and the block's with it, which costs a
	-- few words at a site that is rare.
	val = self:rvalue(val)
	local t = tree.auto(val.ty, self:temp(val.ty))

	self.marks[#self.marks] = self.nlocals
	self.g:expr(self:assignto(t, val), "eff")
	return done(tree.clone(t))
end

-- Whether the token could begin an expression statement.  A keyword that
-- begins a statement could not.
function P:startsexpr()
	local k = self.tok.kind

	if STMTKW[k] or self:istype() then return false end
	-- a label, which is a statement and not the value of anything
	if k == "name" and self:peek().kind == ":" then return false end
	if k == "name" and ASMKW[self.tok.text] then return false end
	if k == "name" and self.tok.text == "__label__" then return false end
	-- An assertion inside a statement expression is still an
	-- assertion, not a call to something named _Static_assert.
	-- container_of writes one.
	if k == "name" and STATICASSERT[self.tok.text] then return false end
	return true
end

function P:block()
	self:expect("{")
	self:push()
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		self:stmt()
	end
	self:expect("}")
	self:pop()
end

function P:userlabel(name)
	return self.labelmap[name] or
		(".Lu_" .. self.fname .. "_" .. name)
end

-- Whether an expression is one nothing comes back from.  A sequence
-- answers for its last arm, which is the value of the whole.
local function noreturn(e)
	while e do
		if e.noret then return true end
		if e.op == "SEQ" and e.arms then
			for _, a in ipairs(e.arms) do
				if a.noret then return true end
			end
			e = e.arms[#e.arms]
		else
			return false
		end
	end
	return false
end

-- Whether a condition is settled where it stands: true or false when it
-- is, nothing when it is not.  These are the shapes `gen:cond` folds, so
-- the two agree on which arm is reached.
-- Whether a condition is known now.  `fold` answers nil for anything
-- it cannot work out, which covers every expression that has to run.
-- Inside a body built where it was called, a slot that still holds
-- what it was given reads as that, which is how `if (sz >= 0)` on an
-- object size nobody can work out settles here.
-- The same tree with the code a body built where it was called carries
-- taken off each operand.  The code runs either way; only the value
-- left behind decides which arm a test reaches.
function P:unseq(n)
	if n == nil then return nil end
	while n.op == "SEQ" and n.arms and #n.arms > 0 do
		n = n.arms[#n.arms]
	end
	if n.op == "CONST" or (n.left == nil and n.right == nil) then
		return n
	end
	local l, r = self:unseq(n.left), self:unseq(n.right)

	if l == n.left and r == n.right then return n end
	local c = tree.clone(n)

	c.left, c.right = l, r
	return tree.reneed(c)
end

-- The same test with every slot that is known to hold one number
-- replaced by that number.  What the generator sees decides which
-- operand of `&&` it writes, so the substitution has to reach it and
-- not only the reachability answer.
local NOLEFT = {ASGN = true, POSTADD = true, ADDR = true}

function P:subkonst(n, addr)
	if n == nil then return nil end
	if n.op == "CONST" or n.op == "NAME" or n.op == "TEXT" then
		return n
	end
	if n.op == "AUTO" and not n.hard and not n.part then
		local s = not addr and self:knownkonst(n.off)

		if s then return tree.const(s.kty, s.konst) end
		return n
	end
	-- A pointer that settles to a number is still worth knowing --
	-- `if (p)` on a null one -- but reading through it would ask
	-- for a load from an address with nothing behind it, and no
	-- table has a rule for that.
	if n.op == "INDIR" then addr = true end
	-- The left of an assignment is where the value goes, not a value.
	local l = not NOLEFT[n.op] and self:subkonst(n.left, addr) or n.left
	local r = self:subkonst(n.right, addr)
	local arms, any = nil, l ~= n.left or r ~= n.right

	if n.arms then
		for i, a in ipairs(n.arms) do
			local b = self:subkonst(a, addr)

			if b ~= a then
				arms = arms or {table.unpack(n.arms)}
				arms[i] = b
				any = true
			end
		end
	end
	-- An operand of `&&` or `||` that settles and does nothing else
	-- is written down, so that what reads the tree next -- the
	-- generator -- can see that the other operand never runs.
	if n.op == "ANDAND" or n.op == "OROR" then
		local function flat(x)
			if x == nil or x.op == "CONST" then return x end
			local v = settle(x)

			if v ~= nil and not tree.effects(x) then
				return tree.const(x.ty, v)
			end
			return x
		end
		local fl, fr = flat(l), flat(r)

		any = any or fl ~= l or fr ~= r
		l, r = fl, fr
	end
	if not any then return n end
	local c = tree.clone(n)

	c.left, c.right = l, r
	if arms then c.arms = arms end
	return tree.reneed(c)
end

-- What a test settles to.  `x && 0` is false however `x` turns out,
-- and `x || 1` is true: the operand still runs, and gen:cond writes
-- it, but the arm behind the test is out of reach.
function settle(n)
	if n == nil then return nil end
	if n.op == "ANDAND" or n.op == "OROR" then
		local a, b = settle(n.left), settle(n.right)
		-- The value that decides on its own: a nought for `&&`,
		-- anything else for `||`.
		local sc = n.op == "OROR"

		if (a ~= nil and (a ~= 0) == sc) or
		   (b ~= nil and (b ~= 0) == sc) then
			return sc and 1 or 0
		end
		if a and b then return sc and 0 or 1 end
		return nil
	end
	if n.op == "LNOT" then
		local a = settle(n.left)

		return a and (a == 0 and 1 or 0)
	end
	if n.op == "CVT" and n.left and
	   isflt(n.ty) == isflt(n.left.ty) then
		return settle(n.left)
	end
	-- An operand that decides on its own, whatever the other one
	-- turns out to be.  The kernel writes `x &= IS_ENABLED(...)`.
	if n.op == "AND" or n.op == "MUL" then
		local a, b = settle(n.left), settle(n.right)

		if a == 0 or b == 0 then return 0 end
		if a and b then return foldbin(n.op, a, b,
			n.ty and n.ty.kind == "uint") end
		return nil
	end
	if n.op == "EQ" or n.op == "NE" then
		local a, b = settle(n.left), settle(n.right)

		if a and b then
			return (a == b) == (n.op == "EQ") and 1 or 0
		end
		-- A value behind a mask cannot hold a bit the mask
		-- clears.  The kernel asks `zonenum(f) == ZONE_DEVICE`
		-- with the zone field three bits wide and ZONE_DEVICE
		-- past the end of it, which is how a configuration
		-- switches a whole family of pages off.
		local k, m = a or b, bitsof(a and n.right or n.left)

		if k and m and k & ~m ~= 0 then
			return n.op == "EQ" and 0 or 1
		end
		return nil
	end
	return fold(n)
end

function P:constcond(n)
	if not n then return nil end
	n = self:unseq(self:subkonst(n))
	local v = settle(n)

	if v == nil and self.inl then
		local a = self:inlsubst(n)

		v = a and fold(a) or nil
	end
	if v == nil then return nil end
	return v ~= 0
end

-- Statements that hold other statements, and so may hold a label.
local NESTS = {["{"] = true, ["if"] = true, ["while"] = true,
	       ["do"] = true, ["for"] = true, ["switch"] = true}

-- Where a statement says what can be reached after it.  A run that
-- never arrives cannot leave: while `deadmark` holds the revival count
-- from the start of an unreachable statement, only a label inside it
-- can bring code back, and until one does the answer is always dead.
function P:setdead(v)
	if self.deadmark and self.revived == self.deadmark then v = true end
	self.dead = v and true or false
end

-- One statement.  When nothing can reach it, read it and drop what it
-- would compile to: a label inside makes the code after it reachable
-- again, so the text still has to be parsed.
function P:stmt()
	if not self.dead then return self:stmt1() end
	local k = self.tok.kind

	if k == "case" or k == "default" or
	   (k == "name" and self:peek().kind == ":" and not self:istype())
	then
		-- A label is where reachable code resumes.  In a switch
		-- on a value settled where it stands the arm is picked
		-- instead, and the handler below says which.
		-- A case label is reached from its own dispatch, so it
		-- brings nothing back when the switch itself is out of
		-- reach.  A label a program may goto always does.
		local arm = k == "case" or k == "default"

		if not (arm and self.sw and (self.sw.konst or self.sw.dead))
		then
			self.dead = false
			self.revived = self.revived + 1
		end
		return self:stmt1()
	end
	-- One that holds statements is walked into rather than dropped
	-- whole, so that a label inside it still lands where a jump from
	-- reachable code expects to find it.  Only a label brings code
	-- back within it: what the statement itself works out about
	-- reachability is about a run that reaches it, and none does.
	if NESTS[k] then
		local omark = self.deadmark

		self.deadmark = self.revived
		self:stmt1()
		self.deadmark = omark
		return
	end
	self.g:hush()
	local ok, err = pcall(self.stmt1, self)

	self.g:unhush()
	if not ok then error(err, 0) end
	self.dead = true
end

function P:stmt1()
	local m = tree.mark()

	if self.tok.kind == "[" and self:peek().kind == "[" then
		self:attrs()
	end
	if self.tok.kind == "name" and STATICASSERT[self.tok.text] then
		self:staticassert()
		tree.release(m)
		return
	end
	-- GNU `__label__ a, b;` gives the block labels of its own, so a
	-- macro that declares one may stand twice in a function.
	if self.tok.kind == "name" and self.tok.text == "__label__" then
		self:adv()
		repeat
			local nm = self:expect("name").text

			self.labelmap[nm] = self.g:newlabel()
		until not self:accept(",")
		self:expect(";")
		tree.release(m)
		return
	end
	local k = self.tok.kind
	local g = self.g
	-- A statement that holds others is read even when nothing can
	-- reach it, so that a label inside still lands where a jump
	-- expects it.  Its own test is not a label: drop what it would
	-- compile to, or a call in it is a call nothing can reach and
	-- the linker still wants the name.
	local wasdead = self.dead

	if k == "name" and ASMKW[self.tok.text] then
		local n = self:asmstmt()
		g:expr(n, "eff")
		-- the outputs land in temporaries; put them where they belong
		for _, o in ipairs(n.outs) do
			if o.tmp then
				g:expr(self:assignto(o.e,
					tree.auto(o.e.ty, o.tmp)), "eff")
			end
		end
		self:accept(";")
		tree.release(m)
		return
	end
	if k == "{" then
		tree.release(m)
		return self:block()
	elseif k == ";" then
		self:adv()
	elseif k == "if" then
		self:adv()
		self:expect("(")
		local c = self:subkonst(self:test(self:expression()))
		self:expect(")")
		-- A condition worked out at compile time rules one arm
		-- out.  Saying so here is what lets a program write, in
		-- the arm for another machine, code this one cannot even
		-- encode.
		local fixed = self:constcond(c)
		local lelse = g:newlabel()

		if wasdead then g:hush() end
		g:cond(c, lelse, false, 0)
		if wasdead then g:unhush() end
		tree.release(m)
		if fixed == false then self.dead = true end
		self:pushregion()
		self:stmt()
		self:popregion()
		local dthen = self.dead

		if self:accept("else") then
			local lend = g:newlabel()

			if not dthen then self.t.jump(g, lend) end
			g:putlabel(lelse)
			self:setdead(fixed == true)
			self:pushregion()
			self:stmt()
			self:popregion()
			g:putlabel(lend)
			self:setdead(dthen and self.dead)
		else
			g:putlabel(lelse)
			self:setdead(fixed == true and dthen)
		end
		return
	elseif k == "while" then
		self:adv()
		self:expect("(")
		local ltop, lbrk = g:newlabel(), g:newlabel()
		g:putlabel(ltop)
		-- The test runs again on every turn, so what a slot held
		-- before the loop says nothing inside it.
		self.loopdepth = self.loopdepth + 1
		local c = self:subkonst(self:test(self:expression()))

		self:expect(")")
		local always = self:constcond(c) == true

		if wasdead then g:hush() end
		g:cond(c, lbrk, false, 0)
		if wasdead then g:unhush() end
		tree.release(m)
		local used = self:loop(ltop, lbrk)

		self.loopdepth = self.loopdepth - 1
		if not self.dead then self.t.jump(g, ltop) end
		g:putlabel(lbrk)
		-- A loop whose test never fails is left only by a break.
		self:setdead(always and not used)
		return
	elseif k == "do" then
		self:adv()
		local ltop, lcont, lbrk = g:newlabel(), g:newlabel(), g:newlabel()
		g:putlabel(ltop)
		local used, cused = self:loop(lcont, lbrk)
		local bodydead = self.dead

		g:putlabel(lcont)
		if cused then self:setdead(false) end
		self:expect("while")
		self:expect("(")
		self.loopdepth = self.loopdepth + 1
		local c = self:subkonst(self:test(self:expression()))

		self.loopdepth = self.loopdepth - 1
		self:expect(")")
		self:expect(";")
		local always = self:constcond(c) == true

		if not self.dead then
			if wasdead then g:hush() end
			g:cond(c, ltop, true, 0)
			if wasdead then g:unhush() end
		end
		g:putlabel(lbrk)
		-- `do { } while (0)` around a body nothing comes back
		-- from is how a kernel writes BUG.
		self:setdead((always or (bodydead and not cused)) and
			not used)
		tree.release(m)
		return
	elseif k == "for" then
		self:adv()
		self:expect("(")
		self:push()
		if wasdead then g:hush() end
		if self.tok.kind ~= ";" then
			if self:istype() then
				self:localdecl()
			else
				g:expr(self:expression(), "eff")
				self:expect(";")
			end
		else
			self:adv()
		end
		if wasdead then g:unhush() end
		local lcond, lcont, lbrk =
			g:newlabel(), g:newlabel(), g:newlabel()
		local mcond = tree.mark()

		-- The test and the step run again on every turn; only the
		-- first clause runs once.
		self.loopdepth = self.loopdepth + 1
		g:putlabel(lcond)
		local notest = self.tok.kind == ";"

		if not notest then
			if wasdead then g:hush() end
			g:cond(self:subkonst(self:test(self:expression())),
				lbrk, false, 0)
			if wasdead then g:unhush() end
		end
		self:expect(";")
		tree.release(mcond)
		local step
		if self.tok.kind ~= ")" then step = self:expression() end
		self:expect(")")
		local used = self:loop(lcont, lbrk)

		g:putlabel(lcont)
		self:setdead(false)
		if step then
			if self.dead then g:hush() end
			g:expr(step, "eff")
			if self.dead then g:unhush() end
		end
		self.t.jump(g, lcond)
		self.loopdepth = self.loopdepth - 1
		g:putlabel(lbrk)
		-- A `for (;;)` with no test is left only by a break.
		self:setdead(notest and not used)
		self:pop()
		tree.release(m)
		return
	elseif k == "switch" then
		self:adv()
		self:expect("(")
		local e = self:subkonst(self:rvalue(self:expression()))

		self:expect(")")
		-- A switch on a value settled where it stands reaches one
		-- arm.  A kernel writes `switch (sizeof(x))` with a
		-- `default:` that calls a name nothing defines, so that
		-- getting the size wrong is a link error; compiling the
		-- default makes every use of it one.
		-- The value still runs; what it settles to is read off
		-- the end of it, the way a test is.
		local konst = fold(self:unseq(e))
		local slot = self:alloc(self.word)

		if wasdead then g:hush() end
		g:expr(self:assignto(tree.auto(self.word, slot), e), "eff")
		if wasdead then g:unhush() end
		tree.release(m)

		local osw, obrk = self.sw, self.brk
		local ldisp, lbrk = g:newlabel(), g:newlabel()
		self.sw = {slot = slot, cases = {}, ty = self.word,
			   konst = konst, dead = self.dead,
			   at = self.lx and self.lx.i}
		self.brk = lbrk
		self.t.jump(g, ldisp)
		-- Nothing falls into the body: the dispatch jumps to a
		-- case label, so what a program writes before the first
		-- one is unreachable.
		self.dead = true
		self:pushregion()
		self:stmt()
		self:popregion()
		if not self.dead then self.t.jump(g, lbrk) end
		self:setdead(false)

		-- The dispatch goes after the body, because the case labels
		-- are only known once it has been read.
		g:putlabel(ldisp)
		if wasdead then g:hush() end
		for _, c in ipairs(self.sw.cases) do
			local t = tree.auto(self.word, slot)
			g:cond(tree.binary("EQ", self.word, t,
				tree.const(self.word, c.val)), c.label, true, 0)
			tree.release(m)
		end
		self.t.jump(g, self.sw.deflab or lbrk)
		if wasdead then g:unhush() end
		g:putlabel(lbrk)
		self:setdead(false)
		self.sw, self.brk = osw, obrk
		return
	elseif k == "case" then
		self:adv()
		local v = self:constexpr()
		-- GNU case ranges: one label, every value in between.
		local hi = v
		if self:accept("...") then hi = self:constexpr() end
		self:expect(":")
		if not self.sw then self:err("case outside a switch") end
		if hi - v > 4096 then self:err("case range is too wide") end
		local l = g:newlabel()
		for i = v, hi do
			self.sw.cases[#self.sw.cases + 1] = {val = i,
							     label = l}
		end
		g:putlabel(l)
		self:inlclear(self.sw.at)
		tree.release(m)
		-- The label always goes out, because the dispatch names
		-- it; only the arm behind it is left uncompiled.  Once
		-- the matching arm has been reached the ones after it
		-- are reachable by falling through, so a label that does
		-- not match leaves the run as it stands.
		if self.sw.konst then
			if self.sw.konst >= v and self.sw.konst <= hi then
				self.dead, self.sw.hit = self.sw.dead, true
				if not self.sw.dead then
					self.revived = self.revived + 1
				end
			elseif not self.sw.hit then
				self.dead = true
			end
		end
		return self:stmt()
	elseif k == "default" then
		self:adv()
		self:expect(":")
		if not self.sw then self:err("default outside a switch") end
		self.sw.deflab = g:newlabel()
		g:putlabel(self.sw.deflab)
		self:inlclear(self.sw.at)
		tree.release(m)
		-- Only when a case has already matched is the default
		-- known to be out of reach.  One that stands before the
		-- matching case is compiled, which costs a few
		-- instructions nothing jumps to.
		if self.sw.konst then
			self.dead = (self.sw.hit or self.sw.dead)
				and true or false
			if not (self.sw.hit or self.sw.dead) then
				self.revived = self.revived + 1
			end
		end
		return self:stmt()
	elseif k == "goto" then
		self:adv()
		-- `goto *e` jumps to a label whose address was taken.
		if self:accept("*") then
			local e = self:rvalue(self:expression())

			self:expect(";")
			if not self.t.jumpto then
				self:err("a computed goto is not " ..
					"supported on " .. self.t.name)
			end
			g:expr(e, "reg", 0)
			self.t.jumpto(g, 0)
			self.dead = true
			tree.release(m)
			return
		end
		local name = self:expect("name").text
		self:expect(";")
		self.t.jump(g, self:userlabel(name))
		self.dead = true
	elseif k == "return" then
		self:adv()
		if self.inlres and self.tok.kind ~= ";" then
			-- Inside a body built where it was called the
			-- answer goes to a slot, not to the register a
			-- return would leave it in, and not through the
			-- caller's own record return.
			local r = self.inlres
			local e = self:conv(self:rvalue(self:expression()),
				r.ty)

			-- One return of a value settled where it stands
			-- makes the whole expansion that value.  What the
			-- body does still happens: its code travels with
			-- the answer either way.
			r.n = r.n + 1
			r.konst = r.n == 1 and
				settle(self:unseq(self:subkonst(e))) or nil
			r.mask = r.n == 1 and bitsof(e) or nil
			g:expr(self:assignto(tree.auto(r.ty, r.off), e),
				"eff")
		elseif self.tok.kind ~= ";" and self.recret then
			local e = self:rvalue(self:expression())
			local d = tree.auto(e.ty, self.recret.off)
			g:expr(tree.node("COPY", e.ty,
				tree.unary("ADDR", self.ty.ptr(e.ty), d),
				self:recaddr(e),
				{val = self.recret.size}), "eff", 0)
		elseif self.tok.kind ~= ";" then
			local e = self:conv(self:rvalue(self:expression()),
				self.rty)
			if self:widepass(self.rty) then
				e = self:waddr(e)
			end
			g:expr(e, "reg", 0)
		end
		self:expect(";")
		self.t.jump(g, self.endlabel)
		self.retused = true
		self.dead = true
	elseif k == "break" then
		self:adv()
		self:expect(";")
		if not self.brk then self:err("break outside a loop") end
		self.t.jump(g, self.brk)
		self.brkused = true
		self.dead = true
	elseif k == "continue" then
		self:adv()
		self:expect(";")
		if not self.cont then self:err("continue outside a loop") end
		self.t.jump(g, self.cont)
		self.contused = true
		self.dead = true
	elseif k == "name" and self:peek().kind == ":" and not self:istype() then
		local name = self.tok.text
		self:adv()
		self:adv()
		g:putlabel(self:userlabel(name))
		-- A named label is where `goto *` may arrive, and a
		-- computed one can arrive from anywhere.
		g:landing()
		self:inlclear(self.writes and
			(self.writes.any and 0 or self.writes.g[name]))
		tree.release(m)
		return self:stmt()
	elseif not self:istype() then
		local e = self:expression()

		g:expr(e, "eff")
		self:expect(";")
		-- A call to a function that does not return, or the
		-- builtin that says so outright, ends the run: what
		-- follows is only reached through a label.
		if noreturn(e) then self.dead = true end
	else
		self:localdecl()
	end
	tree.release(m)
end

-- The body of a loop, with `break` and `continue` pointed at it.
-- Whether either was written decides what follows the loop: a body
-- nothing comes back from ends the run unless something jumped out.
function P:loop(cont, brk)
	local oc, ob = self.cont, self.brk
	local ou, oq = self.brkused, self.contused

	self.cont, self.brk = cont, brk
	self.brkused, self.contused = false, false
	-- A slot read in a loop may have been written on an earlier turn
	-- of it, however the text reads, so what it held before the loop
	-- says nothing inside.
	self.loopdepth = self.loopdepth + 1
	self:pushregion()
	self:stmt()
	self:popregion()
	self.loopdepth = self.loopdepth - 1
	local used, cused = self.brkused, self.contused

	self.cont, self.brk = oc, ob
	self.brkused, self.contused = ou, oq
	return used, cused
end

-- declarations ---------------------------------------------------------

function P:funcdef(name, ty, static, sec, vis, weak, same)
	self.fname = name
	local body = buf.new()
	local saved = self.g.sink
	self.g.sink = body
	self.nlocals, self.maxlocals = 0, 0
	self.dead, self.retused = false, false
	-- Counts the labels that bring unreachable code back, which is
	-- how a statement holding others tells whether anything inside
	-- it can run.
	self.revived, self.deadmark = 0, nil
	self.loopdepth = 0
	-- What a slot is known to hold, and which run of the function
	-- the write that put it there stands in.
	self.konsts, self.regions, self.nregion = {}, {}, 0
	-- What each slot is called, so that a label can ask whether
	-- anything writes it later.
	self.slotname = {}
	self.x87at, self.x87floor = nil, nil
	self.g.x87base = function() return self:x87base() end
	self.fname = name
	self.rty = (ty.ret == self.ty.void or isrec(ty.ret)) and self.word
		or ty.ret
	self.endlabel = self.g:newlabel()
	self.labelmap = {}
	self:push()
	-- The canary sits nearest the return address, so it is the first
	-- slot handed out: whatever overflows meets it first.
	self.hasbuf, self.hasarray, self.tookaddr = false, false, false
	self.guard = self.ssp and self:alloc(self.word) or nil
	-- Each parameter is described, not just placed: a target that has a
	-- floating point class has to know which register file a value came
	-- in, and how many of each the named parameters used up.
	-- Only a target that passes variadic floats in the float file needs
	-- a second save area.
	local nfltreg = self.t.vafloat and (self.t.nfltreg or 0) or 0
	-- A record result too big for the return registers is written
	-- through a pointer the caller hands over ahead of the arguments.
	self.recret = nil
	if isrec(ty.ret) or self:byparts(ty.ret) then
		if not self.t.recabi then
			self:err("a function returning a struct or union " ..
				"is not supported on " .. self.t.name)
		end
		local cls = self.t.eightbytes and self.t.eightbytes(ty.ret)
		self.recret = {size = ty.ret.size, cls = cls,
			       off = self:alloc(ty.ret)}
		if not cls then self.recret.ptr = self:temp() end
	end
	local shape = {}
	for i, prm in ipairs(ty.params) do
		shape[i] = {x87 = prm.x87 or nil,
			    flt = isflt(prm) and not prm.x87 and
				  not self:widepass(prm),
			    rec = (isrec(prm) or self:byparts(prm)) and prm
				  or nil,
			    size = prm.size}
	end
	local slots, gp, fp, stk = md.classify(self.t, shape, nil,
		self.t.hiddenarg and self.recret and not self.recret.cls)
	local pnames = ty.pnames
	for i, prm in ipairs(ty.params) do
		if isrec(prm) and not self.t.recabi then
			self:err("a struct or union parameter is not " ..
				"supported on " .. self.t.name)
		end
		slots[i].off = self:alloc(prm)
		local nm = pnames and pnames[i]
		if nm then
			self:declare(nm, {kind = "local", ty = prm,
					  off = slots[i].off})
			self.slotname[slots[i].off] = nm
		end
		-- Every call this unit makes hands over the same number,
		-- so inside the body the parameter is that number.  The
		-- kernel calls __fpu_restore_sig once, with a flag that
		-- settles to false.
		local k = same and same[i]

		if k ~= nil and self.ty.isint(prm) then
			self:notekonst(slots[i].off,
				tree.const(prm, k), prm)
		end
	end
	-- A variadic function needs somewhere to keep its argument
	-- registers, laid out upward so the walker can step through them:
	-- the integer file first, then the floating point one.
	self.vabase = nil
	self.vagp, self.vafp, self.vastk = gp, fp, stk
	if ty.variadic then
		local first, last
		-- One word past the register save area holds the address of
		-- the caller's stack arguments, where the target cannot name
		-- it with a fixed offset of its own.
		local n = self.t.nargreg + nfltreg
		-- A System V floating point slot is two words wide.
		if self.t.vaabi == "sysv" then
			n = self.t.nargreg + nfltreg * 2
		end
		if self.t.vastkslot then n = n + 1 end
		for _ = 1, n do
			last = self:alloc(self.word)
			first = first or last
		end
		self.vabase = math.min(first, last)
	end
	-- What the body writes, and where, so that a label knows which
	-- slots it has to forget.  A body already read into tokens is
	-- scanned where it stands; one still on the input is taken off
	-- it first, which costs a copy of the tokens and saves a pass
	-- over everything the compiler would otherwise give up on.
	local owrites = self.writes

	if self.lx.f then
		self.writes = scanwrites(self.lx.f, self.lx.n)
		self:block()
	else
		local rec = self:capture()

		self.writes = scanwrites(rec.f, rec.n)
		self:replay(rec, P.block)
	end
	self.writes = owrites
	self:pop()
	-- Nothing comes back from a body that ended with nothing
	-- reachable and never returned.  A validator that walks the
	-- code reads the epilogue as an instruction nothing reaches.
	local noway = self.dead and not self.retused

	self.g:putlabel(self.endlabel)
	local frame = self.t.frame(self.maxlocals)
	if os.getenv("MEM") then
		local n = 0
		for i = 1, body.n do n = n + #body[i] end
		if n > (rawget(_G, "__bodymax") or 0) then
			rawset(_G, "__bodymax", n)
			rawset(_G, "__bodyname", name)
		end
	end
	-- The peephole reads the whole function, so under it the prologue
	-- and the epilogue are written into the same buffer as the body
	-- rather than straight out.
	local whole = self.peep and buf.new() or saved
	local guard = self.guard and self:wantguard() and
		{off = self.guard, name = name} or nil

	self.g.sink = whole
	self.t.prologue(self.g, name, frame, slots, self.vabase, static,
		self.recret, sec, guard)
	-- What the name is and how much of it there is.  A validator
	-- that walks the code reads both, and without them the section
	-- is one run of bytes with no functions in it.
	self.g:write("\t.type\t" .. name .. ",@function\n")
	if not static then
		if weak then self.t.data.weaken(self.g, name) end
		self.t.data.visible(self.g, name, vis)
	end
	body:move(whole)
	if not noway then
		self.t.epilogue(self.g, frame,
			(self.t.nfltreg or 0) > 0 and isflt(self.rty) and
				self.rty.size,
			self:widepass(self.rty) and self.rty.size
				or nil, self.recret, guard)
	end
	if self.peep then
		peep.run(whole:lines(), self.peep,
			function(s) saved:add(s) end)
	end
	self.g.sink = saved
	self.g:write("\t.size\t" .. name .. ", .-" .. name .. "\n")
	-- Back at file scope: a compound literal out here is a static
	-- object, not a frame slot.
	self.fname = nil
	self.recret = nil
end

-- Whether this function earns a canary.  "all" guards everything,
-- "strong" guards a frame an overflow could be aimed at, and the plain
-- one guards a frame with a byte buffer on it.
function P:wantguard()
	if self.ssp == "all" then return true end
	if self.ssp == "strong" then
		return self.hasarray or self.tookaddr
	end
	return self.hasbuf
end

-- Parse a function body and throw the code away.
function P:discarded(name, ty)
	local out, data, sdata = self.out, self.data, self.sdata
	self.out, self.data, self.sdata = buf.new(), buf.new(), buf.new()
	self.dg, self.sg = self.data, self.sdata
	self.g.sink = self.out
	self:funcdef(name, ty, true)
	self.out, self.data, self.sdata = out, data, sdata
	self.dg, self.sg = data, sdata
	self.g.sink = self.out
end

function P:extdef()
	-- File scope is always reached, whatever the last function left
	-- behind: an initializer out here names what it names.
	self.dead = false
	if self.tok.kind == "name" and ASMKW[self.tok.text] then
		local n = self:asmstmt()
		if #n.outs > 0 or #n.ins > 0 then
			self:err("a file scope asm takes no operands")
		end
		-- Code, unless the text says otherwise: what came before
		-- it in the file is no guide, because a definition of
		-- this unit's own waits until the end of the unit and a
		-- data object does not.
		self.g:write("\t.text\n\t" .. n.text .. "\n")
		self:accept(";")
		return
	end
	if self.tok.kind == "name" and STATICASSERT[self.tok.text] then
		return self:staticassert()
	end
	if self.tok.kind == "[" and self:peek().kind == "[" then
		self:attrs()
	end
	-- A stray semicolon at file scope declares nothing.  C99 forbids it,
	-- but real headers leave one after a macro that ends in one.
	if self:accept(";") then return end
	self.sawreg = false
	local base, storage, inl = self:declspec()
	local attrs = self.declattrs or {}
	local asked = self.alignas
	local tls = self.tls

	if attrs.aligned and attrs.aligned ~= true and
	   attrs.aligned > (asked or 0) then
		asked = attrs.aligned
	end

	-- A definition with no type at all returns int, which is how C was
	-- written before it said otherwise and how a good deal of it still
	-- is.  Anything else with no type is a mistake.
	if not base then
		if self.tok.kind ~= "name" and self.tok.kind ~= "*" then
			self:err("expected a declaration")
		end
		base = self.ty.i32
	end
	if self:accept(";") then return end
	repeat
		self.asmname = nil
		local name, wrap = self:dcl(false)
		local ty = self:vectored(wrap(base), attrs)
		-- What the object answers to, which `__asm__("...")` on
		-- the declarator may have said is not its C name.
		local sym = self.asmname or name
		-- GNU C: `register long sp __asm__("rsp")` at file scope
		-- binds the name to a machine register.  There is no
		-- object, so nothing is laid down and nothing is named
		-- outside this file.
		local hard = self.sawreg and name and self.asmname or nil

		self.asmname = nil
		-- A name keeps the linkage its first declaration gave it,
		-- so a function declared static and then defined with no
		-- storage class at all is still internal.
		local prev = name and self.globals[name]
		local intern = storage == "static"
		-- -fvisibility says what a definition is worth outside the
		-- object it lands in.  The attribute says otherwise, and
		-- it sticks to the name: a header declares the attribute
		-- and the definition beside it says nothing.
		local named = attrs.visibility or (prev and prev.vis)
		local vis = named or self.visibility

		if hard then
			self:declare(name, {kind = "hardglobal", ty = ty,
					    reg = hard})
			goto nextname
		end
		-- `alias` names something already defined, so the
		-- declaration that carries it is the whole definition.
		if name and type(attrs.alias) == "string" then
			-- The alias names it, so the body has to be
			-- built even if nothing calls it.  The target
			-- may not have been read yet, so the name is
			-- remembered as well as marked.
			local t = self.globals[attrs.alias]

			self.aliased = self.aliased or {}
			self.aliased[attrs.alias] = true
			if t then
				t.used, t.keep = true, true
				if t.pending and not t.c99 and
				   not t.gnuextern then
					t.wanted = true
				end
			end
			self.t.data.alias(self.dg, sym, attrs.alias,
				attrs.weak, vis, ty.kind == "func")
			self.globals[name] = {kind = ty.kind == "func"
				and "func" or "global", ty = ty, sym = sym,
				vis = named}
			goto nextname
		end

		if not intern and prev and prev.static and
		   (storage == nil or storage == "extern") then
			intern = true
		end
		if not name then
			-- a declarator with no name declares only the type
		elseif storage == "typedef" then
			self.globals[name] = {kind = "typedef", ty = ty}
		elseif ty.kind == "func" then
			ty = self:oldparams(ty)
			-- C makes the definition an inline one only when
			-- every declaration of the name in this unit said
			-- `inline` and none said `extern`.  One that did
			-- either asks for a definition to be emitted.
			-- GNU C turns that around, and a kernel builds
			-- with it: under `__gnu_inline__` it is `extern
			-- inline` that emits nothing and a plain `inline`
			-- that owes the definition.
			local gnu = attrs.gnu_inline and true or false
			local mine = gnu and storage == "extern"
				or (not gnu and storage ~= "extern")
			local only = (inl and mine and
				(prev == nil or prev.onlyinline ~= false))
				and true or false

			-- What was already known about the name is kept:
			-- a body put aside by an earlier declaration is
			-- still the body, and this declaration may be
			-- the one that says it has to be built.
			local g = prev or {}

			g.kind, g.ty, g.sym = "func", ty, sym
			-- A declaration that says the function does not
			-- return says it for every other one too.
			g.noreturn = g.noreturn or attrs.noreturn or nil
			-- A name something outside this unit reaches
			-- without calling it: the loader runs it, or a
			-- table names it, or an alias stands for it.
			g.keep = g.keep or attrs.used or attrs.constructor
				or attrs.destructor
				or (self.aliased and self.aliased[sym])
				or nil
			g.vis, g.static, g.onlyinline = named, intern, only
			self.globals[name] = g
			-- C99: a unit where some declaration says
			-- `extern` owes the external definition, and
			-- which declaration comes first is not fixed.
			if not only and g.pending and g.c99 then
				g.wanted = true
			end
			-- A weak name this unit only mentions stands for
			-- nothing when nothing defines it, which is what
			-- code that tests it for zero expects.
			if attrs.weak and self.tok.kind ~= "{" then
				self.t.data.weaken(self.dg, sym)
			end
			if self.tok.kind == "{" then
				-- A definition that is an inline one emits
				-- nothing: this compiler does not inline,
				-- and C says the external definition lives
				-- in another unit.
				if only and (gnu or not storage) then
					-- An inline definition emits
					-- nothing by itself, but a later
					-- `extern` in this unit would owe
					-- one, so the body waits rather
					-- than being thrown away.
					g.pending = {sym = sym, ty = ty,
						sec = attrs.section,
						vis = vis, weak = attrs.weak,
						static = false,
						always = attrs.always_inline
							and true or nil,
						lx = self:capture()}
					-- Only C99 leaves a later `extern`
					-- owing a definition; under GNU
					-- rules nothing ever does, and
					-- using it does not either.
					g.c99 = not gnu
					g.gnuextern = gnu or nil
					self.deferred[#self.deferred + 1] = g
					return
				elseif intern and not g.keep then
					-- A name of this unit's own is
					-- built only if this unit has a
					-- use for it, which is what gcc
					-- does.  Its body waits as tokens
					-- until the unit is read, so one
					-- nothing reaches costs nothing
					-- and has to compile for nobody.
					local g = self.globals[name]

					g.pending = {sym = sym, ty = ty,
						sec = attrs.section,
						vis = vis, weak = attrs.weak,
						static = true,
						always = attrs.always_inline
							and true or nil,
						lx = self:capture()}
					-- Something called it before it was
					-- written, so it is wanted now.
					g.wanted = g.wanted or g.used
					self.deferred[#self.deferred + 1] = g
				else
					self:funcdef(sym, ty, intern,
						attrs.section, vis,
						attrs.weak)
				end
				return
			end
		else
			if attrs.weak and storage ~= "static" then
				self.t.data.weaken(self.dg, sym)
			end
			local s = {kind = "global", ty = ty, sym = sym,
				   static = intern, vis = named, tls = tls}
			self.globals[name] = s
			if self:accept("=") then
				s.ty = self:initobject(sym, ty, intern,
					asked, attrs.section, vis, tls)
			elseif storage ~= "extern" then
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
					s.ty = ty
				end
				self.t.data.obj(self.dg, sym,
					math.max(asked or 0, ty.align),
					intern, true, attrs.section, vis, tls)
				self.t.data.zero(self.dg, ty.size)
			end
		end
		::nextname::
	until not self:accept(",")
	self:expect(";")
end

function P:drain()
	if not self.emit then return end
	self.emit(self.out:text())
	self.emit(self.sdata:text())
	self.emit(self.data:text())
	self.out:reset()
	self.sdata:reset()
	self.data:reset()
end

-- Build every definition put aside that something asked for.  One of
-- them may be the first to ask for another, so this goes round until a
-- pass finds nothing left to build.  What is still unwanted at the end
-- is let go of there and then: the tokens are the largest thing this
-- compiler holds on to that it may never need.
function P:settle()
	local again = true

	self.settling = true

	while again do
		again = false
		for _, g in ipairs(self.deferred) do
			local p = g.pending

			if p and g.wanted and not g.built then
				g.built = true
				again = true
				-- A `static inline` is this unit's own; an
				-- inline definition the unit owes is a
				-- name anything may call.
				self:replay(p.lx, P.funcdef, p.sym, p.ty,
					p.static, p.sec, p.vis, p.weak,
					g.static and g.same or nil)
				self:drain()
			end
		end
	end
	self.settling = nil
	for i, g in ipairs(self.deferred) do
		g.pending = nil
		self.deferred[i] = nil
	end
end

function P:program()
	while self.tok.kind ~= "eof" do
		self:extdef()
		self:drain()
	end
	self:settle()
	if self.emit then return "" end
	return self.out:text() .. self.sdata:text() .. self.data:text()
end

function P:constexpr()
	local m = tree.mark()
	local v = fold(self:ternary())
	tree.release(m)
	if not v then self:err("a constant is required here") end
	return v
end

-- Constant folding, enough for array sizes, enum values and case labels.
return P
