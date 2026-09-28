-- SPDX-License-Identifier: ISC
-- Eight-byte integers on a target with four-byte registers: the value
-- lives in memory as two halves, and its operations are built from
-- operations on the halves or calls to the runtime.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local fold = cf.fold
local foldbin = cf.foldbin
local isflt = cf.isflt
local isptr = cf.isptr
-- Declared here, defined with `wconst`.
local halves

-- The address of a wide value.  An lvalue has one; a computed value is a
-- sequence whose last arm is the temporary it was left in.
function P:waddr(e)
	local pt = self.ty.ptr(e.ty)
	if e.op == "INDIR" then
		return self:conv(e.left, pt)
	end
	if e.op == "AUTO" or e.op == "NAME" then
		return tree.unary("ADDR", pt, e)
	end
	if e.op == "SEQ" then
		local arms = {}
		for i = 1, #e.arms - 1 do arms[i] = e.arms[i] end
		arms[#e.arms] = self:waddr(e.arms[#e.arms])
		return tree.node("SEQ", pt, nil, nil, {arms = arms})
	end
	if e.op == "CONST" then
		local lo, hi = halves(e)

		return tree.unary("ADDR", pt, self:wconst(e.val, e.ty, hi))
	end
	if e.op == "COND" then
		-- each arm writes the same temporary, and the address of
		-- that temporary is the answer
		local t = self:wtemp(e.ty)
		local arms = {}
		for i, a in ipairs(e.arms) do
			arms[i] = tree.node("COPY", e.ty,
				self:waddr(tree.clone(t)), self:waddr(a),
				{val = e.ty.size})
		end
		local c = tree.node("COND", self.word, e.left, nil,
			{arms = arms})
		return tree.node("SEQ", pt, nil, nil,
			{arms = {c, self:waddr(t)}})
	end
	if not self:widepass(e.ty) then
		-- the register is wide enough to hold it, so it can simply
		-- be put in a temporary and that named
		local t = self:wtemp(e.ty)
		local set = tree.binary("ASGN", e.ty, tree.clone(t), e)
		return tree.node("SEQ", pt, nil, nil,
			{arms = {set, tree.unary("ADDR", pt, tree.clone(t))}})
	end
	self:err("a wide value must be addressable, not " .. e.op)
end

-- A wide constant goes to read-only data; there is no instruction that can
-- carry one.
function P:wconst(v, ty, hi)
	self.nstr = self.nstr + 1
	local label = ".Lwide" .. self.nstr
	self.t.data.obj(self.sg, label, ty.size, true, false)
	self.t.data.item(self.sg, 4, tostring(v & 0xffffffff))
	self.t.data.item(self.sg, 4, tostring((v >> 32) & 0xffffffff))
	if ty.size == 16 then
		self.t.data.item(self.sg, 4, tostring(hi & 0xffffffff))
		self.t.data.item(self.sg, 4, tostring((hi >> 32) & 0xffffffff))
	end
	self.t.data.endobj(self.sg, label)
	return tree.name(ty, label)
end

-- A sixteen-byte constant keeps its low half in `val` and its high
-- half in `hi`, since Lua works in 64 bits.  One without `hi` is its
-- low half widened by its type.
halves = function(n)
	if n.op ~= "CONST" or not n.ty or n.ty.size ~= 16 or
	   isflt(n.ty) then
		return nil
	end
	local hi = n.hi

	if hi == nil then
		hi = (n.ty.kind ~= "uint" and n.val < 0) and -1 or 0
	end
	return n.val, hi
end
P.halves = halves

function P:wk(ty, lo, hi)
	local c = tree.const(ty, lo)

	if ty.size == 16 then c.hi = hi end
	return c
end

-- An arithmetic shift right, which Lua does not have.
local function sar(x, s)
	if s >= 64 then return x < 0 and -1 or 0 end
	if s == 0 or x >= 0 then return x >> s end
	return (x >> s) | ~(-1 >> s)
end

-- Two sixteen-byte constants under op: the halves of the answer, or a
-- truth value for a comparison, or nil when this does not fold it.
local function fold128(op, al, ah, bl, bh, uns)
	if op == "ADD" then
		local lo = al + bl

		return lo, ah + bh + (math.ult(lo, al) and 1 or 0)
	elseif op == "SUB" then
		return al - bl, ah - bh - (math.ult(al, bl) and 1 or 0)
	elseif op == "AND" then return al & bl, ah & bh
	elseif op == "OR" then return al | bl, ah | bh
	elseif op == "XOR" then return al ~ bl, ah ~ bh
	elseif op == "SHL" or op == "SHR" then
		local k = bl

		if bh ~= 0 or k < 0 or k >= 128 then return nil end
		if op == "SHL" then
			if k >= 64 then return 0, al << (k - 64) end
			if k == 0 then return al, ah end
			return al << k, (ah << k) | (al >> (64 - k))
		end
		local top = uns and function(x, s) return x >> s end or sar

		if k >= 64 then
			return top(ah, k - 64), uns and 0 or sar(ah, 64)
		end
		if k == 0 then return al, ah end
		return (al >> k) | (ah << (64 - k)), top(ah, k)
	end
	local eq = al == bl and ah == bh
	local lt

	if ah ~= bh then
		lt = uns and math.ult(ah, bh) or (not uns and ah < bh)
	else
		lt = math.ult(al, bl)
	end
	local r = ({EQ = eq, NE = not eq, LT = lt, GE = not lt,
		    GT = not lt and not eq, LE = lt or eq})[op]

	if r == nil then return nil end
	return r
end

-- A fresh temporary holding the result of a wide operation, and the call
-- that fills it.  The value of the whole is the temporary.
function P:wtemp(ty)
	return tree.auto(ty, self:temp(ty))
end

function P:wcall(name, args, ty, dst)
	dst = dst or self:wtemp(ty)
	local all = {self:waddr(dst)}
	for _, a in ipairs(args) do all[#all + 1] = a end
	local call = self:rtcall(name, self.word, all)
	return tree.node("SEQ", ty, nil, nil, {arms = {call, dst}})
end

-- Give a node another name for the same bits.
function P:retype(n, ty)
	local c = tree.clone(n)
	c.ty = ty
	return c
end

function P:wconv(n, ty)
	local from = n.ty
	local fw, tw = self:iswide(from), self:iswide(ty)
	if fw and tw then
		if isflt(from) == isflt(ty) then
			local lo, hi = halves(n)

			if lo then return self:wk(ty, lo, hi) end
			if n.op ~= "SEQ" then return self:retype(n, ty) end
			local arms = {}
			for i = 1, #n.arms do arms[i] = n.arms[i] end
			arms[#arms] = self:retype(arms[#arms], ty)
			return tree.node("SEQ", ty, nil, nil, {arms = arms})
		end
		if isflt(ty) then
			return self:wcall(from.kind == "uint" and "__w_ul2d"
				or "__w_l2d", {self:waddr(n)}, ty)
		end
		return self:wcall(ty.kind == "uint" and "__w_d2ul"
			or "__w_d2l", {self:waddr(n)}, ty)
	end
	if tw then
		-- a value that settles here widens here when Lua's own
		-- integers are wide enough to hold the answer, rather
		-- than in a call.  `(long long)(unsigned char)0x1ff` is
		-- a constant and a static initializer may say so.
		local k = ty.size <= 16 and not isflt(from) and fold(n)
			or nil

		if k and ty.size == 16 then
			if isflt(ty) then return self:fconst(k + 0.0, ty) end
			return self:wk(ty, k, (from.kind ~= "uint" and
				not isptr(from) and k < 0) and -1 or 0)
		end
		if k then
			if isflt(ty) then return self:fconst(k + 0.0, ty) end
			return tree.const(ty, k)
		end
		if isflt(from) then
			if isflt(ty) then
				return self:wcall("__w_f2d", {n}, ty)
			end
			return self:wconv(self:conv(n, self.ty.f64), ty)
		end
		-- A pointer is already the whole width on a machine
		-- where the value only lives in memory because this
		-- compiler was told to keep it there.  Its bits are the
		-- answer, so they go straight into the slot.
		if isptr(from) and from.size == ty.size and
		   not isflt(ty) then
			local off = self:temp(ty)

			return tree.node("SEQ", ty, nil, nil, {arms = {
				self:assignto(tree.auto(from, off), n),
				tree.auto(ty, off)}})
		end
		local half = self:widehalf(ty, from.kind == "uint")
		local w = from.size < half.size and half or from

		if isptr(w) then w = self.uword end
		n = self:conv(n, w)
		if isflt(ty) then
			return self:wcall(w.kind == "uint" and "__w_u2d"
				or "__w_i2d", {n}, ty)
		end
		-- Widening is two stores: the value, then zero or the
		-- sign.  `wseq` and `whalfset` are written out here
		-- because both are declared below this function.
		local hf = self:widehalf(ty, w.kind == "uint")
		local dst = self:wtemp(ty)
		local pd = tree.unary("ADDR", self.ty.ptr(ty),
				      tree.clone(dst))
		local arms = {}
		local v = n

		-- Unsigned wants the value once, so it goes straight
		-- into the low half.  Signed wants it again for the
		-- sign, and only then is a slot worth taking.
		if w.kind ~= "uint" and
		   (tree.effects(n) or (n.op ~= "AUTO" and
					n.op ~= "CONST" and
					n.op ~= "NAME")) then
			local t = self:temp(w)

			arms[#arms + 1] = self:assignto(tree.auto(w, t), n)
			v = tree.auto(w, t)
		end
		arms[#arms + 1] = self:assignto(self:wpart(pd, 0, hf),
						self:conv(v, hf))
		local hi

		if w.kind == "uint" then
			hi = tree.const(hf, 0)
		else
			-- All ones when the value is negative.  Written
			-- as a test rather than a shift by the width
			-- less one, which is undefined in C and which
			-- `arith` does not read as arithmetic.
			hi = tree.unary("NEG", hf,
				self:conv(self:arith("LT", tree.clone(v),
					tree.const(w, 0)), hf))
		end
		arms[#arms + 1] = self:assignto(
			self:wpart(tree.clone(pd), 1, hf), self:conv(hi, hf))
		arms[#arms + 1] = dst
		return tree.node("SEQ", ty, nil, nil, {arms = arms})
	end
	-- wide to narrow
	-- A value that settles needs no call to take it apart, and a
	-- static initializer has nowhere to put one.
	if not isflt(from) and not isflt(ty) then
		local k = fold(n)

		if k then return tree.const(ty, k) end
	end
	if isflt(from) then
		if isflt(ty) then
			return self:rtcall("__w_d2f", ty, {self:waddr(n)})
		end
		local want = ty.size < 4 and self.ty.i32 or ty
		if isptr(want) then want = self.uword end
		return self:conv(self:rtcall(want.kind == "uint" and "__w_d2u"
			or "__w_d2i", want, {self:waddr(n)}), ty)
	end
	if isflt(ty) then
		-- A wide integer reaches a narrow float through a double:
		-- its low half alone is not the value, and taking it
		-- loses the sign.
		return self:conv(self:wconv(n, self.ty.f64), ty)
	end
	-- A pointer takes the whole width, so it is read out of the
	-- object rather than built from its low half.
	if isptr(ty) and ty.size == from.size then
		return tree.unary("INDIR", ty,
			self:conv(self:waddr(n), self.ty.ptr(ty)))
	end
	-- The low half is a load from the object, not a call to fetch
	-- one.  `__w_lo` was a frame, a load and a return for the one
	-- instruction in the middle.
	local half = self:widehalf(from, true)
	local pre = {}
	local lo = self:wpart(self:wpin(n, pre), 0, half)

	if #pre == 0 then return self:conv(lo, ty) end
	pre[#pre + 1] = lo
	return self:conv(tree.node("SEQ", half, nil, nil, {arms = pre}), ty)
end

local WOP = {ADD = "add", SUB = "sub", MUL = "mul", AND = "and",
	     OR = "or", XOR = "xor"}
local WDIV = {DIV = "div", MOD = "mod"}
local WREL = {EQ = {"EQ", 0}, NE = {"NE", 0}, LT = {"EQ", -1},
	      GT = {"EQ", 1}, LE = {"LE", 0}, GE = {"GE", 0}}

-- A run of statements with a value at the end.  `{f(), v}` would keep
-- only the first of what f answers, so the arms are built by hand.
local function wseq(st, last, ty)
	local arms = {}

	for i = 1, #st do arms[i] = st[i] end
	arms[#arms + 1] = last
	return tree.node("SEQ", ty, nil, nil, {arms = arms})
end

-- One half of a wide value named by its address.
function P:wpart(ptr, k, half)
	local pt = self.ty.ptr(half)

	-- A half of a wide value in a frame slot is a frame slot, at
	-- its own offset.  Reaching it as `leal off(%ebp),r; (r)`
	-- takes the address into a register to read what the machine
	-- can already name.
	local base = ptr

	while base and base.op == "CVT" do base = base.left end
	if base and base.op == "ADDR" and base.left and
	   base.left.op == "AUTO" and base.left.off and
	   not base.left.pin and not base.left.hard and
	   not base.left.vlasize then
		-- The address is no longer written down, so say here
		-- what it used to say: neither half of a wide value is
		-- a whole scalar local, and the register allocator must
		-- not take one.
		local off = base.left.off

		self.irno[off] = true
		self.irno[off + k * half.size] = true
		self.irok[off] = nil
		self.irok[off + k * half.size] = nil
		return tree.auto(half, off + k * half.size)
	end
	local ad = self:conv(tree.clone(ptr), pt)

	if k > 0 then
		ad = tree.binary("ADD", pt, ad,
			tree.const(self.aword, k * half.size))
	end
	return tree.unary("INDIR", half, ad)
end

-- The address of a wide operand, worked out once: each half names it.
function P:wpin(e, pre)
	local ad = self:waddr(e)

	if ad.op == "ADDR" and
	   (ad.left.op == "AUTO" or ad.left.op == "NAME") then
		return ad
	end
	if ad.op == "NAME" then return ad end
	-- A value built into a slot of its own -- a widened one, a
	-- result -- is that slot once its statements have run: they go
	-- first, and the address is the slot's, not a pointer kept in
	-- another slot and read back for every half.
	if ad.op == "SEQ" and ad.arms then
		local last = ad.arms[#ad.arms]

		if last.op == "ADDR" and last.left and
		   (last.left.op == "AUTO" or last.left.op == "NAME") then
			for i = 1, #ad.arms - 1 do
				pre[#pre + 1] = ad.arms[i]
			end
			return last
		end
	end
	local off = self:temp(ad.ty)

	pre[#pre + 1] = self:assignto(tree.auto(ad.ty, off), ad)
	return tree.auto(ad.ty, off)
end

-- `d = e` for one half.
local function whalfset(self, pd, k, half, e)
	return self:assignto(self:wpart(pd, k, half), self:conv(e, half))
end

-- The two operands of an inline form, and the place the answer goes.
function P:wsetup(a, b, rt, pre)
	local pa = self:wpin(a, pre)
	local pb = b and self:wpin(b, pre)
	local dst = self:wtemp(rt)
	local pd = tree.unary("ADDR", self.ty.ptr(rt), tree.clone(dst))

	return pa, pb, dst, pd
end

local WBIT = {AND = "AND", OR = "OR", XOR = "XOR"}

-- A wide add, subtract or bitwise operation, written out.
function P:wsimple(op, a, b, rt)
	-- A target with the carry in an instruction writes the add and
	-- the subtract out itself, from the two addresses.
	if self.t.winline and self.t.winline["__w_" .. WOP[op]] then
		return self:wcall("__w_" .. WOP[op],
			{self:waddr(a), self:waddr(b)}, rt)
	end
	local u = self:widehalf(rt, true)
	local pre = {}
	local pa, pb, dst, pd = self:wsetup(a, b, rt, pre)
	local st = pre

	if WBIT[op] then
		st[#st + 1] = whalfset(self, pd, 0, u,
			self:arith(op, self:wpart(pa, 0, u),
				self:wpart(pb, 0, u)))
		st[#st + 1] = whalfset(self, pd, 1, u,
			self:arith(op, self:wpart(pa, 1, u),
				self:wpart(pb, 1, u)))
		return wseq(st, dst, rt)
	end
	-- The carry out of the low half is what the two halves share: an
	-- add that wrapped answers less than what went in, and a subtract
	-- borrows when the left half is the smaller.
	local t = self:temp(u)
	local lo = function() return tree.auto(u, t) end

	st[#st + 1] = self:assignto(lo(),
		self:arith(op, self:wpart(pa, 0, u), self:wpart(pb, 0, u)))
	local c
	if op == "ADD" then
		c = self:arith("LT", lo(), self:wpart(pa, 0, u))
	else
		c = self:arith("LT", self:wpart(pa, 0, u),
			self:wpart(pb, 0, u))
	end
	local hi = self:arith(op, self:wpart(pa, 1, u), self:wpart(pb, 1, u))

	hi = self:arith(op, hi, self:conv(c, u))
	st[#st + 1] = whalfset(self, pd, 1, u, hi)
	st[#st + 1] = whalfset(self, pd, 0, u, lo())
	return wseq(st, dst, rt)
end

-- `~a` and `-a`, written out.
function P:wunary(op, a, rt)
	local u = self:widehalf(rt, true)
	local pre = {}
	local pa, _, dst, pd = self:wsetup(a, nil, rt, pre)
	local st = pre

	if op == "NOT" then
		st[#st + 1] = whalfset(self, pd, 0, u,
			tree.unary("NOT", u, self:wpart(pa, 0, u)))
		st[#st + 1] = whalfset(self, pd, 1, u,
			tree.unary("NOT", u, self:wpart(pa, 1, u)))
		return wseq(st, dst, rt)
	end
	-- Negating the low half carries into the high one exactly when
	-- the low half was zero.
	local t = self:temp(u)
	local lo = function() return tree.auto(u, t) end

	st[#st + 1] = self:assignto(lo(),
		tree.unary("NEG", u, self:wpart(pa, 0, u)))
	local hi = self:arith("ADD",
		tree.unary("NOT", u, self:wpart(pa, 1, u)),
		self:conv(self:arith("EQ", lo(), tree.const(u, 0)), u))

	st[#st + 1] = whalfset(self, pd, 1, u, hi)
	st[#st + 1] = whalfset(self, pd, 0, u, lo())
	return wseq(st, dst, rt)
end

-- A shift, written out.  The count decides between three shapes, and a
-- count that is known picks one here.
function P:wshift(op, a, n, rt)
	local u = self:widehalf(rt, true)
	local sg = self:widehalf(rt, false)
	local bits = u.size * 8
	local arith = op == "SHR" and rt.kind ~= "uint"
	local k = fold(n)
	-- A count not known here goes to a target that shifts a pair
	-- in an instruction, the value by address and the count as it
	-- is.  A known count picks its halves below, which is shorter.
	local name = op == "SHL" and "__w_shlw" or
		(arith and "__w_shrsw" or "__w_shruw")

	if k == nil and self.t.winline and self.t.winline[name] then
		return self:wcall(name,
			{self:waddr(a), self:conv(n, self.ty.i32)}, rt)
	end
	local pre = {}
	local pa, _, dst, pd = self:wsetup(a, nil, rt, pre)
	local st = pre

	-- The count is read once, and only what it says may be read.
	local cnt

	if k == nil then
		local off = self:temp(self.ty.i32)

		st[#st + 1] = self:assignto(tree.auto(self.ty.i32, off),
			self:arith("AND", self:conv(n, self.ty.i32),
				tree.const(self.ty.i32, 2 * bits - 1)))
		cnt = function() return tree.auto(self.ty.i32, off) end
	else
		k = k & (2 * bits - 1)
		cnt = function() return tree.const(self.ty.i32, k) end
	end
	local function part(i, uns)
		local h = self:wpart(pa, i, u)

		if uns == false then h = self:conv(h, sg) end
		return h
	end
	-- What each half becomes for a count of nothing, a count inside
	-- one half, and a count that reaches past it.
	local zero, near, far

	if op == "SHL" then
		zero = {part(0), part(1)}
		near = {self:arith("SHL", part(0), cnt()),
			self:arith("OR", self:arith("SHL", part(1), cnt()),
				self:arith("SHR", part(0),
					self:arith("SUB",
						tree.const(self.ty.i32, bits),
						cnt())))}
		far = {tree.const(u, 0),
		       self:arith("SHL", part(0),
			       self:arith("SUB", cnt(),
				       tree.const(self.ty.i32, bits)))}
	else
		local top = arith and
			self:conv(self:arith("SHR", part(1, false),
				tree.const(self.ty.i32, bits - 1)), u)
			or tree.const(u, 0)

		zero = {part(0), part(1)}
		near = {self:arith("OR", self:arith("SHR", part(0), cnt()),
				self:arith("SHL", part(1),
					self:arith("SUB",
						tree.const(self.ty.i32, bits),
						cnt()))),
			self:conv(self:arith("SHR", part(1, not arith and true
				or false), cnt()), u)}
		far = {self:conv(self:arith("SHR", part(1, not arith and true
				or false),
				self:arith("SUB", cnt(),
					tree.const(self.ty.i32, bits))), u),
		       top}
	end
	local pick

	if k == 0 then
		pick = zero
	elseif k ~= nil and k >= bits then
		pick = far
	elseif k ~= nil then
		pick = near
	end
	if pick then
		st[#st + 1] = whalfset(self, pd, 0, u, pick[1])
		st[#st + 1] = whalfset(self, pd, 1, u, pick[2])
		return wseq(st, dst, rt)
	end
	local function choose(i)
		local inner = tree.node("COND", u,
			self:arith("GE", cnt(), tree.const(self.ty.i32, bits)),
			nil, {arms = {self:conv(far[i], u),
				      self:conv(near[i], u)}})

		return tree.node("COND", u,
			self:arith("EQ", cnt(), tree.const(self.ty.i32, 0)),
			nil, {arms = {self:conv(zero[i], u), inner}})
	end
	st[#st + 1] = whalfset(self, pd, 0, u, choose(1))
	st[#st + 1] = whalfset(self, pd, 1, u, choose(2))
	return wseq(st, dst, rt)
end

-- A comparison of two wide values, as a truth value.
function P:wcmp(op, a, b, rt)
	local u = self:widehalf(rt, true)
	local sg = self:widehalf(rt, false)
	local uns = rt.kind == "uint"
	local pre = {}
	local pa = self:wpin(a, pre)
	local pb = self:wpin(b, pre)
	local function hi(p) 
		local h = self:wpart(p, 1, u)

		return uns and h or self:conv(h, sg)
	end
	local eqhi = self:arith("EQ", hi(pa), hi(pb))
	local r

	if op == "EQ" or op == "NE" then
		local eqlo = self:arith("EQ", self:wpart(pa, 0, u),
			self:wpart(pb, 0, u))

		r = tree.node("ANDAND", self.ty.i32, eqhi, eqlo)
		if op == "NE" then
			r = tree.unary("LNOT", self.ty.i32, r)
		end
	else
		local m = {LT = "LT", LE = "LT", GT = "GT", GE = "GT"}
		local lo = self:arith(op, self:wpart(pa, 0, u),
			self:wpart(pb, 0, u))
		local h = self:arith(m[op], hi(pa), hi(pb))

		r = tree.node("OROR", self.ty.i32, h,
			tree.node("ANDAND", self.ty.i32, eqhi, lo))
	end
	if #pre == 0 then return r end
	return wseq(pre, r, self.ty.i32)
end

-- An operation on two wide values.  Floating point keeps its own names,
-- because the runtime for it is not the same code.
-- A wide operand whose high word is known to be zero, as the narrow
-- unsigned value it was widened from, or nil.
function P:narrow32(x)
	if x.op == "CONST" and not isflt(x.ty) then
		if x.val >= 0 and x.val <= 0xffffffff then
			return tree.const(self.ty.u32, x.val)
		end
		return nil
	end
	if x.op == "CVT" and x.left and x.left.ty and
	   not isflt(x.left.ty) and x.left.ty.kind == "uint" and
	   x.left.ty.size <= 4 then
		return self:conv(x.left, self.ty.u32)
	end
	-- The two stores an unsigned value is widened by: the value into
	-- the low half and nought into the high.  The value alone is the
	-- narrow operand, and then the stores are never made.
	if x.op == "SEQ" and x.arms and #x.arms == 3 then
		local lo, hi, v = x.arms[1], x.arms[2], x.arms[3]

		if lo.op == "ASGN" and hi.op == "ASGN" and v.op == "AUTO" and
		   lo.left.op == "AUTO" and lo.left.off == v.off and
		   hi.left.op == "AUTO" and hi.left.off == v.off + 4 and
		   hi.right.op == "CONST" and hi.right.val == 0 and
		   lo.right.ty and lo.right.ty.size == 4 and
		   not isflt(lo.right.ty) then
			return self:conv(lo.right, self.ty.u32)
		end
	end
	return nil
end

function P:wideop(op, a, b, rt)
	local flt = isflt(rt)
	-- Two constants fold here, where Lua's own integers are wide
	-- enough; an initializer has no other way to reach a value.
	-- Either side may be a constant expression rather than a
	-- literal: `1ULL << (56 - 24)` is the shape a descriptor table
	-- is written in.
	if not flt and rt.size == 16 then
		local al, ah = halves(a)
		local bl, bh = halves(b)

		if op == "SHL" or op == "SHR" then
			bl, bh = fold(b), 0
		end
		if al and bl then
			local lo, hi = fold128(op, al, ah, bl, bh,
				rt.kind == "uint")

			if type(lo) == "boolean" then
				return tree.const(self.ty.i32, lo and 1 or 0)
			elseif lo then
				return self:wk(rt, lo, hi)
			end
		end
	elseif not flt then
		local ka, kb = fold(a), fold(b)

		if ka and kb then
			local v = foldbin(op, ka, kb, rt.kind == "uint")

			if v then return tree.const(rt, v) end
		end
	end
	local pre = flt and ("__w_" .. self:fprefix(rt)) or "__w_"
	local wi = self.t.winline or {}

	if WOP[op] and not flt then
		-- Everything but the multiply is a short run of
		-- word-sized operations on the halves.
		if op ~= "MUL" then return self:wsimple(op, a, b, rt) end
		-- A multiply whose operand is a narrow value widened, or a
		-- constant that fits a word, has one cross product or
		-- none, and a target that writes those out takes the
		-- narrow value itself.
		local na, nb = self:narrow32(a), self:narrow32(b)

		if na and nb and wi.__w_mulww then
			return self:wcall("__w_mulww", {na, nb}, rt)
		elseif (na or nb) and wi.__w_mulw then
			return self:wcall("__w_mulw",
				{self:waddr(na and b or a), na or nb}, rt)
		end
		return self:wcall(pre .. WOP[op],
			{self:waddr(a), self:waddr(b)}, rt)
	end
	if WDIV[op] and not flt and rt.kind == "uint" then
		-- Unsigned, by a narrow value: two divides on a target
		-- that writes them out.
		local nb = self:narrow32(b)
		local name = "__w_" .. WDIV[op] .. "uw"

		if nb and wi[name] then
			return self:wcall(name, {self:waddr(a), nb}, rt)
		end
	end
	if flt and (WOP[op] or op == "DIV") then
		return self:wcall(pre .. (WOP[op] or "div"),
			{self:waddr(a), self:waddr(b)}, rt)
	end
	if WDIV[op] then
		return self:wcall(pre .. WDIV[op] ..
			(rt.kind == "uint" and "u" or "s"),
			{self:waddr(a), self:waddr(b)}, rt)
	end
	if op == "SHL" or op == "SHR" then
		return self:wshift(op, a, self:rvalue(b), rt)
	end
	local c = WREL[op]
	if not c then self:err(op .. " is not defined on a wide value") end
	if not flt then return self:wcmp(op, a, b, rt) end
	local name = flt and (pre .. "cmp") or
		("__w_cmp" .. (rt.kind == "uint" and "u" or "s"))
	local r = self:rtcall(name, self.ty.i32,
		{self:waddr(a), self:waddr(b)})
	-- an unordered floating point compare answers 2, which is not less,
	-- not equal and not greater
	if flt and (op == "LE" or op == "GE" or op == "LT" or op == "GT") then
		local m = {LT = {"EQ", -1}, GT = {"EQ", 1},
			   LE = {"LE", 0}, GE = {"ULE", 1}}
		local d = m[op]
		if d[1] == "ULE" then
			r.ty = self.ty.u32
			return tree.binary("LE", self.ty.i32, r,
				tree.const(self.ty.u32, d[2]))
		end
		return tree.binary(d[1], self.ty.i32, r,
			tree.const(self.ty.i32, d[2]))
	end
	return tree.binary(c[1], self.ty.i32, r, tree.const(self.ty.i32, c[2]))
end

return {}
