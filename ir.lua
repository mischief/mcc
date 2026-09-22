-- SPDX-License-Identifier: ISC
-- Basic blocks over a recorded function.
--
-- gen.lua keeps a function as a flat list of calls rather than writing
-- it out as it is read; this reads that list and says where the blocks
-- are and which block reaches which.  Nothing here emits anything.
--
-- A block starts at a label and after any branch.  What ends one is a
-- jump, a conditional branch, or a label, and a block that falls off
-- its end reaches the block after it.
--
-- A record entry is five slots: the kind and four payloads.  The kinds
-- that matter here are "l" a label, "j" a jump, and "c" a conditional
-- branch whose payloads are the tree, the label, the sense and the
-- register.  Everything else is code inside whatever block it stands
-- in.

local ir = {}

local STRIDE = 5

-- Walk the record and return the blocks, in the order they were
-- written.  Each block is {at, to, label, succ}: the first and last
-- record index it covers, the label it opens with if it has one, and
-- the blocks control may reach from it.
--
-- `byname` maps a label to the block that opens with it, which is how
-- a branch finds where it goes.
function ir.blocks(r)
	local blocks, byname = {}, {}
	local cur = {at = 1, ends = false}

	local function close(to)
		cur.to = to
		blocks[#blocks + 1] = cur
	end

	for i = 1, r.n, STRIDE do
		local k = r[i]

		if k == "l" then
			-- A label opens a block.  One that follows a
			-- branch opens the block that was waiting.
			if i > cur.at or cur.label then
				close(i - STRIDE)
				cur = {at = i}
			end
			cur.label = r[i + 1]
			byname[r[i + 1]] = cur
		elseif k == "j" then
			cur.jumpto = r[i + 1]
			cur.ends = true
			close(i)
			cur = {at = i + STRIDE}
		elseif k == "c" then
			cur.branchto = r[i + 2]
			close(i)
			cur = {at = i + STRIDE}
		end
	end
	if cur.at <= r.n or #blocks == 0 then close(r.n) end

	-- Now the edges.  A jump reaches only where it goes; a
	-- conditional reaches there and the block after it; anything
	-- else falls through.
	for n, b in ipairs(blocks) do
		local next = blocks[n + 1]

		b.succ = {}
		if b.jumpto then
			local t = byname[b.jumpto]

			if t then b.succ[1] = t end
		else
			if b.branchto then
				local t = byname[b.branchto]

				if t then b.succ[#b.succ + 1] = t end
			end
			if next then b.succ[#b.succ + 1] = next end
		end
	end
	-- And the other way round, which is what a variable read walks.
	for _, b in ipairs(blocks) do b.pred = {} end
	for _, b in ipairs(blocks) do
		for _, s in ipairs(b.succ) do
			s.pred[#s.pred + 1] = b
		end
	end
	return blocks, byname
end

return ir
