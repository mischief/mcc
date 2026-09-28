-- SPDX-License-Identifier: ISC
-- The two-byte floats, _Float16 and __bf16.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local isflt = require("mcc.parse.fold").isflt

-- A two-byte float converts through a float.  Narrowing calls the
-- runtime gcc and clang call, straight from the wider type so it rounds
-- once.  bfloat16 is the top half of a float, so widening one is a
-- shift; binary16 widens in the runtime.
local TRUNC = {[4] = "sf", [8] = "df", [16] = "xf"}

function P:halfconv(n, to)
	local from = n.ty
	local f32 = self.ty.f32

	if from.half then
		local f

		if from.half == "bf" then
			local off = self:temp(f32)

			self.irno[off] = true
			local bits = self:arith("SHL", self:conv(self:halfbits(n),
				self.ty.u32), tree.const(self.ty.i32, 16))
			f = tree.node("SEQ", f32, nil, nil, {arms = {
				self:assignto(tree.auto(self.ty.u32, off),
					bits),
				tree.auto(f32, off)}})
		else
			f = self:abicall("__extendhfsf2", f32, n)
		end
		return self:conv(f, to)
	end
	if not isflt(from) or from.complex then
		n = self:conv(n, self.ty.f64)
		from = n.ty
	end
	return self:abicall("__trunc" .. TRUNC[from.size] .. to.half .. "2",
		to, n)
end

-- The bits of a two-byte float, as an unsigned short.
function P:halfbits(n)
	local off = self:temp(n.ty)

	self.irno[off] = true
	return tree.node("SEQ", self.ty.u16, nil, nil, {arms = {
		self:assignto(tree.auto(n.ty, off), n),
		tree.auto(self.ty.u16, off)}})
end

return {}
