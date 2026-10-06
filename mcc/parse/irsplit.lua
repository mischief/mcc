-- SPDX-License-Identifier: ISC
-- A record local whose address goes nowhere but into whole copies of
-- it is a row of scalars: each member is a slot of its own, and each
-- copy is the members one by one.  The allocator can then keep a
-- member in a register.  Runs over the recorded body before it.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"

local STRIDE = 5
local INT = {int = true, uint = true, ptr = true}

-- The members of a record as slots, or nil when one is not a plain
-- scalar of four or eight bytes, or a union or record of that size
-- read as one.
local function chunks(ty)
	if ty.kind ~= "struct" or not ty.members or #ty.members == 0 then
		return nil
	end
	local out = {}

	for _, m in ipairs(ty.members) do
		local k = m.ty.kind

		if m.bits or (m.ty.size ~= 4 and m.ty.size ~= 8) or
		   not (INT[k] or k == "union" or k == "struct") then
			return nil
		end
		out[#out + 1] = {off = m.off, size = m.ty.size, ty = m.ty}
	end
	return out
end

-- One record type, whichever name reached it.
local function same(a, b)
	return a == b or (a and b and a.members and a.members == b.members)
end

-- Visit every node with its parent.
local function each(n, f, parent, seen)
	if type(n) ~= "table" or seen[n] then return end
	seen[n] = true
	f(n, parent)
	each(n.left, f, n, seen)
	each(n.right, f, n, seen)
	for _, a in ipairs(n.arms or {}) do each(a, f, n, seen) end
	for _, a in ipairs(n.args or {}) do each(a, f, n, seen) end
end

-- The record local an offset falls in.
local function owner(recs, off)
	for base, s in pairs(recs) do
		if off >= base and off < base + s.ty.size then return s end
	end
end

-- Answers the slots of members now held apart, as offset to size, for
-- the allocator to take after the scalar locals, and the pointer
-- slots it made for copies, as the same.
function P:irsplit(rec, frameref, entry)
	local recs = {}

	-- The record locals, by where each starts.
	for i = 1, rec.n, STRIDE do
		if rec[i] == "e" or rec[i] == "c" then
			each(rec[i + 1], function(n)
				if n.op == "AUTO" and n.off and not n.part and
				   n.ty and n.ty.kind == "struct" then
					local s = recs[n.off]

					if s and not same(s.ty, n.ty) then
						s.out = true
					elseif not s then
						local c = chunks(n.ty)

						recs[n.off] = {off = n.off, ty = n.ty,
							chunks = c, out = not c}
					end
				end
			end, nil, {})
		end
	end
	if not next(recs) then return {}, {} end

	-- Text written into the body that names a slot inside one
	-- reads it from the frame: that record stays where it is.
	local function named(s)
		for off in s:gmatch(frameref or "$^") do
			local r = owner(recs, tonumber(off))

			if r then r.out = true end
		end
	end
	-- The whole record is fine only as a copy's operand, in a
	-- copy done for its effect; each member read or written has
	-- to be one of the members, as an integer of its own width.
	local copies = {}

	for i = 1, rec.n, STRIDE do
		local k, x = rec[i], rec[i + 1]

		if k == "w" and type(x) == "string" then
			named(x)
		elseif k == "e" or k == "c" then
			local top = k == "e" and rec[i + 2] == "eff" and x or nil
			local effseq = {}

			each(x, function(n, parent)
				if n.op == "TEXT" and type(n.text) == "string" then
					named(n.text)
					for _, m in pairs(n.rets or {}) do
						if type(m) == "table" and
						   type(m.store) == "string" then
							named(m.store)
						end
					end
					if n.slot then
						local r = owner(recs, n.slot)

						if r then r.out = true end
					end
				end
				-- what a SEQ done for its effect runs
				-- for its effect, all but the last arm
				if n.op == "SEQ" and (n == top or effseq[n]) then
					for j, a in ipairs(n.arms) do
						if j < #n.arms or effseq[n] or
						   n == top then
							effseq[a] = true
						end
					end
				end
				if n.op == "COPY" and (n == top or effseq[n]) then
					copies[#copies + 1] = n
				end
				if n.op ~= "AUTO" or not n.off then return end
				local r = owner(recs, n.off)

				if not r then return end
				if not n.part and n.off == r.off and
				   same(n.ty, r.ty) then
					-- the whole: under an ADDR that is a
					-- copy's operand, and nowhere else
					if not (parent and parent.op == "ADDR") then
						r.out = true
					end
					return
				end
				local ok = false

				for _, c in ipairs(r.chunks or {}) do
					if r.off + c.off == n.off and
					   c.size == n.ty.size and
					   INT[n.ty.kind] and not n.bf then
						ok = true
					end
				end
				if not ok then
					-- read some other way: that member
					-- stays in memory
					for _, c in ipairs(r.chunks or {}) do
						local at = r.off + c.off

						if n.off < at + c.size and
						   n.off + (n.ty.size or 1) > at then
							c.mem = true
						end
					end
				end
			end, nil, {})
		end
	end
	-- An ADDR of the whole has to be under one of those copies.
	local under = {}

	for _, cp in ipairs(copies) do
		under[cp.left] = true
		under[cp.right] = true
	end
	for i = 1, rec.n, STRIDE do
		if rec[i] == "e" or rec[i] == "c" then
			each(rec[i + 1], function(n)
				if n.op == "ADDR" and n.left and
				   n.left.op == "AUTO" and n.left.off then
					local r = owner(recs, n.left.off)

					if r and not under[n] then r.out = true end
				end
			end, nil, {})
		end
	end
	-- A parameter arrived in its slot from the prologue, which is
	-- not in the record.
	for off in pairs(entry or {}) do
		local r = owner(recs, off)

		if r then r.out = true end
	end

	local held = {}

	for _, r in pairs(recs) do
		if not r.out then
			for _, c in ipairs(r.chunks) do
				if not c.mem then
					held[#held + 1] = c
				end
			end
		end
	end
	if #held == 0 then return {}, {} end

	-- Each copy into or out of a record held apart is its members.
	local function inrec(a)
		if a and a.op == "ADDR" and a.left and a.left.op == "AUTO" then
			local r = recs[a.left.off]

			if r and not r.out and same(a.left.ty, r.ty) then
				return r
			end
		end
	end
	local function member(base, c)
		-- c.ty may be a union or a record: read it as an integer
		-- of its width
		local ty = INT[c.ty.kind] and c.ty or
			(c.size == 8 and self.uword or self.ty.u32)

		if base.rec then
			return tree.node("AUTO", ty, nil, nil,
				{off = base.rec.off + c.off, part = true})
		end
		-- an offset even of nothing, so the address is one an
		-- instruction takes as a displacement
		local addr = tree.binary("ADD", self.ty.ptr(ty), base.ptr(),
			tree.const(self.uword, c.off))

		return tree.unary("INDIR", ty, addr)
	end
	local temps = {}

	for _, cp in ipairs(copies) do
		local d, s = inrec(cp.left), inrec(cp.right)

		if d and d == s then
			-- a record onto itself
			cp.op, cp.left, cp.right, cp.arms = "SEQ", nil, nil, {}
			cp.val = nil
		elseif d or s then
			local r = d or s
			local other = d and cp.right or cp.left
			-- the record on the other side, if that is one
			local orec

			if d then orec = s else orec = d end
			local arms = {}
			local base

			if orec then
				base = {rec = orec}
			elseif other.op == "ADDR" and other.left.op == "AUTO" then
				local x = other.left

				base = {rec = {off = x.off}}
			elseif tree.effects(other) or
			       (other.op ~= "AUTO" and other.op ~= "NAME") then
				-- worked out once, into a slot of its own
				local n = self.nlocals

				self.nlocals = self.maxlocals
				local t = self:alloc(other.ty)

				self.nlocals = n
				arms[#arms + 1] = tree.binary("ASGN", other.ty,
					tree.auto(other.ty, t), other)
				temps[t] = other.ty.size
				base = {ptr = function()
					return tree.auto(other.ty, t)
				end}
			else
				base = {ptr = function() return other end}
			end
			local self_ = {rec = r}

			for _, c in ipairs(r.chunks) do
				local mine = member(self_, c)
				local theirs = member(base, c)

				if d then
					arms[#arms + 1] = tree.binary("ASGN",
						mine.ty, mine, theirs)
				else
					arms[#arms + 1] = tree.binary("ASGN",
						theirs.ty, theirs, mine)
				end
			end
			cp.op, cp.left, cp.right, cp.arms = "SEQ", nil, nil, arms
			cp.val = nil
		end
	end
	local res = {}

	for _, r in pairs(recs) do
		if not r.out then
			for _, c in ipairs(r.chunks) do
				if not c.mem then res[r.off + c.off] = c.size end
			end
		end
	end
	return res, temps
end

return {}
