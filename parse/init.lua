-- SPDX-License-Identifier: ISC
-- Initializers: braces and designators flattened to a list of pieces
-- at byte offsets, then written out as data or as stores into a local.

local tree = require "tree"
local lex = require "lex"
local P = require "parse.base"
local cf = require "parse.fold"
local fold = cf.fold
local isflt = cf.isflt
local isrec = cf.isrec
local symoff = cf.symoff

-- What a string literal holds: bytes for a narrow one, code points for a
-- wide one.  The lexer caches the points, and a join throws the cache away
-- rather than merge two of them.
local function strchars(tk, ety)
	if ety.size == 1 then return tk.text end
	return tk.val or lex.utf8points(tk.text)
end

-- The text of an address constant: a symbol, or a symbol and an offset.
-- The second answer says the text names two symbols.  The assembler
-- works that out only when both are in the same section of the same
-- object, which this cannot know, so a local initializer stores it at
-- run time instead of trusting the image.
local function addrtext(n)
	if not n then return nil end
	local v = fold(n)
	if v then return tostring(v) end
	if n.op == "CVT" then return addrtext(n.left) end
	-- A slot in data holds the address itself, whatever a reference
	-- from code would go through, so the loader fills it in directly.
	if n.op == "GOT" and n.left.op == "NAME" then
		-- Read the name, but leave the tree as it stands: the
		-- expression around this one may still turn out not to
		-- be constant, and then the tree is what runs.
		return n.left.sym
	end
	if n.op == "ADDR" and n.left.op == "NAME" then
		local off = n.left.off or 0

		if off == 0 then return n.left.sym end
		return n.left.sym .. (off > 0 and "+" or "-") .. math.abs(off)
	end
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
		local a, ta = addrtext(n.left)
		local b, tb = addrtext(n.right)

		if a and b then
			return a .. (n.op == "ADD" and "+" or "-") .. b,
				ta or tb or
				(not tonumber(a) and not tonumber(b))
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
		local str = strchars(self.tok, ty.of)
		local w = ty.of.size

		self:adv()
		-- An array with no room for the terminator takes the
		-- characters alone: `char name[4] = "_BCM"` is four
		-- bytes, and a fifth would land on the next member.
		-- One too short for the characters keeps what fits, as
		-- gcc does.
		if ty.n and ty.n <= #str then
			if ty.n < #str then
				if type(str) == "table" then
					str = {table.unpack(str, 1, ty.n)}
				else
					str = str:sub(1, ty.n)
				end
			end
			out[#out + 1] = {str = str, width = w, noterm = true}
			return ty.n
		end
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
	-- `({ ... })` is a statement expression and the parenthesis is
	-- part of it, so it is not one of the ones a macro left behind.
	if isrec(ty) and self.tok.kind == "(" and
	   self:peek().kind ~= "{" then
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
					 zero = not text and ty.size > 8
						and ty.size or nil,
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
	-- A whole record or array taken from somewhere else is stored over
	-- the image afterwards.  The image has no number for it, so it
	-- holds its width in zeroes; one word would leave the members
	-- after it at the wrong place.
	out[#out + 1] = {size = ty.size, text = text or "0", expr = e,
			 zero = not text and not x87 and ty.size > 8
				and ty.size or nil,
			 ety = ty, x87 = x87}
	return 1
end

-- Lay the pieces out in order, padding the gaps a designator leaves.  Each
-- piece is the item list for one element, indexed by where it belongs.
-- An initialiser is a set of pieces placed at byte offsets.  Keeping the
-- offset rather than the member number is what lets a designator reach a
-- member of a member: `.u.basic.issigned = s` is one piece, placed deep.
--
-- The pieces are taken apart into the items they hold, so that a piece
-- written later takes only the bytes it names from one written earlier:
-- `.n = { 5, 6 }, .n.y = 9` writes the 9 and keeps the 5, which is what C
-- says of an initializer that names a subobject twice.  A union written
-- twice at two widths is the one case this leaves alone: the wider write
-- covers the narrower one and the sweep steps over it.
local function flatten(out, map, total)
	local byoff = {}
	local offs = {}

	for pi, p in ipairs(map) do
		local at = p.off

		for _, it in ipairs(p.items) do
			local w = it.str and
				(#it.str + (it.noterm and 0 or 1)) *
				(it.width or 1) or it.zero or it.size
			local had = byoff[at]

			-- A piece of no width writes nothing, so it does
			-- not stand in for one that does.  An empty
			-- struct is no bytes wide and sits at the same
			-- offset as whatever follows it: linux spells an
			-- uncontended spin lock that way.
			if had == nil then
				offs[#offs + 1] = at
				byoff[at] = {it = it, pi = pi, w = w}
			elseif (w > 0 or had.w == 0) and pi >= had.pi then
				byoff[at] = {it = it, pi = pi, w = w}
			end
			at = at + w
		end
	end
	table.sort(offs)
	local off = 0

	for _, a in ipairs(offs) do
		local e = byoff[a]

		if a >= off then
			if a > off then out[#out + 1] = {zero = a - off} end
			out[#out + 1] = e.it
			off = a + e.w
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
		local two

		if v then
			text = tostring(v)
		else
			text, two = addrtext(e)
			-- An address goes into a local object where it
			-- stands rather than into the image it is
			-- copied from.  A difference of two names is
			-- only a constant where the assembler can see
			-- both, and an image holding an address is not
			-- position independent, which the linux EFI
			-- stub is checked for.  gcc does the same.
			if dyn and text and tonumber(text) == nil then
				text = nil
			end
		end
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
			self.t.data.string(self.dg, it.str, it.width, it.noterm)
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
	self.t.data.endobj(self.dg, name)
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
	if it.str then
		return (#it.str + (it.noterm and 0 or 1)) * (it.width or 1)
	end
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

	if sized then sym.off = self:alloc(ty) self:keep() end
	local n = self:initlist(ty, out, true)

	if ty.kind == "array" and not ty.n then
		ty = self.ty.array(ty.of, n)
		sym.ty = ty
	end
	if not sized then sym.off = self:alloc(ty) self:keep() end
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

return {
	addrtext = addrtext,
	strchars = strchars,
}
