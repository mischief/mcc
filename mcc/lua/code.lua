-- SPDX-License-Identifier: ISC
-- Code generation for Lua: the resolved tree from mcc.lua.parse becomes
-- expression trees for the generator every C function goes through, so
-- each target that compiles C compiles Lua too.
--
-- Values never live in machine registers.  A function's locals and
-- temporaries are slots of the runtime's value stack, numbered from the
-- frame base the way the Lua virtual machine numbers its registers, and
-- every operation on values is a call into rt/lua with the addresses of
-- the slots it reads and writes.  The machine frame holds only words:
-- the closure, the frame base, the argument count, and counts of values
-- that are known only at run time.
--
-- A slot owns what it holds, so the code keeps one rule: at the start of
-- every statement, every slot above the active locals holds nil.  A
-- statement clears the temporaries it used; a block clears its locals as
-- it ends; break and goto clear what they leave.
--
-- A local that a closure captures and something assigns after its
-- declaration is a box in its slot, made where the local is declared, so
-- that every closure sees the same variable and a closure made on each
-- turn of a loop gets one of its own.  A captured local nothing assigns
-- again is copied into each closure instead, which is most of them, and
-- inside `local function f` the name f is the running closure itself:
-- otherwise every recursive local function would be a cycle, its box
-- holding the closure and the closure holding the box.

local tree = require "mcc.tree"
local gen = require "mcc.gen"
local buf = require "mcc.buf"
local md = require "mcc.md"
local types = require "mcc.types"
local peep = require "mcc.peep"

local M = {}

local U = {}
U.__index = U
local F = {}
F.__index = F

-- What the runtime calls these, and the tags it gives them.
local TNIL, TFALSE, TTRUE, TINT, TFLT, TSTR, TTAB, TFN = 0, 1, 2, 3, 4, 8, 9, 10
local TVSIZE = 16

local ARITH = {["+"] = 0, ["-"] = 1, ["*"] = 2, ["%"] = 3, ["^"] = 4,
	       ["/"] = 5, ["//"] = 6, ["&"] = 7, ["|"] = 8, ["~"] = 9,
	       ["<<"] = 10, [">>"] = 11}
local COMPARE = {["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true,
		 [">"] = true, [">="] = true}
local MULTI = {call = true, method = true, vararg = true}
local KTAG = {["nil"] = TNIL, ["false"] = TFALSE, ["true"] = TTRUE,
	      int = TINT, flt = TFLT, str = TSTR}

local CONSTK = {["nil"] = true, ["true"] = true, ["false"] = true,
		int = true, flt = true, str = true}

-- Does v live in a box?
local function boxed(v)
	return v.captured and v.assigned
end

-- the unit ------------------------------------------------------------

function U:err(msg, line)
	error(("%s:%d: %s"):format(self.chunk, line or 0, msg), 0)
end

-- One TValue in the data section: a payload word pair and a tag.
function U:tvalue(label, lo, hi, tt)
	local d = self.dat

	d:add(("\t.data\n\t.balign\t8\n%s:\n"):format(label))
	if self.t.ptrsize == 8 then
		d:add(("\t.quad\t%s\n"):format(lo))
	else
		d:add(("\t.long\t%s\n\t.long\t%s\n"):format(lo, hi or "0"))
	end
	d:add(("\t.long\t%d\n\t.long\t0\n"):format(tt))
end

function U:newk()
	self.nk = self.nk + 1
	return ".LK" .. self.nk
end

-- The label of a constant TValue for the literal e.
function U:const(e)
	local k = e.k

	if k == "nil" or k == "true" or k == "false" then
		local l = self.kspecial[k]

		if not l then
			l = self:newk()
			self.kspecial[k] = l
			self:tvalue(l, "0", "0", k == "nil" and TNIL or
				k == "true" and TTRUE or TFALSE)
		end
		return l
	end
	if k == "int" then
		local l = self.kint[e.v]

		if not l then
			l = self:newk()
			self.kint[e.v] = l
			local lo, hi = e.v & 0xffffffff, (e.v >> 32) & 0xffffffff

			if self.t.ptrsize == 8 then
				self:tvalue(l, tostring(e.v), nil, TINT)
			else
				self:tvalue(l, tostring(lo), tostring(hi), TINT)
			end
		end
		return l
	end
	if k == "flt" then
		local bits = string.unpack("<i8", string.pack("<d", e.v))
		local l = self.kflt[bits]

		if not l then
			l = self:newk()
			self.kflt[bits] = l
			if self.t.ptrsize == 8 then
				self:tvalue(l, tostring(bits), nil, TFLT)
			else
				self:tvalue(l, tostring(bits & 0xffffffff),
					tostring((bits >> 32) & 0xffffffff), TFLT)
			end
		end
		return l
	end
	if k == "str" then
		local l = self.kstr[e.v]

		if not l then
			l = self:newk()
			self.kstr[e.v] = l
			local s = l .. "s"
			local d = self.dat
			local word = self.t.ptrsize == 8 and ".quad" or ".long"
			local immortal = self.t.ptrsize == 8 and
				"4611686018427387904" or "1073741824"

			d:add(("\t.data\n\t.balign\t8\n%s:\n"):format(s))
			d:add(("\t%s\t%s\n\t.long\t%d\n\t.long\t0\n\t%s\t%d\n")
				:format(word, immortal, TSTR, word, #e.v))
			self.t.data.string(d, e.v)
			self:tvalue(l, s, "0", TSTR)
		end
		return l
	end
	error("not a constant: " .. k)
end

-- Every function of the unit goes through here, in the order met.
function U:queue(fs)
	self.nfn = self.nfn + 1
	local name = (fs.name or "anon"):gsub("[^%w_]", "_")
	local sym = ("lf%d_%s"):format(self.nfn, name)

	self.pending[#self.pending + 1] = {fs = fs, sym = sym}
	return sym
end

function M.compile(main, t, chunk, opt)
	local u = setmetatable({t = t, chunk = chunk or "?", opt = opt or {}},
			       U)

	u.T = types.new(t)
	u.W = t.ptrsize == 8 and u.T.i64 or u.T.i32
	u.I = u.T.i32
	u.out, u.dat = buf.new(), buf.new()
	u.g = gen.new(t, u.out, u.opt)
	u.nk, u.nfn = 0, 0
	u.kint, u.kflt, u.kstr, u.kspecial = {}, {}, {}, {}
	u.pending = {}
	if (u.opt.opt or 0) > 0 then u.peep = t.peep end
	u:func(main, "lr_mainchunk", false)
	local i = 1

	while u.pending[i] do
		local p = u.pending[i]

		u:func(p.fs, p.sym, true)
		i = i + 1
	end
	local d = u.dat

	d:add("\t.section\t.rodata\n\t.globl\tlr_chunkname\nlr_chunkname:\n")
	t.data.string(d, u.chunk)
	return u.out:text() .. u.dat:text() .. (t.trailer or "")
end

-- trees ----------------------------------------------------------------

function F:auto(off, ty)
	local n = tree.auto(ty or self.W, off)

	-- The frame base is read by nearly everything, so on a machine
	-- that keeps a local in a register it is kept in one.
	if off == self.oR and self.pin then n.pin = self.pin end
	return n
end

function F:const(v, ty)
	return tree.const(ty or self.I, v)
end

-- The address of value slot k of this frame.
function F:slot(k)
	if k == 0 then return self:auto(self.oR) end
	return tree.binary("ADD", self.W, self:auto(self.oR),
		tree.const(self.W, k * TVSIZE))
end

function F:kaddr(label)
	return tree.unary("ADDR", self.W,
		tree.name(self.T.array(self.T.i8, TVSIZE), label))
end

-- A call into the runtime.
function F:call(name, rty, args)
	local tys = {}

	for i, a in ipairs(args) do tys[i] = a.ty end
	local fty = self.T.func(rty, tys)

	return tree.node("CALL", rty, tree.name(fty, name), nil,
		{args = args, direct = true, retty = rty})
end

function F:emit(n)
	self.g:expr(n, "eff", 0)
end

function F:rt(name, ...)
	self:emit(self:call(name, self.T.void, {...}))
end

-- A word of the machine frame.
function F:word()
	self.nlocals = self.nlocals + 1
	if self.nlocals > self.maxlocals then self.maxlocals = self.nlocals end
	return self.t.slot(self.nlocals)
end

-- value registers ----------------------------------------------------

function F:reg()
	local r = self.free

	self.free = r + 1
	if self.free > self.maxreg then self.maxreg = self.free end
	if self.free > self.stmthi then self.stmthi = self.free end
	return r
end

-- Release slots [from, to).  What is not counted may stay: above the
-- active locals a slot need only hold nothing counted, so a value that
-- is a number or a boolean is left where it is and costs a test.  A run
-- longer than a few is one call.
function F:clear(from, to)
	if to - from > 4 then
		self:rt("lr_clear", self:slot(from), self:const(to - from))
		return
	end
	for k = from, to - 1 do
		local skip = self.g:newlabel()

		self.g:cond(tree.binary("LT", self.I, self:tag(self:slot(k)),
			self:const(TSTR)), skip, true, 0)
		self:rt("lr_clear", self:slot(k), self:const(1))
		self.g:putlabel(skip)
	end
end

-- Slots [from, to) made nil, for a local that starts with no value.
function F:setnil(from, to)
	self:clear(from, to)
	for k = from, to - 1 do
		self:emit(tree.binary("ASGN", self.I, self:tagref(self:slot(k)),
			self:const(TNIL)))
	end
end

-- expressions ----------------------------------------------------------

-- Can e be evaluated straight into a slot it may also read?  Most can:
-- the runtime works the value out before it writes.  A table is made
-- first and filled after, and `and`/`or` write their first operand
-- before reading the second.
local function direct(e)
	while e.k == "paren" do e = e.e end
	return e.k ~= "table" and e.k ~= "and" and e.k ~= "or"
end

-- The address the value of e can be read from: a local's own slot, a
-- constant, or a temporary it is evaluated into.  The caller puts
-- self.free back when it is done with the address.
function F:operand(e)
	return (self:operandf(e))()
end

-- The same as a function that builds the address afresh each time it
-- is called, for code that names an operand more than once.  An integer
-- constant is given back as its value too.
function F:operandf(e)
	if e.k == "local" and not boxed(e.var) then
		local reg = e.var.reg

		return function() return self:slot(reg) end
	end
	if CONSTK[e.k] then
		local l = self.u:const(e)

		return function() return self:kaddr(l) end,
			e.k == "int" and e.v or nil
	end
	local r = self:reg()

	self:exp2reg(e, r)
	return function() return self:slot(r) end
end

-- Is upvalue idx of this function the function itself?
function F:isself(idx)
	local uv = self.fs.upvals[idx]

	return uv.instack and uv.ref == self.fs.selfvar and
		not uv.ref.assigned
end

-- The varargs: where they start, and how many.
function F:varargs()
	local np = #self.fs.params

	return tree.binary("ADD", self.W, self:auto(self.oBASE),
		tree.const(self.W, np * TVSIZE)), self:auto(self.oNVAR, self.I)
end

-- e, which may give several values, into slots from r on: want of them,
-- or as many as there are for -1.  For -1 the count is left in a word of
-- the frame, whose offset is returned.
function F:multi(e, r, want)
	if e.k == "vararg" then
		local from, n = self:varargs()
		local c = self:call("lr_varargs", self.I,
			{self:slot(r), from, n, self:const(want)})

		if want >= 0 then
			self:emit(c)
			return nil
		end
		local w = self:word()

		self:emit(tree.binary("ASGN", self.I, self:auto(w, self.I), c))
		return w
	end
	return self:callexp(e, r, want)
end

-- A call, its function at slot fa (which must be the last reserved).
function F:callexp(e, fa, want)
	assert(self.free == fa + 1)
	local nfixed = 0

	if e.k == "method" then
		local m = self.free
		local o = self:operand(e.obj)

		self:rt("lr_self", self:slot(fa), o,
			self:kaddr(self.u:const({k = "str", v = e.name})))
		self.free = m
		self:reg()
		nfixed = 1
	else
		self:exp2reg(e.fn, fa)
	end
	local args = e.args
	local count

	for i, a in ipairs(args) do
		local r = self:reg()

		if i == #args and MULTI[a.k] then
			count = self:multi(a, r, -1)
			self.free = r
		else
			self:exp2reg(a, r)
		end
	end
	local n

	if count then
		n = tree.binary("ADD", self.I, self:auto(count, self.I),
			self:const(nfixed + #args - 1))
	else
		n = self:const(nfixed + #args)
	end
	self.free = fa + 1
	self:setline(e.line)
	local c = self:call("lr_call", self.I, {self:slot(fa), n,
		self:const(want)})

	-- The callee leaves its own line behind.
	self.line = nil

	if want >= 0 then
		self:emit(c)
		for _ = 2, want do self:reg() end
		if want == 0 then self.free = fa end
		return nil
	end
	local w = self:word()

	self:emit(tree.binary("ASGN", self.I, self:auto(w, self.I), c))
	return w
end

local INLINE = {["+"] = "ADD", ["-"] = "SUB", ["*"] = "MUL"}

-- Arithmetic into slot r.  Two integers, the common case, are done
-- here without a call: the tags are tested, the payloads added, and the
-- runtime is reached only when either is not an integer or the slot
-- written holds something counted.  A constant operand needs no test.
function F:arith(e, r)
	local op = e.op
	local m = self.free
	local fa, ka = self:operandf(e.a)
	local fb, kb = self:operandf(e.b)
	local g = self.g
	local L = self.T.i64

	self:setline(e.line)
	local fast = INLINE[op] or (op == "%" and kb and kb > 0)

	if not fast then
		self:rt("lr_arith", self:slot(r), fa(), fb(),
			self:const(ARITH[op]))
		self.free = m
		return
	end
	local slow, done = g:newlabel(), g:newlabel()
	local INT = self:const(TINT)

	if not ka then
		g:cond(tree.binary("EQ", self.I, self:tag(fa()), INT), slow,
			false, 0)
	end
	if not kb then
		g:cond(tree.binary("EQ", self.I, self:tag(fb()),
			self:const(TINT)), slow, false, 0)
	end
	g:cond(tree.binary("LT", self.I, self:tag(self:slot(r)),
		self:const(TSTR)), slow, false, 0)
	local va = ka and tree.const(L, ka) or self:ival(fa())
	local vb = kb and tree.const(L, kb) or self:ival(fb())

	if op == "%" then
		-- C's remainder, then the sign Lua's floor gives
		local pos = g:newlabel()

		self:emit(tree.binary("ASGN", L, self:ival(self:slot(r)),
			tree.binary("MOD", L, va, vb)))
		g:cond(tree.binary("LT", self.I, self:ival(self:slot(r)),
			tree.const(L, 0)), pos, false, 0)
		self:emit(tree.binary("ASGN", L, self:ival(self:slot(r)),
			tree.binary("ADD", L, self:ival(self:slot(r)),
				tree.const(L, kb))))
		g:putlabel(pos)
	else
		self:emit(tree.binary("ASGN", L, self:ival(self:slot(r)),
			tree.binary(INLINE[op], L, va, vb)))
	end
	self:emit(tree.binary("ASGN", self.I, self:tagref(self:slot(r)),
		self:const(TINT)))
	g:jump(done)
	g:putlabel(slow)
	self:rt("lr_arith", self:slot(r), fa(), fb(), self:const(ARITH[op]))
	g:putlabel(done)
	self.free = m
end

-- The operands of a concatenation chain, left to right.
local function concatlist(e, l)
	if e.k == "bin" and e.op == ".." then
		concatlist(e.a, l)
		concatlist(e.b, l)
	else
		l[#l + 1] = e
	end
	return l
end

local REL = {["=="] = "EQ", ["~="] = "NE", ["<"] = "LT", ["<="] = "LE",
	     [">"] = "GT", [">="] = "GE"}

-- Jump to label when `a op b` is sense: two integers compared in place,
-- anything else by the runtime.
function F:intcompare(op, fa, ka, fb, kb, label, sense)
	local g = self.g
	local L = self.T.i64
	local slow, done = g:newlabel(), g:newlabel()

	if not ka then
		g:cond(tree.binary("EQ", self.I, self:tag(fa()),
			self:const(TINT)), slow, false, 0)
	end
	if not kb then
		g:cond(tree.binary("EQ", self.I, self:tag(fb()),
			self:const(TINT)), slow, false, 0)
	end
	g:cond(tree.binary(REL[op], self.I,
		ka and tree.const(L, ka) or self:ival(fa()),
		kb and tree.const(L, kb) or self:ival(fb())), label, sense, 0)
	g:jump(done)
	g:putlabel(slow)
	g:cond(self:comparef(op, fa, fb), label, sense, 0)
	g:putlabel(done)
end

-- A comparison by the runtime, as a truth value to branch on.
function F:comparef(op, fa, fb)
	local a, b = fa(), fb()
	local t

	if op == "==" or op == "~=" then
		t = self:call("lr_eq", self.I, {a, b})
	elseif op == "<" then
		t = self:call("lr_lt", self.I, {a, b})
	elseif op == "<=" then
		t = self:call("lr_le", self.I, {a, b})
	elseif op == ">" then
		t = self:call("lr_lt", self.I, {b, a})
	else
		t = self:call("lr_le", self.I, {b, a})
	end
	return tree.binary(op == "~=" and "EQ" or "NE", self.I, t,
		self:const(0))
end

-- A comparison as a truth value the machine can branch on.
function F:compare(e)
	local op = e.op
	local m = self.free
	local a, b = self:operand(e.a), self:operand(e.b)
	local t

	if op == "==" or op == "~=" then
		t = self:call("lr_eq", self.I, {a, b})
	elseif op == "<" then
		t = self:call("lr_lt", self.I, {a, b})
	elseif op == "<=" then
		t = self:call("lr_le", self.I, {a, b})
	elseif op == ">" then
		t = self:call("lr_lt", self.I, {b, a})
	else
		t = self:call("lr_le", self.I, {b, a})
	end
	self.free = m
	return tree.binary(op == "~=" and "EQ" or "NE", self.I, t,
		self:const(0))
end

function F:closure(fs, r)
	local sym = self.u:queue(fs)
	local w = self:word()
	local fty = self.T.func(self.I, {self.W, self.W, self.I})
	local fn = tree.unary("ADDR", self.W, tree.name(fty, sym))

	self:emit(tree.binary("ASGN", self.W, self:auto(w),
		self:call("lr_closure", self.W, {self:slot(r), fn,
			self:const(#fs.upvals), tree.const(self.W, 0)})))
	for i, uv in ipairs(fs.upvals) do
		if uv.instack and uv.ref == fs.selfvar and
		   not uv.ref.assigned then
			-- the closure's own name, which it never holds
		elseif uv.instack and boxed(uv.ref) then
			self:rt("lr_upfrombox", self:auto(w), self:const(i - 1),
				self:slot(uv.ref.reg))
		elseif uv.instack then
			self:rt("lr_upfromval", self:auto(w), self:const(i - 1),
				self:slot(uv.ref.reg))
		elseif self:isself(uv.ref) then
			local m = self.free
			local t = self:reg()

			self:rt("lr_selfvalue", self:slot(t), self:auto(self.oCL))
			self:rt("lr_upfromval", self:auto(w), self:const(i - 1),
				self:slot(t))
			self.free = m
		else
			self:rt("lr_upfromup", self:auto(w), self:const(i - 1),
				self:auto(self.oCL), self:const(uv.ref - 1))
		end
	end
end

function F:table(e, r)
	local narr, nhash = 0, 0

	for _, it in ipairs(e.items) do
		if it.key then nhash = nhash + 1 else narr = narr + 1 end
	end
	self:rt("lr_newtable", self:slot(r), self:const(narr),
		self:const(nhash))
	local pend, first, idx = 0, nil, 1
	local function flush(count)
		if pend == 0 and not count then return end
		local n = self:const(pend)

		if count then
			n = tree.binary("ADD", self.I, self:auto(count, self.I),
				self:const(pend - 1))
		end
		self:rt("lr_setlist", self:slot(r), self:slot(first), n,
			self:const(idx))
		idx = idx + pend
		self.free = first
		pend, first = 0, nil
	end
	for i, it in ipairs(e.items) do
		if it.key then
			local m = self.free
			local k = self:operand(it.key)
			local v = self:operand(it.val)

			self:rt("lr_setindex", self:slot(r), k, v)
			self.free = m
		else
			local s = self:reg()

			first = first or s
			pend = pend + 1
			if i == #e.items and MULTI[it.val.k] then
				local c = self:multi(it.val, s, -1)

				flush(c)
			else
				self:exp2reg(it.val, s)
				if pend == 50 then flush() end
			end
		end
	end
	flush()
end

-- Evaluate e into slot r.
function F:exp2reg(e, r)
	local k = e.k

	if CONSTK[k] then
		local l = self.u:const(e)

		local kv = 0

		if k == "int" then
			kv = e.v
		elseif k == "flt" then
			kv = string.unpack("<i8", string.pack("<d", e.v))
		end
		self:move(r, function() return self:kaddr(l) end, KTAG[k], kv)
	elseif k == "local" then
		if boxed(e.var) then
			self:rt("lr_getbox", self:slot(r), self:slot(e.var.reg))
		elseif e.var.reg ~= r then
			local reg = e.var.reg

			self:move(r, function() return self:slot(reg) end)
		end
	elseif k == "upval" then
		if self:isself(e.idx) then
			self:selfvalue(r)
		else
			self:rt("lr_getup", self:slot(r), self:auto(self.oCL),
				self:const(e.idx - 1))
		end
	elseif k == "index" then
		local m = self.free

		if e.obj.k == "upval" and not self:isself(e.obj.idx) then
			local key = self:operand(e.key)

			self:setline(e.line)
			self:rt("lr_upindex", self:slot(r), self:auto(self.oCL),
				self:const(e.obj.idx - 1), key)
		else
			local fo = self:operandf(e.obj)
			local fk, kk = self:operandf(e.key)

			self:setline(e.line)
			self:getindex(r, fo, fk, kk)
		end
		self.free = m
	elseif k == "call" or k == "method" then
		-- Straight into r when it is the last slot reserved and no
		-- local: a call's arguments go above its function.
		if r == self.free - 1 and r >= self.level then
			self:callexp(e, r, 1)
		else
			local m = self.free
			local fa = self:reg()

			self:callexp(e, fa, 1)
			self:rt("lr_move", self:slot(r), self:slot(fa))
			self.free = m
		end
	elseif k == "vararg" then
		self:multi(e, r, 1)
	elseif k == "paren" then
		self:exp2reg(e.e, r)
	elseif k == "func" then
		self:closure(e.f, r)
	elseif k == "table" then
		self:table(e, r)
	elseif k == "and" or k == "or" then
		local done = self.g:newlabel()

		self:exp2reg(e.a, r)
		self.g:cond(self:truth(self:slot(r)), done, k == "or", 0)
		self:exp2reg(e.b, r)
		self.g:putlabel(done)
	elseif k == "bin" then
		local op = e.op

		if ARITH[op] then
			self:arith(e, r)
		elseif op == ".." then
			local l = concatlist(e, {})
			local m = self.free
			local first = self.free

			for _, x in ipairs(l) do self:exp2reg(x, self:reg()) end
			self:setline(e.line)
			self:rt("lr_concat", self:slot(r), self:slot(first),
				self:const(#l))
			self.free = m
		elseif COMPARE[op] then
			self:setline(e.line)
			self:rt("lr_setbool", self:slot(r), self:compare(e))
		else
			error("operator " .. op)
		end
	elseif k == "un" then
		local m = self.free
		local a = self:operand(e.a)
		local fn = ({unm = "lr_unm", ["not"] = "lr_not", len = "lr_len",
			    bnot = "lr_bnot"})[e.op]

		self:setline(e.line)
		self:rt(fn, self:slot(r), a)
		self.free = m
	else
		error("expression " .. k)
	end
end

-- The tag of the value at address p.  The address carries the type of
-- what it points at, which is how the matcher picks the load.
function F:tagref(p)
	return tree.unary("INDIR", self.I, self:offset(p, 8, self.I))
end

-- p + off, as the address of a ty, folded into p's own offset when p
-- is a slot's.
function F:offset(p, off, ty)
	local pt = self.T.ptr(ty)

	if p.op == "ADD" and p.right.op == "CONST" then
		local q = tree.binary("ADD", pt, p.left,
			tree.const(self.W, p.right.val + off))

		return q
	end
	if off == 0 then
		local q = tree.clone(p)

		q.ty = pt
		return q
	end
	return tree.binary("ADD", pt, p, tree.const(self.W, off))
end

function F:tag(p)
	return self:tagref(p)
end

-- The payload of the value at p, as an integer.
function F:ival(p)
	return tree.unary("INDIR", self.T.i64, self:offset(p, 0, self.T.i64))
end

-- Whether the value at address p is true: its tag is above false's.
function F:truth(p)
	return tree.binary("GT", self.I, self:tag(p), self:const(TFALSE))
end

-- Jump to label when e's truth is sense.
function F:cond(e, label, sense)
	local k = e.k
	local g = self.g

	while k == "paren" do
		e = e.e
		k = e.k
	end
	if k == "nil" or k == "false" then
		if not sense then g:jump(label) end
		return
	end
	if CONSTK[k] or k == "func" or k == "table" and #e.items == 0 and
	   false then
		if sense then g:jump(label) end
		return
	end
	if k == "un" and e.op == "not" then
		return self:cond(e.a, label, not sense)
	end
	if k == "and" or k == "or" then
		-- `a and b` is false if either is; `a or b` true if either is.
		local short = (k == "and") ~= sense

		if short then
			self:cond(e.a, label, sense)
			self:cond(e.b, label, sense)
		else
			local skip = g:newlabel()

			self:cond(e.a, skip, not sense)
			self:cond(e.b, label, sense)
			g:putlabel(skip)
		end
		return
	end
	local m, hi = self.free, self.stmthi
	local test

	self.stmthi = m
	if k == "bin" and COMPARE[e.op] then
		self:setline(e.line)
		local fa, ka = self:operandf(e.a)
		local fb, kb = self:operandf(e.b)

		if self.stmthi == m then
			-- Nothing to clear on the way out, so two
			-- integers can be compared here and now.
			self:intcompare(e.op, fa, ka, fb, kb, label, sense)
			self.free = m
			self.stmthi = hi
			return
		end
		test = self:comparef(e.op, fa, fb)
	else
		test = self:truth(self:operand(e))
	end
	-- Temporaries the test used are cleared before the branch, so
	-- that neither way out finds anything in them.
	if self.stmthi > m then
		local w = self:word()

		self:emit(tree.binary("ASGN", self.I, self:auto(w, self.I),
			test))
		self:clear(m, self.stmthi)
		test = tree.binary("NE", self.I, self:auto(w, self.I),
			self:const(0))
	end
	g:cond(test, label, sense, 0)
	self.free = m
	self.stmthi = hi
end

-- statements -------------------------------------------------------------

function F:setline(line)
	if not line or line == self.line then return end
	self.line = line
	self:emit(tree.binary("ASGN", self.I, tree.name(self.I, "lr_curline"),
		self:const(line)))
end

-- vals into the slots from self.free on, adjusted to want of them.
-- Returns the first.
function F:explist(vals, want)
	local first = self.free

	for i, e in ipairs(vals) do
		local r = self:reg()

		if i == #vals and MULTI[e.k] and want >= i then
			self:multi(e, r, want - i + 1)
			self.free = r
			for _ = 1, want - i + 1 do self:reg() end
		elseif i > want and MULTI[e.k] then
			self:multi(e, r, 0)
		else
			self:exp2reg(e, r)
		end
	end
	-- Slots no value reached may hold what a temporary left.
	local got = #vals
	if got < want and (got == 0 or not MULTI[vals[got].k]) then
		self.free = math.max(self.free, first + want)
		self:setnil(first + got, first + want)
	end
	while self.free < first + want do self:reg() end
	self.free = first + want
	return first
end

-- The value at address v goes to target t, whose table and key, if it
-- is an index, have already been worked out into tk.
function F:storeto(t, tk, vf)
	if tk and not tk.up then
		self:setline(t.line)
		self:setindex(tk.obj, tk.key, tk.kk, vf)
		return
	end
	local v = vf()

	if t.k == "local" then
		if boxed(t.var) then
			self:rt("lr_setbox", self:slot(t.var.reg), v)
		else
			self:rt("lr_move", self:slot(t.var.reg), v)
		end
	elseif t.k == "upval" then
		self:rt("lr_setup", self:auto(self.oCL), self:const(t.idx - 1), v)
	elseif tk.up then
		self:setline(t.line)
		self:rt("lr_upsetindex", self:auto(self.oCL),
			self:const(tk.up - 1), tk.key(), v)
	else
		self:setline(t.line)
		self:rt("lr_setindex", tk.obj(), tk.key(), v)
	end
end

-- A table and key of an assignment target, evaluated now.  With `keep`,
-- a local is copied rather than read where it is, because the same
-- assignment may change it before the store.
function F:prefix(t, keep)
	if t.k ~= "index" then return nil end
	local function hold(e)
		if CONSTK[e.k] then
			local l = self.u:const(e)

			return function() return self:kaddr(l) end,
				e.k == "int" and e.v or nil
		end
		if e.k == "local" and not boxed(e.var) and not keep then
			local reg = e.var.reg

			return function() return self:slot(reg) end
		end
		local r = self:reg()

		self:exp2reg(e, r)
		return function() return self:slot(r) end
	end
	if t.obj.k == "upval" and not self:isself(t.obj.idx) then
		return {up = t.obj.idx, key = hold(t.key)}
	end
	local obj = hold(t.obj)
	local key, kk = hold(t.key)

	return {obj = obj, key = key, kk = kk}
end

function F:assign(s)
	local targets, vals = s.targets, s.vals

	if #targets == 1 and #vals == 1 then
		local t, e = targets[1], vals[1]

		if t.k == "local" and not boxed(t.var) then
			if direct(e) then
				self:exp2reg(e, t.var.reg)
			else
				local r = self:reg()

				self:exp2reg(e, r)
				self:rt("lr_move", self:slot(t.var.reg),
					self:slot(r))
			end
			return
		end
		local tk = self:prefix(t, false)
		local vf = self:operandf(e)

		self:storeto(t, tk, vf)
		return
	end
	local tks = {}

	for i, t in ipairs(targets) do tks[i] = self:prefix(t, true) end
	local first = self:explist(vals, #targets)

	for i = #targets, 1, -1 do
		local r = first + i - 1

		self:storeto(targets[i], tks[i], function() return self:slot(r) end)
	end
end

function F:localstat(s)
	local vars = s.vars

	if s.recursive then
		local v = vars[1]

		v.reg = self:reg()
		self.level = self.free
		if boxed(v) then
			local r = self:reg()

			self:rt("lr_newbox", self:slot(v.reg),
				self:kaddr(self.u:const({k = "nil"})))
			self:closure(s.vals[1].f, r)
			self:rt("lr_setbox", self:slot(v.reg), self:slot(r))
		else
			self:closure(s.vals[1].f, v.reg)
		end
		return
	end
	local first = self:explist(s.vals, #vars)

	for i, v in ipairs(vars) do v.reg = first + i - 1 end
	self.level = first + #vars
	self.free = self.level
	for _, v in ipairs(vars) do
		if v.attrib == "close" then
			self:rt("lr_tbc", self:slot(v.reg),
				self:kaddr(self.u:const({k = "str", v = v.name})))
			self.tbcs[#self.tbcs + 1] = v.reg
		end
		if boxed(v) then
			self:rt("lr_newbox", self:slot(v.reg), self:slot(v.reg))
		end
	end
end

-- The step of a numeric loop whose state is at slot base.  With an
-- integer step the count of turns left is in base+1, which lr_forprep
-- put there; that loop is stepped here, and only a float one is the
-- runtime's.
function F:forstep(base, top)
	local g = self.g
	local L = self.T.i64
	local flt, out = g:newlabel(), g:newlabel()
	local function v(k) return self:ival(self:slot(base + k)) end

	g:cond(tree.binary("EQ", self.I, self:tag(self:slot(base + 2)),
		self:const(TINT)), flt, false, 0)
	g:cond(tree.binary("EQ", self.I, v(1), tree.const(L, 0)), out,
		true, 0)
	self:emit(tree.binary("ASGN", L, v(1),
		tree.binary("SUB", L, v(1), tree.const(L, 1))))
	self:emit(tree.binary("ASGN", L, v(0),
		tree.binary("ADD", L, v(0), v(2))))
	-- the control variable may be a box a closure kept
	self:clear(base + 3, base + 4)
	self:emit(tree.binary("ASGN", L, v(3), v(0)))
	self:emit(tree.binary("ASGN", self.I, self:tagref(self:slot(base + 3)),
		self:const(TINT)))
	g:jump(top)
	g:putlabel(flt)
	g:cond(tree.binary("NE", self.I, self:call("lr_forloop", self.I,
		{self:slot(base)}), self:const(0)), top, true, 0)
	g:putlabel(out)
end

-- Copy the value at the address fsrc builds into slot r.  Neither
-- counted, which is most moves, it is two stores; otherwise the runtime
-- retains and releases.  tt is the tag when the source is a constant.
function F:move(r, fsrc, tt, kv)
	local g = self.g
	local L = self.T.i64
	local slow, done = g:newlabel(), g:newlabel()

	if tt and tt >= TSTR then
		self:rt("lr_move", self:slot(r), fsrc())
		return
	end
	g:cond(tree.binary("LT", self.I, self:tag(self:slot(r)),
		self:const(TSTR)), slow, false, 0)
	if not tt then
		g:cond(tree.binary("LT", self.I, self:tag(fsrc()),
			self:const(TSTR)), slow, false, 0)
	end
	self:emit(tree.binary("ASGN", L, self:ival(self:slot(r)),
		kv and tree.const(L, kv) or self:ival(fsrc())))
	self:emit(tree.binary("ASGN", self.I, self:tagref(self:slot(r)),
		tt and self:const(tt) or self:tag(fsrc())))
	g:jump(done)
	g:putlabel(slow)
	self:rt("lr_move", self:slot(r), fsrc())
	g:putlabel(done)
end

-- Where a table keeps its array part and its size, as lrt.h lays an
-- lr_Table out.  The two have to agree.
function F:tabfields()
	if self.t.ptrsize == 8 then return 16, 24 end
	return 12, 16
end

-- The address of t[k] when t is a table and k an integer within its
-- array part, left in a word of the frame; otherwise a jump to slow.
function F:arrayslot(fo, fk, kk, slow)
	local g = self.g
	local L, U, W = self.T.i64, self.T.u64, self.W
	local ARR, ASIZE = self:tabfields()
	local wh, wi, we = self:word(), self:word(), self:word()
	local function field(off, ty)
		return tree.unary("INDIR", ty, tree.binary("ADD", self.T.ptr(ty),
			self:auto(wh), tree.const(W, off)))
	end

	g:cond(tree.binary("EQ", self.I, self:tag(fo()), self:const(TTAB)),
		slow, false, 0)
	if not kk then
		g:cond(tree.binary("EQ", self.I, self:tag(fk()),
			self:const(TINT)), slow, false, 0)
	end
	local q = tree.clone(fo())

	q.ty = self.T.ptr(W)
	self:emit(tree.binary("ASGN", W, self:auto(wh), tree.unary("INDIR", W, q)))
	self:emit(tree.binary("ASGN", L, self:auto(wi, L), tree.binary("SUB", L,
		kk and tree.const(L, kk) or self:ival(fk()), tree.const(L, 1))))
	g:cond(tree.binary("LT", self.I, self:auto(wi, U), field(ASIZE, U)),
		slow, false, 0)
	local idx = self:auto(wi, L)

	if W.size < 8 then idx = tree.unary("CVT", W, idx) end
	self:emit(tree.binary("ASGN", W, self:auto(we), tree.binary("ADD", W,
		field(ARR, W), tree.binary("MUL", W, idx,
			tree.const(W, TVSIZE)))))
	return we
end

-- slot r = t[k], with the array part of a table read in place.  A nil
-- there may be a table with __index to ask, which the runtime does.
function F:getindex(r, fo, fk, kk)
	local g = self.g
	local slow, done, held = g:newlabel(), g:newlabel(), g:newlabel()
	local we = self:arrayslot(fo, fk, kk, slow)
	local function e() return self:auto(we) end

	g:cond(tree.binary("EQ", self.I, self:tag(e()), self:const(TNIL)),
		slow, true, 0)
	g:cond(tree.binary("LT", self.I, self:tag(self:slot(r)),
		self:const(TSTR)), slow, false, 0)
	self:retainat(e, held)
	self:emit(tree.binary("ASGN", self.T.i64, self:ival(self:slot(r)),
		self:ival(e())))
	self:emit(tree.binary("ASGN", self.I, self:tagref(self:slot(r)),
		self:tag(e())))
	g:jump(done)
	g:putlabel(slow)
	self:rt("lr_index", self:slot(r), fo(), fk())
	g:putlabel(done)
end

-- t[k] = v, in place when the slot of the array part holds something
-- uncounted and not nil: a nil may be a table with __newindex.
function F:setindex(fo, fk, kk, fv)
	local g = self.g
	local slow, done, held = g:newlabel(), g:newlabel(), g:newlabel()
	local we = self:arrayslot(fo, fk, kk, slow)
	local function e() return self:auto(we) end

	g:cond(tree.binary("EQ", self.I, self:tag(e()), self:const(TNIL)),
		slow, true, 0)
	g:cond(tree.binary("LT", self.I, self:tag(e()), self:const(TSTR)),
		slow, false, 0)
	self:retainat(fv, held)
	self:emit(tree.binary("ASGN", self.T.i64, self:ival(e()),
		self:ival(fv())))
	self:emit(tree.binary("ASGN", self.I, self:tagref(e()), self:tag(fv())))
	g:jump(done)
	g:putlabel(slow)
	self:rt("lr_setindex", fo(), fk(), fv())
	g:putlabel(done)
end

-- If the value at the address f builds is counted, count one more.
function F:retainat(f, skip)
	local g = self.g
	local W = self.W

	g:cond(tree.binary("LT", self.I, self:tag(f()), self:const(TSTR)),
		skip, true, 0)
	local q = tree.clone(f())

	q.ty = self.T.ptr(W)
	local obj = tree.unary("INDIR", W, q)
	local q2 = tree.clone(f())

	q2.ty = self.T.ptr(W)
	local rc = tree.unary("INDIR", W, tree.unary("INDIR", self.T.ptr(W), q2))

	self:emit(tree.binary("ASGN", W, tree.unary("INDIR", W, obj), tree.binary(
		"ADD", W, rc, tree.const(W, 1))))
	g:putlabel(skip)
end

-- Slot r = the running closure, counted once more.
function F:selfvalue(r)
	local g = self.g
	local W = self.W
	local slow, done = g:newlabel(), g:newlabel()

	g:cond(tree.binary("LT", self.I, self:tag(self:slot(r)),
		self:const(TSTR)), slow, false, 0)
	self:emit(tree.binary("ASGN", W, tree.unary("INDIR", W,
		self:offset(self:slot(r), 0, W)), self:auto(self.oCL)))
	self:emit(tree.binary("ASGN", self.I, self:tagref(self:slot(r)),
		self:const(TFN)))
	local q = tree.clone(self:auto(self.oCL))

	q.ty = self.T.ptr(W)
	local q2 = tree.clone(self:auto(self.oCL))

	q2.ty = self.T.ptr(W)
	self:emit(tree.binary("ASGN", W, tree.unary("INDIR", W, q),
		tree.binary("ADD", W, tree.unary("INDIR", W, q2),
			tree.const(W, 1))))
	g:jump(done)
	g:putlabel(slow)
	self:rt("lr_selfvalue", self:slot(r), self:auto(self.oCL))
	g:putlabel(done)
end

-- Close the to-be-closed variables at level and above, last first.
function F:closeto(level)
	for i = #self.tbcs, 1, -1 do
		local r = self.tbcs[i]

		if r < level then break end
		self:rt("lr_close", self:slot(r))
	end
end

function F:retstat(s)
	local vals = s.vals
	local src, n

	if #vals == 0 then
		src, n = self:slot(0), self:const(0)
	elseif #vals == 1 and vals[1].k == "local" and
	       not boxed(vals[1].var) then
		src, n = self:slot(vals[1].var.reg), self:const(1)
	else
		local first = self.free
		local count

		for i, e in ipairs(vals) do
			local r = self:reg()

			if i == #vals and MULTI[e.k] then
				count = self:multi(e, r, -1)
			else
				self:exp2reg(e, r)
			end
		end
		src = self:slot(first)
		if count then
			n = tree.binary("ADD", self.I, self:auto(count, self.I),
				self:const(#vals - 1))
		else
			n = self:const(#vals)
		end
	end
	self:closeto(0)
	self.g:expr(self:call("lr_ret", self.I, {self:auto(self.oBASE),
		self:auto(self.oTOP), src, n}), "reg", 0)
	self.g:jump(self.endlabel)
end

-- A block: its labels are known before its statements are compiled, so
-- a goto forward knows how many locals its label sees.
function F:block(b, before)
	local blk = {base = self.level, labels = {}, parent = self.blk}
	local lv = self.level
	local body = b.body

	for i, s in ipairs(body) do
		if s.k == "label" then
			if blk.labels[s.name] then
				self.u:err(("label '%s' already defined")
					:format(s.name), s.line)
			end
			-- A label with nothing after it but other labels is
			-- out of the scope of the block's locals.
			local atend = true

			for j = i + 1, #body do
				if body[j].k ~= "label" then
					atend = false
					break
				end
			end
			blk.labels[s.name] = {label = self.g:newlabel(),
				level = atend and blk.base or lv}
		elseif s.k == "local" then
			lv = lv + #s.vars
		end
	end
	self.blk = blk
	for _, s in ipairs(body) do self:stat(s) end
	if before then before() end
	self:closeto(blk.base)
	while #self.tbcs > 0 and self.tbcs[#self.tbcs] >= blk.base do
		self.tbcs[#self.tbcs] = nil
	end
	self:clear(blk.base, self.level)
	self.level, self.free, self.stmthi = blk.base, blk.base, blk.base
	self.blk = blk.parent
end

function F:loop(brk, level)
	local l = {brk = brk, level = level}

	self.loops[#self.loops + 1] = l
	return l
end

function F:stat(s)
	local m = tree.mark()
	local k = s.k
	local g = self.g

	self.stmthi = self.level
	if k ~= "block" and k ~= "label" then self:setline(s.line) end
	if k == "local" then
		self:localstat(s)
	elseif k == "assign" then
		self:assign(s)
	elseif k == "callstat" then
		self:callexp(s.call, self:reg(), 0)
	elseif k == "return" then
		self:retstat(s)
	elseif k == "block" then
		self:block(s)
	elseif k == "if" then
		local done = g:newlabel()

		for _, arm in ipairs(s.arms) do
			local nxt = g:newlabel()

			self:cond(arm.cond, nxt, false)
			self:block(arm.body)
			g:jump(done)
			g:putlabel(nxt)
		end
		if s.els then self:block(s.els) end
		g:putlabel(done)
	elseif k == "while" then
		local top, brk = g:newlabel(), g:newlabel()

		g:putlabel(top)
		self:cond(s.cond, brk, false)
		self:loop(brk, self.level)
		self:block(s.body)
		self.loops[#self.loops] = nil
		g:jump(top)
		g:putlabel(brk)
	elseif k == "repeat" then
		local top, again, brk = g:newlabel(), g:newlabel(),
			g:newlabel()
		local level = self.level

		g:putlabel(top)
		self:loop(brk, level)
		self:block(s.body, function()
			self.loops[#self.loops] = nil
			self.stmthi = self.level
			self:cond(s.cond, again, false)
			self:clear(self.level, self.stmthi)
			self:clear(level, self.level)
			g:jump(brk)
			g:putlabel(again)
			self:clear(self.level, self.stmthi)
		end)
		g:jump(top)
		g:putlabel(brk)
	elseif k == "numfor" then
		local base = self.level
		local top, cont, brk, out = g:newlabel(), g:newlabel(),
			g:newlabel(), g:newlabel()

		self:exp2reg(s.a, self:reg())
		self:exp2reg(s.b, self:reg())
		if s.c then
			self:exp2reg(s.c, self:reg())
		else
			self:exp2reg({k = "int", v = 1}, self:reg())
		end
		self:clear(base + 3, self.stmthi)
		self.free = base + 3
		self:reg()
		s.var.reg = base + 3
		self.level = base + 4
		self.stmthi = self.level
		g:cond(tree.binary("NE", self.I, self:call("lr_forprep", self.I,
			{self:slot(base)}), self:const(0)), out, false, 0)
		g:putlabel(top)
		if boxed(s.var) then
			self:rt("lr_newbox", self:slot(base + 3),
				self:slot(base + 3))
		end
		self:loop(brk, base)
		self:block(s.body)
		self.loops[#self.loops] = nil
		g:putlabel(cont)
		self:forstep(base, top)
		g:putlabel(out)
		self:clear(base, base + 4)
		g:putlabel(brk)
		self.level, self.free = base, base
	elseif k == "genfor" then
		local base = self.level
		local top, brk, out = g:newlabel(), g:newlabel(), g:newlabel()
		local nv = #s.vars

		self:explist(s.vals, 3)
		self:clear(base + 3, self.stmthi)
		self.level = base + 3
		self.free = self.level
		g:putlabel(top)
		for i, v in ipairs(s.vars) do v.reg = base + 2 + i end
		self.free = base + 3
		for i = 0, 2 do
			self:rt("lr_move", self:slot(base + 3 + i),
				self:slot(base + i))
		end
		self:setline(s.line)
		self:emit(self:call("lr_call", self.I, {self:slot(base + 3),
			self:const(2), self:const(nv)}))
		g:cond(tree.binary("EQ", self.I, self:tag(self:slot(base + 3)),
			self:const(TNIL)), out, true, 0)
		self:rt("lr_move", self:slot(base + 2), self:slot(base + 3))
		self.level = base + 3 + nv
		self.free = self.level
		self.maxreg = math.max(self.maxreg, base + 3 + math.max(nv, 3))
		for _, v in ipairs(s.vars) do
			if boxed(v) then
				self:rt("lr_newbox", self:slot(v.reg),
					self:slot(v.reg))
			end
		end
		self:loop(brk, base)
		self:block(s.body)
		self.loops[#self.loops] = nil
		self:clear(base + 3, base + 3 + nv)
		g:jump(top)
		g:putlabel(out)
		self:clear(base, base + 3 + math.max(nv, 3))
		g:putlabel(brk)
		self.level, self.free = base, base
	elseif k == "break" then
		local l = self.loops[#self.loops]

		if not l then self.u:err("break outside a loop", s.line) end
		self:closeto(l.level)
		self:clear(l.level, self.level)
		g:jump(l.brk)
	elseif k == "goto" then
		local b, lab = self.blk, nil

		while b do
			lab = b.labels[s.name]
			if lab then break end
			b = b.parent
		end
		if not lab then
			self.u:err(("no visible label '%s' for goto")
				:format(s.name), s.line)
		end
		if lab.level > self.level then
			self.u:err(("<goto %s> jumps into the scope of a local")
				:format(s.name), s.line)
		end
		self:closeto(lab.level)
		self:clear(lab.level, self.level)
		g:jump(lab.label)
	elseif k == "label" then
		g:putlabel(self.blk.labels[s.name].label)
		self.line = nil
	else
		error("statement " .. k)
	end
	-- What the statement left in its temporaries goes now.
	if self.stmthi > self.level then
		self:clear(self.level, self.stmthi)
	end
	self.free = self.level
	self.stmthi = self.level
	tree.release(m)
end

-- functions ----------------------------------------------------------------

function U:func(fs, sym, static)
	local t, g = self.t, self.g
	local f = setmetatable({u = self, fs = fs, g = g, t = t, T = self.T,
				W = self.W, I = self.I}, F)

	f.nlocals, f.maxlocals = 0, 0
	f.loops, f.tbcs = {}, {}
	local shape = {{size = self.W.size}, {size = self.W.size}, {size = 4}}
	local slots = md.classify(t, shape, nil, false, nil)

	for i = 1, 3 do
		if slots[i].stk and not slots[i].reg and not slots[i].pieces and
		   t.argsinplace then
			slots[i].off = t.stackargs + slots[i].stk * t.ptrsize
			slots[i].inplace = true
		else
			slots[i].off = f:word()
		end
	end
	f.oCL, f.oBASE, f.oNARGS = slots[1].off, slots[2].off, slots[3].off
	f.oR, f.oTOP, f.oNVAR = f:word(), f:word(), f:word()
	if t.pinregs then
		f.pin = t.pinregs[1]
		f.pinsave = f:word()
	end
	local np = #fs.params

	for i, v in ipairs(fs.params) do v.reg = i - 1 end
	f.level, f.free, f.maxreg, f.stmthi = np, np, np, np
	f.endlabel = g:newlabel()

	local body = buf.new()
	local saved = g.sink

	g.sink = body
	for _, v in ipairs(fs.params) do
		if boxed(v) then
			f:rt("lr_newbox", f:slot(v.reg), f:slot(v.reg))
		end
	end
	f:block(fs.body)
	f:retstat({vals = {}})
	g:putlabel(f.endlabel)
	-- Now the frame's size is known, the entry can be written.
	local nslots = math.max(f.maxreg, 1)
	local pre = buf.new()

	g.sink = pre
	if fs.vararg then
		g:expr(tree.binary("ASGN", self.W, f:auto(f.oR),
			f:call("lr_venter", self.W, {f:auto(f.oBASE),
				f:auto(f.oNARGS, self.I), f:const(np),
				f:const(nslots)})), "eff", 0)
		local none = g:newlabel()

		g:expr(tree.binary("ASGN", self.I, f:auto(f.oNVAR, self.I),
			f:const(0)), "eff", 0)
		g:cond(tree.binary("GT", self.I, f:auto(f.oNARGS, self.I),
			f:const(np)), none, false, 0)
		g:expr(tree.binary("ASGN", self.I, f:auto(f.oNVAR, self.I),
			tree.binary("SUB", self.I, f:auto(f.oNARGS, self.I),
				f:const(np))), "eff", 0)
		g:putlabel(none)
		g:expr(tree.binary("ASGN", self.W, f:auto(f.oTOP),
			tree.binary("ADD", self.W, f:auto(f.oR),
				tree.const(self.W, nslots * TVSIZE))), "eff", 0)
	else
		-- Called with as many arguments as it has parameters, which
		-- is nearly always, a function only checks the stack and
		-- says where its frame ends.
		local W = self.W
		local slow, done = g:newlabel(), g:newlabel()
		local function name(n) return tree.name(W, n) end

		g:expr(tree.binary("ASGN", W, f:auto(f.oR), f:auto(f.oBASE)),
			"eff", 0)
		g:expr(tree.binary("ASGN", W, f:auto(f.oTOP),
			tree.binary("ADD", W, f:auto(f.oR),
				tree.const(W, nslots * TVSIZE))), "eff", 0)
		g:cond(tree.binary("EQ", self.I, f:auto(f.oNARGS, self.I),
			f:const(np)), slow, false, 0)
		g:cond(tree.binary("LT", self.I, f:auto(f.oTOP),
			name("lr_stackend")), slow, false, 0)
		g:expr(tree.binary("ASGN", W, name("lr_top"), f:auto(f.oTOP)),
			"eff", 0)
		g:cond(tree.binary("GT", self.I, f:auto(f.oTOP),
			name("lr_hiwater")), done, false, 0)
		g:expr(tree.binary("ASGN", W, name("lr_hiwater"),
			f:auto(f.oTOP)), "eff", 0)
		g:jump(done)
		g:putlabel(slow)
		f:rt("lr_enter", f:auto(f.oBASE), f:auto(f.oNARGS, self.I),
			f:const(np), f:const(nslots))
		g:putlabel(done)
	end

	local inner = buf.new()

	pre:move(inner)
	body:move(inner)
	local frame = t.frame(f.maxlocals)

	local whole = buf.new()

	g.sink = whole
	g:write("\t.text\n")
	g:write("\t.type\t" .. sym .. ",@function\n")
	g.body = inner
	g.pinsave = f.pin and {{reg = f.pin, off = f.pinsave}} or nil
	t.prologue(g, sym, frame, slots, nil, static, nil, nil, nil)
	inner:move(whole)
	t.epilogue(g, frame, false, nil, nil, nil, self.I)
	g.body = nil
	g.pinsave = nil
	if self.peep then
		peep.run(whole:lines(), self.peep, function(l) saved:add(l) end)
	else
		whole:move(saved)
	end
	g.sink = saved
	g:write("\t.size\t" .. sym .. ", .-" .. sym .. "\n")
end

return M
