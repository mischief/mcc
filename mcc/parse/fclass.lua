-- SPDX-License-Identifier: ISC
-- Classifying a float, and copying a sign, from the bits of the value.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local FBITS = require("mcc.parse.builtin").FBITS

-- A float classified from its bits, which needs no call.  The value goes
-- to a slot and is read back as an integer: the sign, a field of
-- exponent, and the fraction.  The x87 type writes its integer bit out,
-- so its fraction is the sixty-three bits below that.
function P:fclass(fc, a)
	local i32 = self.ty.i32
	local off = self:temp(a.ty)
	local ex, frac, neg, emax

	self.irno[off] = true
	local set = self:assignto(tree.auto(a.ty, off), a)
	if a.ty.x87 then
		self.irno[off + 8] = true
		local function se()
			return self:conv(tree.auto(self.ty.u16, off + 8), i32)
		end
		emax = 0x7fff
		ex = function()
			return self:arith("AND", se(), tree.const(i32, emax))
		end
		frac = function()
			return self:arith("AND", tree.auto(self.ty.u64, off),
				tree.const(self.ty.u64, 0x7fffffffffffffff))
		end
		neg = function()
			return self:arith("NE", self:arith("AND", se(),
				tree.const(i32, 0x8000)), tree.const(i32, 0))
		end
	else
		local l = FBITS[a.ty.size]
		local bt = self.ty[l.bits]
		local function b() return tree.auto(bt, off) end

		emax = (1 << l.ebits) - 1
		ex = function()
			return self:conv(self:arith("AND", self:arith("SHR", b(),
				tree.const(i32, l.fbits)), tree.const(bt, emax)),
				i32)
		end
		frac = function()
			return self:arith("AND", b(),
				tree.const(bt, (1 << l.fbits) - 1))
		end
		neg = function()
			return self:arith("NE", self:arith("SHR", b(),
				tree.const(i32, l.ebits + l.fbits)),
				tree.const(bt, 0))
		end
	end
	local function zero(t) return tree.const(t.ty, 0) end
	local function top()
		return self:arith("EQ", ex(), tree.const(i32, emax))
	end
	local function inf()
		local f = frac()

		return tree.node("ANDAND", i32, top(),
			self:arith("EQ", f, zero(f)))
	end
	local r

	if fc == "isnan" then
		local f = frac()

		r = tree.node("ANDAND", i32, top(), self:arith("NE", f, zero(f)))
	elseif fc == "isinf" then
		r = inf()
	elseif fc == "isfin" then
		r = self:arith("NE", ex(), tree.const(i32, emax))
	elseif fc == "isneg" then
		r = neg()
	elseif fc == "isnorm" then
		r = tree.node("ANDAND", i32,
			self:arith("NE", ex(), tree.const(i32, emax)),
			self:arith("NE", ex(), tree.const(i32, 0)))
	else
		-- isinf_sign: -1 or 1 for an infinity, else 0.
		r = self:arith("MUL", self:conv(inf(), i32),
			self:arith("SUB", tree.const(i32, 1),
				self:arith("MUL", tree.const(i32, 2),
					self:conv(neg(), i32))))
	end
	return tree.node("SEQ", i32, nil, nil, {arms = {set, r}})
end

-- x with the sign of y, in the bits.  The top byte holds the sign on
-- every format here, the x87 one included.
function P:copysign(x, y, ty)
	local sz = ty.x87 and 10 or ty.size
	local ox, oy = self:temp(ty), self:temp(ty)
	local u8 = self.ty.u8
	local at = sz - 1

	self.irno[ox] = true
	self.irno[oy] = true
	self.irno[ox + at] = true
	self.irno[oy + at] = true
	local function byte(o) return tree.auto(u8, o + at) end
	local sign = self:arith("AND", byte(oy), tree.const(self.ty.i32, 0x80))
	local rest = self:arith("AND", byte(ox), tree.const(self.ty.i32, 0x7f))

	return tree.node("SEQ", ty, nil, nil, {arms = {
		self:assignto(tree.auto(ty, ox), self:conv(x, ty)),
		self:assignto(tree.auto(ty, oy), self:conv(y, ty)),
		self:assignto(byte(ox), self:arith("OR", sign, rest)),
		tree.auto(ty, ox)}})
end

return {}
