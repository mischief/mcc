-- SPDX-License-Identifier: ISC
-- The matcher and the driver, target neutral.
--
-- `expr` is the 1972 rcexpr: try the table for the context asked for, and
-- fall back to computing into a register and adapting.  Everything machine
-- dependent is reached through the target table, never written here.

local tree = require "mcc.tree"
local md = require "mcc.md"
local buf = require "mcc.buf"

local gen = {}
gen.__index = gen

function gen.new(target, sink, opt)
	return setmetatable({
		t = target,
		sink = sink,
		o = opt or {},
		spill = 0,
		-- How many values are sitting below the stack pointer
		-- waiting to be read.  Nothing may move the stack pointer
		-- while any of them are.
		nomove = 0,
		nlabel = 0,
		fdepth = {},
		dcalc = target.dcalc or tree.dcalc,
	}, gen)
end

-- Recording ------------------------------------------------------------
--
-- Everything this compiler emits, it emits while it parses, so at a
-- join both arms are already written and nothing above can see the
-- whole function.  A record holds the calls instead, in order, and
-- plays them back at the end -- which leaves room in between for a
-- pass that does need the whole function.
--
-- Four slots a call and not a table for each: a Lua table costs 308
-- bytes here and four slots cost about 70, measured.  It is the same
-- reason lex.lua keeps a token as six slots.
--
-- Whether a function is recorded at all is settled before its body is
-- built, from how many tokens it holds -- which the parser already has,
-- because it takes the body off the input before reading it.  Deciding
-- once and up front means there is no half-recorded state: a function
-- is either kept whole or written straight out, and the second is
-- exactly what this compiler did before any of this.
--
-- Stopping partway is what a budget check inside the record would do,
-- and it is wrong: emitting in the middle of the parse puts code in a
-- different basic block from where the parse would have put it,
-- because the two interleave with state the parser is still changing.
local RSTRIDE = 5

function gen:startrec()
	self.rec = {n = 0}
end

-- True while the calls are being kept rather than made.
function gen:recording()
	return self.rec ~= nil
end

local function put(g, k, a, b, c, d)
	local r = g.rec
	local n = r.n

	r[n + 1], r[n + 2], r[n + 3] = k, a, b
	r[n + 4], r[n + 5] = c, d
	r.n = n + RSTRIDE
	return true
end

-- The parser sometimes needs the text an expression turns into, not
-- the expression: an inlined body and a statement expression are both
-- built into a buffer of their own and travel on as a TEXT node.
-- Recording defeats that, because nothing reaches a sink.  So the
-- record is put down for the length of such a window and the code is
-- written for real; the TEXT node that comes out of it goes through
-- the record like anything else, so the order is kept.
function gen:pause()
	local r = self.rec

	self.rec = nil
	return r
end

function gen:resume(r)
	self.rec = r
end

function gen:endrec()
	local r = self.rec

	self.rec = nil
	return r
end

function gen:playback(r)
	if not r then return end
	for i = 1, r.n, RSTRIDE do
		local k = r[i]

		if k == "e" then self:expr(r[i + 1], r[i + 2], r[i + 3])
		elseif k == "c" then
			self:docond(r[i + 1], r[i + 2], r[i + 3], r[i + 4])
		elseif k == "j" then self.t.jump(self, r[i + 1])
		elseif k == "w" then self:write(r[i + 1])
		elseif k == "l" then self:putlabel(r[i + 1])
		elseif k == "p" then self:landing()
		elseif k == "h" then self:hush()
		elseif k == "u" then self:unhush()
		end
	end
end

-- A landing pad, where an indirect branch is allowed to arrive.  Only a
-- machine with branch protection has one, and only when asked.
function gen:landing()
	if self:recording() and put(self, "p") then return end
	if self.o.cet and self.t.landing then self.t.landing(self) end
end

function gen:write(s)
	if self:recording() and put(self, "w", s) then return end
	self.sink:add(s)
end

-- Throw away what is written until the matching `unhush`.  A statement
-- nothing can reach is still read, because it may hold a label, but what
-- it would compile to is dropped: a program writes code in an arm it has
-- ruled out that the machine it is built for cannot even encode.
-- The constraint letters that take a constant.  Several of them take
-- only part of the range, and the machine says which: `N` is the port
-- number of an in or out instruction and stops at 255, so a wider one
-- has to go to a register instead.  A letter whose range the value
-- misses is passed over, and the next letter in the constraint decides.
local IMMLETTER = "inNsIJKLMOeZ"

local function immok(t, c, v)
	for i = 1, #c do
		local l = c:sub(i, i)

		if IMMLETTER:find(l, 1, true) and
		   (not t.asmfits or t.asmfits(l, v)) then
			return true
		end
	end
	return false
end

function gen:hush()
	if self:recording() and put(self, "h") then return end
	local n = (self.nhush or 0) + 1

	self.nhush = n
	if n == 1 then
		self.heard, self.sink = self.sink, buf.new()
	end
end

function gen:unhush()
	if self:recording() and put(self, "u") then return end
	local n = self.nhush - 1

	self.nhush = n
	if n == 0 then
		self.sink, self.heard = self.heard, nil
	end
end

function gen:newlabel()
	self.nlabel = self.nlabel + 1
	return ".L" .. self.nlabel
end

function gen:putlabel(l)
	if self:recording() and put(self, "l", l) then return end
	self:write(l .. ":\n")
end

-- Which nodes the two operand shapes describe.  A leaf describes itself,
-- as it did in the original.
local function operands(n)
	local d = tree.ops[n.op]
	if d.arity == 0 then return n, nil end
	if d.arity == 1 then return n.left, nil end
	return n.left, n.right
end

function gen:fits(sh, n, nreg)
	if not sh then return true end
	if not n then
		return not sh.deref and sh.max >= 4
	end
	-- Through a widening conversion of the same sign, which emits
	-- nothing: the operand is what was converted, at its own width.
	if sh.thru then
		local c = n.left

		if n.op ~= "CVT" or not c or not c.ty or
		   n.ty.kind ~= c.ty.kind or n.ty.size <= c.ty.size or
		   (n.ty.kind ~= "int" and n.ty.kind ~= "uint") then
			return false
		end
		n = c
	end
	if self.dcalc(n, nreg) > sh.max then return false end
	if sh.deref and n.op ~= "INDIR" then return false end
	-- A local the body keeps in a register: the operand is the
	-- register, so the template may address through it and nothing
	-- is loaded to reach it.
	if sh.pin and not (n.op == "AUTO" and n.pin) then return false end
	if sh.kind == "ptr" then
		-- a size letter beside p constrains the pointee
		if n.ty.kind ~= "ptr" then return false end
		if sh.size and (not n.ty.to or n.ty.to.size ~= sh.size) then
			return false
		end
		if sh.pkind and (not n.ty.to or n.ty.to.kind ~= sh.pkind) then
			return false
		end
		return true
	end
	if sh.nocon and n.op == "CONST" then return false end
	if sh.size and n.ty.size ~= sh.size then return false end
	if sh.kind and n.ty.kind ~= sh.kind then return false end
	return true
end

function gen:match(n, ctx, reg)
	local ops = self.t.code[ctx]
	if not ops then return nil end
	local alts = ops[n.op]
	if not alts then return nil end
	local nr = self.t.nreg - reg
	local o1, o2 = operands(n)
	for _, a in ipairs(alts) do
		-- An operand worked out into the next register has one
		-- register fewer to work with: `e` means it fits what is
		-- left from where it starts, not from where this node
		-- starts.  Counted from here, the last alternative to
		-- take a register reached past the allocation order.
		local b1, b2 = 0, 0

		for _, st in ipairs(md.steps(a)) do
			if st.sel == "left" then b1 = st.bump
			elseif st.sel == "right" then b2 = st.bump end
		end
		if self:fits(a[1], o1, nr - b1) and
		   self:fits(a[2], o2, nr - b2) and
		   (not a.pred or a.pred(o1, o2, n)) then
			return a
		end
	end
	return nil
end

-- Reading one of these changes nothing, so in an effect context there is
-- nothing to emit -- and on a target where the value is wider than a
-- register there is no instruction that could.
local NOEFFECT = {AUTO = true, NAME = true, CONST = true, ADDR = true,
		  INDIR = true, GOT = true}

-- Operators that produce a truth value.  They have no table entry; the
-- generator builds them from branches and two constants.
local COND = {EQ = true, NE = true, LT = true, LE = true, GT = true,
	      GE = true, ANDAND = true, OROR = true, LNOT = true}

-- Which depths hold a float.  A machine with a file of its own needs to
-- know before it saves one, and by then the node is out of reach.
function gen:expr(n, ctx, reg)
	if self:recording() and put(self, "e", n, ctx, reg) then return end
	self:value(n, ctx, reg)
	if ctx == "reg" and n and n.ty then
		self.fdepth[reg or 0] = n.ty.kind == "float" and
			(n.ty.x87 and "x" or true) or nil
	end
end

function gen:value(n, ctx, reg)
	if not n then return end
	reg = reg or 0
	-- Reading a variable or a constant for its effect does nothing, and
	-- on a target where the value is wider than a register there is no
	-- instruction that could.
	if ctx == "eff" and NOEFFECT[n.op] and not tree.effects(n) then
		return
	end
	-- A record read for its effect reads nothing: perl writes
	-- `(void)*(PL_ppaddr[OP_LC])(aTHX)`, and only the call is left.
	if ctx == "eff" and n.op == "INDIR" and n.ty and
	   (n.ty.kind == "struct" or n.ty.kind == "union") then
		return self:value(n.left, "eff", reg)
	end
	if n.op == "INREG" then
		if reg ~= n.regno then
			self.t.move(self, reg, n.regno, n.ty.size,
				    n.ty.kind == "float")
		end
		if ctx ~= "reg" then
			self.t.adapt(self, n, ctx, reg)
		end
		return
	end
	if n.op == "ASM" then
		self:inlineasm(n, reg)
		return
	end
	-- A statement expression: its code was written where it stood, and
	-- goes in here, which may be inside an arm that does not always
	-- run.  It starts from the first register, so whatever is live
	-- below this point is saved around it, the way a call is.
	if n.op == "TEXT" then
		for i = 0, reg - 1 do self.t.save(self, i) end
		self:write(self:valuetext(n.text))
		for i = reg - 1, 0, -1 do self.t.restore(self, i) end
		return
	end
	-- A name bound to a machine register at file scope: reading it
	-- reads the register.  Only an inline asm operand takes it as it
	-- stands, so this is the value form.
	if n.op == "HARD" then
		if not self.t.readhard then
			error("a global register variable is not supported " ..
				"on " .. self.t.name)
		end
		self.t.readhard(self, n.hard, reg or 0, n.ty.size)
		if ctx ~= "reg" then self.t.adapt(self, n, ctx, reg) end
		return
	end
	if n.op == "CALL" then
		self.t.call(self, n, reg)
		if ctx ~= "reg" then
			self.t.adapt(self, n, ctx, reg)
		end
		return
	end
	-- Only the last arm has a value; the rest are for their effect.
	if n.op == "SEQ" then
		for i, a in ipairs(n.arms) do
			self:expr(a, i == #n.arms and ctx or "eff", reg)
		end
		return
	end
	-- A conversion is about two types at once, which an operand shape
	-- cannot say, so the target is asked directly.
	if n.op == "CVT" then
		self:expr(n.left, "reg", reg)
		self.t.convert(self, n.left.ty, n.ty, reg)
		if ctx ~= "reg" then
			self.t.adapt(self, n, ctx, reg)
		end
		return
	end
	-- A conditional is control flow, so it is built here rather than
	-- matched.
	if n.op == "COND" then
		local lfalse, lend = self:newlabel(), self:newlabel()
		self:docond(n.left, lfalse, false, reg)
		self:expr(n.arms[1], ctx, reg)
		self.t.jump(self, lend)
		self:putlabel(lfalse)
		self:expr(n.arms[2], ctx, reg)
		self:putlabel(lend)
		return
	end
	-- A whole struct or union moves as bytes; no table can say how many.
	if n.op == "COPY" then
		self:expr(n.left, "reg", reg)
		self:expr(n.right, "reg", reg + 1)
		self.t.blockcopy(self, n.val, reg)
		return
	end
	local a = self:match(n, ctx, reg)
	if a then
		self:run(a, n, ctx, reg)
		return
	end
	-- A truth value with no table entry is built from branches, whatever
	-- the context asked for.
	if COND[n.op] then
		self:materialize(n, reg)
		if ctx ~= "reg" then
			self.t.adapt(self, n, ctx, reg)
		end
		return
	end
	if ctx ~= "reg" then
		a = self:match(n, "reg", reg)
		if a then
			self:run(a, n, "reg", reg)
			self.t.adapt(self, n, ctx, reg)
			return
		end
	end
	error(("no match for %s:%s in %s (need %d, reg %d)")
		:format(n.op, n.ty.name, ctx, n.need, reg))
end

-- Inline assembly.  Operands are numbered outputs first, then inputs, the
-- way gcc numbers them.  An asm statement is a statement, so no scratch
-- register is live when one is reached and there is no allocation to
-- reconcile: each operand simply takes the next free register, skipping any
-- the template names for itself.
function gen:inlineasm(n, reg)
	local t = self.t
	local list = {}
	-- A `+` constraint is read as well as written, so the value goes
	-- into the register before the template runs and comes back after.
	for _, o in ipairs(n.outs) do
		list[#list + 1] = {o = o, out = true,
			inout = (o.c or ""):find("+", 1, true) ~= nil}
	end
	for _, o in ipairs(n.ins) do list[#list + 1] = {o = o} end

	-- The operand shapes that are already a place the machine can
	-- name, or that one instruction can be made to name.  A constant
	-- is not one: `"rm" (0)` wants a register.
	local MEMOK = {AUTO = true, NAME = true, INDIR = true}
	-- A member of an object at file scope is `name + n`, which is a
	-- place the machine names as it stands.  Working the address
	-- out into a register instead makes the instruction a different
	-- length, and linux patches over `call *pv_ops+N(%rip)` by
	-- measuring it.
	local function nameoff(e, off, depth)
		off = off or 0
		if e == nil or (depth or 0) > 8 then return nil end
		if e.op == "ADDR" and e.left and e.left.op == "NAME" and
		   not e.left.got then
			return e.left, off + (e.left.off or 0)
		end
		if e.op == "CVT" then
			return nameoff(e.left, off, (depth or 0) + 1)
		end
		if e.op == "ADD" then
			if e.right and e.right.op == "CONST" then
				return nameoff(e.left, off + e.right.val,
					(depth or 0) + 1)
			end
			if e.left and e.left.op == "CONST" then
				return nameoff(e.right, off + e.left.val,
					(depth or 0) + 1)
			end
		end
		return nil
	end
	local taken, keep = {}, {}
	local function note(name)
		local idx, saved = t.asmpin(name)
		if idx then taken[idx] = true end
		if saved then keep[#keep + 1] = name end
	end
	for _, c in ipairs(n.clob) do
		if c ~= "memory" and c ~= "cc" then note(c) end
	end

	for _, d in ipairs(list) do
		local c = d.o.c:gsub("[=+&%%]", "")
		d.size = d.o.e.ty.size
		-- `"=@ccz"` answers with a condition the template left in
		-- the flags, not with a register the template wrote.  It
		-- still needs a place to land in, which the read below
		-- fills from the flags.
		local cc = d.out and d.o.c:match("^[=&]*@cc(%a+)$")

		if cc then
			d.ccout = cc
		elseif d.o.e.ty.vector and c:find("[xv]") and t.vregname then
			-- A vector in a vector register.  The parser left
			-- it in a frame slot, which one move fills from and
			-- one puts back.
			d.vec = true
		elseif c:match("^%d+$") then
			-- A matching constraint names an earlier operand
			-- and shares its place, so it needs none of its own.
			d.tie = tonumber(c) + 1
		-- A place the machine can name in an instruction is used
		-- as it stands, and an indirection has its address worked
		-- out into a register first.  Anything else is not a
		-- place, so a constraint that also offers a register, as
		-- `"rm"` does, takes one instead.
		elseif c:find("m") and (MEMOK[d.o.e.op] or
					not c:find("[rqQabcdSDgvxyz]")) then
			d.mem = true
			local e = d.o.e

			if e.op ~= "AUTO" and e.op ~= "NAME" and
			   e.op ~= "CONST" then
				if e.op ~= "INDIR" then
					error("an asm memory operand " ..
						"must be an lvalue")
				end
				local nm, off = nameoff(e.left)

				if nm and off == 0 then
					d.msym = nm
				elseif nm then
					d.msym = tree.node("NAME", e.ty,
						nil, nil,
						{sym = nm.sym ..
						 (off > 0 and "+" or "-") ..
						 math.abs(off)})
				else
					d.through = e.left
				end
			end
		elseif d.o.const and immok(t, c, d.o.const) then
			d.imm = d.o.const
		-- A constraint that offers nothing but an immediate has
		-- to have one.  gcc satisfies these after it inlines and
		-- folds; this compiler does neither, so say so rather
		-- than write a register where the template wants a
		-- number.
		elseif c:find("[inN]") and not c:find("[rmqQabcdSDfgvxyz]")
		then
			-- Code that cannot run is still read.  A kernel
			-- writes `WARN_ON(!IS_ENABLED(X))`, and with X on
			-- the arm is ruled out before the value it asks
			-- for is ever worked out.  None of this goes out,
			-- so any number will do.
			if (self.nhush or 0) > 0 then
				d.imm = 0
			else
				error("an asm operand with constraint '" ..
					d.o.c .. "' must be a constant")
			end
		elseif d.o.const and c:find("[IJKLMOeZs]") and
		       not c:find("[rmqQabcdSDfgvxyz]") then
			error("the constant " .. d.o.const ..
				" is outside what constraint '" .. d.o.c ..
				"' takes")
		elseif d.o.e.hard and t.hardreg then
			-- The expression is a name bound to a machine
			-- register, so that is the one the template sees
			-- whatever the constraint letter would have
			-- chosen.
			d.hard = d.o.e.hard
			d.fixed = t.hardreg(d.hard, d.size)
			if not d.fixed then
				error("no register " .. d.hard)
			end
			-- A name bound to the register at file scope is
			-- the register: there is nothing to load into it
			-- and nothing to put back afterwards.
			d.inplace = d.o.e.op == "HARD" or nil
			note(d.fixed)
		else
			-- On a machine that keeps floats in a file of their
			-- own, a float needs a constraint that names it.
			-- t and u name the top of the x87 stack and the
			-- one below it, which is how the extended type is
			-- handed to a template.
			if t.asmx87 and d.o.e.ty.x87 and c:find("[tuf]") then
				d.x87 = c:find("u") and 1 or 0
			elseif t.asmx87 and d.o.e.ty.kind == "float" and
			       c:find("[tu]") and not c:find("[xv]") then
				-- A double handed over on the x87
				-- stack, as a libm written for it does:
				-- it is worked out in an SSE register
				-- and crosses over around the template.
				d.x87 = c:find("u") and 1 or 0
				d.flt = true
			elseif t.fregname and d.o.e.ty.kind == "float" then
				if not c:find("[xvf]") then
					error("an asm operand with " ..
						"constraint '" .. d.o.c ..
						"' cannot hold a floating " ..
						"point value")
				end
				d.flt = true
			end
			for i = 1, #c do
				-- A pair is two registers holding one
				-- value and is not a register name, so
				-- it answers before `asmreg` does.
				if t.asmpair then
					d.pair = t.asmpair(c:sub(i, i),
							   d.size)
				end
				if d.pair then
					d.letter = c:sub(i, i)
					break
				end
				d.fixed = t.asmreg(c:sub(i, i), d.size)
				if d.fixed then
					d.letter = c:sub(i, i)
					break
				end
			end
			if d.fixed then note(d.fixed) end
			if d.pair then
				note(d.pair[1])
				note(d.pair[2])
			end
		end
	end

	-- An input pinned to the same register as an output shares its
	-- place, the way cpuid pairs "=a" with "a".
	for i, d in ipairs(list) do
		if not d.out and not d.tie and d.fixed then
			for j = 1, i - 1 do
				local o = list[j]

				if o.out and o.fixed == d.fixed then
					d.tie = j
					break
				end
			end
		end
	end

	-- An operand the machine can name as it stands goes to and from
	-- its register in one instruction, and needs no scratch place on
	-- the way.  A frame slot and a constant are most of what a
	-- kernel's port I/O hands to a template.
	-- ...but not one another operand shares a place with: a tie
	-- takes the register the other was given, and a plain operand
	-- is given none.
	local tied = {}

	for _, d in ipairs(list) do
		if d.tie then tied[d.tie] = true end
	end
	for i, d in ipairs(list) do
		local e = d.o.e

		if d.fixed and not d.tie and not tied[i] and not d.inplace and
		   not d.through and not d.mem and not d.imm and
		   not d.flt and not d.x87 and t.addr and
		   e and e.ty and e.ty.size == d.size then
			if e.op == "CONST" and not d.out and t.asmimm then
				d.plain = t.asmimm(e.val)
			elseif e.op == "AUTO" and e.off and not e.pin and
			       not e.hard and not e.vlasize and
			       (not d.out or d.o.direct) then
				-- A slot the register allocator took is
				-- not in the frame any more, whatever
				-- its address says.
				d.plain = t.addr(self, e)
			end
		end
	end

	-- An input pinned to a register goes there as soon as it is worked
	-- out, so when scratch runs short those take turns in one place
	-- rather than each holding one of their own.
	-- An operand pinned to a register passes through its scratch
	-- place and is done with it: an input before the template, an
	-- output after.  One that is read and written both takes two
	-- turns, one on each side, and needs the place for neither
	-- longer than that.
	local function turns(d)
		return d.fixed ~= nil and not d.through and
			not d.inplace and
			(not d.out or d.o.tmp ~= nil or d.o.direct)
	end
	local wants, pins, avail = 0, 0, 0
	for _, d in ipairs(list) do
		if not d.tie and not d.inplace and not d.plain and
		   not d.pair and not d.vec and
		   ((not d.mem and not d.imm) or d.through) then
			if turns(d) then
				pins = pins + 1
			else
				wants = wants + 1
			end
		end
	end
	for i = 0, t.nreg - 1 do
		if not taken[i] then avail = avail + 1 end
	end
	local serial = wants + pins > avail

	local most = t.nasmreg or t.nreg
	local free, shared = 0, nil
	local vfree = 0

	for _, d in ipairs(list) do
		if d.vec and not d.tie then
			d.vreg, vfree = vfree, vfree + 1
		end
	end
	for _, d in ipairs(list) do
		if not d.tie and not d.inplace and not d.plain and
		   not d.pair and not d.vec and
		   ((not d.mem and not d.imm) or d.through) then
			local turn = serial and turns(d)

			if turn and shared then
				d.reg, d.serial = shared, true
			else
				while taken[free] do free = free + 1 end
				if free >= most then
					error("too many asm operands in '" ..
						n.text .. "'")
				end
				-- Past the allocation order the register
				-- belongs to the caller, so it is saved
				-- around the template like a clobber.
				if free >= t.nreg then
					local nm = t.regname(free, t.ptrsize)

					keep[#keep + 1] = nm
				end
				d.reg, taken[free] = free, true
				free = free + 1
				if turn then shared, d.serial = d.reg, true end
			end
		end
	end
	for _, d in ipairs(list) do
		if d.tie then
			local o = list[d.tie]

			if not o then
				error("no asm operand " .. (d.tie - 1))
			end
			d.reg, d.fixed, d.letter = o.reg, o.fixed, o.letter
			d.mem, d.imm, d.flt, d.x87 = o.mem, o.imm, o.flt,
				o.x87
			d.vec, d.vreg = o.vec, o.vreg
			d.hard = o.hard
			-- Sharing a place means taking a turn in it.
			d.serial = o.serial
		end
	end

	-- A modifier letter before the digit asks for the operand at another
	-- width, or for a constant without whatever marks an immediate.
	local WIDTH = {b = 1, w = 2, k = 4, q = 8}

	local function operand(d, mod)
		if d.through then return t.memreg(d.reg) end
		if d.msym then return t.addr(self, d.msym) end
		if d.mem then return t.addr(self, d.o.e) end
		if d.imm then
			-- `c`, `p` and `P` ask for the constant with nothing
			-- in front of it.  `a` asks for it as an address
			-- the instruction can reach, which on a machine
			-- whose code is written relative to itself is
			-- not the same text: the kernel's static cpu
			-- feature test is `testb %[bit], %a[byte]`.
			if mod == "a" and t.asmaddr then
				return t.asmaddr(tostring(d.imm))
			end
			if mod == "c" or mod == "a" or mod == "p" or
			   mod == "P" then
				return tostring(d.imm)
			end
			return t.asmimm(d.imm)
		end
		if d.x87 then
			return d.x87 == 0 and "%st" or "%st(1)"
		end
		if d.vec then
			-- `%x0` and `%t0` ask for the xmm and ymm names
			local vs = mod == "x" and 16 or mod == "t" and 32 or
				d.size

			return t.vregname(d.vreg, vs)
		end
		local size = WIDTH[mod] or d.size
		if d.hard then return t.hardreg(d.hard, size) end
		if d.fixed then return t.asmreg(d.letter, size) end
		if d.flt then return t.fregname(d.reg, size) end
		return t.regname(d.reg, size)
	end

	local function find(name)
		for _, d in ipairs(list) do
			if d.o.name == name then return d end
		end
		error("no asm operand named " .. name)
	end

	local function byname(name)
		for _, l in ipairs(n.labels or {}) do
			if l.name == name then return l end
		end
		error("no asm label named " .. name)
	end

	local text, i, buf = n.text, 1, {}
	-- Basic asm, with no operands at all, goes through as written: a
	-- % in it belongs to the assembler, as in `%note`.
	local basic = #list == 0 and not n.ext

	if basic then i = #text + 1 end
	buf[1] = basic and text or nil
	while i <= #text do
		local ch = text:sub(i, i)
		if ch ~= "%" then
			buf[#buf + 1] = ch
			i = i + 1
		else
			local nx = text:sub(i + 1, i + 1)
			if nx == "%" then
				buf[#buf + 1] = "%"
				i = i + 2
			elseif nx == "=" then
				buf[#buf + 1] = tostring(self:newlabel())
					:gsub("%D", "")
				i = i + 2
			else
				local mod, k = nil, i + 1
				if nx:match("%a") and
				   text:sub(i + 2, i + 2):match("[%d%[]") then
					mod, k = nx, i + 2
				end
				-- `%l[name]` and `%lN` name a label the
				-- template may jump to, which only asm
				-- goto has.
				if mod == "l" then
					local c = text:sub(k, k)
					local lb, j

					if c == "[" then
						j = text:find("]", k + 1,
							true)
						lb = byname(text:sub(k + 1,
							j - 1))
						i = j + 1
					else
						local d = text:match("^%d+",
							k)

						lb = n.labels[tonumber(d) -
							#list + 1]
						i = k + #d
					end
					if not lb then
						error("no asm label")
					end
					buf[#buf + 1] = lb.sym
					goto nexttok
				end
				local c = text:sub(k, k)
				if c:match("%d") then
					local d = list[tonumber(c) + 1]
					if not d then
						error("no asm operand " .. c)
					end
					buf[#buf + 1] = operand(d, mod)
					i = k + 1
				elseif c == "[" then
					local j = text:find("]", k + 1, true)
					buf[#buf + 1] = operand(
						find(text:sub(k + 1, j - 1)),
						mod)
					i = j + 1
				else
					error("unknown asm escape %" .. nx)
				end
			end
		end
		::nexttok::
	end

	for _, name in ipairs(keep) do t.asmkeep(self, name, true) end
	-- A vector operand's slot: its own, or the one the parser gave an
	-- output that is not a frame slot.
	local function vslot(d)
		local e = d.o.e

		if d.out and d.o.tmp then e = tree.auto(e.ty, d.o.tmp) end
		return t.addr(self, e)
	end
	for _, d in ipairs(list) do
		if d.vec and not d.tie and (not d.out or d.inout) then
			t.vmove(self, vslot(d), t.vregname(d.vreg, d.size),
				d.size)
		end
	end
	-- Working a value out into register r may use every register above
	-- r as scratch, so the operands go in lowest register first: a
	-- tied input in register 0 worked out after one in register 1
	-- wrote over it (x86 csum_fold, and every checksum with it).
	local byreg = {}

	for _, d in ipairs(list) do byreg[#byreg + 1] = d end
	table.sort(byreg, function(x, y)
		return (x.reg or math.huge) < (y.reg or math.huge)
	end)
	for _, d in ipairs(byreg) do
		if d.through then
			self:expr(d.through, "reg", d.reg)
		elseif (not d.out or d.inout) and d.reg and not d.serial and
		       not d.plain then
			self:expr(d.o.e, "reg", d.reg)
		end
	end
	-- An input taking a turn goes alone: worked out, then moved home
	-- before the next one needs the place.
	for _, d in ipairs(list) do
		if d.serial and (not d.out or d.inout) then
			self:expr(d.o.e, "reg", d.reg)
			t.rawmove(self, d.fixed, t.regname(d.reg, d.size),
				  d.size)
		end
	end
	for _, d in ipairs(list) do
		if (not d.out or d.inout) and d.fixed and not d.serial and
		   not d.inplace then
			t.rawmove(self, d.fixed,
				  d.plain or t.regname(d.reg, d.size),
				  d.size)
		end
	end
	-- The x87 operands go on its stack last, deepest first, so that
	-- the one the template calls the top really is.
	for k = 1, 0, -1 do
		for _, d in ipairs(list) do
			if d.x87 == k and (not d.out or d.inout) then
				t.asmx87(self, d.reg, true, d.o.e.ty)
			end
		end
	end
	self:write("\t" .. table.concat(buf) .. "\n")
	-- A flag output is read straight after the template, before
	-- anything else here writes the flags.
	for _, d in ipairs(list) do
		if d.ccout then
			if not t.asmflag then
				error("an asm flag output is not supported " ..
					"on " .. t.name)
			end
			t.asmflag(self, d.ccout, d.reg, d.size)
		end
	end
	-- and come off it in the other order.  An input the template
	-- did not take is still there and has to go; a clobber naming
	-- its place is how a template says it took it.
	local function tookst(k)
		for _, c in ipairs(n.clob) do
			if c == ("st(" .. k .. ")") or
			   (k == 0 and c == "st") then
				return true
			end
		end
		return false
	end

	-- An input tied to an output is the output's value going in, and
	-- comes off as the output: it is not dropped as well.
	for _, d in ipairs(list) do
		if d.x87 == 1 and not d.out and not d.tie and
		   not tookst(1) then
			t.asmx87drop(self, 1)
		end
	end
	for k = 0, 1 do
		for _, d in ipairs(list) do
			if d.x87 == k and d.out then
				t.asmx87(self, d.reg, false, d.o.e.ty)
			end
		end
	end
	for _, d in ipairs(list) do
		if d.x87 == 0 and not d.out and not d.tie and
		   not tookst(0) then
			t.asmx87drop(self, 0)
		end
	end
	-- An output goes to a frame slot of its own first: storing it into
	-- its lvalue could need a second register and destroy another output.
	-- A pair holds one value in two registers; both halves go back.
	for _, d in ipairs(list) do
		if d.pair and d.out then
			local lo, hi = t.asmhalves(self, d.o.e)

			if not lo then
				error("an asm operand with constraint '" ..
					(d.o.c or "") .. "' has to be a " ..
					"place this machine can name")
			end
			t.rawmove(self, lo, d.pair[1], 4)
			t.rawmove(self, hi, d.pair[2], 4)
		end
	end
	for _, d in ipairs(list) do
		if d.vec and d.out then
			t.vmove(self, t.vregname(d.vreg, d.size), vslot(d),
				d.size)
		end
	end
	for _, d in ipairs(list) do
		-- An output the template wrote to memory is already where
		-- it belongs and has no landing place to read back from.
		if d.out and not d.through and not d.pair and not d.vec and
		   (d.o.tmp or d.o.direct) then
			if d.fixed and d.o.direct and d.plain then
				-- Straight from the register the template
				-- left it in to the slot it belongs to.
				t.rawmove(self, d.plain, d.fixed, d.size)
				goto nextout
			end
			if d.fixed then
				t.rawmove(self, t.regname(d.reg, d.size),
					  d.fixed, d.size)
			end
			local ty = d.o.e.ty
			local dst = d.o.direct and d.o.e or
				tree.auto(ty, d.o.tmp)

			self:expr(tree.binary("ASGN", ty, dst,
				tree.node("INREG", ty, nil, nil,
					  {regno = d.reg})), "eff", d.reg)
		end
		::nextout::
	end
	for j = #keep, 1, -1 do t.asmkeep(self, keep[j], false) end
end

function gen:run(a, n, ctx, reg)
	local held = 0
	local steps = md.steps(a)
	-- A fixed-register instruction destroys registers the allocator does
	-- not know it is using.  Save the ones still holding a value.
	--
	-- An operand left on the stack is popped by the template itself,
	-- so it has to be on top when the template runs: the saves go
	-- first there, underneath it.  A divide by a value parked on the
	-- stack otherwise popped the saved dividend's neighbour and
	-- divided by that.
	local saved
	local function save()
		if not a.clob then return end
		for _, c in ipairs(a.clob) do
			if c < reg then
				saved = saved or {}
				saved[#saved + 1] = c
				self.t.save(self, c)
			end
		end
	end
	local early = false

	for _, s in ipairs(steps) do
		if s.ctx == "stack" then early = true end
	end
	if early then save() end
	for _, s in ipairs(steps) do
		local sub = n
		if s.sel == "left" then sub = n.left
		elseif s.sel == "right" then sub = n.right end
		if s.deref and sub and sub.op == "INDIR" then
			sub = sub.left
		end
		self:expr(sub, s.ctx, reg + s.bump)
		if s.ctx == "stack" then
			held = held + 1
			self.nomove = self.nomove + 1
		end
	end
	self.nomove = self.nomove - held
	if not early then save() end
	if type(a.asm) == "function" then
		a.asm(self, n, reg)
	elseif a.asm and #a.asm > 0 then
		self:emit(a, n, reg)
	end
	if saved then
		for i = #saved, 1, -1 do
			self.t.restore(self, saved[i])
		end
	end
end

function gen:emit(a, n, reg)
	local t = self.t
	local o1, o2 = operands(n)
	local labels = {}
	local buf = {}
	-- `rz` says which type sizes %R: the node by default, or an operand
	-- where the instruction works at the operand's width.
	local rty = n.ty
	if a.rz == 1 then rty = o1.ty elseif a.rz == 2 then rty = o2.ty end

	local function pick(i)
		if i == 1 then return o1 elseif i == 2 then return o2 end
		return n
	end

	for _, p in ipairs(md.parts(a)) do
		if p.lit then
			buf[#buf + 1] = p.lit
		elseif p.esc == "A" then
			buf[#buf + 1] = t.addr(self, pick(p.arg))
		elseif p.esc == "R" then
			buf[#buf + 1] = t.regname(reg + (p.arg or 0), rty.size)
		elseif p.esc == "T" then
			-- The extended float file, which is frame slots:
			-- the same depth, and nothing a call can destroy.
			buf[#buf + 1] = t.ldslot(self, reg + (p.arg or 0))
		elseif p.esc == "F" then
			-- The float file, indexed by the same depth: the
			-- value at depth k is in float register k, and no
			-- two live values share a depth.
			buf[#buf + 1] = t.fregname(reg + (p.arg or 0),
				rty.size)
		elseif p.esc == "P" then
			buf[#buf + 1] = t.regname(reg + (p.arg or 0), t.ptrsize)
		elseif p.esc == "W" then
			buf[#buf + 1] = t.regname(reg + (p.arg or 0), 4)
		elseif p.esc == "C" then
			local x = pick(p.arg)
			buf[#buf + 1] = tostring(x.val or x.off)
		elseif p.esc == "N" then
			local x = pick(p.arg)
			buf[#buf + 1] = tostring(-(x.val or x.off))
		elseif p.esc == "z" then
			buf[#buf + 1] = t.suffix(pick(p.arg).ty)
		elseif p.esc == "I" then
			-- %I2 asks the target for the alternative's second
			-- mnemonic, where one template needs both
			local alt = a
			if p.arg == 2 then
				alt = setmetatable({store = true},
						   {__index = a})
			end
			buf[#buf + 1] = assert(t.mnem(n, alt),
					       "no mnemonic for " .. n.op)
		elseif p.esc == "S" then
			-- the top of the spill area, taken off it: a target
			-- whose stack pointer must not move after the
			-- prologue spills into its own frame instead
			self.spill = self.spill - 1
			buf[#buf + 1] = tostring(t.spillslot(self.spill))
		elseif p.esc == "L" then
			local k = p.arg or 0
			labels[k] = labels[k] or self:newlabel()
			buf[#buf + 1] = labels[k]
		end
	end
	self:write(table.concat(buf))
	self:write("\n")
end

-- Branch on a condition.  The short-circuit operators are control flow, so
-- they never reach a table; the rest go through the cc context and the
-- target's conditional jump.
-- An unconditional branch.  The parser went straight to the target
-- for this, which put a jump into the record as text like any other
-- write; a block cannot be built from that.  Recorded, it says where
-- it goes.
function gen:jump(label)
	if self:recording() and put(self, "j", label) then return end
	self.t.jump(self, label)
end

-- The front door, and the only one the parser uses.  Recorded whole:
-- a branch has to be built again when the registers are decided, so
-- keeping the text it turned into is not enough.
function gen:cond(n, label, sense, reg)
	if self:recording() and put(self, "c", n, label, sense, reg) then
		return
	end
	return self:docond(n, label, sense, reg)
end

-- A body's text with each `return` marker turned into what reading the
-- value needs: the store into the slot, and the jump to the body's end.
function gen:valuetext(text)
	if not text:find("\1", 1, true) then return text end
	return (text:gsub("\1(%d+)([AB])\1", function(id, part)
		local m = self.retmarks[tonumber(id)]

		return (part == "A" and m.store or m.jump) or ""
	end))
end

-- The text of an unconditional jump, for splicing into a body's text.
function gen:jumptext(label)
	local sv, one = self.sink, buf.new()

	self.sink = one
	self.t.jump(self, label)
	self.sink = sv
	return one:text()
end

-- A body built where it was called, used as a test: when every return
-- in it was a constant, each one jumps to the arm it picks, and the
-- slot the value would sit in is never written or read.  Nothing is
-- live in a register across it, because a jump out of the middle would
-- skip the restore after it.
function gen:branchbody(n, label, sense, reg)
	if reg ~= 0 or #n.arms ~= 2 then return false end
	local t, x = n.arms[1], n.arms[2]

	if t.op ~= "TEXT" or not t.slot or not t.rets then return false end
	while x.op == "LNOT" do sense, x = not sense, x.left end
	if x.op ~= "AUTO" or x.off ~= t.slot or x.part or x.bf then
		return false
	end
	-- A marker that went into some other text -- a statement
	-- expression inside the body -- has been written as a store
	-- already, and only the slot knows what it said.
	for id in pairs(t.rets) do
		if not t.text:find("\1" .. id .. "A\1", 1, true) or
		   not t.text:find("\1" .. id .. "B\1", 1, true) then
			return false
		end
	end
	local lfall = self:newlabel()
	local text = t.text:gsub("\1(%d+)([AB])\1", function(id, part)
		local m = t.rets[tonumber(id)]

		if not m then
			-- a body inside this one that was read for
			-- its value, as an argument or an operand
			m = self.retmarks[tonumber(id)]
			return (part == "A" and m.store or m.jump) or ""
		end
		if part == "A" then return "" end
		return self:jumptext((m.k ~= 0) == sense and label or lfall)
	end)

	self:write(text)
	-- Falling off the end of a body that should have returned a
	-- value is undefined; it goes the way a false answer would.
	self:putlabel(lfall)
	return true
end

function gen:docond(n, label, sense, reg)
	reg = reg or 0
	-- A condition that is already settled is not a test: the branch
	-- is taken always or never.  `do { ... } while (0)` is written
	-- in every other macro a kernel has, and testing a nought in a
	-- register leaves code nothing can reach behind it.
	if n.op == "CONST" then
		if (n.val ~= 0) == sense then self.t.jump(self, label) end
		return
	end
	local op = n.op
	if op == "LNOT" then
		return self:docond(n.left, label, not sense, reg)
	elseif op == "ANDAND" or op == "OROR" then
		local l = n.left

		-- A body built where it was called carries its code and
		-- then its value.  The code runs here either way, and
		-- what is left may be settled.
		while l.op == "SEQ" and l.arms and #l.arms > 0 do
			for i = 1, #l.arms - 1 do
				self:expr(l.arms[i], "eff", reg)
			end
			l = l.arms[#l.arms]
		end
		-- A left that is settled decides on its own.  A kernel
		-- writes `do { } while (0 && (c))` to keep `c` type
		-- checked and nothing else, and guards a call to a name
		-- nothing defines with a test that answers false.
		if l.op == "CONST" then
			if (op == "ANDAND") ~= (l.val ~= 0) then
				if (op == "OROR") == sense then
					self.t.jump(self, label)
				end
				return
			end
			return self:docond(n.right, label, sense, reg)
		end
		if op == "ANDAND" then
			if sense then
				local x = self:newlabel()

				self:docond(l, x, false, reg)
				self:docond(n.right, label, true, reg)
				self:putlabel(x)
			else
				self:docond(l, label, false, reg)
				self:docond(n.right, label, false, reg)
			end
		elseif sense then
			self:docond(l, label, true, reg)
			self:docond(n.right, label, true, reg)
		else
			local x = self:newlabel()

			self:docond(l, x, true, reg)
			self:docond(n.right, label, false, reg)
			self:putlabel(x)
		end
		return
	elseif op == "COND" then
		-- A conditional in a condition is control flow twice over:
		-- each arm decides the branch on its own.
		local lelse, lend = self:newlabel(), self:newlabel()
		self:docond(n.left, lelse, false, reg)
		self:docond(n.arms[1], label, sense, reg)
		self.t.jump(self, lend)
		self:putlabel(lelse)
		self:docond(n.arms[2], label, sense, reg)
		self:putlabel(lend)
		return
	elseif op == "SEQ" then
		if self:branchbody(n, label, sense, reg) then return end
		-- Only the last arm decides the branch; the rest are effects.
		for i = 1, #n.arms - 1 do
			self:expr(n.arms[i], "eff", reg)
		end
		return self:docond(n.arms[#n.arms], label, sense, reg)
	end
	self:expr(n, "cc", reg)
	self.t.branch(self, n, label, sense, reg)
end

-- Whether a condition is settled, without writing anything down.
local function known(n)
	if n == nil then return nil end
	if n.op == "CONST" then return n.val ~= 0 end
	if n.op == "LNOT" then
		local v = known(n.left)

		if v == nil then return nil end
		return not v
	end
	if n.op == "SEQ" and n.arms and #n.arms > 0 then
		return known(n.arms[#n.arms])
	end
	if n.op == "ANDAND" or n.op == "OROR" then
		local a = known(n.left)

		if a == nil then return nil end
		if a == (n.op == "OROR") then return a end
		return known(n.right)
	end
	return nil
end

-- Turn a condition into a zero or a one in a register.
function gen:materialize(n, reg)
	local v = known(n)

	if v ~= nil then
		local l = self:newlabel()

		-- What the condition does still happens.  The branch is
		-- the only thing that goes, and with it the arm behind
		-- it, which no run arrives at.
		self:docond(n, l, not v, reg)
		self:putlabel(l)
		self:expr(tree.const(n.ty, v and 1 or 0), "reg", reg)
		return
	end
	-- A machine that can read a condition out of its flags into a
	-- register does that for a plain comparison, or the not of one,
	-- or the not of a value: no branch, no labels.
	if self.t.setflag then
		local m, sense = n, true

		if m.op == "LNOT" then m, sense = m.left, false end
		local d = tree.ops[m.op]

		if (d and d.rel) or (not sense and not COND[m.op]) then
			self:expr(m, "cc", reg)
			self.t.setflag(self, m, sense, reg, n.ty.size)
			return
		end
	end
	local lfalse, lend = self:newlabel(), self:newlabel()
	self:docond(n, lfalse, false, reg)
	self:expr(tree.const(n.ty, 1), "reg", reg)
	self.t.jump(self, lend)
	self:putlabel(lfalse)
	self:expr(tree.const(n.ty, 0), "reg", reg)
	self:putlabel(lend)
end

return gen
