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
local ir    = require "ir"
local lex   = require "lex"
local sys = require "sys"

local cf = require "parse.fold"
local bitcount = cf.bitcount
local narrow = cf.narrow
local cutto = cf.cutto
local retyped = cf.retyped
local foldbin = cf.foldbin
local isptr = cf.isptr
local isrec = cf.isrec
local isflt = cf.isflt
local bitsof = cf.bitsof
local mentions = cf.mentions
local fltn = cf.fltn
local symoff = cf.symoff
local fold = cf.fold
local foldn = cf.foldn
local reaches = cf.reaches
local settlen = cf.settlen
local settle = cf.settle
require "parse.asm"
require "parse.inline"
local tokens = require "parse.tokens"
local NFIELD = tokens.NFIELD
local autoof = tokens.autoof
local copytok = tokens.copytok
local scanlabels = tokens.scanlabels
local scanwrites = tokens.scanwrites
local words = require "parse.words"
local ALIGNAS = words.ALIGNAS
local ALIGNOF = words.ALIGNOF
local ASMKW = words.ASMKW
local ATOMICKW = words.ATOMICKW
local ATTRKW = words.ATTRKW
local AUTOTYPE = words.AUTOTYPE
local BIN = words.BIN
local COMPLEXKW = words.COMPLEXKW
local CPLXHALF = words.CPLXHALF
local DECLKW = words.DECLKW
local FLOATN = words.FLOATN
local FUNCNAME = words.FUNCNAME
local IGNORE = words.IGNORE
local INLINEKW = words.INLINEKW
local INT128 = words.INT128
local OPASSIGN = words.OPASSIGN
local PARENED = words.PARENED
local QUAL = words.QUAL
local SPECIAL = words.SPECIAL
local STATICASSERT = words.STATICASSERT
local STMTKW = words.STMTKW
local STORAGE = words.STORAGE
local STRPREFIX = words.STRPREFIX
local TLSKW = words.TLSKW
local TYPEOF = words.TYPEOF
local VALIST = words.VALIST
local builtin = require "parse.builtin"
local BUILTIN = builtin.BUILTIN
local init = require "parse.init"
local addrtext = init.addrtext
local strchars = init.strchars
require "parse.wide"
local float = require "parse.float"
local dec80 = float.dec80
require "parse.complex"
require "parse.bitfield"

local P = require "parse.base"

-- What the standard library answers with, for a call to a name that was
-- never declared.  C89 says such a call answers with an int, and on a
-- 64-bit machine an int is half of a pointer, so `char *p = strdup(s);`
-- silently loses the top word and the program faults.
--
-- gcc carries a prototype for each of these and does not.  The list is
-- exactly gcc's, measured rather than guessed: doing less means a fault
-- gcc does not have, and doing more means a program that works here and
-- not there.  gcc keeps nothing for strtol, atol, getenv, fopen or
-- signal, so neither does this.
local LIBRET = {}
for _, group in ipairs{
	{"voidp", "malloc", "calloc", "realloc", "aligned_alloc", "alloca",
	 "memcpy", "memmove", "memset", "memchr", "mempcpy"},
	{"charp", "strdup", "strndup", "strcpy", "strncpy", "stpcpy",
	 "stpncpy", "strcat", "strncat", "strchr", "strrchr", "strstr",
	 "strpbrk", "index", "rindex"},
	{"ulong", "strlen", "strnlen", "strspn", "strcspn"},
	{"long", "labs"},
	{"llong", "llabs", "imaxabs"},
} do
	for i = 2, #group do LIBRET[group[i]] = group[1] end
end
-- The type each of those names stands for, once the target is known.
function P:libret(name)
	local k = LIBRET[name]

	if k == "voidp" then return self.ty.ptr(self.ty.void) end
	if k == "charp" then return self.ty.ptr(self.plainchar) end
	if k == "ulong" then return self.uword end
	if k == "long" then return self.word end
	if k == "llong" then return self.ty.i64 end
	return self.ty.i32
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
	-- `-mno-sse` says the float registers are out of bounds, so a
	-- variadic function keeps no float save area and never looks in
	-- one.
	p.nosse = opt and opt.nosse or nil
	-- -fshort-wchar: an `L` string holds two bytes an element.
	p.shortwchar = opt and opt.shortwchar or nil
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
	-- A call in a constant expression at file scope is expanded to
	-- fold it, and the expansion declares locals before any function
	-- has been read, so this has to stand from the start.
	p.slotname = {}
	-- What each block has to run on the way out: the objects in it
	-- that were declared with `cleanup`, in the order they were
	-- declared.
	p.cleanups = {}
	-- How deep in braces each of those blocks began, which is what a
	-- goto compares against to know which ones it leaves.
	p.cleanbd = {}
	p.bdepth = 0
	-- The peephole runs only when asked for: -O0 is what a debugger
	-- and a bug report want.
	if opt and (opt.opt or 0) > 0 then p.peep = target.peep end
	-- -Os: leave a body written without `inline` out of line.
	p.small = opt and opt.small or false
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
	-- The same for a static object: its bytes are written into a
	-- buffer of its own and only join the output when something
	-- turns out to name it.  A table of operations nothing reaches
	-- would otherwise drag in every function it names, and those
	-- name what the configuration left out.
	p.dstatics, p.dcand, p.dseen = {}, {}, {}
	-- Which names already have an object of their own here.
	p.defobj = {}
	if sys.getenv("MEM") then rawset(_G, "__parser", p) end
	p.marks, p.nlocals, p.maxlocals = {}, 0, 0
	p.stmarks = {}
	p:adv()
	return p
end

function P:err(msg)
	local t = self.tok
	error(("%s:%d: %s"):format((t and t.file) or self.lx.name or "-",
		(t and t.line) or 0, msg), 0)
end

-- scopes ---------------------------------------------------------------

-- Frame slots are reused once a block ends.  A long function with many
-- disjoint blocks, which is what a virtual machine's dispatch loop is,
-- would otherwise want a slot for every local it ever names.
function P:push(inblock)
	self.scopes[#self.scopes + 1] = {}
	self.tags[#self.tags + 1] = {}
	self.marks[#self.marks + 1] = self.nlocals
	self.stmarks[#self.stmarks + 1] = self.nlocals
	self.cleanups[#self.cleanups + 1] = {}
	-- A block`s scope stands at the depth inside its braces.  Every
	-- other scope -- a for, a switch -- has no braces of its own and
	-- sits between two depths, so a label at the depth around it is
	-- outside it and a label in its body is inside.
	self.cleanbd[#self.cleanups] = (self.bdepth or 0) +
		(inblock and 0 or 0.5)
end

function P:pop()
	self.scopes[#self.scopes] = nil
	self.tags[#self.tags] = nil
	self.cleanups[#self.cleanups] = nil
	self.nlocals = self.marks[#self.marks] or self.nlocals
	-- The extended float area is handed out once and never given
	-- back: the generator holds its offsets for the whole function.
	if self.x87floor and self.nlocals < self.x87floor then
		self.nlocals = self.x87floor
	end
	self.marks[#self.marks] = nil
	self.stmarks[#self.stmarks] = nil
end

-- A named object keeps its slot until its block ends, so the statement
-- mark rises past it.  Everything above the mark is scratch.
function P:keep()
	local i = #self.stmarks

	if i > 0 and self.nlocals > self.stmarks[i] then
		self.stmarks[i] = self.nlocals
	end
end

-- Where the extended floats of this function live: eight slots of
-- sixteen bytes, indexed by the same depth a register would be, and
-- taken from the frame the first time one is wanted.
function P:x87base()
	if not self.x87at then
		-- Played back, the body is already read and every block
		-- has given its slots back, so the mark to build on is
		-- the highest the function ever reached and not the
		-- depth it happens to be at.  Asked for while the body
		-- is being read, `x87floor` is what stops a later pop
		-- from handing these out again.
		if self.playing and self.nlocals < self.maxlocals then
			self.nlocals = self.maxlocals
		end
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
	-- A declarator with nothing to name reaches here when the
	-- parser has lost its way, and indexing a table with nothing
	-- says so in Lua's words rather than the program's.
	if name == nil then
		self:err("a declaration with no name")
		return s
	end
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

	-- Every slot handed out, so a target can drop the ones the
	-- finished body never names.
	if self.fobjs then
		local o, k = self.fobjs, ty.kind
		-- A store this wide or wider replaces the whole value.  A
		-- volatile object keeps a word of its own: a longjmp may
		-- come back to a read of it that no jump in the text shows.
		local whole = words == 1 and k ~= "array" and k ~= "struct" and
			k ~= "union" and not ty.complex and ty.size or 9

		if ty.volatile or self.allocvol then whole = -1 end

		o[#o + 1] = off
		o[#o + 1] = words
		o[#o + 1] = whole
	end

	-- How far each object reaches, so that an address taken of one
	-- member is known to reach the rest of it.
	self.lobj = self.lobj or {}
	self.lobj[off] = words * self.t.ptrsize

	-- Which offsets name a whole scalar local and which are part
	-- of something bigger.  Only the parser knows: a field of a
	-- record is an AUTO at the field's own offset, and looks from
	-- below exactly like a local that happens to live there.  An
	-- offset that is ever part of something bigger is out for the
	-- whole function, because a slot handed out twice is two
	-- objects and the second one would inherit a register the
	-- first had no business in.
	if self.irok then
		local k = ty.kind
		local scalar = k ~= "array" and k ~= "struct" and
			k ~= "union" and k ~= "func" and k ~= "float" and
			not ty.complex and not ty.volatile and
			not self.allocvol and
			not ty.atomic and ty.size and
			ty.size <= self.t.ptrsize and words == 1

		if scalar then
			-- The type as well as the offset: a parameter
			-- allocated a register needs one copy out of
			-- its slot at entry, and that copy has a width.
			self.irok[off] = ty
		else
			for i = 0, words - 1 do
				self.irno[self.t.slot(self.nlocals - i)] = true
			end
		end
	end
	if self.allocvol then
		self.volat = self.volat or {}
		self.volat[off] = true
	end
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
		  _Alignas = true, alignas = true,
		  -- `auto` says where an object lives, which is where a
		  -- local lives anyway, so it says nothing here.  It still
		  -- begins a declaration.
		  auto = true}

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
	-- What is inside is a declaration of its own and gathers
	-- attributes of its own.  The one being read out here keeps
	-- what it had: linux writes the section a per-cpu object goes
	-- in before the typeof that names its type.
	local outer = self.declattrs
	local t

	if self:istype() then
		t = self:typename()
	else
		t = self:expression().ty
	end
	self.declattrs = outer
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
					-- The argument may name a type, as
					-- `aligned(sizeof(w))` does, and
					-- reading one starts a declaration
					-- of its own, which puts a fresh
					-- table where this one was.
					local keep = self.declattrs

					a[name] = fold(self:ternary())
					self.declattrs = keep
					tree.release(m)
				elseif name == "cleanup" and
				       save.kind == "name" then
					-- The argument names a function,
					-- not a value.
					a[name] = save.text
					self:adv()
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
			if a and a.regparm then self.regparm = a.regparm end
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
		-- Each member is a declaration of its own.  What the
		-- declaration this record stands in has gathered is put
		-- back when the body ends.
		local outerattrs = self.declattrs

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
				-- What the specifiers said goes for every
				-- declarator; what follows one is that
				-- member's own.
				local ma = self.declattrs.aligned
				local mp = self.declattrs.packed

				repeat
					self.declattrs.aligned = ma
					self.declattrs.packed = mp
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
					local al = self.declattrs.aligned

					members[#members + 1] =
						{name = name, ty = mty,
						 bits = bits,
						 align = type(al) == "number"
							and al or nil,
						 packed = self.declattrs.packed
							or nil}
				until not self:accept(",")
				self:expect(";")
			end
			::nextmember::
		end
		self:expect("}")
		self.declattrs = outerattrs
		self:skipattrs(attrs)
		-- `#pragma pack(n)` in force caps every member's alignment,
		-- and the record's with them.
		local pk = self.lx.pragmapack and self.lx:pragmapack()

		if pk then attrs.maxalign = pk end
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
			self:declare(name, {kind = "const",
					    ty = self:enumconst(next_),
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

-- The type of one enumeration constant.  An enumerator is an int
-- where the value fits, and a wider type where it does not.
function P:enumconst(v)
	local T = self.ty

	if v >= -2147483648 and v <= 2147483647 then return T.i32 end
	if v >= 0 and v <= 4294967295 then return T.u32 end
	if v >= 0 then return T.u64 end
	return T.i64
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
	-- Whether a keyword that only a declaration may hold was read.
	-- `auto i = 3;` and `static j;` are declarations of an int, and
	-- nothing else can begin with those words.
	local only = false
	-- `volatile` in the specifiers, which the type does not carry.
	local vol = false
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
			if k == "volatile" then vol = true end
			only = true
			self:adv()
		elseif k == "name" and self.tok.text == "auto" and
		       not base and not size then
			only = true
			self:adv()
		elseif k == "name" and IGNORE[self.tok.text] then
			if self.tok.text:find("^__volatile") then vol = true end
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
				local outer = self.declattrs

				self:adv()
				base = self:typename()
				self.declattrs = outer
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
			only = true
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
	self.sawvol = vol
	if base then
		if cplx then base = self.ty.complex(base) end
		return base, storage, inl, only
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
		return nil, storage, inl, only
	end
	if cplx then t = self.ty.complex(t) end
	return t, storage, inl, only
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
	-- `f(a, b)` is a list of names and not a prototype: the types
	-- come from the declarations after it, and a call to the
	-- function is not checked against the count.  A name that is a
	-- typedef makes it a prototype instead, so what decides is
	-- whether anything in the list said a type.
	local bare = true

	repeat
		if self:accept("...") then
			variadic = true
			break
		end
		local said = self:declspec()
		local b = said or self.ty.i32

		if said then bare = false end
		self.vmdim = true
		local name, wrap = self:dcl(true)
		list[#list + 1] = self.ty.decay(wrap(b))
		if name then
			names = names or {}
			names[#list] = name
		end
	until not self:accept(",")
	-- `typedef void P; int f(P);` takes no parameters.  The keyword
	-- is read above, before any declarator; this is the same list
	-- said through a name.
	if #list == 1 and not names and not variadic and
	   list[1].kind == "void" then
		return {}, false
	end
	return list, variadic, names, bare and #list > 0 or nil
end

-- A declarator, read inside out.  Returns the name, which may be nil for an
-- abstract one, and a function that wraps the base type.
function P:dcl(abstract)
	-- Only the outermost array of a parameter decays to a pointer, so
	-- only that one may have a size the compiler cannot work out.
	local vm = self.vmdim
	self.vmdim = nil
	self.msabi = nil
	self.regparm = nil
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

		-- `long (c) = 3;` names c, even where c is a typedef.  A
		-- declarator that has to name something wins over a
		-- parameter list.  A parameter reads the other way round,
		-- which is why an abstract declarator keeps the type.
		if k == "*" or k == "(" or k == "[" or att or
		   (k == "name" and (not abstract or not self:istype())) then
			name, innerwrap = self:dcl(abstract)
			self:expect(")")
		else
			-- Read before the parameters: each of those is a
			-- declarator of its own and clears the flag.
			local ms = self.msabi or
				(self.declattrs and self.declattrs.ms_abi)
			local rp = self.regparm or
				(self.declattrs and self.declattrs.regparm)
			local ps, va, nm, np = self:params()

			self:expect(")")
			sfx[#sfx + 1] = function(t)
				local f = self.ty.func(t, ps, va, nm)

				f.noproto = np
				f.msabi = ms or nil
				f.regparm = rp
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
			local rp = self.regparm or
				(self.declattrs and self.declattrs.regparm)
			local ps, va, nm, np = self:params()

			self:expect(")")
			sfx[#sfx + 1] = function(t)
				local f = self.ty.func(t, ps, va, nm)

				f.noproto = np
				f.msabi = ms or nil
				f.regparm = rp
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

-- Whether a register can hold the whole of one of these.  A record,
-- an array or anything wider than a register lives in memory because
-- it has to; volatile and _Atomic live there because the program said
-- where they live.
local function pinnable(self, ty)
	if ty.volatile or ty.atomic then return false end
	if ty.kind == "array" or isrec(ty) or ty.kind == "func" then
		return false
	end
	if isflt(ty) or ty.complex then return false end
	if ty.size > self.t.ptrsize or self:iswide(ty) then return false end
	-- A frame slot is a word wide whatever sits in it, so a
	-- narrow value is read at whatever width the instruction
	-- wants and the bytes above it are ignored.  A register has
	-- one width, and an instruction that asks for four bytes of a
	-- one byte name is not an instruction.  So only the widths a
	-- template already names: a word, and the four bytes an int
	-- takes on the machines here.
	if ty.size ~= self.t.ptrsize and ty.size ~= 4 then return false end
	return true
end


-- `__attribute__((vector_size(n)))` makes a type n bytes wide, holding
-- as many of what it was written as will fit.  A vector is a value: it
-- is copied, passed and returned whole, and a subscript reaches an
-- element.  This compiler has no vector arithmetic; immintrin.h does
-- that in inline asm.
function P:vectored(ty, attrs)
	local n = attrs and attrs.vector_size

	if type(n) ~= "number" or n <= 0 or ty.kind == "array" or
	   ty.size == 0 or n % ty.size ~= 0 then
		return ty
	end
	-- A vector is aligned to its width, but no wider than the widest
	-- vector the machine loads in one go, which is 16 bytes on every
	-- target here.  An explicit `aligned` overrides it either way:
	-- that is how the unaligned spellings are said.
	return self.ty.vector(ty, n, type(attrs.aligned) == "number" and
		attrs.aligned or nil)
end

-- The character type of a string literal.  A prefix says how wide its
-- characters are.  u8 and no prefix are both plain char.
function P:strelem(pfx)
	if pfx == "L" then
		return self.shortwchar and self.ty.u16 or self.ty.i32
	end
	if pfx == "u" then return self.ty.u16 end
	if pfx == "U" then return self.ty.u32 end
	return self.plainchar
end

-- An argument wider than a register travels by address, as it does at
-- any other call.  The target reads the words back out of it and puts
-- them where the convention says, so this changes nothing the callee
-- sees.  A builtin that hands the runtime a double on a 32-bit machine
-- reaches this.
function P:widenargs(args)
	local wide, wflt

	for i, a in ipairs(args) do
		if a.ty and self:widepass(a.ty) then
			if not self.t.wideargs then
				self:err("a " .. (a.ty.name or "wide") ..
					" argument is not supported on " ..
					self.t.name)
			end
			wide = wide or {}
			wide[i] = a.ty.size
			if isflt(a.ty) then
				wflt = wflt or {}
				wflt[i] = true
			end
			args[i] = self:waddr(a)
		end
	end
	return wide, wflt
end

function P:rtcall(name, rty, args)
	-- A name of this unit's own answering for the runtime is built
	-- because this call names it, which nothing else here says.
	self.rtneed = self.rtneed or {}
	-- One the target writes out where it stands needs no body.
	local inline = self.t.winline and self.t.winline[name]

	if not inline then self.rtneed[name] = true end
	local g = self.globals and self.globals[name]

	if g and g.pending and not inline then g.wanted = true end
	local wide, wflt = self:widenargs(args)
	-- soft: the runtime takes bit patterns in ordinary registers, whatever
	-- the target's calling convention does with a float.
	local n = tree.node("CALL", rty,
		tree.name(self.ty.func(rty, {}, true), name), nil,
		{args = args, direct = true, soft = true, wide = wide,
		 wflt = wflt})
	if not self:widepass(rty) then return n end
	if not self.t.wideargs then
		self:err("a " .. (rty.name or "wide") ..
			" result is not supported on " .. self.t.name)
	end
	local slot = self:temp(rty)
	n.retslot, n.retty, n.ty = slot, rty, self.word
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
		-- A constant is 0 or 1 here and now.  `return true` in a
		-- body built where it was called is then a value rather
		-- than a comparison, and the caller's test of it settles.
		local kv = isflt(n.ty) and n.op == "CONST" and
			self:fvalue(n) or (not isflt(n.ty) and fold(n)) or nil

		if kv ~= nil then
			return tree.const(ty, kv ~= 0 and 1 or 0)
		end

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
	-- A constant converts here and now.  Left as a node it becomes
	-- a load into a register, a narrow, and a store; folded it is
	-- the store alone, which is what `p->ax = 0xe820` should be.
	if n.op == "CONST" and n.val and not n.rel and
	   (ty.kind == "int" or ty.kind == "uint") and
	   (n.ty.kind == "int" or n.ty.kind == "uint" or
	    n.ty.kind == "ptr") then
		return tree.const(ty, cutto(n.val, ty))
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
	-- An array whose bounds are not all numbers knows its size only
	-- where it was declared, and left it in a frame slot.  Stepping
	-- over one of those is a multiply by what the slot holds.
	if to.vsize then
		return tree.binary("MUL", n.ty, n,
			self:conv(tree.auto(self.uword, to.vsize), n.ty))
	end
	if to.size == 1 then return n end
	-- A constant index is a constant offset: `p[3]` is `p + 12`, and
	-- an add of a constant folds into the load's displacement.
	if n.op == "CONST" then return tree.const(n.ty, n.val * to.size) end
	return tree.binary("MUL", n.ty, n, tree.const(n.ty, to.size))
end

-- What sizeof answers with.  The name of a whole array whose bounds
-- are not all numbers carries the slot holding its size; an inner
-- level of one carries it on the type.
function P:sizeofexpr(e)
	if e.vlasize then return tree.auto(self.uword, e.vlasize) end
	if e.ty and e.ty.vsize then
		return tree.auto(self.uword, e.ty.vsize)
	end
	return tree.const(self.uword, e.ty.size)
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

-- A label or a string this unit made, which no other can replace.
function P:ownsym(sym)
	if sym:sub(1, 2) == ".L" then return true end
	local s = self.globals[sym]

	if s == nil then return false end
	-- Hidden and internal say no other object may replace this
	-- one, so the linker settles it and the table is not needed.
	if s.vis == "hidden" or s.vis == "internal" then return true end
	return s.static == true
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
	-- A compound literal: its stores, then the address of its slot.
	if e.op == "SEQ" and e.clit then
		local arms = {}

		for i = 1, #e.arms - 1 do arms[i] = e.arms[i] end
		arms[#e.arms] = self:addrof(e.arms[#e.arms])
		return tree.node("SEQ", arms[#e.arms].ty, nil, nil,
			{arms = arms})
	end
	-- Whoever holds the address may write through it.
	self:inlkill(e)
	-- A frame slot whose address escapes is one an overflow can be
	-- aimed at, which is what the stronger stack protector looks for.
	if e.op == "AUTO" then
		self.tookaddr = true
		-- Which slots an address has escaped from, so far.
		-- A body built where it was called runs before
		-- anything later in the caller, so a slot whose
		-- address is not out yet cannot be reached from
		-- inside one.
		-- The whole object escapes, not only the member named:
		-- `&list` reaches `list.prev`, and container_of gets from
		-- a member back to all of it.
		if e.off then
			local lo = e.off
			local hi = e.off + math.max(e.ty.size or 1, 1)

			for base, size in pairs(self.lobj or {}) do
				if base <= e.off and e.off < base + size then
					if base < lo then lo = base end
					if base + size > hi then
						hi = base + size
					end
				end
			end
			self.aoff = self.aoff or {}
			self.aoff[#self.aoff + 1] = {lo = lo, hi = hi}
		end
	end
	-- A local kept in a register has no address to take.  The scan
	-- that set the register aside refuses any name an `&` reaches,
	-- so arriving here means the scan and the parser disagree about
	-- what the tokens said, and the answer would be a pointer to a
	-- slot nothing writes.  Say so rather than hand one back.
	if e.pin then
		self:err("the address of `" ..
			 (self.slotname[e.off] or "?") ..
			 "', which is kept in a register")
	end
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

-- Whether an address has escaped from any part of the frame bytes
-- [off, off + size): a pointer to them may be written through.
function P:escaped(off, size)
	size = math.max(size or 1, 1)
	for _, r in ipairs(self.aoff or {}) do
		if off < r.hi and r.lo < off + size then return true end
	end
	return false
end

-- An array or a function used in an expression becomes a pointer.
function P:rvalue(n)
	-- A parameter of a body built where it was called, still holding
	-- what the caller wrote, and what the caller wrote is a
	-- constant.  Only here: a constant is a value and not an
	-- object, so a place that wants the parameter itself -- an
	-- address, an assignment -- must still get the slot.  An asm
	-- output comes through here too, only to decay an array, and
	-- `asmout` says so.
	if self.inl and not self.asmout and n.op == "AUTO" and
	   not n.bf and not n.pin and not n.hard and not n.vlasize then
		local a = self:inlsubst(n)
		local v = a and fold(a)

		-- A caller local whose address has not escaped cannot
		-- be reached from inside the body, so reading it there
		-- is reading what the caller wrote.  One load instead
		-- of a store and a load.
		if not v and a and a.op == "AUTO" and a.off and
		   not self:escaped(a.off, a.ty and a.ty.size) and not a.pin and
		   not a.hard and not a.vlasize and
		   a.ty and n.ty and a.ty.size == n.ty.size then
			local sl = self:inlslot(n.off)

			if sl then sl.nsub = (sl.nsub or 0) + 1 end
			-- The caller's slot, read at the parameter's
			-- type.  A conversion that needed no code left
			-- the caller's type on the node, and the body
			-- means its own: `GCObject *` and `GCUnion *`
			-- are the same eight bytes and not the same
			-- members.
			return tree.auto(n.ty, a.off)
		end
		if v then
			-- One read fewer that wants the slot.  When
			-- none are left the write to it is dead.
			local sl = self:inlslot(n.off)

			if sl then sl.nsub = (sl.nsub or 0) + 1 end
			return tree.const(n.ty, v)
		end
		-- A short expression over the caller's own locals and
		-- constants, `x + 1`, is worked out where it is read
		-- rather than stored and loaded back: nothing in the
		-- body can change what it reads.  It may stand wherever
		-- the parameter's value may, and nowhere the slot itself
		-- is wanted, which is what `rvalue` already keeps apart.
		-- The same width is not the same type: a conversion
		-- that needs no code leaves the caller's type on the
		-- node, and two pointers of one width do not have the
		-- same members.
		if a and self:plain(a, 3) and a.ty and n.ty and
		   a.ty.size == n.ty.size and a.ty.kind == n.ty.kind and
		   (a.ty.kind ~= "ptr" or a.ty.to == n.ty.to) then
			local sl = self:inlslot(n.off)

			if sl then sl.nsub = (sl.nsub or 0) + 1 end
			return retyped(a, n.ty)
		end
	end
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
		if self.holding then
			-- The entry, not the node: a tree node is handed
			-- back and used again long before this is read.
			local f = self.holding.fns

			if n.fn then f[#f + 1] = n.fn end
		else
			wantbody(n, self.dead)
		end
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

-- Whether a tree is a few arithmetic nodes over constants and the
-- caller's own unescaped locals, and so may be worked out again
-- wherever it is read.  `budget` is how many nodes it may have.
local PLAIN = {ADD = true, SUB = true, MUL = true, AND = true, OR = true,
	       XOR = true, SHL = true, SHR = true, NEG = true, NOT = true,
	       CVT = true}

function P:plain(n, budget)
	if n == nil or budget <= 0 then return false end
	if n.op == "CONST" then return not isflt(n.ty) end
	-- The address of a local or a global is a constant, whatever is
	-- done through it.
	if n.op == "ADDR" then
		local c = n.left

		return c ~= nil and (c.op == "NAME" or (c.op == "AUTO" and
			c.off ~= nil and not c.pin and not c.hard and
			not c.vlasize))
	end
	if n.op == "AUTO" then
		return n.off ~= nil and not self:escaped(n.off, n.ty.size) and
			not n.pin and not n.hard and not n.vlasize and
			not n.bf and not n.part
	end
	if not PLAIN[n.op] or isflt(n.ty) then return false end
	if n.left and not self:plain(n.left, budget - 1) then return false end
	if n.right and not self:plain(n.right, budget - 1) then return false end
	return true
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

	-- `(&v)->f` is `v.f`, which is what an array of one record
	-- decays to when it is written `ap->stk`.
	if arrow and base.op == "ADDR" and base.left and
	   base.left.op == "AUTO" and base.left.off and not base.left.pin and
	   not base.left.hard and not base.left.vlasize then
		base, arrow = base.left, false
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
	local n = self:named(addr, m.ty) or tree.unary("INDIR", m.ty, addr)
	n.bf = m.bits and m or nil
	return n
end

-- A place at a constant offset from a named object is the name with
-- the offset, on a machine whose instructions take one: `g.a[3]` is
-- `g+12`, and not the address of g worked out into a register and
-- read through.  Only where nothing goes through a table the loader
-- fills in.
function P:named(addr, ty)
	if not self.t.nameoff or self.pic then return nil end
	local sym, off = symoff(addr)

	if not sym then return nil end
	local n = tree.name(ty, sym)

	if off ~= 0 then n.off = off end
	return n
end

-- Bit-fields ------------------------------------------------------------
--
-- A bit-field is named by the lvalue of the unit that holds it, tagged
-- with where inside that unit it sits.  Reading one shifts it to the top
-- of a register and back down, which brings the sign with it; writing one
-- puts the unit back together around it.

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
		local chars = strchars(tk, ety)

		self.t.data.stringdef(self.sg, label, chars, ety.size)
		-- An array, so that sizeof sees the characters rather than
		-- a pointer.  Every other use decays through rvalue.
		local n = tree.name(self.ty.array(ety, #chars + 1), label)

		-- The characters travel with the node, so that a builtin
		-- handed two of them can answer without the library.
		if ety.size == 1 then n.str = tk.text end
		return n
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
				-- An undeclared name called as a function
				-- answers with an int, which is what C89
				-- says and is not the width of a word:
				-- the upper half of what the callee left
				-- is not part of the value, and comparing
				-- all of it reads whatever was there.  A
				-- name the library owns answers with what
				-- the library says.
				local rt = self:libret(lib or tk.text)

				s = {kind = "func", sym = lib or tk.text,
				     ty = self.ty.func(rt, {}, true)}
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
			return tree.const(s.ty or self.word, s.val)
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

				if slot then
					slot.nread = (slot.nread or 0) + 1
					break
				end
				fr = fr.up
			end
			if s.hard then
				local e = tree.auto(s.ty, s.off)

				e.hard = s.hard
				return e
			end
			if s.pin then return autoof(s) end
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
		-- The stores travel in the tree, as a statement
		-- expression's do: an operand that does not always run
		-- takes them with it.  linux's bio_for_each_bvec builds one
		-- on the right of an && that guards the read it makes.
		local saved = self.g.sink
		local blk = buf.new()
		local paused = self.g:pause()

		self.g.sink = blk
		self:initlocal(sym, ty)
		self.g.sink = saved
		self.g:resume(paused)
		local v = tree.auto(sym.ty, sym.off)
		local text = blk:text()

		if text == "" then return v end
		local n = tree.node("SEQ", sym.ty, nil, nil,
			{arms = {tree.node("TEXT", self.ty.void, nil, nil,
				{text = text}), v}})

		n.clit = true
		return n
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
	-- An old-style definition is not a prototype, however much the
	-- declarations after the parameter list say about the types.
	-- So a call to one is not checked against it: C says the
	-- argument count is nobody's business, and a program that
	-- passes more is passing more.
	local f = self.ty.func(ty.ret, params, ty.variadic, ty.pnames)

	f.noproto = ty.noproto
	f.msabi = ty.msabi
	f.regparm = ty.regparm
	return f
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

-- A constant `return` in an inlined body is a marker, not code.  A test
-- that branches on the expansion turns each marker into a jump to the
-- arm it picks; any other use gets the store and a jump to the end.
-- objtool follows each path, and a join where only one path ran `stac`
-- is reported as a return with user access open.
local nretmark = 0

function P:call(callee)
	-- `(&f)(x)`, cast or not, is a call to f.  static_call(f) comes
	-- out that way, and an indirect call leaves .noinstr.text.
	-- A cast to another function type is not peeled: the arguments
	-- are converted the way the cast says, not the way f says.
	local via = callee

	while via.op == "CVT" and via.ty.kind == "ptr" and via.left and
	      via.left.ty.kind == "ptr" and via.ty.to == via.left.ty.to do
		via = via.left
	end
	if via.op == "ADDR" and via.left and via.left.op == "NAME" and
	   via.left.ty.kind == "func" and not via.left.tls and
	   via.ty.to == via.left.ty and callee.ty.to == via.left.ty then
		callee = via.left
	end
	local direct = callee.op == "NAME" and callee.ty.kind == "func"
	local fty = callee.ty
	if not direct then
		callee = self:rvalue(callee)
		fty = callee.ty
	end
	if fty.kind == "ptr" then fty = fty.to end

	-- An argument's code is written where the call is, not where the
	-- argument was read, and a body built here writes its parameters
	-- in between.  So the slots an argument reached are kept until
	-- the call is done: otherwise a parameter lands on a slot the
	-- argument beside it still writes, and the write comes second.
	-- linux reads `__blk_mq_get_ctx(q, raw_smp_processor_id())`,
	-- where the second argument is a whole switch of its own.
	local ohi = self.hiwater

	self.hiwater = self.nlocals
	local args = {}
	if self.tok.kind ~= ")" then
		repeat
			args[#args + 1] = self:rvalue(self:assign())
		until not self:accept(",")
	end
	self:expect(")")
	local usedargs = self.hiwater

	self.hiwater = ohi and (ohi > usedargs and ohi or usedargs) or nil
	if usedargs > self.nlocals then self.nlocals = usedargs end
	self:keep()

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
			-- A complex parameter is a record here, but a
			-- real argument still has to become one.
			if args[i] and (not isrec(p) or
			   (p.complex and not args[i].ty.complex)) then
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
	local wflt

	for i, a in ipairs(args) do
		if self:widepass(a.ty) then
			if self:byparts(a.ty) then
				recs = recs or {}
				recs[i] = a.ty
			elseif self.t.wideargs then
				wide = wide or {}
				wide[i] = a.ty.size
				-- The address is a pointer, so the target
				-- cannot see what it points at.
				if isflt(a.ty) then
					wflt = wflt or {}
					wflt[i] = true
				end
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
		{args = args, direct = direct, wide = wide, wflt = wflt,
		 recs = recs,
		 msabi = fty.kind == "func" and fty.msabi or nil,
		 regparm = fty.kind == "func" and fty.regparm or nil,
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
	n.retslot, n.retty = slot, rty
	n.ty = self.word
	return tree.node("SEQ", rty, nil, nil,
		{arms = {n, tree.auto(rty, slot)}})
end

function P:postfix(e)
	while true do
		if self:accept("[") then
			local i = self:expression()
			self:expect("]")
			local oa = self.asmout

			self.asmout = nil
			-- A vector's elements are the array it holds.
			if e.ty.vector then e = self:member(e, "__v", false) end
			local p = self:arith("ADD", e, i)

			self.asmout = oa
			e = self:named(p, p.ty.to) or
				tree.unary("INDIR", p.ty.to, p)
		elseif self:accept(".") then
			e = self:member(e, self:expect("name").text, false)
		elseif self:accept("->") then
			local oa = self.asmout

			self.asmout = nil
			e = self:rvalue(e)
			self.asmout = oa
			e = self:member(e, self:expect("name").text, true)
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

	-- A literal is never negative; one that comes back that way ran
	-- past the signed range and wrapped, so only the widest unsigned
	-- type holds it.  0xffffffffffffffff is not an int.
	local function holds(t, x)
		if x < 0 then return t.size == 8 and t.kind == "uint" end
		if t.size == 4 then
			if t.kind == "uint" then
				return x <= 4294967295
			end
			return x <= 2147483647
		end
		return true
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
	if v < 0 then return T.u64 end
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
				if t.vsize then
					return tree.auto(self.uword, t.vsize)
				end
				return tree.const(self.uword, t.size)
			end
			local e = self:expression()
			self:expect(")")
			e = self:postfix(e)
			return self:sizeofexpr(e)
		end
		local e = self:unary()
		return self:sizeofexpr(e)
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
		-- A scalar and a vector of its size are the same bits,
		-- which go through a slot to change type.
		if (t.vector and not isrec(e.ty)) or
		   (e.ty.vector and not isrec(t)) then
			if t.size ~= e.ty.size then
				self:err("a vector cast has to keep the size")
			end
			if t.vector then
				local off = self:temp(t)

				return tree.node("SEQ", t, nil, nil, {arms = {
					tree.binary("ASGN", e.ty,
						tree.auto(e.ty, off), e),
					tree.auto(t, off)}})
			end
			return tree.unary("INDIR", t, self:conv(
				self:recaddr(e), self.ty.ptr(t)))
		end
		-- A cast to a record is a cast in name only, except for
		-- _Complex, where it converts each half and may build
		-- the pair from a real.
		if isrec(t) and not t.complex then
			-- One vector to another of its size keeps the bits.
			if t.vector and e.ty.vector then
				if t.size ~= e.ty.size then
					self:err("a vector cast has to keep " ..
						"the size")
				end
				e = tree.clone(e)
				e.ty = t
				return e
			end
			if isrec(e.ty) then
				e.ty = t
				return e
			end
			return self:tounion(t, e)
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
			return self:wunary("NEG", e, e.ty)
		end
		local ty = self:promote(e.ty)

		if e.op == "CONST" then return tree.const(ty, -e.val) end
		return tree.unary("NEG", ty, e)
	elseif k == "+" then
		self:adv()
		return self:unary()
	elseif k == "~" then
		self:adv()
		local e = self:rvalue(self:unary())
		-- GNU C: `~` on a complex value is its conjugate.
		if e.ty.complex then
			return self:cplxarith("CONJ", e)
		end
		if self:iswide(e.ty) then
			if e.op == "CONST" then
				return tree.const(e.ty, ~e.val)
			end
			return self:wunary("NOT", e, e.ty)
		end
		local ty = self:promote(e.ty)

		if e.op == "CONST" then return tree.const(ty, ~e.val) end
		return tree.unary("NOT", ty, e)
	elseif k == "!" then
		self:adv()
		return tree.unary("LNOT", self.ty.i32,
			self:test(self:unary()))
	elseif k == "*" then
		self:adv()
		-- The pointer is a value whatever the whole is used for:
		-- an asm output `*p` still reads p.
		local oa = self.asmout

		self.asmout = nil
		local e = self:rvalue(self:unary())

		self.asmout = oa
		if not isptr(e.ty) then self:err("not a pointer") end
		-- `*&x` is x.
		if e.op == "ADDR" and e.left and e.left.ty == e.ty.to and
		   (e.left.op == "AUTO" or e.left.op == "NAME") then
			return self:postfix(e.left)
		end
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
-- `(union u)x` is GNU's cast to a union: the answer is a union of
-- that type holding x in the member whose type it has.  A record
-- value needs an address, so the answer is a temporary.
function P:tounion(t, e)
	if t.kind ~= "union" then
		self:err("only a union may be cast to from a value")
		return e
	end
	local want = self.ty.decay(e.ty)
	local m

	for _, mem in ipairs(t.members or {}) do
		if not mem.bits and self.ty.same(mem.ty, want) then
			m = mem
			break
		end
	end
	if not m then
		self:err("no member of this union has that type")
		return e
	end
	local off = self:temp(t)
	local set = tree.binary("ASGN", m.ty,
		tree.auto(m.ty, off + m.off), self:conv(e, m.ty))

	return tree.node("SEQ", t, nil, nil,
		{arms = {set, tree.auto(t, off)}})
end

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

-- Inline forms ---------------------------------------------------------
--
-- A wide value is two words in memory, so most of what is done to one is
-- a short run of word-sized operations on its halves.  Writing them here
-- keeps a call, and a runtime to call, out of the object.  What is left
-- for the runtime is the multiply, the divide and the remainder.

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

-- Keep a value in a slot of our own, so the tree may read it twice.
function P:pin(e)
	local off = self:temp(e.ty)
	local slot = function() return tree.auto(e.ty, off) end

	return slot, self:assignto(slot(), e)
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

-- initializers ---------------------------------------------------------

-- inline assembly ------------------------------------------------------



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
-- Whether any bound of an array type is worked out at run time.  An
-- array with a number for its own bound is still one when the type
-- under it has none: `char a[3][w]` reserves as little as `char a[h][w]`
-- does until w is read.
local function isvla(ty)
	while ty.kind == "array" do
		if ty.vlen then return true end
		ty = ty.of
	end
	return false
end

-- The byte size of a type that cannot be measured until the
-- declaration is reached, worked out there and left in a frame slot.
-- Every array level from the inside out gets a slot of its own,
-- because stepping over one level scales by the size of the level
-- under it and that size is a run-time value too.
function P:vlasize(ty)
	if ty.kind ~= "array" then
		return tree.const(self.uword, ty.size)
	end
	-- Innermost first: `char f[h][w]` works w out before h, and the
	-- order among the bounds of one declaration is nobody's
	-- business.
	local under = self:vlasize(ty.of)
	local count

	if ty.vlen then
		count = self:conv(self:rvalue(ty.vexpr), self.uword)
	else
		count = tree.const(self.uword, ty.n or 0)
	end
	-- An ordinary array of an ordinary type is a number, and a
	-- number needs no slot.
	if not ty.vlen and under.op == "CONST" then
		return tree.const(self.uword, ty.size)
	end
	local off = self:alloc(self.uword)

	self.g:expr(self:assignto(tree.auto(self.uword, off),
		self:arith("MUL", count, under)), "eff")
	ty.vsize = off
	return tree.auto(self.uword, off)
end

function P:vladecl(name, ty, storage)
	if storage == "static" then
		self:err("a static variable length array is not supported")
	end
	if not self.fname then
		self:err("a variable length array must be inside a function")
	end
	if not self.t.alloca then
		self:err("a variable length array is not supported on " ..
			self.t.name)
	end
	-- What is under all the brackets has to be a type of a size,
	-- however many of the bounds are worked out here.
	local base = ty.of

	while base.kind == "array" do base = base.of end

	if base.size == 0 or base.incomplete then
		self:err("a variable length array of an incomplete type")
	end
	local el = ty.of
	local pt = self.ty.ptr(el)

	local bytes = self:vlasize(ty)
	local poff = self:alloc(pt)

	-- Every slot this declaration took has to outlive the statement
	-- it stands in, so the mark is raised after the last of them.
	self:keep()
	self.g:expr(self:assignto(tree.auto(pt, poff),
		tree.unary("ALLOCA", pt, bytes)), "eff")
	self:declare(name, {kind = "local", ty = ty, off = poff,
			    vla = ty.vsize, vlaty = pt})
	self:notebuf(ty)
end

function P:localdecl()
	local base, storage, _, only = self:declspec()
	local vol = self.sawvol

	-- `auto i = 3;` and `register j;` name an int: C said so before
	-- it said otherwise, and a word only a declaration may hold has
	-- already been read.
	if not base and only then base = self.ty.i32 end
	if not base then return false end
	-- A static in a block is an object like any other: what the
	-- declaration said about which section it belongs in holds here
	-- too.  A kernel writes `static struct q k __initdata = {...}`
	-- inside the function that registers it.
	local attrs = self.declattrs or {}
	local asked = self.alignas
	local tls = self.tls
	if self:accept(";") then return true end
	-- What the specifiers said goes for every declarator; what
	-- follows one is that declarator`s own.  `for (T a __cleanup(f)
	-- = x, *b = 0; ...)` cleans up a and not b.
	local basecl = self.declattrs and self.declattrs.cleanup

	repeat
		self.asmname = nil
		if self.declattrs then self.declattrs.cleanup = basecl end
		local name, wrap = self:dcl(false)
		-- Read it now: the initializer may build a body where it
		-- stands, and that body`s own declarations write here.
		local mycl = self.declattrs and self.declattrs.cleanup
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
			self:keep()
			self.g:expr(self:assignto(autoof(s), e),
				"eff")
			self:notebuf(ty)
			goto nextdecl
		end
		-- A bound worked out at run time: the room comes off the
		-- stack where the declaration stands, and the name is the
		-- pointer to it.
		if isvla(ty) and storage ~= "extern" and
		   storage ~= "typedef" and ty.kind ~= "func" then
			self:vladecl(name, ty, storage)
			goto nextdecl
		end
		-- `char (*p)[w]` is an ordinary pointer, but stepping it
		-- scales by a size only this declaration knows, so the
		-- size is worked out here whether or not p is used.
		do
			local at = ty

			while at and at.kind == "ptr" do at = at.to end
			if at and at.kind == "array" and isvla(at) and
			   storage ~= "extern" and storage ~= "typedef" then
				self:vlasize(at)
				self:keep()
			end
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
			-- A body built where it was called may be built
			-- more than once, and the object inside it is
			-- one object however many copies there are.  Its
			-- name comes from the body and the place in it,
			-- so every copy names the same one and it is
			-- written out once.  linux spells the operand of
			-- the buffer-clearing `verw` that way, inside a
			-- body it says must always be built where it was
			-- called.
			local rec = self.lx and self.lx.rec
			local lbl

			if rec then
				if not rec.sid then
					rec.sid = self.nstr
					self.nstr = self.nstr + 1
				end
				lbl = ("%s.s%d_%d"):format(".Lstatic",
					rec.sid, self.lx.i)
			else
				lbl = ".Lstatic" .. self.nstr
				self.nstr = self.nstr + 1
			end
			-- The same object written a second time goes
			-- nowhere: one copy of the body is enough.
			local odg = self.dg

			self.statmade = self.statmade or {}
			if self.statmade[lbl] then self.dg = buf.new() end
			self.statmade[lbl] = true
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
				self.t.data.endobj(self.dg, lbl)
			end
			self.dg = odg
			d.ty = ty
		else
			-- The frame slot waits for the initializer, which is
			-- what gives an array without a bound its size.
			local s = self:declare(name, {kind = "local", ty = ty,
						      hard = hard})

			-- A name the scan set a register aside for, whose
			-- type turns out to be one a register can hold.
			-- It still gets a frame slot, which nothing reads:
			-- the slot keeps every offset unique and keeps
			-- the rest of the compiler from meeting a local
			-- without one.
			-- `cleanup` hands the object's address to the
			-- function it names when the scope ends, and the
			-- `&` is the compiler's rather than the
			-- program's, so no scan over the tokens can see
			-- it.  linux frees a pointer that way all over.
			-- A volatile object lives in memory, and a
			-- number written to it is not known to stay.
			self.allocvol = vol
			if self.pins and self.pins[name] and not hard and
			   storage ~= "static" and not tls and not mycl and
			   not vol and pinnable(self, ty) then
				s.pin = self.pins[name]
				self.pins[name] = nil
				self.pinused[s.pin] = true
				s.off = s.off or self:alloc(ty)
				self.slotname[s.off] = name
			end
			if self:accept("=") then
				if self.tok.kind == "{" or
				   (ty.kind == "array" and
				    self.tok.kind == "str" and
				    ty.of.size ==
				    self:strelem(self.tok.pfx).size) then
					self:initlocal(s, ty)
				else
					-- The object stands before its
					-- initializer runs, so `unsigned
					-- long x = x;` reads this slot and
					-- not one further out.  That is
					-- how a kernel says to leave a
					-- register variable alone.
					s.off = self:alloc(ty)
					self.slotname[s.off] = name
					self:keep()

					local e = self:assign()

					self.g:expr(self:assignto(
						autoof(s), e), "eff")
				end
				if type(mycl) == "string" then
					self:notecleanup(s.off, ty, mycl)
				end
			else
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
					s.ty = ty
				end
				s.off = self:alloc(ty)
			end
			self.slotname[s.off] = name
			self.allocvol = nil
			self:keep()
			self:notebuf(s.ty or ty)
		end
		::nextdecl::
	until not self:accept(",")
	self:expect(";")
	return true
end

-- A value that reads nothing and means the same wherever it is used.
local function fixedval(n)
	while n.op == "CVT" do n = n.left end
	if n.op == "CONST" then return true end
	if n.op == "NAME" and n.ty.kind == "func" then return true end
	return n.op == "ADDR" and n.left and n.left.op == "NAME" and
		not n.left.tls
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
	local paused = self.g:pause()

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
		if not self.dead then
			self:runcleanups(#self.cleanups - 1)
		end
		self.g.sink = saved
		self.g:resume(paused)
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
	-- A constant or a global's address is the same outside the block,
	-- so it travels as it is.  linux's static_call(f) is
	-- `({ ...; &__SCT__f; })`, which then is a direct call.
	if fixedval(val) then return done(val) end
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

-- `__attribute__((cleanup(f)))` on a block-scope object says to call
-- `f(&object)` when the object goes out of scope.  The kernel builds
-- `guard(mutex)` and `__free()` on it, so a compiler that reads the
-- attribute and does nothing takes a lock and never gives it back.
function P:notecleanup(off, ty, fn)
	local sc = self.cleanups[#self.cleanups]

	if not sc then
		self:err("cleanup outside a block")
		return
	end
	sc[#sc + 1] = {off = off, ty = ty, fn = fn}
	-- The call comes at the end of the block, which is after the
	-- point where a definition put aside decides whether anything
	-- wanted it.  Say so now.
	local sym = self:find(fn)

	if sym and sym.kind == "func" then
		wantbody({fn = sym}, false)
	end
end

-- Whether anything above `depth` has something to run.
function P:hascleanup(depth)
	for i = #self.cleanups, (depth or 0) + 1, -1 do
		if #self.cleanups[i] > 0 then return true end
	end
	return false
end

-- Run what the scopes above `depth` left, innermost scope first and,
-- within a scope, in reverse of the order the objects were declared.
-- The objects stay where they are: leaving a scope is not the end of
-- the frame, and an outer scope may still run its own.
function P:runcleanups(depth)
	local g = self.g

	for i = #self.cleanups, (depth or 0) + 1, -1 do
		local sc = self.cleanups[i]

		for k = #sc, 1, -1 do
			local c = sc[k]
			local sym = self:find(c.fn)

			if not sym or sym.kind ~= "func" then
				self:err("no function " .. c.fn ..
					" to clean up with")
				return
			end
			local m = tree.mark()
			local callee = tree.name(sym.ty, sym.sym)

			callee.fn = sym
			local pt = self.ty.ptr(c.ty)
			local arg = tree.unary("ADDR", pt,
				tree.auto(c.ty, c.off))

			g:expr(tree.node("CALL",
				sym.ty.ret or self.ty.void, callee, nil,
				{args = {arg}, direct = true}), "eff")
			tree.release(m)
		end
	end
end

function P:block()
	self:expect("{")
	self.bdepth = (self.bdepth or 0) + 1
	self:push(true)
	local st = #self.stmarks

	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		self.direct = true
		self:stmt()
		-- A temporary dies with the statement that made it, so
		-- the next statement takes its slot back.  Named objects
		-- raised the mark and keep theirs.
		local keep = self.stmarks[st] or self.nlocals

		if self.x87floor and keep < self.x87floor then
			keep = self.x87floor
		end
		if keep < self.nlocals then self.nlocals = keep end
	end
	if not self.dead then self:runcleanups(#self.cleanups - 1) end
	self:expect("}")
	self.bdepth = self.bdepth - 1
	self:pop()
end

function P:userlabel(name)
	-- The dot is what keeps the two halves apart.  With an
	-- underscore between them, a label `pmp_fail` in
	-- `sata_pmp_eh_recover` and a label `fail` in
	-- `sata_pmp_eh_recover_pmp` spell the same name, and a goto in
	-- one function lands in the other.
	return self.labelmap[name] or
		(".Lu_" .. self.fname .. "." .. name)
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

		if s then
			return retyped(tree.const(s.kty, s.konst), n.ty)
		end
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
-- Take one statement's tokens off the input without parsing it, for a
-- look before it is read for real.  A block runs to its closing brace,
-- an if takes its else, a do its while, and anything else runs to the
-- semicolon that ends it.
function P:takestmt()
	local f, n = {}, 0
	local line, file = self.tok.line, self.tok.file

	local function take()
		local t = self.tok

		if t.kind == "eof" then self:err("unterminated statement") end
		f[n + 1], f[n + 2], f[n + 3] = t.kind, t.text, t.val
		f[n + 4], f[n + 5], f[n + 6] = t.line, t.file, t.pfx
		n = n + NFIELD
		self:adv()
	end
	local function group(open, close)
		local depth = 0

		repeat
			local k = self.tok.kind

			if k == open then depth = depth + 1
			elseif k == close then depth = depth - 1 end
			take()
		until depth == 0
	end
	local function stmt()
		local k = self.tok.kind

		if k == "{" then
			group("{", "}")
		elseif k == "while" or k == "for" or k == "switch" then
			take()
			group("(", ")")
			stmt()
		elseif k == "if" then
			take()
			group("(", ")")
			stmt()
			if self.tok.kind == "else" then take() stmt() end
		elseif k == "do" then
			take()
			stmt()
			take()			-- while
			group("(", ")")
			take()			-- ;
		elseif k == "case" or k == "default" then
			repeat take() until f[n - NFIELD + 1] == ":"
			stmt()
		elseif k == "name" and self:peek().kind == ":" then
			take()
			take()
			stmt()
		else
			local depth = 0

			while true do
				local kk = self.tok.kind

				if kk == "(" or kk == "{" or kk == "[" then
					depth = depth + 1
				elseif kk == ")" or kk == "}" or kk == "]" then
					depth = depth - 1
				end
				take()
				if kk == ";" and depth == 0 then break end
			end
		end
	end
	stmt()
	return {f = f, n = n, line = line, file = file}
end

-- Whether a statement taken off the input holds a label a goto could
-- land on, or a case.  A name and a colon is a label where a statement
-- can begin; after a `?` it is the other arm of a conditional.
local LABELAFTER = {[";"] = true, ["{"] = true, ["}"] = true,
		   [":"] = true, [")"] = true, ["else"] = true}

local function haslabel(f, n)
	for i = 1, n, NFIELD do
		local k = f[i]

		if k == "case" or k == "default" then return true end
		if k == "name" and i + NFIELD <= n and f[i + NFIELD] == ":" then
			local before = i > NFIELD and f[i - NFIELD] or ";"

			if LABELAFTER[before] then return true end
		end
	end
	return false
end

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
	-- A loop nothing reaches from above may still be entered by a
	-- goto to a label inside it, and then the whole body is reached
	-- again through the loop's own back edge: linux's hashlen_string
	-- jumps into its do-while.  So the loop is read ahead, and one
	-- that holds a label is built as live code.
	if k == "while" or k == "do" or k == "for" then
		local rec = self:takestmt()

		if haslabel(rec.f, rec.n) then
			self.dead = false
			self.revived = self.revived + 1
			self:replay(rec, P.stmt1)
			return
		end
		local omark = self.deadmark

		self.deadmark = self.revived
		self:replay(rec, P.stmt1)
		self.deadmark = omark
		return
	end
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
	-- Whether a block holds this statement itself, rather than an
	-- if, a loop or a label: only such a statement runs whenever
	-- the block does.
	local direct = self.direct

	self.direct = false

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

			if not dthen then g:jump(lend) end
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
		if not self.dead then g:jump(ltop) end
		g:putlabel(lbrk)
		-- A loop whose test never fails is left only by a break.
		self:setdead(always and not used)
		return
	elseif k == "do" then
		self:adv()
		local ltop, lcont, lbrk = g:newlabel(), g:newlabel(), g:newlabel()
		g:putlabel(ltop)
		local used, cused = self:loop(lcont, lbrk, self:donce())
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
		g:jump(lcond)
		self.loopdepth = self.loopdepth - 1
		g:putlabel(lbrk)
		-- A `for (;;)` with no test is left only by a break.
		self:setdead(notest and not used)
		-- The first clause may declare something with a cleanup,
		-- which is what `scoped_guard` is: the loop turns once
		-- and the destructor runs where it leaves, whether it
		-- left by the test or by a break.
		if not self.dead then
			self:runcleanups(#self.cleanups - 1)
		end
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
		local obrkd = self.brkdepth

		self.brk = lbrk
		self.brkdepth = #self.cleanups
		-- A break in here leaves the switch, not a loop around it.
		local obused = self.brkused

		self.brkused = false
		g:jump(ldisp)
		-- Nothing falls into the body: the dispatch jumps to a
		-- case label, so what a program writes before the first
		-- one is unreachable.
		self.dead = true
		self:pushregion()
		self:stmt()
		self:popregion()
		-- With a default, no break and a body that does not run
		-- off its end, every way through leaves some other way:
		-- `return 0;` after a switch whose arms all return is
		-- code nothing reaches, and objtool says so.
		local closed = self.dead and self.sw.deflab ~= nil and
			not self.brkused

		self.brkused = obused
		if not self.dead then g:jump(lbrk) end
		self:setdead(false)

		-- The dispatch goes after the body, because the case labels
		-- are only known once it has been read.
		g:putlabel(ldisp)
		if wasdead then g:hush() end
		for _, c in ipairs(self.sw.cases) do
			local test

			if c.hi == c.val then
				test = tree.binary("EQ", self.word,
					tree.auto(self.word, slot),
					tree.const(self.word, c.val))
			else
				-- A range is one unsigned compare: how
				-- far past the low end the value sits,
				-- against how wide the range is.
				test = tree.binary("LE", self.word,
					tree.binary("SUB", self.uword,
						tree.auto(self.uword, slot),
						tree.const(self.uword,
							c.val)),
					tree.const(self.uword, c.hi - c.val))
			end
			g:cond(test, c.label, true, 0)
			tree.release(m)
		end
		g:jump(self.sw.deflab or lbrk)
		if wasdead then g:unhush() end
		g:putlabel(lbrk)
		self:setdead(closed)
		self.sw, self.brk = osw, obrk
		self.brkdepth = obrkd
		return
	elseif k == "case" then
		self:adv()
		local v = self:constexpr()
		-- GNU case ranges: one label, every value in between.
		local hi = v
		if self:accept("...") then hi = self:constexpr() end
		self:expect(":")
		if not self.sw then self:err("case outside a switch") end
		if hi < v then self:err("case range runs backwards") end
		local l = g:newlabel()

		self.sw.cases[#self.sw.cases + 1] = {val = v, hi = hi,
						     label = l}
		g:putlabel(l)
		self:inlclear(self.sw.at)
		tree.release(m)
		-- The label always goes out, because the dispatch names
		-- it; only the arm behind it is left uncompiled.  Once
		-- the matching arm has been reached the ones after it
		-- are reachable by falling through, so a label that does
		-- not match leaves the run as it stands.
		-- The dispatch jumps to the one that matches, so that
		-- arm is where the run resumes.  An arm the dispatch
		-- does not jump to is still reached by falling into it
		-- from the arm above, so the run stands as it was: an
		-- arm before the match has nothing above it and stays
		-- out of reach, and one after it is reachable exactly
		-- when the match did not break.
		if self.sw.konst and self.sw.konst >= v and
		   self.sw.konst <= hi then
			self.dead, self.sw.hit = self.sw.dead, true
			if not self.sw.dead then
				self.revived = self.revived + 1
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
		-- The dispatch comes here only when no case matched.
		-- When one did, this arm is still reached by falling
		-- into it from the arm above -- `case 2: x; default: y;`
		-- runs both -- so the run stands as it was rather than
		-- ending here.  Saying it ended here left the arm
		-- uncompiled and the fall-through landing on the
		-- dispatch, which jumped back to it for ever.
		if self.sw.konst and not self.sw.hit and not self.sw.dead
		then
			self.dead = false
			self.revived = self.revived + 1
		end
		return self:stmt()
	elseif k == "goto" then
		self:adv()
		-- A jump out of a block runs what that block left, and
		-- where the label stands says which blocks those are.
		--
		-- A body built where it was called brought its own
		-- labels with it, so a jump inside one leaves none of
		-- the scopes around the call.
		--
		-- A jump back to a label already read knows the depth it
		-- stood at.  A jump forward does not, and this compiler
		-- will not guess: skipping a destructor quietly is worse
		-- than saying so.
		local base = self.inlbase or 0

		if self:hascleanup(base) then
			local nm = self.tok.kind == "name" and self.tok.text
			local td = nm and (self.labelbd or {})[nm]

			if not nm then
				self:err("a computed goto out of a scope " ..
					"with a cleanup is not supported")
			elseif not td then
				self:err("a goto to a label this body does " ..
					"not have")
			else
				local keep = #self.cleanups

				while keep > base and
				      (self.cleanbd[keep] or 0) > td do
					keep = keep - 1
				end
				self:runcleanups(keep)
			end
		end
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
		g:jump(self:userlabel(name))
		self.dead = true
	elseif k == "return" then
		self:adv()
		-- A return in a body built where it was called leaves
		-- that body, not the function it was built into, so it
		-- runs what the expansion left and nothing older.
		local clbase = self.inlbase or 0
		local ranclean = false
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
			--
			-- A return nothing can reach says nothing about
			-- what the expansion is worth.  A kernel writes
			-- `if (!IS_ENABLED(X)) return false;` and then a
			-- real answer below it, and with X off the second
			-- one is not there.
			if not wasdead then
				r.n = r.n + 1
				r.konst = r.n == 1 and settle(
					self:unseq(self:subkonst(e))) or nil
				r.mask = r.n == 1 and bitsof(e) or nil
			end
			-- The one return that ends the body, held by its
			-- outermost block, is the last thing the body does:
			-- its expression is the expansion's value, worked
			-- out where the caller wants it, and the slot is
			-- never written.
			local ke = self:subkonst(e)

			if not wasdead and r.n == 1 and direct and
			   self.bdepth == 1 and self.tok.kind == ";" and
			   self:peek().kind == "}" and
			   not self:hascleanup(clbase) then
				r.value = e
				r.plain = true
			elseif ke.op == "CONST" and math.type(ke.val) ==
			       "integer" then
				-- The store is kept aside for the reader
				-- that wants the value.  The jump that
				-- follows is kept the same way below.
				local sv, one = g.sink, buf.new()

				g.sink = one
				g:expr(self:assignto(tree.auto(r.ty, r.off),
						     e), "eff")
				g.sink = sv
				nretmark = nretmark + 1
				r.marks = r.marks or {}
				r.marks[nretmark] = {k = ke.val,
						     store = one:text()}
				g.retmarks = g.retmarks or {}
				g.retmarks[nretmark] = r.marks[nretmark]
				r.pend = nretmark
				g:write(("\1%dA\1"):format(nretmark))
			else
				r.plain = true
				g:expr(self:assignto(tree.auto(r.ty, r.off),
						     e), "eff")
			end
		elseif self.tok.kind ~= ";" and self.recret then
			local e = self:rvalue(self:expression())
			local r = self.recret
			local dst

			-- A real value returned as a complex one.
			if r.ty.complex and not e.ty.complex then
				e = self:conv(e, r.ty)
			end

			-- A record that goes back through the caller's
			-- pointer is written there from here, on a target
			-- that says so, rather than into a slot of ours
			-- that the epilogue copies out again.
			if r.ptr and self.t.retdirect then
				dst = tree.auto(self.ty.ptr(e.ty), r.ptr)
				r.direct = true
			else
				dst = tree.unary("ADDR", self.ty.ptr(e.ty),
					tree.auto(e.ty, r.off))
			end
			g:expr(tree.node("COPY", e.ty, dst, self:recaddr(e),
				{val = r.size}), "eff", 0)
		elseif self.tok.kind ~= ";" then
			local e = self:conv(self:rvalue(self:expression()),
				self.rty)

			if self:widepass(self.rty) then
				if self:hascleanup(clbase) then
					self:err("a wide result with a " ..
						"cleanup is not supported")
				end
				e = self:waddr(e)
			elseif self:hascleanup(clbase) then
				-- The value is worked out first and the
				-- destructors run after, and one of them
				-- would write over the register the value
				-- sits in.  Park it in a slot.
				local slot = self:temp(self.rty)

				g:expr(self:assignto(
					tree.auto(self.rty, slot), e), "eff")
				self:runcleanups(clbase)
				e = tree.auto(self.rty, slot)
				ranclean = true
			end
			g:expr(e, "reg", 0)
		end
		if not ranclean then self:runcleanups(clbase) end
		self:expect(";")
		local ir = self.inlres

		if ir and ir.pend then
			local sv, one = g.sink, buf.new()

			g.sink = one
			g:jump(self.endlabel)
			g.sink = sv
			ir.marks[ir.pend].jump = one:text()
			g:write(("\1%dB\1"):format(ir.pend))
			ir.pend = nil
		else
			g:jump(self.endlabel)
		end
		self.retused = true
		self.dead = true
	elseif k == "break" then
		self:adv()
		self:expect(";")
		if not self.brk then self:err("break outside a loop") end
		self:runcleanups(self.brkdepth)
		g:jump(self.brk)
		self.brkused = true
		self.dead = true
	elseif k == "continue" then
		self:adv()
		self:expect(";")
		if not self.cont then self:err("continue outside a loop") end
		self:runcleanups(self.contdepth)
		g:jump(self.cont)
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
-- `do { ... } while (0)` runs once, so what a slot held before it is
-- still what it holds inside.  A kernel wraps nearly every statement
-- macro in one, and reads the flags of a bug table entry through two
-- of them.  The body has to be a block: then the `while` that follows
-- the brace it closes is the one that belongs to this `do`.
function P:donce()
	local lx = self.lx

	if not lx or not lx.f or not self.tok or self.tok.kind ~= "{" then
		return false
	end
	local f, n, i, d = lx.f, lx.n, lx.i, 1

	while i <= n do
		if f[i] == "{" then
			d = d + 1
		elseif f[i] == "}" then
			d = d - 1
			if d == 0 then
				local j = i + NFIELD

				return f[j] == "while" and
					f[j + NFIELD] == "(" and
					f[j + 2 * NFIELD] == "num" and
					f[j + 2 * NFIELD + 2] == 0 and
					f[j + 3 * NFIELD] == ")"
			end
		end
		i = i + NFIELD
	end
	return false
end

function P:loop(cont, brk, once)
	local oc, ob = self.cont, self.brk
	local ou, oq = self.brkused, self.contused

	local od, oe = self.contdepth, self.brkdepth

	self.cont, self.brk = cont, brk
	self.contdepth, self.brkdepth = #self.cleanups, #self.cleanups
	self.brkused, self.contused = false, false
	-- A slot read in a loop may have been written on an earlier turn
	-- of it, however the text reads, so what it held before the loop
	-- says nothing inside.
	if not once then self.loopdepth = self.loopdepth + 1 end
	self:pushregion()
	self:stmt()
	self:popregion()
	if not once then self.loopdepth = self.loopdepth - 1 end
	local used, cused = self.brkused, self.contused

	self.cont, self.brk = oc, ob
	self.contdepth, self.brkdepth = od, oe
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
	self.fobjs = self.t.compact and {} or nil
	self.volat, self.allocvol = nil, nil
	self.stmarks = {}
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
	-- Where each label of this body sits, for a goto that has to run
	-- what the scopes it leaves left behind.
	self.x87at, self.x87floor = nil, nil
	-- Which offsets this function may keep in a register, and
	-- which are part of something bigger.  Both start again with
	-- every function, because a slot is reused.
	self.irok, self.irno = {}, {}
	self.aoff, self.lobj = nil, nil
	-- Parameter slots that arrive in a register, by offset.
	self.argslot = {}
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
	local nfltreg = self:vaflt()
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
			       off = self:alloc(ty.ret), ty = ty.ret}
		if not cls then self.recret.ptr = self:temp() end
	end
	local shape = {}
	for i, prm in ipairs(ty.params) do
		shape[i] = {
			-- A machine whose floating point never travels in
			-- an integer register says so the way the extended
			-- type does: always in memory.
			x87 = (prm.x87 or (self.t.fltstack and isflt(prm)))
			      or nil,
			flt = isflt(prm) and not prm.x87 and
			      not self:widepass(prm),
			rec = (isrec(prm) or self:byparts(prm)) and prm
			      or nil,
			size = prm.size}
	end
	-- A convention that sends every argument of a variadic function
	-- to the stack has to hear that this one is variadic.
	local hidden = self.t.hiddenarg and self.recret and
		not self.recret.cls
	local slots, gp, fp, stk = md.classify(self.t, shape,
		self.t.varstack and ty.variadic and #ty.params or nil,
		hidden, ty.regparm)
	-- Whether the caller handed the record pointer over in a
	-- register, which decides whether the callee takes it off the
	-- stack on the way back.
	if hidden then
		self.recret.inreg = (ty.regparm or self.t.nargreg) > 0
			or nil
	end
	local pnames = ty.pnames
	for i, prm in ipairs(ty.params) do
		if isrec(prm) and not self.t.recabi then
			self:err("a struct or union parameter is not " ..
				"supported on " .. self.t.name)
		end
		if slots[i].stk and not slots[i].reg and
		   not slots[i].pieces and self.t.argsinplace then
			-- What the caller left on its own stack is the
			-- callee's to keep, so it is read where it lies
			-- rather than copied into the frame.
			slots[i].off = self.t.stackargs +
				slots[i].stk * self.t.ptrsize
			slots[i].inplace = true
		else
			slots[i].off = self:alloc(prm)
		end
		-- Which register this parameter arrives in, so that a
		-- register given to it can be filled from there rather
		-- than from the slot the prologue would have spilled
		-- it to.
		if slots[i].reg and not slots[i].pieces and
		   (slots[i].words or 1) == 1 then
			self.argslot[slots[i].off] = slots[i]
		end
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
		local n = (self.t.varstack and 0 or self.t.nargreg) + nfltreg
		-- A System V floating point slot is two words wide.
		if self.t.vaabi == "sysv" then
			n = self.t.nargreg + nfltreg * 2
		end
		if self.t.vastkslot then n = n + 1 end
		for _ = 1, n do
			last = self:alloc(self.word)
			first = first or last
		end
		-- The save area is walked as one piece.
		if self.fobjs and n > 0 then
			local o = self.fobjs

			o[#o + 1] = math.min(first, last)
			o[#o + 1] = n
			o[#o + 1] = 9
		end
		-- A machine with no argument registers saves none of them,
		-- and the walker reads the caller's stack words instead.
		self.vabase = first and math.min(first, last) or 0
	end
	-- What the body writes, and where, so that a label knows which
	-- slots it has to forget.  A body already read into tokens is
	-- scanned where it stands; one still on the input is taken off
	-- it first, which costs a copy of the tokens and saves a pass
	-- over everything the compiler would otherwise give up on.
	local owrites = self.writes

	-- Keep the whole function rather than writing it out as it is
	-- read, so that a pass over all of it can run before anything
	-- is emitted.  Off unless asked for: the record is proved by
	-- the output being the same byte for byte, and until the pass
	-- that needs it exists it is only a cost.
	local ircap = tonumber(sys.getenv("MCC_IR") or "") or 0
	local recording = false
	local onopin = self.nopin

	self.bdepth = 0
	if self.lx.f then
		self:choosepins(self.lx)
		self.writes = scanwrites(self.lx.f, self.lx.n)
		-- The opening brace is the token in hand, so the scan
		-- starts one inside it.
		self.labelbd = scanlabels(self.lx.f, self.lx.n, self.lx.i, 1)
		self:block()
	else
		local rec = self:capture()

		-- A body this big is written straight out: the record
		-- would not fit the memory this compiler is allowed.
		-- The count is of tokens, which stands in for nodes
		-- well enough and is known before anything is built.
		if ircap > 0 and rec.n <= ircap then
			recording = true
			tree.hold(true)
			self.g:startrec()
			-- The older pinning reads the tokens and counts
			-- mentions before anything is parsed; the
			-- allocator over the record counts the real
			-- uses and knows where they are.  Both cannot
			-- have the registers, and the one that knows
			-- more should.
			self.nopin = true
		end
		self:choosepins(rec)
		self.writes = scanwrites(rec.f, rec.n)
		self.labelbd = scanlabels(rec.f, rec.n, 1, 0)
		self:replay(rec, P.block)
	end
	if recording then
		-- Decide which locals live in a register before any of
		-- the function is written out.  Everything this needs
		-- -- the blocks, what is live where, what meets a call
		-- -- can only be known now that the whole body is in
		-- hand, which is what the record is for.
		local rec = self.g.rec
		local entrycopy

		local only = sys.getenv("MCC_IRFN")

		if self.t.freeregs and #self.t.freeregs > 0 and
		   (not only or only == name) then
			for off in pairs(self.irno) do self.irok[off] = nil end
			local blocks = ir.blocks(rec)
			local info, crosses = ir.liveness(rec, blocks)

			-- A register the ABI asks the callee to give
			-- back holds its value over a call, so meeting
			-- one is no reason to refuse the register.
			if self.t.freesaved then crosses = {} end
			local ok = ir.eligible(rec, self.t)

			for off in pairs(ok) do
				if not self.irok[off] then ok[off] = nil end
			end

			local pin = ir.colour(rec, blocks, info, crosses,
					      ok, self.t.freeregs, self.t)

			ir.mark(rec, pin)
			-- A slot live on the way in was filled by the
			-- prologue, which is not in the record, so the
			-- register it now lives in has to be filled
			-- once at the top of the body.  That is one
			-- instruction against every read of a
			-- parameter, which is most of what a small
			-- function reads.
			--
			-- Held until the record is put down: written
			-- here they would go into the record, which is
			-- to say after the body rather than before it.
			local entry = blocks[1] and
				info[blocks[1]].livein or {}

			entrycopy = {}
			for off, reg in pairs(pin) do
				if entry[off] then
					local t = self.irok[off]
					local dst = tree.auto(t, off)
					local a = self.argslot[off]

					if a then
						-- It arrives in a register
						-- of the calling convention,
						-- which is numbered its own
						-- way and may not even be
						-- one an expression can be
						-- given.  So the prologue
						-- moves it, where both
						-- names are in hand, and
						-- there is no copy here at
						-- all.
						a.into = reg
					else
						dst.pin = reg
						entrycopy[#entrycopy + 1] =
							tree.node("ASGN", t,
								dst,
								tree.auto(t,
									off))
					end
				end
			end
		end
		local played = self.g:endrec()

		self.playing = true
		for _, e in ipairs(entrycopy or {}) do
			self.g:expr(e, "eff")
		end
		self.g:playback(played)
		self.playing = nil
		tree.hold(false)
	end
	self.writes = owrites
	self.nopin = onopin
	self:pop()
	-- Nothing comes back from a body that ended with nothing
	-- reachable and never returned.  A validator that walks the
	-- code reads the epilogue as an instruction nothing reaches.
	local noway = self.dead and not self.retused

	self.g:putlabel(self.endlabel)
	local frame = self.t.frame(self.maxlocals)
	if sys.getenv("MEM") then
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
	local whole = (self.peep or self.fobjs) and buf.new() or saved
	local guard = self.guard and self:wantguard() and
		{off = self.guard, name = name} or nil

	self.g.sink = whole
	-- The body is written before the prologue, so a target that
	-- wants to know which registers it touched can read it.
	self.g.body = body
	-- The registers this body kept a local in, and where the
	-- prologue puts the caller's copy of each.
	if self.pinused then
		local keep = {}

		for r in pairs(self.pinused) do
			keep[#keep + 1] = {reg = r, off = self.pinslot[r]}
		end
		table.sort(keep, function(a, b) return a.reg < b.reg end)
		self.g.pinsave = #keep > 0 and keep or nil
	else
		self.g.pinsave = nil
	end
	-- What the name is.  A validator that walks the code reads it,
	-- and without it the section is one run of bytes with no
	-- functions in it.  It goes before the prologue rather than
	-- after: the peephole never looks across a line it does not
	-- understand, and between the prologue and the body is where a
	-- parameter put away and read straight back out sits.
	self.g:write("\t.type\t" .. name .. ",@function\n")
	self.t.prologue(self.g, name, frame, slots, self.vabase, static,
		self.recret, sec, guard)
	-- What this unit has a body for, so that the runtime the
	-- compiler carries does not write a second one.
	-- The number says in which order the bodies went out, which is
	-- the order constructors of one priority run in.
	self.defined = self.defined or {}
	self.ndefined = (self.ndefined or 0) + 1
	self.defined[name] = self.defined[name] or self.ndefined
	if not static then
		if weak then self.t.data.weaken(self.g, name) end
		self.t.data.visible(self.g, name, vis)
	end
	body:move(whole)
	if not noway then
		self.t.epilogue(self.g, frame,
			((self.t.nfltreg or 0) > 0 or self.t.fltretabi) and
				isflt(self.rty) and self.rty.size,
			self:widepass(self.rty) and self.rty.size
				or nil, self.recret, guard)
	end
	self.g.body = nil
	if self.fobjs then
		local text = self.t.compact(whole:text(), self.fobjs,
			self.maxlocals, self.guard)

		whole = buf.new()
		whole:add(text)
		self.fobjs = nil
		if not self.peep then whole:move(saved) end
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
		if self.tok.kind ~= "name" and self.tok.kind ~= "*" and
		   self.tok.kind ~= "(" then
			self:err("expected a declaration")
		end
		base = self.ty.i32
	end
	if self:accept(";") then return end
	repeat
		self.asmname = nil
		local name, wrap = self:dcl(false)
		local ty = self:vectored(wrap(base), attrs)

		-- An attribute after the declarator belongs to this name:
		-- linux writes `__typeof__(struct rq) runqueues
		-- __attribute__((__aligned__(64)))`, and the alignment
		-- was read before the declarator was.
		if attrs.aligned and attrs.aligned ~= true and
		   attrs.aligned > (asked or 0) then
			asked = attrs.aligned
		end
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
		local named = attrs.visibility or (prev and prev.vis) or
			(self.lx.pragmavis and self.lx:pragmavis())
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
			-- C99 makes the definition external when any
			-- declaration of the name says neither inline nor
			-- extern; GNU's `extern inline` never is, whatever
			-- came before it: a header declares the plain
			-- prototype and then the inline body.
			local only = (inl and mine and
				(gnu or prev == nil or
				 prev.onlyinline ~= false))
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
			-- Run before main or after it.  The attribute may
			-- be on a declaration and the body come later
			-- with nothing said, so it sticks to the name.
			for _, k in ipairs{"constructor", "destructor"} do
				if attrs[k] and not g[k] then
					g[k] = attrs[k]
					self.ctors = self.ctors or {}
					self.ctors[#self.ctors + 1] = {g = g,
						fini = k == "destructor"}
				end
			end
			g.keep = g.keep or attrs.used or attrs.constructor
				or attrs.destructor
				or (self.aliased and self.aliased[sym])
				or (self.rtneed and self.rtneed[sym])
				or nil
			g.vis, g.static, g.onlyinline = named, intern, only
			-- A section given on one declaration holds for the
			-- definition too: OpenBSD puts __cptext on the
			-- prototypes in codepatch.h and nothing on the bodies.
			if attrs.section then
				g.section = attrs.section
			elseif g.section then
				attrs.section = g.section
			end
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
				elseif attrs.always_inline then
					-- `always_inline` on a definition
					-- with external linkage.  The body
					-- goes out as it must, and the
					-- tokens are kept as well so that a
					-- call in this unit is still built
					-- in place.  A kernel leans on
					-- that: a `noinstr` caller may only
					-- reach what lands in its own
					-- section, and gnu_inline makes
					-- every `__always_inline` one of
					-- these.
					local h = self.globals[name]

					h.pending = {sym = sym, ty = ty,
						sec = attrs.section,
						vis = vis, weak = attrs.weak,
						static = intern,
						always = true,
						lx = self:capture()}
					h.wanted = true
					self.deferred[#self.deferred + 1] = h
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
			-- A name may be written down without a value
			-- first and given one later.  Only one of the
			-- two goes out, and it is the one with the
			-- value.
			local said = self.defobj[sym]
			local tent = self.tok.kind ~= "=" and
				storage ~= "extern"

			if tent and said then goto nextname end
			if storage ~= "extern" then
				self.defobj[sym] = true
				-- What was put aside without a value is
				-- not what this name stands for.
				if not tent and self.dcand[sym] then
					self.dcand[sym].dead = true
				end
			end
			-- A static object nothing outside can name is
			-- written aside until something here names it.
			local hold

			if intern and not tls and not attrs.used and
			   not attrs.constructor and not attrs.destructor and
			   not attrs.section and not attrs.weak and
			   not (self.aliased and self.aliased[sym]) then
				hold = {sym = sym, buf = buf.new(), fns = {}}
				self.dg, self.holding = hold.buf, hold
			elseif tent and not tls then
				-- A tentative definition is not the
				-- object: a definition with a value later
				-- in the unit is, and only one of the two
				-- goes out.  So the zeroes wait until the
				-- unit has been read.  A kernel tracepoint
				-- is written exactly that way, the
				-- declaration and the definition one after
				-- the other in the same header.
				hold = {sym = sym, buf = buf.new(),
					fns = {}, always = true}
				self.dg, self.holding = hold.buf, hold
			end
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
				self.t.data.endobj(self.dg, sym)
			end
			if hold then
				self.dg, self.holding = self.data, nil
				self.dstatics[#self.dstatics + 1] = hold
				self.dcand[sym] = hold
			end
		end
		::nextname::
	until not self:accept(",")
	self:expect(";")
end

-- Which of the objects put aside the text just written names.
function P:noteuses(s)
	if not next(self.dcand) or s == "" then return end
	-- A name may hold a dollar but never begins with one: that is
	-- the sign on an immediate, and `$thing` names thing.
	for id in s:gmatch("[%a_.\128-\255][%w_.$\128-\255]*") do
		if self.dcand[id] then self.dseen[id] = true end
	end
end

function P:drain()
	self:noteuses(self.out:text())
	self:noteuses(self.sdata:text())
	self:noteuses(self.data:text())
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
	-- A name this unit calls with the same number everywhere reads
	-- that number inside its body.  That only holds while every call
	-- has been read, and a body built here may hold one: linux calls
	-- apic_read_boot_cpu_id(true) from one static body and
	-- apic_read_boot_cpu_id(false) from another, and the first was
	-- counted before the second was read.  So a body that names
	-- another one takes the answer away from it, before anything is
	-- built.
	local byname = {}

	for _, g in ipairs(self.deferred) do
		local p = g.pending

		if p and p.sym then byname[p.sym] = g end
	end
	for _, g in ipairs(self.deferred) do
		local p = g.pending
		local f = p and p.lx and p.lx.f

		for i = 1, f and p.lx.n or 0, NFIELD do
			if f[i] == "name" then
				local h = byname[f[i + 1]]

				if h then h.same, h.nosame = nil, true end
			end
		end
	end

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
		-- An object put aside that the code turned out to name
		-- joins the output, and what it names is wanted in turn.
		for _, h in ipairs(self.dstatics) do
			if not h.out and not h.dead and
			   (h.always or self.dseen[h.sym]) then
				h.out, again = true, true
				local text = h.buf:text()

				self.data:add(text)
				self:noteuses(text)
				for _, fn in ipairs(h.fns) do
					wantbody({fn = fn}, false)
				end
			end
		end
	end
	self:drain()
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
	self:ctorarrays()
	self:drain()
	if self.emit then return "" end
	return self.out:text() .. self.sdata:text() .. self.data:text()
end

-- A function marked constructor or destructor and defined here goes in
-- .init_array or .fini_array, which the start-up code walks before main
-- and after it.  A priority names a section of its own, which a linker
-- sorts by the number; the rest go in declaration order.
function P:ctorarrays()
	local list = {}

	for _, c in ipairs(self.ctors or {}) do
		if self.defined and self.defined[c.g.sym] then
			list[#list + 1] = c
		end
	end
	table.sort(list, function(x, y)
		return self.defined[x.g.sym] < self.defined[y.g.sym]
	end)
	for _, c in ipairs(list) do
		local g = c.g
		local sym = g.sym

		if self.defined and self.defined[sym] then
			local prio = g[c.fini and "destructor" or "constructor"]
			local sec = c.fini and ".fini_array" or ".init_array"

			if type(prio) == "number" then
				sec = ("%s.%05d"):format(sec, prio)
			end
			self.dg:write(("\t.section\t%s,\"aw\"\n\t.balign\t%d\n")
				:format(sec, self.t.ptrsize))
			self.t.data.item(self.dg, self.t.ptrsize, sym)
		end
	end
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
