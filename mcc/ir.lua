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
	-- an inlined body kept as a record: the trees in it
	if n.op == "BODY" then
		for i = 1, n.rec.n, STRIDE do
			local k = n.rec[i]

			if k == "e" or k == "c" then walk(n.rec[i + 1], f, seen) end
		end
	end
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
	-- How many times each slot is named.  Every one of them is an
	-- instruction that reaches memory, so the count is what a
	-- register would save.
	local hits = {}
	-- inside an inlined body, every touch counts as a read: its
	-- own branches are not blocks here, so what it writes first
	-- may run after what it reads
	local region = 0

	-- An AUTO is a leaf, and every place the walk reaches one is a
	-- real use of it.  So it is accounted before the `seen` gate:
	-- mcc builds a temporary as SEQ{ASGN(t, e), t} with the SAME
	-- node in both places, and gated, the second one vanishes --
	-- which makes a slot read after a call look like a slot
	-- nothing reads, and puts it in a register a call destroys.
	local function touch(off, iswrite)
		if region > 0 then iswrite = false end
		hits[off] = (hits[off] or 0) + 1
		if iswrite then
			write[off] = true
		elseif not write[off] then
			read[off] = true
		end
		if sawcall and before[off] then cross[off] = true end
		before[off] = true
	end

	local function scan(n, seen)
		if not n or type(n) ~= "table" then return end
		if n.op == "AUTO" and n.off then
			touch(n.off, false)
			return
		end
		if seen[n] then return end
		seen[n] = true
		if n.op == "ASGN" and n.left and n.left.op == "AUTO" and
		   n.left.off then
			-- The right runs first and may read this slot,
			-- which is what `x += 1` is.
			scan(n.right, seen)
			for _, a in ipairs(n.arms or {}) do scan(a, seen) end
			touch(n.left.off, true)
			return
		end
		if n.op == "CALL" then
			-- The callee and the arguments run before it.
			scan(n.left, seen)
			for _, a in ipairs(n.args or {}) do scan(a, seen) end
			calls, sawcall = true, true
			return
		end
		if n.op == "BODY" then
			region = region + 1
			for i = 1, n.rec.n, STRIDE do
				local k = n.rec[i]

				if k == "e" or k == "c" then
					scan(n.rec[i + 1], seen)
				end
			end
			region = region - 1
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
	return read, write, calls, cross, hits
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
		local rd, wr, calls, cr, hits = touches(r, b)

		info[b] = {read = rd, write = wr, calls = calls, cross = cr,
				   hits = hits, livein = {}, liveout = {}}
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
			-- Everything this block touches, not only what is live
			-- through it.  Narrowing this to "touched before the
			-- call and again after" is wrong: the walk is over a
			-- tree and the tree is not the order the code runs in.
			-- Sethi-Ullman evaluates the harder subtree first, so
			-- in `t + f(x)` the call runs BEFORE t is read, though
			-- t is the left child and the walk reaches it first.
			for off in pairs(d.livein) do crosses[off] = true end
			for off in pairs(d.liveout) do crosses[off] = true end
			for off in pairs(d.read) do crosses[off] = true end
			for off in pairs(d.write) do crosses[off] = true end
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
-- So a function holding any text keeps its slots where they are,
-- unless the target can say which slots a text names (`frameref`):
-- then only those stay.
--
-- ADDR is the other: a slot whose address is taken can be reached
-- through a pointer, and a register has no address.
--
-- A record copied whole borrows registers past the allocation order.
-- A target that names its callee-saved registers keeps those clear of
-- the copy, so for it a copy only says so in the second answer.
function ir.eligible(r, t, held)
	local ok, bad, text, copies = {}, {}, false, false
	local fixed = {}
	local seen = {}

	-- Text that names slots: those stay, and it may call.
	local function named(s)
		for off in s:gmatch(t.frameref) do
			bad[tonumber(off)] = true
		end
		copies = true
		-- a register the token scan gave is written into it,
		-- and has to stay what it was
		for _, h in ipairs(held or {}) do
			if s:find(h.name, 1, true) then fixed[h.reg] = true end
		end
	end

	for i = 1, r.n, STRIDE do
		local k = r[i]

		if k == "w" and t.frameref and type(r[i + 1]) == "string" then
			-- written into the record as it stands
			if r[i + 1]:find(t.frameref) then named(r[i + 1]) end
		elseif k == "e" or k == "c" then
			walk(r[i + 1], function(n)
				if n.op == "TEXT" and t.frameref and
				   type(n.text) == "string" then
					-- An inlined body.  Its returns
					-- are marks filled in as it is
					-- written; the stores they stand
					-- for name the result's slot.
					named(n.text)
					if n.slot then bad[n.slot] = true end
					for _, m in pairs(n.rets or {}) do
						if type(m) == "table" and
						   type(m.store) == "string" then
							named(m.store)
						end
					end
					if n.text:find("\1", 1, true) and
					   not n.slot and not n.rets then
						text = true
					end
				elseif n.op == "TEXT" or n.op == "ASM" then
					text = true
				elseif n.op == "BODY" then
					-- what it wrote raw, and whether
					-- it calls: only the callee-saved
					-- registers live through one
					for j = 1, n.rec.n, STRIDE do
						if n.rec[j] == "w" and
						   type(n.rec[j + 1]) == "string" and
						   t.frameref and
						   n.rec[j + 1]:find(t.frameref) then
							named(n.rec[j + 1])
						end
					end
					copies = true
				elseif n.op == "ADDR" and n.left and
				       n.left.op == "AUTO" and n.left.off then
					bad[n.left.off] = true
				elseif n.op == "COPY" then
					copies = true
					if not t.savedregs then
						text = true
					end
				elseif n.op == "AUTO" and n.off then
					local ty = n.ty

					if ty and not ty.x87 and
					   ty.kind ~= "float" and
					   ty.kind ~= "array" and
					   ty.kind ~= "struct" and
					   ty.kind ~= "union" and
					   ty.size and ty.size <= t.ptrsize
					then
						-- one offset may be two locals
						-- in turn; the narrowest decides
						if not ok[n.off] or ty.size < ok[n.off] then
							ok[n.off] = ty.size
						end
					else
						bad[n.off] = true
					end
				end
			end, seen)
		end
	end
	if text then return {}, copies, true, fixed end
	for off in pairs(bad) do ok[off] = nil end
	return ok, copies, false, fixed
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
-- How many times a slot has to be named before a register is worth
-- spending on it.  The register costs a save and a restore; each
-- mention it saves is a load or a store that does not happen.
local PAYOFF = 4

-- Whether a value in reg survives a call, and a record copy.
local function saved(t, reg)
	return t and (t.freesaved or (t.savedregs and t.savedregs[reg]))
end

-- How deep in loops each block is.  A jump back to a block at or
-- before it closes a loop over the blocks between, which is what
-- structured code makes.
local function loopdepth(blocks)
	local at, depth = {}, {}

	for n, b in ipairs(blocks) do
		at[b], depth[b] = n, 0
	end
	for n, b in ipairs(blocks) do
		for _, s in ipairs(b.succ) do
			if at[s] <= n then
				for k = at[s], n do
					depth[blocks[k]] = depth[blocks[k]] + 1
				end
			end
		end
	end
	return depth
end

function ir.colour(r, blocks, info, crosses, eligible, free, t, copies,
		   first)
	local live, weight, hits = {}, {}, {}
	local depth = loopdepth(blocks)

	for _, b in ipairs(blocks) do
		local d = info[b]
		local here = {}
		-- a mention in a loop is made once a turn
		local times = 8 ^ math.min(depth[b], 3)

		for off in pairs(d.livein) do here[off] = true end
		for off in pairs(d.read) do here[off] = true end
		for off in pairs(d.write) do here[off] = true end
		for off in pairs(here) do
			live[off] = live[off] or {}
			live[off][b] = true
		end
		for off, n in pairs(d.hits) do
			hits[off] = (hits[off] or 0) + n * times
		end
	end
	local want = {}

	for off in pairs(eligible) do
		if (hits[off] or 0) >= PAYOFF then
			weight[off] = hits[off]
			want[#want + 1] = off
		end
	end
	-- The slots in `first` before the rest, which are the members
	-- of records held apart; then the busiest first, and by offset
	-- after that so two runs of the compiler agree.
	table.sort(want, function(a, b)
		local fa, fb = not first or first[a], not first or first[b]

		if fa ~= fb then return fa and true or false end
		if weight[a] ~= weight[b] then return weight[a] > weight[b] end
		return a < b
	end)
	local pin, taken = {}, {}

	for _, off in ipairs(want) do
		for _, reg in ipairs(free) do
			-- Not every register has a name at every width:
			-- esi and edi on i386 have no eight-bit half,
			-- so a `char` cannot live in one.
			local clash = t and t.canhold and
				not t.canhold(reg, eligible[off])

			-- a call or a record copy destroys the rest
			if (crosses[off] or copies) and not saved(t, reg) then
				clash = true
			end

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

-- Take the registers the token scan gave back off the nodes, so the
-- allocator can hand them out again, all but those in keep.  Answers
-- the slots that keep theirs.
function ir.unpin(r, keep)
	local seen, kept = {}, {}

	for i = 1, r.n, STRIDE do
		local k = r[i]

		if k == "e" or k == "c" then
			walk(r[i + 1], function(x)
				if x.op == "AUTO" and x.pin then
					if keep[x.pin] then
						kept[x.off] = true
					else
						x.pin = nil
					end
				end
			end, seen)
		end
	end
	return kept
end

-- The record as text on stderr, one entry a line, for MCC_IRDUMP.
function ir.dump(r, pin)
	local function show(n)
		if type(n) ~= "table" then return tostring(n) end
		local s = n.op .. (n.off and ("@" .. n.off) or "") ..
			(n.part and "p" or "") .. (n.pin and ("=r" .. n.pin) or "") ..
			(n.ty and (":" .. (n.ty.kind or "?") .. (n.ty.size or "")) or "")
		local kids = {}

		for _, c in ipairs({n.left, n.right}) do kids[#kids + 1] = show(c) end
		for _, c in ipairs(n.arms or {}) do kids[#kids + 1] = show(c) end
		for _, c in ipairs(n.args or {}) do kids[#kids + 1] = show(c) end
		if n.op == "BODY" then kids[#kids + 1] = "{" .. n.rec.n // STRIDE .. " entries}" end
		return #kids > 0 and (s .. "(" .. table.concat(kids, " ") .. ")") or s
	end
	for i = 1, r.n, STRIDE do
		local x = r[i + 1]

		io.stderr:write(r[i], " ", tostring(r[i + 2]), " ", type(x) == "table" and show(x) or
			(tostring(x):gsub("\n", "|")), "\n")
	end
	for off, reg in pairs(pin or {}) do
		io.stderr:write("pin ", off, " r", reg, "\n")
	end
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
