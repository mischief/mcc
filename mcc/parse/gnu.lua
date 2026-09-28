-- SPDX-License-Identifier: ISC
-- GNU extensions that plain C never writes: statement expressions,
-- `a ?: b`, casts to a union, typeof and __auto_type.

local tree = require "mcc.tree"
local buf = require "mcc.buf"
local P = require "mcc.parse.base"
local autoof = require("mcc.parse.tokens").autoof
local words = require "mcc.parse.words"
local ASMKW = words.ASMKW
local STATICASSERT = words.STATICASSERT
local STMTKW = words.STMTKW

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

-- `a ?: b` is `a ? a : b` without saying a twice.  The value is
-- needed in both places, so it goes in a frame slot when working it
-- out has any effect of its own.
function P:elvis(c)
	self:adv()
	c = self:rvalue(c)
	self:pushregion()
	local b = self:rvalue(self:ternary())

	self:popregion()
	local rt = self:condtype(c, b)

	if not tree.effects(c) then
		return tree.node("COND", rt, self:test(tree.clone(c)), nil,
			{arms = {self:conv(c, rt), self:conv(b, rt)}})
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

-- `__auto_type name = e;` inside a function: the type is what the
-- initializer turned out to be.
function P:autodecl(name, storage)
	if storage ~= nil and storage ~= "static" then
		self:err("__auto_type takes no storage class")
	end
	self:expect("=")
	local e = self:rvalue(self:assign())

	local ty = self.ty.decay(e.ty)

	if storage == "static" then
		self:err("a static __auto_type is not supported")
	end
	local s = self:declare(name, {kind = "local", ty = ty})

	s.off = self:alloc(ty)
	self.slotname[s.off] = name
	self:keep()
	self.g:expr(self:assignto(autoof(s), e), "eff")
	self:notebuf(ty)
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

return {}
