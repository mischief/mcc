-- The matcher and the driver, target neutral.
--
-- `expr` is the 1972 rcexpr: try the table for the context asked for, and
-- fall back to computing into a register and adapting.  Everything machine
-- dependent is reached through the target table, never written here.

local tree = require "tree"
local md = require "md"

local gen = {}
gen.__index = gen

function gen.new(target, sink)
	return setmetatable({
		t = target,
		sink = sink,
		spill = 0,
		nlabel = 0,
		dcalc = target.dcalc or tree.dcalc,
	}, gen)
end

function gen:write(s)
	self.sink:add(s)
end

function gen:newlabel()
	self.nlabel = self.nlabel + 1
	return ".L" .. self.nlabel
end

function gen:putlabel(l)
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
	if self.dcalc(n, nreg) > sh.max then return false end
	if sh.deref and n.op ~= "INDIR" then return false end
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
		if self:fits(a.s1, o1, nr) and self:fits(a.s2, o2, nr) then
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

function gen:expr(n, ctx, reg)
	if not n then return end
	reg = reg or 0
	-- Reading a variable or a constant for its effect does nothing, and
	-- on a target where the value is wider than a register there is no
	-- instruction that could.
	if ctx == "eff" and NOEFFECT[n.op] and not tree.effects(n) then
		return
	end
	if n.op == "INREG" then
		if reg ~= n.regno then
			self.t.move(self, reg, n.regno, n.ty.size)
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
		self:write(n.text)
		for i = reg - 1, 0, -1 do self.t.restore(self, i) end
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
		self:cond(n.left, lfalse, false, reg)
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
		if c:find("m") then
			d.mem = true
		elseif d.o.const and (c:find("i") or c:find("n") or
				      c:find("N")) then
			d.imm = d.o.const
		else
			for i = 1, #c do
				d.fixed = t.asmreg(c:sub(i, i), d.size)
				if d.fixed then
					d.letter = c:sub(i, i)
					break
				end
			end
			if d.fixed then note(d.fixed) end
		end
	end

	local free = 0
	for _, d in ipairs(list) do
		if not d.mem and not d.imm then
			while taken[free] do free = free + 1 end
			assert(free < t.nreg, "too many asm operands")
			d.reg, taken[free] = free, true
			free = free + 1
		end
	end

	-- A modifier letter before the digit asks for the operand at another
	-- width, or for a constant without whatever marks an immediate.
	local WIDTH = {b = 1, w = 2, k = 4, q = 8}

	local function operand(d, mod)
		if d.mem then return t.addr(self, d.o.e) end
		if d.imm then
			if mod == "c" then return tostring(d.imm) end
			return t.asmimm(d.imm)
		end
		local size = WIDTH[mod] or d.size
		if d.fixed then return t.asmreg(d.letter, size) end
		return t.regname(d.reg, size)
	end

	local function find(name)
		for _, d in ipairs(list) do
			if d.o.name == name then return d end
		end
		error("no asm operand named " .. name)
	end

	local text, i, buf = n.text, 1, {}
	-- Basic asm, with no operands at all, goes through as written: a
	-- % in it belongs to the assembler, as in `%note`.
	if #list == 0 then i = #text + 1 end
	buf[1] = #list == 0 and text or nil
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
	end

	for _, name in ipairs(keep) do t.asmkeep(self, name, true) end
	for _, d in ipairs(list) do
		if (not d.out or d.inout) and d.reg then
			self:expr(d.o.e, "reg", d.reg)
		end
	end
	for _, d in ipairs(list) do
		if (not d.out or d.inout) and d.fixed then
			t.rawmove(self, d.fixed, t.regname(d.reg, d.size),
				  d.size)
		end
	end
	self:write("\t" .. table.concat(buf) .. "\n")
	-- An output goes to a frame slot of its own first: storing it into
	-- its lvalue could need a second register and destroy another output.
	for _, d in ipairs(list) do
		if d.out then
			if d.fixed then
				t.rawmove(self, t.regname(d.reg, d.size),
					  d.fixed, d.size)
			end
			local ty = d.o.e.ty
			self:expr(tree.binary("ASGN", ty,
				tree.auto(ty, d.o.tmp),
				tree.node("INREG", ty, nil, nil,
					  {regno = d.reg})), "eff", d.reg)
		end
	end
	for j = #keep, 1, -1 do t.asmkeep(self, keep[j], false) end
end

function gen:run(a, n, ctx, reg)
	for _, s in ipairs(md.steps(a)) do
		local sub = n
		if s.sel == "left" then sub = n.left
		elseif s.sel == "right" then sub = n.right end
		if s.deref and sub and sub.op == "INDIR" then
			sub = sub.left
		end
		self:expr(sub, s.ctx, reg + s.bump)
	end
	-- A fixed-register instruction destroys registers the allocator does
	-- not know it is using.  Save the ones still holding a value.
	local saved
	if a.clob then
		for _, c in ipairs(a.clob) do
			if c < reg then
				saved = saved or {}
				saved[#saved + 1] = c
				self.t.save(self, c)
			end
		end
	end
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
function gen:cond(n, label, sense, reg)
	reg = reg or 0
	local op = n.op
	if op == "LNOT" then
		return self:cond(n.left, label, not sense, reg)
	elseif op == "ANDAND" then
		if sense then
			local l = self:newlabel()
			self:cond(n.left, l, false, reg)
			self:cond(n.right, label, true, reg)
			self:putlabel(l)
		else
			self:cond(n.left, label, false, reg)
			self:cond(n.right, label, false, reg)
		end
		return
	elseif op == "COND" then
		-- A conditional in a condition is control flow twice over:
		-- each arm decides the branch on its own.
		local lelse, lend = self:newlabel(), self:newlabel()
		self:cond(n.left, lelse, false, reg)
		self:cond(n.arms[1], label, sense, reg)
		self.t.jump(self, lend)
		self:putlabel(lelse)
		self:cond(n.arms[2], label, sense, reg)
		self:putlabel(lend)
		return
	elseif op == "SEQ" then
		-- Only the last arm decides the branch; the rest are effects.
		for i = 1, #n.arms - 1 do
			self:expr(n.arms[i], "eff", reg)
		end
		return self:cond(n.arms[#n.arms], label, sense, reg)
	elseif op == "OROR" then
		if sense then
			self:cond(n.left, label, true, reg)
			self:cond(n.right, label, true, reg)
		else
			local l = self:newlabel()
			self:cond(n.left, l, true, reg)
			self:cond(n.right, label, false, reg)
			self:putlabel(l)
		end
		return
	end
	self:expr(n, "cc", reg)
	self.t.branch(self, n, label, sense, reg)
end

-- Turn a condition into a zero or a one in a register.
function gen:materialize(n, reg)
	local lfalse, lend = self:newlabel(), self:newlabel()
	self:cond(n, lfalse, false, reg)
	self:expr(tree.const(n.ty, 1), "reg", reg)
	self.t.jump(self, lend)
	self:putlabel(lfalse)
	self:expr(tree.const(n.ty, 0), "reg", reg)
	self:putlabel(lend)
end

return gen
