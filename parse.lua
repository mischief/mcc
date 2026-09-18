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

-- Spellings that carry no meaning here.  They are ordinary identifiers to
-- the lexer, so the parser has to know them by name.
local IGNORE = {}
for _, k in ipairs{"_Noreturn", "restrict", "__restrict", "__restrict__",
		   "__inline", "__inline__", "__signed__", "__const",
		   "__volatile__", "_Atomic", "__extension__"} do
	IGNORE[k] = true
end
local BUILTIN = {}
for _, k in ipairs{"__builtin_huge_val", "__builtin_huge_valf",
		   "__builtin_inf", "__builtin_inff", "__builtin_nan",
		   "__builtin_expect", "__builtin_fabs", "__builtin_fabsf",
		   "__builtin_sqrt", "__builtin_sqrtf", "__builtin_floor",
		   "__builtin_ceil", "__builtin_bswap16",
		   "__builtin_bswap32", "__builtin_bswap64"} do
	BUILTIN[k] = true
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
-- GNU typeof, which names the type of a type name or of an expression.
local TYPEOF = {typeof = true, __typeof = true, __typeof__ = true}
local STORAGE = {static = true, extern = true, typedef = true}
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
	p.wideabi = target.ptrsize < 8
	-- reach a symbol another unit may replace through the table the
	-- loader fills in, which is what a shared object needs
	p.pic = (opt and opt.pic) or false
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
		file = t.file}
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
	self.marks[#self.marks] = nil
end

function P:find(name)
	for i = #self.scopes, 1, -1 do
		local s = self.scopes[i][name]
		if s then return s end
	end
	return self.globals[name]
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
	-- The answer is the lowest address of the object, wherever the
	-- target grows its frame from.
	if self.t.upward then
		return self.t.slot(self.nlocals - words + 1)
	end
	return self.t.slot(self.nlocals)
end

-- types ----------------------------------------------------------------

-- Names that can only stand in front of a declaration, never an
-- expression, so seeing one settles which this is.
local DECLONLY = {__attribute__ = true, __attribute = true,
		  __declspec = true,
		  _Alignas = true, alignas = true}

function P:istype()
	local k = self.tok.kind
	if DECLKW[k] then return true end
	if k == "[" and self:peek().kind == "[" then return true end
	if k == "name" then
		if TYPEOF[self.tok.text] then return true end
		if FLOATN[self.tok.text] then return true end
		if VALIST[self.tok.text] then return true end
		if DECLONLY[self.tok.text] then return true end
		local s = self:find(self.tok.text)
		return s ~= nil and s.kind == "typedef"
	end
	return false
end

-- GNU typeof: a type name gives itself, and anything else gives the type
-- the expression would have.  Nothing is emitted for the expression; only
-- its type is wanted.
function P:typeofspec()
	self:adv()
	self:expect("(")
	local t
	if self:istype() then
		t = self:typename()
	else
		t = self:rvalue(self:expression()).ty
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

function P:skipparens()
	if self.tok.kind ~= "(" then return end
	local depth = 0
	repeat
		if self.tok.kind == "(" then depth = depth + 1
		elseif self.tok.kind == ")" then depth = depth - 1
		elseif self.tok.kind == "eof" then self:err("unbalanced (") end
		self:adv()
	until depth == 0
end

-- Qualifiers and the spellings that mean nothing to this compiler.
function P:quals(into)
	while true do
		local k = self.tok.kind
		if QUAL[k] then
			self:adv()
		elseif k == "name" and IGNORE[self.tok.text] then
			self:adv()
		elseif k == "name" and ATTRKW[self.tok.text] then
			self:adv()
			self:attrlist(into or self.declattrs)
		elseif k == "name" and PARENED[self.tok.text] then
			self:adv()
			self:skipparens()
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
	if tag then st = self:findtag(tag) end
	if not st or (st.kind ~= kind) then
		st = self.ty.record(kind, tag)
		if tag then self:addtag(tag, st) end
	end
	if self:accept("{") then
		local members = {}
		while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
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
		end
		self:expect("}")
		self:skipattrs(attrs)
		self.ty.complete(st, members, attrs)
		return st
	end
	self:skipattrs(attrs)
	return st
end

function P:enumspec()
	self:skipattrs()
	local tag
	if self.tok.kind == "name" then
		tag = self.tok.text
		self:adv()
	end
	if self:accept("{") then
		local next_ = 0
		while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
			local name = self:expect("name").text
			if self:accept("=") then next_ = self:constexpr() end
			self:declare(name, {kind = "const", ty = self.ty.i32,
					    val = next_})
			next_ = next_ + 1
			if not self:accept(",") then break end
		end
		self:expect("}")
	end
	if tag then self:addtag(tag, self.ty.i32) end
	return self.ty.i32
end

-- The specifiers before a declarator.  Returns the base type and the
-- storage class.
function P:declspec()
	local storage, sign, longs, base = nil, nil, 0, nil
	local size, inl, align
	self.alignas = nil
	-- What the attributes on this declaration said, for the few that
	-- change what is emitted.
	self.declattrs = {}
	while true do
		local k = self.tok.kind
		if k == "[" and self:peek().kind == "[" then
			self:attrs()
		elseif QUAL[k] then
			self:adv()
		elseif k == "name" and IGNORE[self.tok.text] then
			self:adv()
		elseif k == "name" and ATTRKW[self.tok.text] then
			self:adv()
			self:attrlist(self.declattrs)
		elseif k == "name" and PARENED[self.tok.text] then
			self:adv()
			self:skipparens()
		elseif k == "name" and VALIST[self.tok.text] and not base
		   and not size then
			base = self:valist()
			self:adv()
		elseif k == "name" and FLOATN[self.tok.text] and not base
		   and not size then
			base = self.ty[FLOATN[self.tok.text]]
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
		elseif k == "inline" then
			inl = true
			self:adv()
		elseif STORAGE[k] then
			storage = k
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
		elseif k == "char" or k == "int" or k == "void" or
		       k == "_Bool" then
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
	if base then return base, storage, inl end
	local t
	if size == "_Bool" then
		t = self.ty.bool
	elseif size == "float" then
		t = self.ty.f32
	elseif size == "double" then
		t = self.ty.f64
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
	else
		return nil, storage, inl
	end
	return t, storage, inl
end

function P:params()
	local list, variadic = {}, false
	if self.tok.kind == ")" then return list, variadic end
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
			local ps, va, nm = self:params()
			self:expect(")")
			sfx[#sfx + 1] = function(t)
				return self.ty.func(t, ps, va, nm)
			end
		end
	elseif self.tok.kind == "name" then
		name = self.tok.text
		self:adv()
	end

	while true do
		if self:accept("[") then
			local n
			-- `[restrict]` and `[static 4]` say something about
			-- the parameter, not about the size
			self:quals()
			if self.tok.kind == "static" then
				self:adv()
				self:quals()
			end
			if self.tok.kind ~= "]" and
			   vm and nstar == 0 and #sfx == 0 then
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
				n = self:constexpr()
			end
			self:expect("]")
			sfx[#sfx + 1] = function(t)
				return self.ty.array(t, n)
			end
		elseif self:accept("(") then
			local ps, va, nm = self:params()
			self:expect(")")
			sfx[#sfx + 1] = function(t)
				return self.ty.func(t, ps, va, nm)
			end
		else
			break
		end
	end
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

function P:rtcall(name, rty, args)
	-- soft: the runtime takes bit patterns in ordinary registers, whatever
	-- the target's calling convention does with a float.
	local n = tree.node("CALL", rty,
		tree.name(self.ty.func(rty, {}, true), name), nil,
		{args = args, direct = true, soft = true})
	if not (self.wideabi and self:iswide(rty)) then return n end
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
		if n.op == "CONST" then
			local v = isflt(from) and self:fvalue(n) or n.val

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
		if isflt(from) and isflt(to) then
			return self:rtcall("__" .. self:fprefix(from) .. "2" ..
				self:fprefix(to), to, {n})
		end
		if isflt(to) then
			if isptr(from) then self:err("pointer to float") end
			-- The runtime takes a whole word, so a narrower value
			-- has to be extended before the call rather than left
			-- with whatever is above it.
			local w = from
			if w.size < self.word.size then
				w = w.kind == "uint" and self.uword or self.word
			end
			n = self:conv(n, w)
			return self:rtcall("__" ..
				(w.kind == "uint" and "u" or "i") .. "2" ..
				self:fprefix(to), to, {n})
		end
		local want = to
		if want.size < self.word.size then
			want = want.kind == "uint" and self.uword or self.word
		end
		local c = self:rtcall("__" .. self:fprefix(from) .. "2" ..
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

-- The number a float constant stands for.  A float travels as its bit
-- pattern, so reading one back is an unpacking.
function P:fvalue(n)
	if n.op ~= "CONST" or not isflt(n.ty) then return nil end
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
	e = self:rvalue(e)
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
function P:global(ty, sym, static)
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
	if e.op == "INDIR" then return e.left end
	if e.ty.kind == "array" then return self:rvalue(e) end
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
	if n.bf then return self:bfget(n) end
	if n.ty.kind == "func" then
		if n.op == "INDIR" then return n.left end
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
	return tree.node("SEQ", self:bftypes(m), nil, nil,
		{arms = {set, self:bfget(back)}})
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
			local f = tk.text and tk.text:match("[fF]$")
			return self:fconst(tk.val, f and self.ty.f32
					   or self.ty.f64)
		end
		return tree.const(self:constty(tk.val, tk.text), tk.val)
	end
	if tk.kind == "str" then
		self:adv()
		self.nstr = self.nstr + 1
		local label = ".Lstr" .. self.nstr
		self.t.data.stringdef(self.sg, label, tk.text)
		-- An array, so that sizeof sees the bytes rather than a
		-- pointer.  Every other use decays through rvalue.
		return tree.name(self.ty.array(self.plainchar, #tk.text + 1),
				 label)
	end
	if tk.kind == "name" and tk.text == "__builtin_va_start" then
		self:adv()
		return self:vastart()
	end
	if tk.kind == "name" and tk.text == "__builtin_va_arg" then
		self:adv()
		return self:vaarg()
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
			-- an undeclared name called as a function
			s = {kind = "func", sym = tk.text,
			     ty = self.ty.func(self.word, {}, true)}
			self.globals[tk.text] = s
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
			return tree.name(s.ty, s.sym)
		end
		if s.kind == "const" then
			return tree.const(self.word, s.val)
		end
		if s.kind == "local" then
			return tree.auto(s.ty, s.off)
		end
		return self:global(s.ty, s.sym or tk.text, s.static)
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

	local rty = fty.kind == "func" and fty.ret or self.word
	local retrec = isrec(rty) and rty or nil
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
	if self.wideabi then
		for i, a in ipairs(args) do
			if self:iswide(a.ty) then
				wide = wide or {}
				wide[i] = a.ty.size
				args[i] = self:waddr(a)
			end
		end
	end
	-- The target needs the named count to classify a variadic call.
	local n = tree.node("CALL", rty, callee, nil,
		{args = args, direct = direct, wide = wide, recs = recs,
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
	if not (self.wideabi and self:iswide(rty)) then return n end
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
			if isptr(e.ty) then step = step * e.ty.to.size end
			if self:iswide(e.ty) then
				-- the old value has to be kept, because the
				-- step writes over it
				local t = self:wtemp(e.ty)
				local keep = tree.node("COPY", e.ty,
					self:waddr(tree.clone(t)),
					self:waddr(tree.clone(e)),
					{val = e.ty.size})
				local bump = self:assignto(tree.clone(e),
					self:arith("ADD", e,
						tree.const(self.ty.i32, step)))
				e = tree.node("SEQ", e.ty, nil, nil,
					{arms = {keep, bump, t}})
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
				self:err("postfix step on a float")
			else
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
			return tree.const(self.uword,
				self:postfix(e).ty.size)
		end
		return tree.const(self.uword, self:unary().ty.size)
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
	    (DECLKW[self.ahead.kind] or
	     (self.ahead.kind == "name" and (function()
		if TYPEOF[self.ahead.text] then return true end
		local s = self:find(self.ahead.text)
		return s ~= nil and s.kind == "typedef"
	     end)())) then
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
		if isrec(t) then
			e.ty = t
			return e
		end
		return self:conv(e, t)
	elseif k == "-" then
		self:adv()
		local e = self:rvalue(self:unary())
		if e.op == "CONST" and isflt(e.ty) then
			-- flipping the sign bit is exact, and keeps a negative
			-- literal usable as a constant
			return tree.const(e.ty,
				e.val ~ (1 << (e.ty.size * 8 - 1)))
		end
		if isflt(e.ty) then
			if self:iswide(e.ty) then
				return self:wcall("__w_dneg",
					{self:waddr(e)}, e.ty)
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
	elseif k == "&" then
		self:adv()
		return self:addrof(self:unary())
	elseif k == "++" or k == "--" then
		self:adv()
		local e = self:unary()
		local step = k == "++" and 1 or -1
		return self:assignto(tree.clone(e),
			self:arith("ADD", e, tree.const(self.ty.i32, step)))
	end
	return self:postfix(self:primary())
end

function P:binary(minp)
	local a = self:unary()
	while true do
		local b = BIN[self.tok.kind]
		if not b or b[1] < minp then return a end
		self:adv()
		local rhs = self:binary(b[1] + 1)

		if b[2] == "ANDAND" or b[2] == "OROR" then
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
		local b = self:rvalue(self:ternary())
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
	local a = self:expression()
	self:expect(":")
	local b = self:ternary()
	a, b = self:rvalue(a), self:rvalue(b)
	local rt = self:condtype(a, b)
	return tree.node("COND", rt, c, nil,
		{arms = {self:conv(a, rt), self:conv(b, rt)}})
end

-- A whole record moves as bytes.
function P:assignto(lhs, rhs)
	if lhs.bf then return self:bfset(lhs, rhs) end
	if self:iswide(lhs.ty) then
		local r = self:conv(self:rvalue(rhs), lhs.ty)
		local cp = tree.node("COPY", lhs.ty, self:waddr(lhs),
			self:waddr(r), {val = 8})
		return tree.node("SEQ", lhs.ty, nil, nil,
			{arms = {cp, tree.clone(lhs)}})
	end
	if isrec(lhs.ty) then
		return tree.node("COPY", lhs.ty, self:recaddr(lhs),
			self:recaddr(rhs), {val = lhs.ty.size})
	end
	return tree.binary("ASGN", lhs.ty, lhs,
		self:conv(self:rvalue(rhs), lhs.ty))
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

function P:iswide(ty)
	return self.widen and not ty.addr and ty.size == 8 and
		(ty.kind == "int" or ty.kind == "uint" or ty.kind == "float")
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
	if not self.wideabi then
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
		-- a constant widens here, where Lua's integers are wide
		-- enough, rather than in a call
		if n.op == "CONST" and not isflt(from) and not isflt(ty) then
			local v = n.val
			if from.kind == "uint" and from.size < 8 then
				v = v & ((1 << (from.size * 8)) - 1)
			end
			return tree.const(ty, v)
		end
		if n.op == "CONST" and not isflt(from) and isflt(ty) then
			return self:fconst(n.val + 0.0, ty)
		end
		if isflt(from) then
			if isflt(ty) then
				return self:wcall("__w_f2d", {n}, ty)
			end
			return self:wconv(self:conv(n, self.ty.f64), ty)
		end
		local w = from.size < 4 and self.ty.i32 or from
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
	return self:conv(self:rtcall("__w_lo", self.ty.u32,
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
		-- nothing to emit: the caller never looks at the answer
		return tree.const(self.ty.i32, 0)
	end
	if name == "__builtin_constant_p" then
		local m = tree.mark()
		local e = self:rvalue(self:assign())
		local v = fold(e) ~= nil

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
	if name == "__builtin_huge_val" or name == "__builtin_inf" then
		return self:fconst(math.huge, self.ty.f64)
	end
	if name == "__builtin_huge_valf" or name == "__builtin_inff" then
		return self:fconst(math.huge, self.ty.f32)
	end
	if name == "__builtin_nan" then
		return self:fconst(0.0 / 0.0, self.ty.f64)
	end
	if name == "__builtin_expect" then
		return args[1]
	end
	local w = name:match("^__builtin_bswap(%d+)$")
	if w then
		return self:bswap(args[1], tonumber(w) // 8)
	end
	-- the rest are the library function of the same name, called the way
	-- the target calls anything else
	local fn = name:gsub("^__builtin_", "")
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
	local flt = self.t.vafloat and (self.t.nfltreg or 0) > 0 and isflt(ty)
	local p = self:rtcall("__va_next", self.ty.ptr(ty), {
		ap,
		tree.const(self.word, ty.size),
		tree.const(self.word, flt and 1 or 0),
	})
	p.soft = nil
	return tree.unary("INDIR", ty, p)
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
	if ty.kind == "array" and ty.of.size == 1 and self.tok.kind == "str" then
		local str = self.tok.text
		self:adv()
		out[#out + 1] = {str = str}
		local n = #str + 1
		if ty.n and ty.n > n then
			out[#out + 1] = {zero = ty.n - n}
		end
		return n
	end

	if self:accept("{") then
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

	local text, e = self:initscalar(ty, dyn)
	out[#out + 1] = {size = ty.size, text = text or "0", expr = e, ety = ty}
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

		if self.tok.kind == "[" then
			self:accept("[")
			local k = fold(self:ternary())

			if not k then self:err("a constant is required here") end
			self:expect("]")
			i = k + 1
			ety, off = self:designator(ty.of, k * w)
			self:expect("=")
		end
		local items = {}

		self:initlist(ety, items, dyn)
		map[#map + 1] = {off = off, size = ety.size, items = items}
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
	if isflt(ty) then
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

function P:emitinit(name, ty, out, static, align, sec)
	self.t.data.obj(self.dg, name, math.max(align or 0, ty.align),
		static, false, sec)
	for _, it in ipairs(out) do
		if it.str then
			self.t.data.string(self.dg, it.str)
		elseif it.zero then
			self.t.data.zero(self.dg, it.zero)
		else
			self.t.data.item(self.dg, it.size, it.text)
		end
	end
end

-- Parse an initializer for an object of type `ty`, and emit it.  Returns the
-- type, which for an array with no bound is now complete.
function P:initobject(name, ty, static, align, sec)
	local out = {}
	local n = self:initlist(ty, out)
	if ty.kind == "array" and not ty.n then
		ty = self.ty.array(ty.of, n)
	end
	self:emitinit(name, ty, out, static, align, sec)
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
	while self.tok.kind == "volatile" or self.tok.kind == "goto" or
	      (self.tok.kind == "name" and IGNORE[self.tok.text]) do
		if self.tok.kind == "goto" then
			self:err("asm goto is not supported")
		end
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
			local e = self:rvalue(self:expression())
			self:expect(")")
			list[#list + 1] = {c = c, e = e, name = nm,
					   const = fold(e)}
		until not self:accept(",")
	end

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
			end
		end
	end
	self:expect(")")

	-- An output needs somewhere safe to land: the template leaves it in a
	-- register, and storing it straight into its lvalue could need a
	-- second register and destroy another output.
	for _, o in ipairs(outs) do
		if o.e.op ~= "AUTO" and o.e.op ~= "NAME" and
		   o.e.op ~= "INDIR" then
			self:err("an asm output must be an lvalue")
		end
		-- An output the template writes to memory is already
		-- where it belongs and needs no landing place.
		if not o.c:find("m", 1, true) then o.tmp = self:temp() end
	end
	return tree.node("ASM", self.ty.void, nil, nil,
		{text = text, outs = outs, ins = ins, clob = clob})
end

-- statements -----------------------------------------------------------

function P:localdecl()
	local base, storage = self:declspec()
	if not base then return false end
	local asked = self.alignas
	if self:accept(";") then return true end
	repeat
		local name, wrap = self:dcl(false)
		local ty = wrap(base)

		-- Every frame slot is a word wide and a word aligned, so
		-- that much is free; more than that this compiler cannot
		-- give, and saying so beats laying it out wrong.
		if asked and asked > self.t.ptrsize and
		   storage ~= "static" and storage ~= "extern" then
			self:err("_Alignas of " .. asked ..
				" on a local is not supported")
		end
		if storage == "typedef" then
			self:declare(name, {kind = "typedef", ty = ty})
		elseif storage == "extern" or ty.kind == "func" then
			self:declare(name, {kind = "func", ty = ty,
					    sym = name})
		elseif storage == "static" then
			local lbl = ".Lstatic" .. self.nstr
			self.nstr = self.nstr + 1
			if self:accept("=") then
				ty = self:initobject(lbl, ty, true, asked)
			else
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
				end
				self.t.data.obj(self.dg, lbl,
					math.max(asked or 0, ty.align),
					true, true)
				self.t.data.zero(self.dg, ty.size)
			end
			self:declare(name, {kind = "global", ty = ty,
					    sym = lbl})
		else
			-- The frame slot waits for the initializer, which is
			-- what gives an array without a bound its size.
			local s = self:declare(name, {kind = "local", ty = ty})
			if self:accept("=") then
				if self.tok.kind == "{" or
				   (ty.kind == "array" and ty.of.size == 1
				    and self.tok.kind == "str") then
					self:initlocal(s, ty)
				else
					s.off = self:alloc(ty)
					self.g:expr(self:assignto(
						tree.auto(ty, s.off),
						self:assign()), "eff")
				end
			else
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
					s.ty = ty
				end
				s.off = self:alloc(ty)
			end
		end
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
	local val
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		if self:istype() then
			self:localdecl()
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
	if isrec(val.ty) then
		self.g:expr(tree.node("COPY", val.ty,
			tree.unary("ADDR", self.ty.ptr(val.ty), t),
			self:recaddr(val), {val = val.ty.size}), "eff")
	else
		self.g:expr(tree.binary("ASGN", val.ty, t, val), "eff")
	end
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
	return ".Lu_" .. self.fname .. "_" .. name
end

function P:stmt()
	local m = tree.mark()

	if self.tok.kind == "[" and self:peek().kind == "[" then
		self:attrs()
	end
	local k = self.tok.kind
	local g = self.g

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
		local c = self:test(self:expression())
		self:expect(")")
		local lelse = g:newlabel()
		g:cond(c, lelse, false, 0)
		tree.release(m)
		self:stmt()
		if self:accept("else") then
			local lend = g:newlabel()
			self.t.jump(g, lend)
			g:putlabel(lelse)
			self:stmt()
			g:putlabel(lend)
		else
			g:putlabel(lelse)
		end
		return
	elseif k == "while" then
		self:adv()
		self:expect("(")
		local ltop, lbrk = g:newlabel(), g:newlabel()
		g:putlabel(ltop)
		local c = self:test(self:expression())
		self:expect(")")
		g:cond(c, lbrk, false, 0)
		tree.release(m)
		self:loop(ltop, lbrk)
		self.t.jump(g, ltop)
		g:putlabel(lbrk)
		return
	elseif k == "do" then
		self:adv()
		local ltop, lcont, lbrk = g:newlabel(), g:newlabel(), g:newlabel()
		g:putlabel(ltop)
		self:loop(lcont, lbrk)
		g:putlabel(lcont)
		self:expect("while")
		self:expect("(")
		local c = self:test(self:expression())
		self:expect(")")
		self:expect(";")
		g:cond(c, ltop, true, 0)
		g:putlabel(lbrk)
		tree.release(m)
		return
	elseif k == "for" then
		self:adv()
		self:expect("(")
		self:push()
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
		local lcond, lcont, lbrk =
			g:newlabel(), g:newlabel(), g:newlabel()
		local mcond = tree.mark()
		g:putlabel(lcond)
		if self.tok.kind ~= ";" then
			g:cond(self:test(self:expression()), lbrk, false, 0)
		end
		self:expect(";")
		tree.release(mcond)
		local step
		if self.tok.kind ~= ")" then step = self:expression() end
		self:expect(")")
		self:loop(lcont, lbrk)
		g:putlabel(lcont)
		if step then g:expr(step, "eff") end
		self.t.jump(g, lcond)
		g:putlabel(lbrk)
		self:pop()
		tree.release(m)
		return
	elseif k == "switch" then
		self:adv()
		self:expect("(")
		local e = self:rvalue(self:expression())
		self:expect(")")
		local slot = self:alloc(self.word)
		g:expr(self:assignto(tree.auto(self.word, slot), e), "eff")
		tree.release(m)

		local osw, obrk = self.sw, self.brk
		local ldisp, lbrk = g:newlabel(), g:newlabel()
		self.sw = {slot = slot, cases = {}, ty = self.word}
		self.brk = lbrk
		self.t.jump(g, ldisp)
		self:stmt()
		self.t.jump(g, lbrk)

		-- The dispatch goes after the body, because the case labels
		-- are only known once it has been read.
		g:putlabel(ldisp)
		for _, c in ipairs(self.sw.cases) do
			local t = tree.auto(self.word, slot)
			g:cond(tree.binary("EQ", self.word, t,
				tree.const(self.word, c.val)), c.label, true, 0)
			tree.release(m)
		end
		self.t.jump(g, self.sw.deflab or lbrk)
		g:putlabel(lbrk)
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
		tree.release(m)
		return self:stmt()
	elseif k == "default" then
		self:adv()
		self:expect(":")
		if not self.sw then self:err("default outside a switch") end
		self.sw.deflab = g:newlabel()
		g:putlabel(self.sw.deflab)
		tree.release(m)
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
			tree.release(m)
			return
		end
		local name = self:expect("name").text
		self:expect(";")
		self.t.jump(g, self:userlabel(name))
	elseif k == "return" then
		self:adv()
		if self.tok.kind ~= ";" and self.recret then
			local e = self:rvalue(self:expression())
			local d = tree.auto(e.ty, self.recret.off)
			g:expr(tree.node("COPY", e.ty,
				tree.unary("ADDR", self.ty.ptr(e.ty), d),
				self:recaddr(e),
				{val = self.recret.size}), "eff", 0)
		elseif self.tok.kind ~= ";" then
			local e = self:conv(self:rvalue(self:expression()),
				self.rty)
			if self.wideabi and self:iswide(self.rty) then
				e = self:waddr(e)
			end
			g:expr(e, "reg", 0)
		end
		self:expect(";")
		self.t.jump(g, self.endlabel)
	elseif k == "break" then
		self:adv()
		self:expect(";")
		if not self.brk then self:err("break outside a loop") end
		self.t.jump(g, self.brk)
	elseif k == "continue" then
		self:adv()
		self:expect(";")
		if not self.cont then self:err("continue outside a loop") end
		self.t.jump(g, self.cont)
	elseif k == "name" and self:peek().kind == ":" and not self:istype() then
		local name = self.tok.text
		self:adv()
		self:adv()
		g:putlabel(self:userlabel(name))
		-- A named label is where `goto *` may arrive.
		g:landing()
		tree.release(m)
		return self:stmt()
	elseif not self:istype() then
		g:expr(self:expression(), "eff")
		self:expect(";")
	else
		self:localdecl()
	end
	tree.release(m)
end

function P:loop(cont, brk)
	local oc, ob = self.cont, self.brk
	self.cont, self.brk = cont, brk
	self:stmt()
	self.cont, self.brk = oc, ob
end

-- declarations ---------------------------------------------------------

function P:funcdef(name, ty, static, sec)
	self.fname = name
	local body = buf.new()
	local saved = self.g.sink
	self.g.sink = body
	self.nlocals, self.maxlocals = 0, 0
	self.fname = name
	self.rty = (ty.ret == self.ty.void or isrec(ty.ret)) and self.word
		or ty.ret
	self.endlabel = self.g:newlabel()
	self:push()
	-- Each parameter is described, not just placed: a target that has a
	-- floating point class has to know which register file a value came
	-- in, and how many of each the named parameters used up.
	-- Only a target that passes variadic floats in the float file needs
	-- a second save area.
	local nfltreg = self.t.vafloat and (self.t.nfltreg or 0) or 0
	-- A record result too big for the return registers is written
	-- through a pointer the caller hands over ahead of the arguments.
	self.recret = nil
	if isrec(ty.ret) then
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
		shape[i] = {flt = isflt(prm) and
				  not (self.wideabi and self:iswide(prm)),
			    rec = isrec(prm) and prm or nil,
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
		if self.t.vastkslot then n = n + 1 end
		for _ = 1, n do
			last = self:alloc(self.word)
			first = first or last
		end
		self.vabase = math.min(first, last)
	end
	self:block()
	self:pop()
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

	self.g.sink = whole
	self.t.prologue(self.g, name, frame, slots, self.vabase, static,
		self.recret, sec)
	body:move(whole)
	self.t.epilogue(self.g, frame,
		(self.t.nfltreg or 0) > 0 and isflt(self.rty) and self.rty.size,
		self.wideabi and self:iswide(self.rty) and self.rty.size
			or nil, self.recret)
	if self.peep then
		peep.run(whole:lines(), self.peep,
			function(s) saved:add(s) end)
	end
	self.g.sink = saved
	-- Back at file scope: a compound literal out here is a static
	-- object, not a frame slot.
	self.fname = nil
	self.recret = nil
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
	if self.tok.kind == "name" and ASMKW[self.tok.text] then
		local n = self:asmstmt()
		if #n.outs > 0 or #n.ins > 0 then
			self:err("a file scope asm takes no operands")
		end
		self.g:write("\t" .. n.text .. "\n")
		self:accept(";")
		return
	end
	if self.tok.kind == "name" and self.tok.text == "_Static_assert" then
		self:adv()
		self:skipparens()
		self:accept(";")
		return
	end
	if self.tok.kind == "[" and self:peek().kind == "[" then
		self:attrs()
	end
	-- A stray semicolon at file scope declares nothing.  C99 forbids it,
	-- but real headers leave one after a macro that ends in one.
	if self:accept(";") then return end
	local base, storage, inl = self:declspec()
	local attrs = self.declattrs or {}
	local asked = self.alignas

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
		local name, wrap = self:dcl(false)
		local ty = wrap(base)
		if not name then
			-- a declarator with no name declares only the type
		elseif storage == "typedef" then
			self.globals[name] = {kind = "typedef", ty = ty}
		elseif ty.kind == "func" then
			ty = self:oldparams(ty)
			self.globals[name] = {kind = "func", ty = ty,
					      sym = name,
					      static = storage == "static"}
			if self.tok.kind == "{" then
				-- A plain `inline` definition emits nothing:
				-- this compiler does not inline, and C says
				-- the external one lives in another unit.
				if inl and not storage then
					self:discarded(name, ty)
				else
					self:funcdef(name, ty,
						storage == "static",
						attrs.section)
				end
				return
			end
		else
			local s = {kind = "global", ty = ty, sym = name,
				   static = storage == "static"}
			self.globals[name] = s
			if self:accept("=") then
				s.ty = self:initobject(name, ty,
					storage == "static", asked,
					attrs.section)
			elseif storage ~= "extern" then
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
					s.ty = ty
				end
				self.t.data.obj(self.dg, name,
					math.max(asked or 0, ty.align),
					storage == "static", true,
					attrs.section)
				self.t.data.zero(self.dg, ty.size)
			end
		end
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

function P:program()
	while self.tok.kind ~= "eof" do
		self:extdef()
		self:drain()
	end
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
