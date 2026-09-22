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
-- One walk, in order, because which came first is the whole point: a
-- slot written before it is read in this block does not need what
-- came in, and that is where liveness stops.  The destination of an
-- assignment is written, not read; everything else an AUTO names is
-- read.
--
-- `cross` is the slots a call is live across.  Within one block that
-- means touched before a call and again after it -- neither live in
-- nor live out, so nothing else would catch it.
local function touches(r, b)
	local read, write, calls = {}, {}, false
	local before, cross = {}, {}
	local sawcall = false

	local function scan(n, seen)
		if not n or type(n) ~= "table" or seen[n] then return end
		seen[n] = true
		if n.op == "AUTO" and n.off then
			if not write[n.off] then read[n.off] = true end
			if sawcall and before[n.off] then cross[n.off] = true end
			before[n.off] = true
			return
		end
		if n.op == "ASGN" and n.left and n.left.op == "AUTO" and
		   n.left.off then
			-- The right runs first and may read this slot,
			-- which is what `x += 1` is.
			scan(n.right, seen)
			for _, a in ipairs(n.arms or {}) do scan(a, seen) end
			seen[n.left] = true
			write[n.left.off] = true
			if sawcall and before[n.left.off] then
				cross[n.left.off] = true
			end
			before[n.left.off] = true
			return
		end
		if n.op == "CALL" then
			-- The callee and the arguments run before it.
			scan(n.left, seen)
			for _, a in ipairs(n.args or {}) do scan(a, seen) end
			calls, sawcall = true, true
			return
		end
		scan(n.left, seen)
		scan(n.right, seen)
		for _, a in ipairs(n.arms or {}) do scan(a, seen) end
		for _, a in ipairs(n.args or {}) do scan(a, seen) end
	end

	local seen = {}

	for i = b.at, b.to, STRIDE do
		local k = r[i]

		if k == "e" or k == "c" then scan(r[i + 1], seen) end
	end
	return read, write, calls, cross
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
        local rd, wr, calls, cr = touches(r, b)

        info[b] = {read = rd, write = wr, calls = calls, cross = cr,
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
            -- Anything live through the block is live across the
            -- call in it; anything touched on both sides of one is
            -- live across it without being either.
            for off in pairs(d.livein) do crosses[off] = true end
            for off in pairs(d.liveout) do crosses[off] = true end
            for off in pairs(d.cross) do crosses[off] = true end
        end
    end
    return info, crosses, used
end

-- Which slots may live in a register at all.
--
-- The hard one is TEXT.  An inlined body and a statement expression
-- were built into text while the record was put down, and that text
-- already names its slots the way the machine addresses them.  Move
-- such a slot into a register and the text still reaches the frame.
-- So a function holding any text keeps its slots where they are.
--
-- ADDR is the other: a slot whose address is taken can be reached
-- through a pointer, and a register has no address.
function ir.eligible(r, t)
	local ok, bad, text = {}, {}, false
	local seen = {}

	for i = 1, r.n, STRIDE do
		local k = r[i]

		if k == "e" or k == "c" then
			walk(r[i + 1], function(n)
				if n.op == "TEXT" or n.op == "ASM" then
					text = true
				elseif n.op == "ADDR" and n.left and
				       n.left.op == "AUTO" and n.left.off then
					bad[n.left.off] = true
				elseif n.op == "COPY" then
					-- a record copied whole is
					-- addressed, not read
					text = true
				elseif n.op == "AUTO" and n.off then
					local ty = n.ty

					if ty and not ty.x87 and
					   ty.kind ~= "float" and
					   ty.kind ~= "array" and
					   ty.kind ~= "struct" and
					   ty.kind ~= "union" and
					   ty.size and ty.size <= t.ptrsize
					then
						ok[n.off] = true
					else
						bad[n.off] = true
					end
				end
			end, seen)
		end
	end
	if text then return {} end
	for off in pairs(bad) do ok[off] = nil end
	return ok
end

-- Give the slots that earn one a register.
--
-- Two slots may share a register when they are never live at the same
-- time.  Liveness is by block here, which is coarse and safe: two
-- slots live in one block are held apart even where they would not
-- have met.
--
-- `free` is the registers no expression is ever given and the ABI
-- does not ask back, so a slot in one costs no save and no restore --
-- but only a slot that is never live across a call may use it.
function ir.colour(r, blocks, info, crosses, eligible, free)
	local live, weight = {}, {}

	for _, b in ipairs(blocks) do
		local d = info[b]
		local here = {}

		for off in pairs(d.livein) do here[off] = true end
		for off in pairs(d.read) do here[off] = true end
		for off in pairs(d.write) do here[off] = true end
		for off in pairs(here) do
			live[off] = live[off] or {}
			live[off][b] = true
		end
	end
	local want = {}
	-- A slot live on the way into the first block is one nothing
	-- in the body wrote: a parameter, which the prologue put there
	-- outside the record, or a local read before it is set.  Give
	-- it a register and every read finds a register nothing filled.
	local entry = blocks[1] and info[blocks[1]].livein or {}

	for off in pairs(eligible) do
		if not crosses[off] and not entry[off] then
			local n = 0

			for _ in pairs(live[off] or {}) do n = n + 1 end
			weight[off] = n
			want[#want + 1] = off
		end
	end
	-- The busiest first, and by offset after that so two runs of
	-- the compiler agree.
	table.sort(want, function(a, b)
		if weight[a] ~= weight[b] then return weight[a] > weight[b] end
		return a < b
	end)
	local pin, taken = {}, {}

	for _, off in ipairs(want) do
		for _, reg in ipairs(free) do
			local clash = false

			for other, where in pairs(taken) do
				if where == reg then
					for b in pairs(live[off] or {}) do
						if (live[other] or {})[b] then
							clash = true
							break
						end
					end
				end
				if clash then break end
			end
			if not clash then
				taken[off] = reg
				pin[off] = reg
				break
			end
		end
	end
	return pin
end

-- Put the answer on the nodes, where the code tables read it.
function ir.mark(r, pin)
	local seen = {}
	local n = 0

	for i = 1, r.n, STRIDE do
		local k = r[i]

		if k == "e" or k == "c" then
			walk(r[i + 1], function(x)
				if x.op == "AUTO" and x.off and pin[x.off] then
					x.pin = pin[x.off]
					n = n + 1
				end
			end, seen)
		end
	end
	return n
end

return ir
