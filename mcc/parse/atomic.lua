-- SPDX-License-Identifier: ISC
-- The `__sync`, `__atomic` and C11 atomic builtins.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local fold = cf.fold
local isptr = cf.isptr
local b = require "mcc.parse.builtin"
local SYNCOP = b.SYNCOP
local SYNCAFTER = b.SYNCAFTER
local ATOMOP = b.ATOMOP
local ATOMAFTER = b.ATOMAFTER

-- The `__sync_` family, on the same runtime C11 atomics use.  Every
-- one of them is sequentially consistent, which is what the family
-- promised before there was a way to ask for less.
local SEQCST = 5

function P:syncop(what, args, width)
	local vp = self.ty.ptr(self.ty.void)
	local u64 = self.ty.u64
	local i32 = self.ty.i32
	local function num(v) return tree.const(i32, v) end

	if what == "synchronize" then
		return self:rtcall("__mcc_atomic_fence", self.ty.void,
			{num(SEQCST)})
	end
	if #args < 1 or not isptr(self.ty.decay(args[1].ty)) then
		self:err("__sync_" .. what .. " needs a pointer")
		return tree.const(i32, 0)
	end
	local et = self.ty.decay(args[1].ty).to

	-- A name that carries the width says what the operand is,
	-- whatever the pointer was declared to point at.  Where the two
	-- agree the declared type stands, so the answer keeps its sign.
	if width and et.size ~= width then
		et = self.ty["u" .. (width * 8)] or
			self:err("__sync_" .. what .. "_" .. width ..
				 " is not supported") or self.ty.u64
	end

	local w = num(width or et.size)
	local p = self:conv(args[1], vp)

	if what == "lock_release" then
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, tree.const(u64, 0), w, num(SEQCST)})
	end
	if what == "lock_test_and_set" then
		return self:conv(self:rtcall("__mcc_atomic_exchange", u64,
			{p, self:conv(args[2], u64), w, num(SEQCST)}), et)
	end
	if what == "val_compare_and_swap" or
	   what == "bool_compare_and_swap" then
		-- The runtime writes what it found back over the
		-- expected value, so that goes in a slot of its own.
		local off = self:temp(et)
		local slot = tree.auto(et, off)
		-- Through assignto rather than an ASGN node: a value
		-- wider than a register does not travel in one, and on
		-- i386 a long long is wider than a register.
		local pre = self:assignto(slot, self:conv(args[2], et))
		local call = self:rtcall("__mcc_atomic_cas", i32,
			{p, tree.unary("ADDR", vp, tree.clone(slot)),
			 self:conv(args[3], u64), w, num(SEQCST)})

		if what == "bool_compare_and_swap" then
			return tree.node("SEQ", i32, nil, nil,
				{arms = {pre, call}})
		end
		-- The value form answers with what was there, which is
		-- the slot either way.
		return tree.node("SEQ", et, nil, nil,
			{arms = {pre, call, tree.clone(slot)}})
	end
	local op = SYNCOP[what]

	if op == nil then
		self:err("__sync_" .. what .. " is not supported")
		return tree.const(i32, 0)
	end
	return self:atomrmw(op, SYNCAFTER[what], et, p, args[2], w,
			    num(SEQCST))
end

-- The `__atomic` family.  Everything lands on the same runtime the
-- `__sync` family and <stdatomic.h> use; what is different is that
-- the memory order comes from the caller and that the forms without
-- `_n` carry the value by address so that any size can be named.
function P:atomicop(what, args)
	local vp = self.ty.ptr(self.ty.void)
	local cvp = self.ty.ptr(self.ty.void)
	local u64 = self.ty.u64
	local i32 = self.ty.i32
	local function num(v) return tree.const(i32, v) end
	-- What a pointer points at, as an lvalue.  The generic forms
	-- carry their value by address.
	local function deref(e)
		local t = self.ty.decay(e.ty)

		if not isptr(t) then
			self:err("__atomic_" .. what ..
				 " needs a pointer here")
			return tree.const(self.ty.i32, 0)
		end
		return tree.unary("INDIR", t.to, self:rvalue(e))
	end
	local function want(n)
		if #args >= n then return true end
		self:err("__atomic_" .. what .. " wants " .. n ..
			 " arguments")
		return false
	end

	if what == "thread_fence" or what == "signal_fence" then
		if not want(1) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_fence", self.ty.void,
			{self:conv(args[1], i32)})
	end
	-- Whether one of this width is done in place rather than under a
	-- lock.  The answer has to be a constant, because a header tests
	-- it with #if-like code and a program branches on it.
	if what == "always_lock_free" or what == "is_lock_free" then
		if not want(1) then return tree.const(i32, 0) end

		local n = fold(args[1])
		local ok = n == 1 or n == 2 or n == 4 or n == 8

		return tree.const(i32, ok and 1 or 0)
	end
	if #args < 1 or not isptr(self.ty.decay(args[1].ty)) then
		self:err("__atomic_" .. what .. " needs a pointer")
		return tree.const(i32, 0)
	end
	local et = self.ty.decay(args[1].ty).to

	-- The pointer may be to a const or a _Atomic; what matters here
	-- is the width and what the value converts to.
	local w = num(et.size)
	local p = self:conv(args[1], vp)

	-- A flag is one byte whatever it is declared as: gcc says these
	-- two work on a byte.
	if what == "test_and_set" then
		if not want(2) then return tree.const(i32, 0) end
		return self:arith("NE", self:rtcall("__mcc_atomic_exchange",
			u64, {p, tree.const(u64, 1), num(1),
			      self:conv(args[2], i32)}), tree.const(u64, 0))
	end
	if what == "clear" then
		if not want(2) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, tree.const(u64, 0), num(1),
			 self:conv(args[2], i32)})
	end
	if what == "load_n" then
		if not want(2) then return tree.const(i32, 0) end
		return self:conv(self:rtcall("__mcc_atomic_load", u64,
			{p, w, self:conv(args[2], i32)}), et)
	end
	if what == "store_n" then
		if not want(3) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, self:conv(self:conv(args[2], et), u64), w,
			 self:conv(args[3], i32)})
	end
	if what == "exchange_n" then
		if not want(3) then return tree.const(i32, 0) end
		return self:conv(self:rtcall("__mcc_atomic_exchange", u64,
			{p, self:conv(self:conv(args[2], et), u64), w,
			 self:conv(args[3], i32)}), et)
	end
	-- The generic forms carry the value by address.  A read through
	-- the pointer is what turns one into the form above.
	if what == "load" then
		if not want(3) then return tree.const(i32, 0) end
		return self:assignto(deref(args[2]),
			self:conv(self:rtcall("__mcc_atomic_load", u64,
				{p, w, self:conv(args[3], i32)}), et))
	end
	if what == "store" then
		if not want(3) then return tree.const(i32, 0) end
		return self:rtcall("__mcc_atomic_store", self.ty.void,
			{p, self:conv(deref(args[2]), u64), w,
			 self:conv(args[3], i32)})
	end
	if what == "exchange" then
		if not want(4) then return tree.const(i32, 0) end
		return self:assignto(deref(args[3]),
			self:conv(self:rtcall("__mcc_atomic_exchange", u64,
				{p, self:conv(deref(args[2]), u64), w,
				 self:conv(args[4], i32)}), et))
	end
	-- Compare and exchange takes the expected value by address in
	-- both spellings, and the runtime writes what it found back
	-- there, so nothing has to be copied into a slot first.  The
	-- weak flag changes nothing here: the runtime never fails
	-- spuriously.  The failure order is not used, which is allowed:
	-- a stronger order than asked for is always correct.
	if what == "compare_exchange_n" or what == "compare_exchange" then
		if not want(5) then return tree.const(i32, 0) end

		local des = what == "compare_exchange_n" and
			self:conv(args[3], et) or deref(args[3])

		return self:rtcall("__mcc_atomic_cas", i32,
			{p, self:conv(args[2], cvp), self:conv(des, u64), w,
			 self:conv(args[5], i32)})
	end
	local op = ATOMOP[what]

	if op == nil then
		self:err("__atomic_" .. what .. " is not supported")
		return tree.const(i32, 0)
	end
	if not want(3) then return tree.const(i32, 0) end
	return self:atomrmw(op, ATOMAFTER[what], et, p, args[2], w,
			    self:conv(args[3], i32))
end

-- One read-modify-write, for both families.  `et` is the type of the
-- value, `p` the pointer already converted, `raw` what the caller
-- wrote for the operand, `w` the width and `ord` the memory order.
function P:atomrmw(op, after, et, p, raw, w, ord)
	local u64 = self.ty.u64

	-- A pointer operand is worked on as if it were a uintptr_t: the
	-- value is not scaled by what the pointer points at, which is
	-- what gcc says and what a driver counts on.  So the arithmetic
	-- is done in an integer as wide as the pointer and the answer
	-- goes back to the pointer type at the end.
	local at = isptr(et) and (self.ty["u" .. (et.size * 8)] or u64)
		   or et
	local v = self:conv(raw, at)
	local pre = nil

	-- The forms that answer with the value after read the operand
	-- twice, so anything in it would happen twice -- and a body
	-- built where it was called would be built twice, which names
	-- its labels twice.  Once into a slot, then read from there.
	if after and tree.effects(v) then
		local voff = self:temp(at)

		pre = self:assignto(tree.auto(at, voff), v)
		v = tree.auto(at, voff)
	end
	local old

	if op == "add" or op == "sub" then
		local amount = tree.clone(v)

		if op == "sub" then
			amount = self:arith("SUB", self:conv(
				tree.const(at, 0), at), amount)
		end
		old = self:rtcall("__mcc_atomic_fetch_add", u64,
			{p, self:conv(amount, u64), w, ord})
	else
		old = self:rtcall("__mcc_atomic_fetch_bit", u64,
			{p, self:conv(tree.clone(v), u64), w, ord,
			 tree.const(self.ty.i32, op)})
	end
	old = self:conv(old, at)

	local function done(e)
		e = self:conv(e, et)
		if not pre then return e end
		return tree.node("SEQ", e.ty, nil, nil, {arms = {pre, e}})
	end

	if not after then return done(old) end
	-- The forms that answer with the value after do the operation
	-- once more on what was there.
	local BIT = {[0] = "AND", [1] = "OR", [2] = "XOR"}
	local rhs = tree.clone(v)

	if op == "add" then return done(self:arith("ADD", old, rhs)) end
	if op == "sub" then return done(self:arith("SUB", old, rhs)) end
	if op == 3 then
		return done(self:arith("XOR", self:arith("AND", old, rhs),
			self:conv(tree.const(at, -1), at)))
	end
	return done(self:arith(BIT[op], old, rhs))
end

return {}
