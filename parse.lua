-- Declarations, statements and expressions.
--
-- One pass: a statement is parsed, generated and released before the next is
-- read.  Nothing whole-function is kept except the symbol table for the
-- scopes that are open and the assembly already written.

local tree  = require "tree"
local gen   = require "gen"
local types = require "types"
local md    = require "md"

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
		   "__builtin_ceil"} do
	BUILTIN[k] = true
end
local PARENED = {__attribute__ = true, __asm__ = true, asm = true,
		 _Alignas = true, __declspec = true}
local STORAGE = {static = true, extern = true, typedef = true}

function P.new(lx, target, emit)
	local p = setmetatable({lx = lx, t = target, emit = emit}, P)
	local T = types.new(target)
	p.ty = T
	p.word = target.ptrsize == 8 and T.i64 or T.i32
	p.uword = target.ptrsize == 8 and T.u64 or T.u32
	p.fbits = target.ptrsize	-- unused, kept for symmetry
	-- Plain char is signed on x86 and unsigned on RISC-V, and a program
	-- that uses it to index a table can tell.
	p.plainchar = target.charsigned == false and T.u8 or T.i8
	p.base = {
		char = p.plainchar, uchar = T.u8, short = T.i16, ushort = T.u16,
		int = T.i32, uint = T.u32, long = p.word, ulong = p.uword,
		void = T.void,
	}
	p.out, p.data, p.sdata = {}, {}, {}
	p.g = gen.new(target, p.out)
	p.dg = {write = function(_, s) p.data[#p.data + 1] = s end}
	-- String literals land in their own list, because an initializer may
	-- make one while its own data is being written.
	p.sg = {write = function(_, s) p.sdata[#p.sdata + 1] = s end}
	p.globals, p.scopes, p.tags, p.nstr = {}, {}, {{}}, 0
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
	return self.t.slot(self.nlocals)
end

-- types ----------------------------------------------------------------

function P:istype()
	local k = self.tok.kind
	if DECLKW[k] then return true end
	if k == "name" then
		local s = self:find(self.tok.text)
		return s ~= nil and s.kind == "typedef"
	end
	return false
end

-- Skip a balanced parenthesised group, for __attribute__ and its kin.
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
function P:quals()
	while true do
		local k = self.tok.kind
		if QUAL[k] then
			self:adv()
		elseif k == "name" and IGNORE[self.tok.text] then
			self:adv()
		elseif k == "name" and PARENED[self.tok.text] then
			self:adv()
			self:skipparens()
		else
			return
		end
	end
end

-- struct or union, named or not, defined here or referred to.
function P:record(kind)
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
				-- an anonymous member; skip it
			else
				repeat
					local name, wrap = self:dcl(false)
					if self:accept(":") then
						self:constexpr()
					end
					members[#members + 1] =
						{name = name, ty = wrap(mbase)}
				until not self:accept(",")
				self:expect(";")
			end
		end
		self:expect("}")
		self.ty.complete(st, members)
	end
	return st
end

function P:enumspec()
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
	local size, inl
	while true do
		local k = self.tok.kind
		if QUAL[k] then
			self:adv()
		elseif k == "name" and IGNORE[self.tok.text] then
			self:adv()
		elseif k == "name" and PARENED[self.tok.text] then
			self:adv()
			self:skipparens()
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
		elseif k == "char" or k == "int" or k == "void" then
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
	if base then return base, storage, inl end
	local t
	if size == "float" then
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
	repeat
		if self:accept("...") then
			variadic = true
			break
		end
		local b = self:declspec() or self.ty.i32
		local name, wrap = self:dcl(true)
		local ty = self.ty.decay(wrap(b))
		list[#list + 1] = {name = name, ty = ty}
	until not self:accept(",")
	return list, variadic
end

-- A declarator, read inside out.  Returns the name, which may be nil for an
-- abstract one, and a function that wraps the base type.
function P:dcl(abstract)
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
		if k == "*" or k == "(" or k == "[" or
		   (k == "name" and not self:istype()) then
			name, innerwrap = self:dcl(abstract)
			self:expect(")")
		else
			local ps, va = self:params()
			self:expect(")")
			sfx[#sfx + 1] = function(t)
				return self.ty.func(t, ps, va)
			end
		end
	elseif self.tok.kind == "name" then
		name = self.tok.text
		self:adv()
	end

	while true do
		if self:accept("[") then
			local n
			if self.tok.kind ~= "]" then n = self:constexpr() end
			self:expect("]")
			sfx[#sfx + 1] = function(t)
				return self.ty.array(t, n)
			end
		elseif self:accept("(") then
			local ps, va = self:params()
			self:expect(")")
			sfx[#sfx + 1] = function(t)
				return self.ty.func(t, ps, va)
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
	return tree.node("CALL", rty,
		tree.name(self.ty.func(rty, {}, true), name), nil,
		{args = args, direct = true, soft = true})
end

function P:fprefix(t)
	return t.size == 8 and "d" or "f"
end

function P:conv(n, ty)
	if n.ty == ty then return n end
	if isrec(ty) or isrec(n.ty) then return n end
	if isflt(ty) or isflt(n.ty) then
		local from, to = n.ty, ty
		if isflt(from) and isflt(to) then
			return self:rtcall("__" .. self:fprefix(from) .. "2" ..
				self:fprefix(to), to, {n})
		end
		if isflt(to) then
			if isptr(from) then self:err("pointer to float") end
			local w = from.size < 4 and self.ty.i32 or from
			n = self:conv(n, w)
			return self:rtcall("__" ..
				(w.kind == "uint" and "u" or "i") .. "2" ..
				self:fprefix(to), to, {n})
		end
		local want = to.size < 4 and self.ty.i32 or to
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
				self:scale(self:conv(b, self.word), a.ty.to))
		end
		if isptr(b.ty) and op == "ADD" then
			return tree.binary(op, b.ty, b,
				self:scale(self:conv(a, self.word), b.ty.to))
		end
		if isptr(a.ty) and isptr(b.ty) and op == "SUB" then
			local d = tree.binary("SUB", self.word, a, b)
			if a.ty.to.size == 1 then return d end
			return tree.binary("DIV", self.word, d,
				tree.const(self.word, a.ty.to.size))
		end
	end
	-- A shift takes its type from its left side alone; the two sides do
	-- not meet.
	if op == "SHL" or op == "SHR" then
		local rt = self:promote(a.ty)
		return tree.binary(op, rt, self:conv(a, rt),
			self:conv(b, self:promote(b.ty)))
	end
	local rt = self:usual(a.ty, b.ty)
	if isflt(rt) then return self:floatop(op, a, b, rt) end
	return tree.binary(op, rt, self:conv(a, rt), self:conv(b, rt))
end

function P:floatop(op, a, b, rt)
	a, b = self:conv(a, rt), self:conv(b, rt)
	local p = self:fprefix(rt)
	if FOP[op] then
		return self:rtcall("__" .. p .. FOP[op], rt, {a, b})
	end
	local c = FCMP[op]
	if not c then self:err(op .. " is not defined on floating point") end
	local r = self:rtcall("__" .. p .. "cmp", self.ty.i32, {a, b})
	if c[1] == "ULE" then
		r.ty = self.ty.u32
		return tree.binary("LE", self.word, r,
			tree.const(self.ty.u32, c[2]))
	end
	return tree.binary(c[1], self.word, r, tree.const(self.ty.i32, c[2]))
end

-- A float used as a truth value is compared against zero.
function P:test(e)
	e = self:rvalue(e)
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

-- The address of an lvalue.  Taking the address of an indirection is the
-- indirection's own operand, which is what keeps &p->x from building a tree
-- no table can match.
function P:addrof(e)
	if e.op == "INDIR" then return e.left end
	if e.ty.kind == "array" then return self:rvalue(e) end
	return tree.unary("ADDR", self.ty.ptr(e.ty), e)
end

-- An array or a function used in an expression becomes a pointer.
function P:rvalue(n)
	if n.ty.kind == "func" then
		if n.op == "INDIR" then return n.left end
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

	if not arrow and base.op == "AUTO" then
		return tree.auto(m.ty, base.off + m.off)
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
	return tree.unary("INDIR", m.ty, addr)
end

function P:primary()
	local tk = self.tok
	if self:accept("(") then
		local e = self:expression()
		self:expect(")")
		return e
	end
	if tk.kind == "num" then
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
		if not s then self:err("undeclared " .. tk.text) end
		if s.kind == "func" then
			return tree.name(s.ty, s.sym)
		end
		if s.kind == "const" then
			return tree.const(self.word, s.val)
		end
		if s.kind == "local" then
			return tree.auto(s.ty, s.off)
		end
		return tree.name(s.ty, s.sym or tk.text)
	end
	self:err("unexpected " .. (tk.text or tk.kind))
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
	if rty == self.ty.void or isrec(rty) or rty.kind == "array" then
		rty = self.word
	end
	-- convert to the declared parameter types where they are known
	local named = 0
	if fty.kind == "func" then
		named = #fty.params
		for i, p in ipairs(fty.params) do
			if args[i] then args[i] = self:conv(args[i], p.ty) end
		end
	end
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
	-- The target needs the named count to classify a variadic call.
	return tree.node("CALL", rty, callee, nil,
		{args = args, direct = direct,
		 nfixed = fty.kind == "func" and fty.variadic and
			  #fty.params or nil})
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
			if isflt(e.ty) then
				self:err("postfix step on a float")
			end
			e = tree.node("POSTADD", e.ty, e, nil, {val = step})
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
	local wide = suf:find("[lL]") ~= nil
	local hexoct = text:match("^0[xX]") or text:match("^0%d")
	local fits32 = v >= -2147483648 and v <= 2147483647
	local fitsu32 = v >= 0 and v <= 4294967295
	if uns then
		if not wide and fitsu32 then return T.u32 end
		return T.u64
	end
	if not wide and fits32 then return T.i32 end
	if hexoct and not wide and fitsu32 then return T.u32 end
	-- a literal too large for a signed word has wrapped round
	if v < 0 then return T.u64 end
	return T.i64
end

function P:unary()
	local k = self.tok.kind
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
	elseif k == "(" and self:peek() and self.ahead and
	    (DECLKW[self.ahead.kind] or
	     (self.ahead.kind == "name" and (function()
		local s = self:find(self.ahead.text)
		return s ~= nil and s.kind == "typedef"
	     end)())) then
		self:adv()
		local t = self:typename()
		self:expect(")")
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
		if isflt(e.ty) then
			if e.op == "CONST" then
				-- flipping the sign bit is exact, and keeps a
				-- negative literal usable as a constant
				e.val = e.val ~ (1 << (e.ty.size * 8 - 1))
				return e
			end
			return self:rtcall("__" .. self:fprefix(e.ty) .. "neg",
				e.ty, {e})
		end
		return tree.unary("NEG", self:promote(e.ty), e)
	elseif k == "+" then
		self:adv()
		return self:unary()
	elseif k == "~" then
		self:adv()
		local e = self:rvalue(self:unary())
		return tree.unary("NOT", self:promote(e.ty), e)
	elseif k == "!" then
		self:adv()
		return tree.unary("LNOT", self.word, self:test(self:unary()))
	elseif k == "*" then
		self:adv()
		local e = self:rvalue(self:unary())
		if not isptr(e.ty) then self:err("not a pointer") end
		return self:postfix(tree.unary("INDIR", e.ty.to, e))
	elseif k == "&" then
		self:adv()
		return self:addrof(self:unary())
	elseif k == "++" or k == "--" then
		self:adv()
		local e = self:unary()
		local step = k == "++" and 1 or -1
		return tree.binary("ASGN", e.ty, e,
			self:arith("ADD", e, tree.const(self.word, step)))
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
			a = tree.binary(b[2], self.word,
				self:test(a), self:test(rhs))
		else
			a = self:arith(b[2], a, rhs)
		end
	end
end

function P:ternary()
	local c = self:binary(1)
	if not self:accept("?") then return c end
	c = self:test(c)
	local a = self:expression()
	self:expect(":")
	local b = self:ternary()
	a, b = self:rvalue(a), self:rvalue(b)
	local rt = isptr(a.ty) and a.ty or (isptr(b.ty) and b.ty or
		self:usual(a.ty, b.ty))
	return tree.node("COND", rt, c, nil,
		{arms = {self:conv(a, rt), self:conv(b, rt)}})
end

-- A whole record moves as bytes.
function P:assignto(lhs, rhs)
	if isrec(lhs.ty) then
		local d = self:addrof(lhs)
		local s = self:addrof(rhs)
		return tree.node("COPY", lhs.ty, d, s, {val = lhs.ty.size})
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
		local asg = tree.binary("ASGN", lv.ty, tree.clone(lv),
			self:conv(self:arith(op, lv, rhs), lv.ty))
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
	return tree.unary("INDIR", a.ty, tree.auto(ty, off)), set
end

-- A frame slot for the compiler's own use.  It lives as long as any local
-- of the enclosing block, which is longer than it needs to but costs one
-- word at a site that is rare.
function P:temp()
	return self:alloc(self.ty.ptr(self.ty.i8))
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

local function fold(n)
	if not n then return nil end
	if n.op == "CONST" then return n.val end
	if n.op == "NEG" then
		local a = fold(n.left)
		return a and -a
	end
	if n.op == "NOT" then
		local a = fold(n.left)
		return a and ~a
	end
	if n.op == "LNOT" then
		local a = fold(n.left)
		return a and (a == 0 and 1 or 0)
	end
	if n.op == "CVT" then return fold(n.left) end
	local a, b = fold(n.left), fold(n.right)
	if not a or not b then return nil end
	local o = n.op
	if o == "ADD" then return a + b end
	if o == "SUB" then return a - b end
	if o == "MUL" then return a * b end
	if o == "DIV" then return b ~= 0 and a // b or 0 end
	if o == "MOD" then return b ~= 0 and a % b or 0 end
	if o == "AND" then return a & b end
	if o == "OR"  then return a | b end
	if o == "XOR" then return a ~ b end
	if o == "SHL" then return a << b end
	if o == "SHR" then return a >> b end
	if o == "EQ"  then return a == b and 1 or 0 end
	if o == "NE"  then return a ~= b and 1 or 0 end
	if o == "LT"  then return a < b and 1 or 0 end
	if o == "LE"  then return a <= b and 1 or 0 end
	if o == "GT"  then return a > b and 1 or 0 end
	if o == "GE"  then return a >= b and 1 or 0 end
	return nil
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
	-- the rest are the library function of the same name, called the way
	-- the target calls anything else
	local fn = name:gsub("^__builtin_", "")
	local rty = args[1] and args[1].ty or self.word
	local n = self:rtcall(fn, rty, args)
	n.soft = nil
	return n
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
		set("reg", area(self.vabase + self.vagp * ps)),
		set("freg", area(self.vabase + (nreg + self.vafp) * ps)),
		set("stk", area(self.t.stackargs + self.vastk * ps)),
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
	if n.op == "ADDR" and n.left.op == "NAME" then return n.left.sym end
	if n.op == "NAME" then return nil end
	if n.op == "ADD" or n.op == "SUB" then
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
		local i = from.size == 8 and "<i8" or "<i4"
		v = string.unpack(f, string.pack(i, v))
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
local function assemble(out, pieces, n, at, sizeof, total)
	local off = 0
	for k = 1, n do
		local p = pieces[k]
		if p then
			local a = at(k)
			if a > off then out[#out + 1] = {zero = a - off} end
			for _, it in ipairs(p) do out[#out + 1] = it end
			off = a + sizeof(k)
		end
	end
	if total > off then out[#out + 1] = {zero = total - off} end
end

function P:initarray(ty, out, dyn)
	local pieces, i, n = {}, 1, 0
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		if self:accept("[") then
			local k = fold(self:ternary())
			if not k then self:err("a constant is required here") end
			self:expect("]")
			self:expect("=")
			i = k + 1
		end
		pieces[i] = {}
		self:initlist(ty.of, pieces[i], dyn)
		if i > n then n = i end
		i = i + 1
		if not self:accept(",") then break end
	end
	self:expect("}")
	if ty.n and ty.n > n then n = ty.n end
	local w = ty.of.size
	assemble(out, pieces, n, function(k) return (k - 1) * w end,
		 function() return w end, n * w)
	return n
end

function P:initrec(ty, out, dyn)
	local members = ty.members or {}
	local pieces, i = {}, 1
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		if self:accept(".") then
			local nm = self:expect("name").text
			i = nil
			for k, m in ipairs(members) do
				if m.name == nm then i = k end
			end
			if not i then self:err("no member " .. nm) end
			self:expect("=")
		end
		local mem = members[i]
		if not mem then break end
		pieces[i] = {}
		self:initlist(mem.ty, pieces[i], dyn)
		i = i + 1
		if ty.kind == "union" then break end
		if not self:accept(",") then break end
	end
	while self.tok.kind ~= "}" and self.tok.kind ~= "eof" do
		self:adv()
	end
	self:expect("}")
	assemble(out, pieces, #members,
		 function(k) return members[k].off end,
		 function(k) return members[k].ty.size end, ty.size)
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

function P:emitinit(name, ty, out, static)
	self.t.data.obj(self.dg, name, ty.align, static, false)
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
function P:initobject(name, ty, static)
	local out = {}
	local n = self:initlist(ty, out)
	if ty.kind == "array" and not ty.n then
		ty = self.ty.array(ty.of, n)
	end
	self:emitinit(name, ty, out, static)
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
	local n = self:initlist(ty, out, true)
	if ty.kind == "array" and not ty.n then
		ty = self.ty.array(ty.of, n)
		sym.ty = ty
	end
	sym.off = self:alloc(ty)
	self:emitinit(lbl, ty, out, true)
	local dst = tree.unary("ADDR", self.ty.ptr(ty), tree.auto(ty, sym.off))
	local src = tree.unary("ADDR", self.ty.ptr(ty), tree.name(ty, lbl))
	self.g:expr(tree.node("COPY", ty, dst, src, {val = ty.size}), "eff")
	local off = 0
	for _, it in ipairs(out) do
		if it.expr then
			local lv = tree.auto(it.ety, sym.off + off)
			self.g:expr(tree.binary("ASGN", it.ety, lv, it.expr),
				    "eff")
		end
		off = off + itemsize(it)
	end
end

-- statements -----------------------------------------------------------

function P:localdecl()
	local base, storage = self:declspec()
	if not base then return false end
	if self:accept(";") then return true end
	repeat
		local name, wrap = self:dcl(false)
		local ty = wrap(base)
		if storage == "typedef" then
			self:declare(name, {kind = "typedef", ty = ty})
		elseif storage == "extern" or ty.kind == "func" then
			self:declare(name, {kind = "func", ty = ty,
					    sym = name})
		elseif storage == "static" then
			local lbl = ".Lstatic" .. self.nstr
			self.nstr = self.nstr + 1
			if self:accept("=") then
				ty = self:initobject(lbl, ty, true)
			else
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
				end
				self.t.data.obj(self.dg, lbl, ty.align,
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
	local k = self.tok.kind
	local g = self.g

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
		self:expect(":")
		if not self.sw then self:err("case outside a switch") end
		local l = g:newlabel()
		self.sw.cases[#self.sw.cases + 1] = {val = v, label = l}
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
		local name = self:expect("name").text
		self:expect(";")
		self.t.jump(g, self:userlabel(name))
	elseif k == "return" then
		self:adv()
		if self.tok.kind ~= ";" then
			g:expr(self:conv(self:rvalue(self:expression()),
				self.rty), "reg", 0)
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

function P:funcdef(name, ty, static)
	local body = {}
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
	local shape = {}
	for i, prm in ipairs(ty.params) do
		shape[i] = {flt = isflt(prm.ty), size = prm.ty.size}
	end
	local slots, gp, fp, stk = md.classify(self.t, shape)
	for i, prm in ipairs(ty.params) do
		slots[i].off = self:alloc(prm.ty)
		if prm.name then
			self:declare(prm.name, {kind = "local", ty = prm.ty,
						off = slots[i].off})
		end
	end
	-- A variadic function needs somewhere to keep its argument
	-- registers, laid out upward so the walker can step through them:
	-- the integer file first, then the floating point one.
	self.vabase = nil
	self.vagp, self.vafp, self.vastk = gp, fp, stk
	if ty.variadic then
		for _ = 1, self.t.nargreg + nfltreg do
			self:alloc(self.word)
		end
		self.vabase = self.t.slot(self.nlocals)
	end
	self:block()
	self:pop()
	self.g:putlabel(self.endlabel)
	local frame = self.t.frame(self.maxlocals)
	self.g.sink = saved
	self.t.prologue(self.g, name, frame, slots, self.vabase, static)
	for _, x in ipairs(body) do saved[#saved + 1] = x end
	self.t.epilogue(self.g, frame,
		(self.t.nfltreg or 0) > 0 and isflt(self.rty) and self.rty.size)
end

-- Parse a function body and throw the code away.
function P:discarded(name, ty)
	local out, data, sdata = self.out, self.data, self.sdata
	self.out, self.data, self.sdata = {}, {}, {}
	self.g.sink = self.out
	self:funcdef(name, ty, true)
	self.out, self.data, self.sdata = out, data, sdata
	self.g.sink = self.out
end

function P:extdef()
	if self.tok.kind == "name" and self.tok.text == "_Static_assert" then
		self:adv()
		self:skipparens()
		self:accept(";")
		return
	end
	local base, storage, inl = self:declspec()
	if not base then self:err("expected a declaration") end
	if self:accept(";") then return end
	repeat
		local name, wrap = self:dcl(false)
		local ty = wrap(base)
		if storage == "typedef" then
			self.globals[name] = {kind = "typedef", ty = ty}
		elseif ty.kind == "func" then
			self.globals[name] = {kind = "func", ty = ty,
					      sym = name}
			if self.tok.kind == "{" then
				-- A plain `inline` definition emits nothing:
				-- this compiler does not inline, and C says
				-- the external one lives in another unit.
				if inl and not storage then
					self:discarded(name, ty)
				else
					self:funcdef(name, ty,
						storage == "static")
				end
				return
			end
		else
			local s = {kind = "global", ty = ty, sym = name}
			self.globals[name] = s
			if self:accept("=") then
				s.ty = self:initobject(name, ty,
					storage == "static")
			elseif storage ~= "extern" then
				if ty.kind == "array" and not ty.n then
					ty = self.ty.array(ty.of, 1)
					s.ty = ty
				end
				self.t.data.obj(self.dg, name, ty.align,
					storage == "static", true)
				self.t.data.zero(self.dg, ty.size)
			end
		end
	until not self:accept(",")
	self:expect(";")
end

function P:drain()
	if not self.emit then return end
	self.emit(table.concat(self.out))
	self.emit(table.concat(self.sdata))
	self.emit(table.concat(self.data))
	self.out, self.data, self.sdata = {}, {}, {}
	self.g.sink = self.out
end

function P:program()
	while self.tok.kind ~= "eof" do
		self:extdef()
		self:drain()
	end
	if self.emit then return "" end
	return table.concat(self.out) .. table.concat(self.sdata) ..
		table.concat(self.data)
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
