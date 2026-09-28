-- SPDX-License-Identifier: ISC
-- What GNU attributes ask for: the attribute list itself, `mode` and
-- `vector_size` types, packed enums, cleanups, and constructors.  A
-- declaration with no attribute loads none of it.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local fold = require("mcc.parse.fold").fold
local isrec = require("mcc.parse.fold").isrec

-- What an attribute says, for the few that change what this compiler
-- does.  The rest are read and dropped: they say something about the
-- program that this compiler does not act on.
--
-- Both spellings of a name mean the same thing, so the underscores go.
local function attrname(s)
	return (s:gsub("^__", ""):gsub("__$", ""))
end

-- Attributes whose argument is a constant expression, not a token to skip.
local NUMATTR = {aligned = true, alloc_size = true, vector_size = true}

local IMODE = {QI = 1, HI = 2, SI = 4, DI = 8, TI = 16}
local ISIZE = {[1] = "8", [2] = "16", [4] = "32", [8] = "64", [16] = "128"}
local FMODE = {SF = "f32", DF = "f64", XF = "f80", TF = "f128"}

-- `__attribute__((a, b(1), c("x")))`, or the C23 `[[...]]` spelling.
-- Answers a table of what was named, which a caller looks in for the
-- ones it cares about.
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
				elseif name == "mode" and
				       save.kind == "name" then
					a[name] = attrname(save.text)
					self:adv()
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

-- GNU `mode(m)` names an integer or float type by its machine width.
function P:moded(ty, m)
	local k = ty.kind

	if FMODE[m] and (k == "int" or k == "uint" or k == "float") then
		return self.ty[FMODE[m]]
	end
	if k ~= "int" and k ~= "uint" then return ty end
	local n = IMODE[m]

	-- These follow the word.  libgcc compares answer a word too.
	if m == "word" or m == "pointer" or m == "unwind_word" or
	   m == "libgcc_cmp_return" or m == "libgcc_shift_count" then
		n = self.t.ptrsize
	end
	if not n then return ty end
	return self.ty[(k == "uint" and "u" or "i") .. ISIZE[n]]
end

-- `__attribute__((vector_size(n)))` makes a type n bytes wide, holding
-- as many of what it was written as will fit.  A vector is a value: it
-- is copied, passed and returned whole, and a subscript reaches an
-- element.  This compiler has no vector arithmetic; immintrin.h does
-- that in inline asm.
function P:vecmode(ty, attrs)
	if attrs and attrs.mode then ty = self:moded(ty, attrs.mode) end
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

-- Run what the scopes above `depth` left, innermost scope first and,
-- within a scope, in reverse of the order the objects were declared.
-- The objects stay where they are: leaving a scope is not the end of
-- the frame, and an outer scope may still run its own.
function P:cleanupcalls(depth)
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

-- A cast to or from a vector, or nil when it is not one of these.
function P:vcast(t, e)
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
	-- One vector to another of its size keeps the bits.
	if isrec(t) and not t.complex and t.vector and e.ty.vector then
		if t.size ~= e.ty.size then
			self:err("a vector cast has to keep the size")
		end
		e = tree.clone(e)
		e.ty = t
		return e
	end
end

return {}
