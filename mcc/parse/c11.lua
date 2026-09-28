-- SPDX-License-Identifier: ISC
-- What C99 and C11 added that older code never writes: compound
-- literals, _Generic, _Static_assert and the `[[...]]` attributes.

local tree = require "mcc.tree"
local buf = require "mcc.buf"
local P = require "mcc.parse.base"
local copytok = require("mcc.parse.tokens").copytok

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

return {}
