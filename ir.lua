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

-- Every node of a tree, once.  A tree is a tree, but an arm or an
-- argument list can hold the same node twice and walking it twice
-- would count a use twice.
local function walk(n, f, seen)
	if not n or type(n) ~= "table" then return end
	if seen[n] then return end
	seen[n] = true
	f(n)
	walk(n.left, f, seen)
	walk(n.right, f, seen)
	for _, a in ipairs(n.arms or {}) do walk(a, f, seen) end
	for _, a in ipairs(n.args or {}) do walk(a, f, seen) end
end

-- What each block does to each slot, and whether a call runs in it.
--
-- A slot is read where an AUTO node names it and written where one is
-- the left of an assignment.  A write that happens before any read in
-- the block kills what came in, which is what liveness needs to stop
-- at.
local function touches(r, b)
	local read, write, calls = {}, {}, false
	local seen = {}

	for i = b.at, b.to, STRIDE do
		local k = r[i]

		if k == "e" or k == "c" then
			local n = r[i + 1]
			local killed = {}

			walk(n, function(x)
				if x.op == "CALL" then calls = true end
				if x.op == "ASGN" and x.left and
				   x.left.op == "ASGN" then return end
			end, seen)
			-- The left of an assignment is written; every
			-- other AUTO is read.
			walk(n, function(x)
				if x.op ~= "AUTO" or not x.off then return end
				if not write[x.off] and not killed[x.off] then
					read[x.off] = true
				end
			end, {})
			walk(n, function(x)
				if x.op == "ASGN" and x.left and
				   x.left.op == "AUTO" and x.left.off then
					write[x.left.off] = true
					killed[x.left.off] = true
				end
			end, {})
		end
	end
	return read, write, calls
end

-- Which slots are live where, by walking the graph backwards to a
-- fixpoint.  `live[b]` is the set of slots live on entry to b.
--
-- Also answers, per slot, whether it is live across a call: a slot
-- live on entry to a block that calls, or written before a call in
-- one and read after, cannot sit in a register the callee may use.
function ir.liveness(r, blocks)
    local info = {}

    for _, b in ipairs(blocks) do
        local rd, wr, calls = touches(r, b)

        info[b] = {read = rd, write = wr, calls = calls,
                   livein = {}, liveout = {}}
    end
    local changed = true

    while changed do
        changed = false
        for n = #blocks, 1, -1 do
            local b = blocks[n]
            local d = info[b]
            local out = {}

            for _, s in ipairs(b.succ) do
                for off in pairs(info[s].livein) do out[off] = true end
            end
            d.liveout = out
            for off in pairs(out) do
                if not d.write[off] and not d.livein[off] then
                    d.livein[off] = true
                    changed = true
                end
            end
            for off in pairs(d.read) do
                if not d.livein[off] then
                    d.livein[off] = true
                    changed = true
                end
            end
        end
    end
    -- A slot that is live anywhere a call runs cannot live in a
    -- register the ABI lets the callee keep.
    local crosses, used = {}, {}

    for _, b in ipairs(blocks) do
        local d = info[b]

        for off in pairs(d.read) do used[off] = true end
        for off in pairs(d.write) do used[off] = true end
        if d.calls then
            for off in pairs(d.livein) do crosses[off] = true end
            for off in pairs(d.liveout) do crosses[off] = true end
            -- Anything the block itself touches around the call.
            for off in pairs(d.read) do crosses[off] = true end
            for off in pairs(d.write) do crosses[off] = true end
        end
    end
    return info, crosses, used
end

return ir
