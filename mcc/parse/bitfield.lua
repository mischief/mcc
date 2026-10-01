-- SPDX-License-Identifier: ISC
-- Bit-fields: the storage unit a field lives in, and reading and
-- writing the field inside it.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"

-- The type the unit is loaded and stored as.  A _Bool unit holds other
-- fields beside the one bit, so it moves as a plain byte: going through
-- _Bool would leave 0 or 1 and drop the rest.
function P:bfunit(m)
	local T = self.ty

	if not m.ty.isbool then return m.ty end
	if m.ty.size == 1 then return T.u8 end
	if m.ty.size == 2 then return T.u16 end
	if m.ty.size == 4 then return T.u32 end
	return T.u64
end

-- The type the shifting is done in, and the type the value comes out as.
function P:bftypes(m)
	local w = self:promote(m.ty)
	if self:iswide(m.ty) or m.ty.size > w.size then w = m.ty end
	local uns = m.ty.kind == "uint" or m.ty.isbool
	local shift = uns and (w.size == 8 and self.ty.u64 or self.ty.u32)
		or (w.size == 8 and self.ty.i64 or self.ty.i32)
	local out = shift
	if m.bits < 32 then out = self.ty.i32 end
	return shift, out
end

-- A field in a packed record can run past its unit by up to seven
-- bits.  Such a field is read from the unit and the byte after it.
local function straddles(m)
	return m.bit + m.bits > m.ty.size * 8 and m.ty.size <= 4
end

-- The byte after the unit that `lv` names.
function P:bfnext(lv, m)
	local T = self.ty

	if lv.op == "AUTO" then
		local b = tree.auto(T.u8, lv.off + m.ty.size)

		b.part = true
		return b
	end
	local unit = tree.clone(lv)

	unit.bf = nil
	-- Retype a copy: the address may be used again.
	local pb = T.ptr(T.u8)
	local addr = tree.clone(self:addrof(unit))

	addr.ty = pb
	return tree.unary("INDIR", T.u8, tree.binary("ADD", pb, addr,
		tree.const(self.word, m.ty.size)))
end

-- The unit and the byte after it joined in 64 bits, with the field
-- taken out of that.
function P:bfwide(n, m)
	local T = self.ty
	local lv, pre = self:once(n)
	local lo = tree.clone(lv)

	lo.bf = nil
	lo.ty = m.ty.size == 4 and T.u32 or m.ty.size == 2 and T.u16 or T.u8
	local v = self:arith("OR", self:conv(lo, T.u64),
		self:arith("SHL", self:conv(self:bfnext(lv, m), T.u64),
			tree.const(T.i32, m.ty.size * 8)))
	local uns = m.ty.kind == "uint"
	local _, out = self:bftypes(m)

	v = self:arith("SHL", v, tree.const(T.i32, 64 - m.bit - m.bits))
	v = self:arith("SHR", self:conv(v, uns and T.u64 or T.i64),
		tree.const(T.i32, 64 - m.bits))
	v = self:conv(v, out)
	if not pre then return v end
	return tree.node("SEQ", v.ty, nil, nil, {arms = {pre, v}})
end

function P:bfget(n)
	local m = n.bf
	if straddles(m) then return self:bfwide(n, m) end
	local shift, out = self:bftypes(m)
	local w = shift.size * 8
	local raw = tree.clone(n)

	raw.bf = nil
	raw.ty = self:bfunit(m)
	raw = self:conv(raw, shift)
	if w - m.bit - m.bits > 0 then
		raw = self:arith("SHL", raw,
			tree.const(self.ty.i32, w - m.bit - m.bits))
	end
	raw = self:arith("SHR", raw, tree.const(self.ty.i32, w - m.bits))
	return self:conv(raw, out)
end

function P:bfset(lv, rhs)
	local m = lv.bf
	-- The place is named three times below -- read, written, read
	-- back -- so an address that costs anything to work out is
	-- worked out once.  A body built where it was called costs a
	-- great deal: three copies of it would run three times.
	local pre

	lv, pre = self:once(lv)
	lv.bf = m
	if straddles(m) then
		-- Two fields: the bits in the unit, then the rest in the
		-- byte after it.  The value is worked out once.
		local T = self.ty
		local inunit = m.ty.size * 8 - m.bit
		local val, set = self:pin(self:conv(self:rvalue(rhs), T.u32))
		local lo = tree.clone(lv)

		lo.bf = {ty = T.u32, off = m.off, bit = m.bit, bits = inunit,
			 name = m.name}
		lo.ty = m.ty.size == 4 and T.u32 or m.ty.size == 2 and T.u16
			or T.u8
		lo.bf.ty = lo.ty
		local hi = self:bfnext(lv, m)

		hi.bf = {ty = T.u8, off = m.off + m.ty.size, bit = 0,
			 bits = m.bits - inunit, name = m.name}
		local arms = {set, self:bfset(lo, val()),
			self:bfset(hi, self:arith("SHR", val(),
				tree.const(T.i32, inunit))),
			self:bfwide(tree.clone(lv), m)}
		if pre then table.insert(arms, 1, pre) end
		return tree.node("SEQ", arms[#arms].ty, nil, nil,
			{arms = arms})
	end
	local shift = self:bftypes(m)
	local uns = shift.size == 8 and self.ty.u64 or self.ty.u32
	local mask = m.bits >= 64 and -1 or ((1 << m.bits) - 1)
	local uty = self:bfunit(m)
	local unit = tree.clone(lv)

	unit.bf = nil
	unit.ty = uty
	local old = tree.clone(unit)
	old.bf = nil
	local keep = self:arith("AND", self:conv(old, uns),
		tree.const(uns, ~(mask << m.bit)))
	local val = self:rvalue(rhs)

	-- A _Bool bit-field holds 0 or 1, not the low bits of what was
	-- written.  Linux sets one from `flags & PERCPU_REF_ALLOW_REINIT`.
	if m.ty.isbool then val = self:conv(val, m.ty) end
	local put = self:arith("AND", self:conv(val, uns),
		tree.const(uns, mask))
	if m.bit > 0 then
		put = self:arith("SHL", put, tree.const(self.ty.i32, m.bit))
	end
	-- Through assignto, not tree.binary: a unit wider than a
	-- register is stored by the runtime, and a bit-field of more
	-- than thirty-two bits has one on a 32-bit machine.
	local set = self:assignto(unit,
		self:conv(self:arith("OR", keep, put), uty))
	local back = tree.clone(lv)

	back.bf = m
	local out = tree.node("SEQ", self:bftypes(m), nil, nil,
		{arms = {set, self:bfget(back)}})

	if not pre then return out end
	return tree.node("SEQ", out.ty, nil, nil, {arms = {pre, out}})
end

return {}
