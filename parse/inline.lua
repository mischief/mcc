-- SPDX-License-Identifier: ISC
-- Bodies built where they are called: which calls qualify, binding the
-- arguments, playing the body back in place, and the numbers a slot is
-- known to hold while it runs.

local tree = require "tree"
local buf = require "buf"
local P = require "parse.base"
local cf = require "parse.fold"
local fold = cf.fold
local isptr = cf.isptr
local isrec = cf.isrec
local mentions = cf.mentions
local retyped = cf.retyped
local settle = cf.settle
local tokens = require "parse.tokens"
local NFIELD = tokens.NFIELD
local scanlabels = tokens.scanlabels
local scanwrites = tokens.scanwrites
local words = require "parse.words"
local ASMKW = words.ASMKW

-- How deep one expansion may sit inside another, and how long a body
-- may be.  Past either, the call stays a call.
--
-- `__attribute__((always_inline))` means what it says, and a kernel
-- leans on it: a function that reads a table in .init.rodata is
-- written that way so that the reference lands in its caller, which
-- is in .init.text.  Left out of line it would be a reference from
-- .text to .init, which the kernel's own checker refuses.  So the
-- length does not apply to one, and the depth is far enough not to
-- be reached by anything a person writes.
local INLDEPTH, INLTOKENS, INLALWAYS = 4, 160, 24
-- Under -Os, how many tokens a body may have and still be built where
-- it is called.
local INLSMALL = 24
-- What a body that is one `return` is allowed to hold.
local INLONERET = 600

function P:inlinable(g, args)
	local p = g and g.pending

	-- A body written without `inline` waits only to be let go of,
	-- not to be built where it was called.
	if not p or not p.lx then return false end
	-- A body put in a section by name was put there on purpose, and
	-- building it somewhere else moves it out of that section.
	if p.sec then return false end

	-- Asked for small code: a body that says `always_inline` is
	-- built where it was called, because a kernel leans on it to
	-- put the reference in the caller's section; so is a small
	-- body that is an asm statement, because a call to one costs
	-- more than the instruction it wraps; and so is a body of a
	-- few tokens, whose argument and result now bind where the
	-- caller has them.  Measured: bodies up to 24 tokens shrink the
	-- corpus and 40 grow it.
	if self.small and not p.always and not self:asmwrap(p.lx) and
	   (p.lx.fold or p.lx).ntok > INLSMALL then
		return false
	end
	if (self.inldepth or 0) >= (p.always and INLALWAYS or INLDEPTH) then
		return false
	end

	local lx = p.lx.fold or p.lx

	if not p.always and
	   lx.ntok > (lx.single and INLONERET or INLTOKENS) then
		return false
	end
	if p.lx.once then return false end
	local ty = p.ty

	if ty.variadic or ty.noproto then return false end
	if #args ~= #ty.params then return false end
	-- A function of no arguments names none, so there is nothing to
	-- ask about; one with arguments has to name every one of them.
	if #ty.params > 0 and not ty.pnames then return false end
	for i = 1, #ty.params do
		local t = ty.params[i]

		-- A wide value travels by other means; keep to what a
		-- slot and an assignment can carry.  A small record can:
		-- the kernel passes pmd_t and pud_t by value everywhere,
		-- and a body that never looks at one still has to be
		-- built where it was called for its answer to settle.
		if not (ty.pnames[i] and ty.pnames[i] ~= "") then
			return false
		end
		if t.kind == "array" or self:widepass(t) or
		   (isrec(t) and (t.complex or t.size > 16)) then
			return false
		end
	end
	local r = ty.ret

	if r ~= self.ty.void and (isrec(r) or self:byparts(r) or
	    r.kind == "array" or self:widepass(r)) then
		return false
	end
	return true
end

-- Whether a body is small and holds an asm statement, read off its
-- tokens.
local INLASM = 48

function P:asmwrap(lx)
	local l = lx.fold or lx

	if l.ntok > INLASM then return false end
	if l.asmwrap == nil then
		l.asmwrap = false
		for i = 1, l.n, NFIELD do
			if l.f[i] == "name" and ASMKW[l.f[i + 1]] then
				l.asmwrap = true
				break
			end
		end
	end
	return l.asmwrap
end

-- Build the body where it was called.  The code goes to a buffer of its
-- own and travels in the tree, the way a statement expression's does, so
-- an arm of `?:` takes its own with it.
function P:inline(g, args)
	local p = g.pending
	local ty = p.ty
	local saved = self.g.sink
	local blk = buf.new()
	local paused = self.g:pause()

	self.g.sink = blk
	-- The answer outlives the block that fills it: the slot is taken
	-- before the scope opens, so the scope closing does not hand it
	-- to the next expansion while the value is still wanted.
	local res = ty.ret ~= self.ty.void and self:alloc(ty.ret) or nil
	-- A name in the body means what it meant where the body was
	-- written, not what it means here.  The blocks around the call
	-- go out of sight: what is left is the file, whose names are
	-- global and whose tags are the outermost level.  Without this a
	-- caller with a local called `apic` changes what a header's
	-- `apic->read` reads.
	local oscopes, otags = self.scopes, self.tags

	self.scopes, self.tags = {}, {self.tags[1]}
	self:push()
	-- Each parameter is a slot of its own, written once before the
	-- body runs.  Beside it the argument is kept, so an operand that
	-- must be a constant can read what the caller wrote as long as
	-- nothing has changed the parameter yet.
	local frame = {byoff = {}, up = self.inl}

	-- Each write goes to a buffer of its own, so that one the body
	-- never reads can be left out: `__apply_fineibt` takes five
	-- arguments and looks at none of them, and two of the five are
	-- names this configuration does not define.
	local pres = {}
	-- `scanwrites` names every parameter the body assigns to, steps,
	-- or takes the address of.  One it does not name holds what the
	-- caller wrote for as long as the body runs.
	local blx = p.lx.fold or p.lx
	local bsc = scanwrites(blx.f, blx.n)

	for i, pt in ipairs(ty.params) do
		local off = self:alloc(pt)
		local a = self:conv(args[i], pt)
		local one = buf.new()
		local sv = self.g.sink

		self.g.sink = one
		self.g:expr(self:assignto(tree.auto(pt, off), a), "eff")
		self.g.sink = sv
		self:declare(ty.pnames[i], {kind = "local", ty = pt,
					    off = off})
		frame.byoff[off] = {arg = a, live = true,
				    ro = bsc.w[ty.pnames[i]] == nil,
				    depth = self.loopdepth}
		pres[#pres + 1] = {off = off, out = one,
				   eff = tree.effects(a)}
	end
	local rty = ty.ret
	local void = rty == self.ty.void
	local orty, oend, olab, ofn = self.rty, self.endlabel,
		self.labelmap, self.fname
	local ores, orec = self.inlres, self.recret
	local ires

	-- A label inside the body belongs to this expansion alone, so a
	-- body built twice does not name the same label twice.
	-- The registers set aside for this function were chosen from
	-- its own tokens.  A body built inside it has its own names
	-- and its own locals, and nothing has looked at them, so it
	-- gets none of them.
	local opins = self.pins

	self.pins = nil
	self.rty = void and self.word or rty
	self.endlabel = self.g:newlabel()
	self.labelmap = {}
	-- A label written out by name carries the function's, so each
	-- expansion needs one of its own.
	self.ninline = (self.ninline or 0) + 1
	self.fname = ("%s.i%d"):format(ofn or "f", self.ninline)
	-- The body returns nothing a record return would carry, so the
	-- caller's arrangements for one are out of the way.
	self.recret = nil
	self.inlres = res and {off = res, ty = rty, n = 0} or nil
	self.inl = frame
	self.inldepth = (self.inldepth or 0) + 1
	-- A return in the body leaves the body, not the function it was
	-- built into, so what follows the expansion is reachable again.
	local odead, oret = self.dead, self.retused
	-- A label inside a body built where it was called is reached
	-- only from inside it, so it says nothing about the code around
	-- the call.
	local orev, omark = self.revived, self.deadmark
	local owrites = self.writes
	-- Every slot this body touches has to outlive it, so how far it
	-- reached is counted rather than where it ended.
	local ohi = self.hiwater

	self.hiwater = self.nlocals
	-- A body built where nothing can reach the call is itself out
	-- of reach.
	self.retused, self.deadmark = false, nil
	local lx = blx

	self.writes = bsc
	-- The body brought its own labels and its own blocks.  A goto
	-- inside it reaches none of the scopes around the call, so the
	-- depths start again here and nothing below this point is run.
	local olbd, obd, obase = self.labelbd, self.bdepth, self.inlbase

	self.labelbd = scanlabels(lx.f, lx.n, 1, 0)
	self.bdepth, self.inlbase = 0, #self.cleanups
	-- The body's nodes outlive its statements: the value it ends
	-- with is worked out by the caller, after the body has run.
	local oheld = tree.hold(true)

	self:replay(lx, P.block)
	tree.hold(oheld)
	self.labelbd, self.bdepth, self.inlbase = olbd, obd, obase
	local used = self.hiwater

	self.hiwater = ohi and (ohi > used and ohi or used) or nil
	-- Nothing comes back from a body that ended with nothing
	-- reachable and never returned: the label at its end is where a
	-- return would have gone, and there was none.
	local noway = self.dead and not self.retused

	self.g:putlabel(self.endlabel)
	self.dead, self.retused = odead, oret
	self.revived, self.deadmark = orev, omark
	self.writes = owrites
	self.inldepth = self.inldepth - 1
	self.inl = frame.up
	self.pins = opins
	self.rty, self.endlabel, self.labelmap, self.fname =
		orty, oend, olab, ofn
	ires, self.inlres, self.recret = self.inlres, ores, orec
	-- The slots this body used are not handed back.  Its code
	-- travels in the tree and runs later, beside whatever was built
	-- after it: an argument worked out here and a parameter written
	-- there would otherwise take turns in one slot, and the second
	-- one would land on the first.  Raising the mark keeps them
	-- until the block ends, which costs a few words at a site that
	-- is rare.
	self.marks[#self.marks] = used
	self:pop()
	self.scopes, self.tags = oscopes, otags
	self.g.sink = saved
	self.g:resume(paused)

	-- Which return ran decides what the slot holds, so what one of
	-- them wrote is not what the expansion answers.
	if res then self.konsts[res] = nil end
	-- The writes the body had a use for, and then the body.
	local head = buf.new()

	for _, one in ipairs(pres) do
		local sl = frame.byoff[one.off]

		-- A read that took the caller's constant instead does
		-- not want the slot; when every read did, nothing
		-- reads it and the write is dead.
		if one.eff or (sl.nread or 0) > (sl.nsub or 0) then
			one.out:move(head)
		end
	end
	blk:move(head)
	local text = tree.node("TEXT", self.ty.void, nil, nil,
			       {text = head:text()})

	-- Every return was a constant, so a test on the expansion can
	-- branch from each return instead of reading the slot.
	if ires and ires.marks then
		text.rets = ires.marks
		text.slot = not ires.plain and res or nil
	end
	-- A body with one return of a settled value is that value, so a
	-- test on it -- `enabled() && handler()` where enabled answers
	-- false -- settles too.
	local konst = ires and ires.n == 1 and ires.konst or nil
	local v = void and tree.const(self.ty.i32, 0)
		or (konst and tree.const(rty, konst))
		or (ires and ires.n == 1 and ires.value)
		or tree.auto(rty, res)

	-- What the body said about the answer travels with it: a test on
	-- a value behind a mask settles even when the value does not.
	if ires and ires.n == 1 and ires.mask and v.op == "AUTO" then
		v.mask = ires.mask
	end

	local n = tree.node("SEQ", v.ty, nil, nil, {arms = {text, v}})

	n.noret = (noway or g.noreturn) and true or nil
	return n
end

-- The record a body built where it was called keeps for one of its
-- parameter slots, or nil for a slot that is not one.
function P:inlslot(off)
	local f = self.inl

	while f do
		if f.byoff[off] then return f.byoff[off] end
		f = f.up
	end
	return nil
end

-- What the caller wrote for a parameter, while the parameter still
-- holds it.  Only an operand that has to be a constant asks.
function P:inlarg(e)
	-- A member at the front of a record parameter has the slot's
	-- offset and is not the slot: the caller wrote the whole record,
	-- and this reads a piece of it at the piece's own type.
	if e == nil or e.op ~= "AUTO" or e.part or e.bf then return nil end
	local f = self.inl

	while f do
		local s = f.byoff[e.off]

		if s then
			if not s.live or s.depth < self.loopdepth then
				return nil
			end
			if s.konst then
				return tree.const(s.kty, s.konst)
			end
			return s.arg
		end
		f = f.up
	end
	return nil
end

-- The same tree with every parameter that still holds what the caller
-- wrote replaced by what the caller wrote, so an operand built out of
-- one -- `1 << (bit & 7)` -- can be worked out here.  Answers nothing
-- when no parameter is named, so the ordinary path is not disturbed.
function P:inlsubst(e, depth)
	if e == nil or (depth or 0) > 16 then return nil end
	if e.op == "AUTO" then
		local a = self:inlarg(e)

		-- What the caller handed over may itself be a parameter
		-- of whatever built the caller, so this goes all the way
		-- out.
		if not a then return nil end
		a = self:inlsubst(a, (depth or 0) + 1) or a
		return retyped(a, e.ty)
	end
	local l = self:inlsubst(e.left, (depth or 0) + 1)
	local r = self:inlsubst(e.right, (depth or 0) + 1)
	local arms, any = nil, l ~= nil or r ~= nil

	if e.arms then
		for i, a in ipairs(e.arms) do
			local b = self:inlsubst(a, (depth or 0) + 1)

			if b then
				arms = arms or {table.unpack(e.arms)}
				arms[i] = b
				any = true
			end
		end
	end
	if not any then return nil end
	local c = tree.clone(e)

	c.left, c.right = l or e.left, r or e.right
	if arms then c.arms = arms end
	return tree.reneed(c)
end

-- A label may be jumped to from anywhere, so nothing a slot held
-- before it can be trusted after it.
-- Whether every write to a name from here on puts back the number it
-- already holds.  The kernel writes `can_reclaim_pt = false` inside a
-- loop below the label, over a slot that was false to begin with.
function P:samewrites(list, at, k)
	if not list then return false end
	for _, one in ipairs(list) do
		if one.at >= at then
			local v = one.v

			if not v then return false end
			if v.kind == "num" then
				if v.val ~= k.konst then return false end
			elseif v.kind == "name" then
				local sym = self:find(v.text)

				if not sym or sym.kind ~= "const" or
				   sym.val ~= k.konst then
					return false
				end
			else
				return false
			end
		end
	end
	return true
end

-- What a label does to the values slots are known to hold.  `from` is
-- the earliest place a run can arrive from, and `at` is where the
-- label stands.  A slot is no longer known when something writes it
-- after the label -- the run may come back round -- or when the write
-- that gave it its value stands after that earliest arrival, because
-- a run that jumped here never passed through it.
function P:inlclear(from, at)
	local f = self.inl
	local sc = self.writes

	at = at or (self.lx and self.lx.i)
	if sc and at then
		for off, k in pairs(self.konsts) do
			local last = k.name and sc.w[k.name]

			if not k.name or not k.at or
			   (last and last >= at and
			    not self:samewrites(sc.wv[k.name], at, k)) or
			   (from and k.at > from) then
				self.konsts[off] = nil
			end
		end
	else
		self.konsts = {}
	end
	while f do
		for _, s in pairs(f.byoff) do s.live = false end
		f = f.up
	end
end

-- A slot of a body built where it was called, given a value settled
-- where it stands.  The number is kept rather than the tree: the arena
-- hands the nodes of a statement back at the end of it, and this has
-- to last until the slot is written or the body ends.
function P:notekonst(off, e, ty, hard, was)
	if self.dead or hard or isrec(ty) or self:iswide(ty) then
		return
	end
	-- A volatile object may change under the program: every read
	-- goes to memory.
	if ty.volatile or (self.volat and self.volat[off]) then return end
	if not self.ty.isint(ty) and not isptr(ty) then return end
	-- `x = x + 1` in a loop writes a different number every turn.
	if self.loopdepth > 0 and mentions(e, off) then
		return
	end
	local k = fold(e)

	-- A copy of a slot that holds one number holds the same one.
	-- A statement expression hands its value over that way, and an
	-- operand may decide the answer on its own.
	if k == nil then k = settle(self:unseq(self:subkonst(e))) end
	if k == nil then return end
	k = fold(self:conv(tree.const(e.ty, k), ty))
	if k == nil then return end
	-- A write that puts back what was already there changes
	-- nothing, so the slot keeps the answer it had and the run it
	-- was written in.  The kernel sets a flag false again inside a
	-- loop over a flag that was false to begin with.
	if was and was.konst == k and was.kty == ty then
		self.konsts[off] = was
		return
	end
	-- Where the write stands: the arm of the `if` or the turn of the
	-- loop it is in.  A read outside that arm may not have passed
	-- through it, and one on a later turn of the loop may be reading
	-- what the turn before wrote.
	local d = #self.regions

	self.konsts[off] = {konst = k, kty = ty,
			    name = self.slotname and self.slotname[off],
			    at = self.lx and self.lx.i,
			    depth = self.loopdepth,
			    region = d, id = self.regions[d]}
end

-- What a slot holds, when it is the same number wherever the read
-- stands.
function P:knownkonst(off)
	local s = self.konsts[off]

	if not s then return nil end
	if s.depth < self.loopdepth then return nil end
	if s.region > 0 and self.regions[s.region] ~= s.id then
		return nil
	end
	return s
end

-- Each arm of a test and each body of a loop is a run of its own.
function P:pushregion()
	self.nregion = self.nregion + 1
	self.regions[#self.regions + 1] = self.nregion
end

function P:popregion()
	self.regions[#self.regions] = nil
end

-- Whatever is written to is no longer what the caller wrote.
function P:inlkill(e)
	if e == nil then return end
	if e.op == "INDIR" or e.op == "ADDR" then e = e.left end
	if e == nil or e.op ~= "AUTO" then return end
	-- A write nothing can reach leaves the slot as it was.
	if not self.dead then self.konsts[e.off] = nil end
	local f = self.inl

	while f do
		local s = f.byoff[e.off]

		if s then s.live = false return end
		f = f.up
	end
end

return {}
