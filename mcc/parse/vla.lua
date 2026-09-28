-- SPDX-License-Identifier: ISC
-- Variable length arrays, whose size is worked out at run time.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"

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

return {}
