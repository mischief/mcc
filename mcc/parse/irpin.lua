-- SPDX-License-Identifier: ISC
-- The register choice over a recorded function body, which runs only
-- when MCC_IR asks for the record.

local tree = require "mcc.tree"
local ir = require "mcc.ir"
local sys = require "mcc.sys"
local P = require "mcc.parse.base"

-- Decide which locals live in a register before any of the function is
-- written out.  Everything this needs -- the blocks, what is live where,
-- what meets a call -- can only be known now that the whole body is in
-- hand, which is what the record is for.
function P:irplay(name)
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

return {}
