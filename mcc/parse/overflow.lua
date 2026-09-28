-- SPDX-License-Identifier: ISC
-- The overflow checks, `__builtin_add_overflow` and its kin.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local fold = cf.fold
local isptr = cf.isptr
local reaches = cf.reaches
local OVOP = require("mcc.parse.builtin").OVOP

-- `__builtin_add_overflow(a, b, res)` and its two siblings.  The wrapped
-- value goes through `res`, and the answer says whether the true one fits
-- the type `res` points at.
--
-- The work happens in a type wide enough to hold both operands, chosen so
-- that neither changes value on the way in.  Two things can go wrong and
-- both are asked about: the operation itself may wrap in that type, and
-- the value may not fit the narrower type it is stored in.
function P:overflow(op, name, args)
	if #args ~= 3 then
		self:err(name .. " takes three arguments")
	end
	local pt = self.ty.decay(self:rvalue(args[3]).ty)
	local rt = isptr(pt) and pt.to

	if not rt or not self.ty.isint(rt) then
		self:err("the last argument of " .. name ..
			" must point at an integer")
		rt = self.ty.i32
	end
	local a, b = self:rvalue(args[1]), self:rvalue(args[2])

	for _, e in ipairs{a, b} do
		if not self.ty.isint(e.ty) then
			self:err(name .. " takes integer arguments")
		end
	end
	a, b = self:conv(a, self:promote(a.ty)),
		self:conv(b, self:promote(b.ty))
	-- Wide enough for both operands, and signed when either is: a
	-- signed operand beside an unsigned one of the same width needs
	-- twice the width to hold both.
	local sa, sb = a.ty.kind == "int", b.ty.kind == "int"
	-- A constant that is not negative is the same value read either
	-- way, so it takes the other operand's signedness and no wider
	-- type is needed to hold both.  `check_mul_overflow(sz, 2, &sz)`
	-- mixes a size with a literal and means what it says.
	local UNS = {[1] = self.ty.u8, [2] = self.ty.u16,
		     [4] = self.ty.u32, [8] = self.ty.u64}

	if sa ~= sb then
		local ka, kb = fold(a), fold(b)

		if sa and ka and ka >= 0 then
			a, sa = self:conv(a, UNS[a.ty.size]), false
		elseif sb and kb and kb >= 0 then
			b, sb = self:conv(b, UNS[b.ty.size]), false
		end
	end
	local w = a.ty.size > b.ty.size and a.ty.size or b.ty.size
	local wsig = sa

	if sa ~= sb then
		wsig = true
		if (sa and b.ty.size or a.ty.size) >= w then w = w * 2 end
	end
	if w < rt.size then w = rt.size end
	-- A signed operand beside an unsigned one of the same width has
	-- no type wide enough to hold both.  A sum or a difference still
	-- answers without one: the bits are worked out in the unsigned
	-- type and how far the true value sits from them is counted.
	local mixed = false

	if w > 8 then
		if op == "mul" then
			self:err(name .. " on these types needs more " ..
				"than eight bytes to work in")
		else
			mixed = true
			wsig = false
		end
		w = 8
	end
	local UT = {[1] = self.ty.u8, [2] = self.ty.u16, [4] = self.ty.u32,
		    [8] = self.ty.u64}
	local ST = {[1] = self.ty.i8, [2] = self.ty.i16, [4] = self.ty.i32,
		    [8] = self.ty.i64}
	local wt, ut, st = wsig and ST[w] or UT[w], UT[w], ST[w]
	local pre = {}
	-- Wrapping is only defined for the unsigned type, so the bits are
	-- worked out there and read back as signed where a test needs it.
	local au, sav = self:pin(self:conv(self:conv(a, wt), ut))
	local bu, sbv = self:pin(self:conv(self:conv(b, wt), ut))

	pre[#pre + 1], pre[#pre + 2] = sav, sbv
	local ru, srv = self:pin(self:arith(OVOP[op], au(), bu()))

	pre[#pre + 1] = srv
	local pp, spv = self:pin(self:conv(self:rvalue(args[3]), pt))

	pre[#pre + 1] = spv
	pre[#pre + 1] = self:assignto(tree.unary("INDIR", rt, pp()),
		self:conv(ru(), rt))

	local i32 = self.ty.i32
	local function as() return self:conv(au(), st) end
	local function bs() return self:conv(bu(), st) end
	local function rs() return self:conv(ru(), st) end
	-- Through arith, not tree.binary: a value wider than a register
	-- is compared by the runtime, and only arith knows that.
	local function cmp(o, x, y) return self:arith(o, x, y) end
	local function both(x, y) return tree.binary("ANDAND", i32, x, y) end
	local function either(x, y) return tree.binary("OROR", i32, x, y) end
	local test
	-- How many times the unsigned type wrapped: the true value is
	-- `ru` plus that many times two to the width.  Only zero and
	-- minus one leave anything a result type could hold.
	local function turns()
		local zero = tree.const(st, 0)
		local an = sa and cmp("LT", as(), zero) or
			tree.const(i32, 0)
		local bn = sb and cmp("LT", bs(), zero) or
			tree.const(i32, 0)
		local c = op == "add" and cmp("LT", ru(), au())
			or cmp("LT", au(), bu())

		if op == "add" then
			return tree.binary("SUB", i32,
				tree.binary("SUB", i32, c, an), bn)
		end
		return tree.binary("SUB", i32,
			tree.binary("SUB", i32, bn, c), an)
	end

	if mixed then
		local kp, skv = self:pin(self:conv(turns(), i32))

		pre[#pre + 1] = skv
		local bits = rt.size * 8
		local kz = cmp("EQ", kp(), tree.const(i32, 0))
		local km = cmp("EQ", kp(), tree.const(i32, -1))
		-- Wrapped once and nothing else: the answer is `ru` read
		-- as signed, which only reaches that far with the top
		-- bit set.
		local low

		if rt.kind == "uint" then
			low = km
		elseif rt.size == 8 then
			low = both(km, cmp("GE", rs(), tree.const(st, 0)))
		else
			low = both(km, either(
				cmp("GE", rs(), tree.const(st, 0)),
				cmp("LT", rs(),
					tree.const(st, -(1 << (bits - 1))))))
		end
		-- Did not wrap: the answer is `ru` read as unsigned.
		if not (rt.kind == "uint" and rt.size == 8) then
			local hi = rt.kind == "uint" and
				(1 << (bits - 1)) * 2 - 1
				or (1 << (bits - 1)) - 1

			low = either(low,
				both(kz, cmp("GT", ru(),
					tree.const(ut, hi))))
		end
		test = either(both(cmp("NE", kp(), tree.const(i32, 0)),
				cmp("NE", kp(), tree.const(i32, -1))), low)
	elseif op == "mul" then
		-- Dividing the answer back gives the other operand unless
		-- it overflowed.  Signed division traps on the one pair
		-- whose answer is the most negative value, so that pair
		-- is ruled out before the division is reached.
		if not wsig then
			test = both(self:test(au()),
				cmp("NE", self:arith("DIV", ru(), au()),
					bu()))
		else
			local m1 = tree.const(st, -1)
			local lo = tree.const(st, -(1 << (w * 8 - 2)) * 2)

			test = both(self:test(as()),
				either(both(cmp("EQ", as(), m1),
						cmp("EQ", bs(), lo)),
					both(cmp("NE", as(), m1),
						cmp("NE", self:arith("DIV",
							rs(), as()), bs()))))
		end
	elseif not wsig then
		-- A sum that came out below what went in wrapped, and a
		-- difference wraps when the first is the smaller.
		test = op == "add" and cmp("LT", ru(), au())
			or cmp("LT", au(), bu())
	else
		-- A signed sum overflows when the answer differs in sign
		-- from both operands; a difference when the operands
		-- differ from each other and the answer from the first.
		local x = op == "add" and self:arith("XOR", bu(), ru())
			or self:arith("XOR", au(), bu())
		local y = self:arith("XOR", au(), ru())

		test = cmp("LT", self:conv(self:arith("AND", x, y), st),
			tree.const(st, 0))
	end
	-- What fits the type it is worked out in may still not fit the one
	-- it is stored in.
	if not mixed and not reaches(wt, rt) then
		local bits = rt.size * 8
		local fit

		if rt.kind == "uint" then
			if wsig then fit = cmp("LT", rs(), tree.const(st, 0)) end
			if rt.size < w then
				local hi = (1 << (bits - 1)) * 2 - 1
				local c = wsig and cmp("GT", rs(),
						tree.const(st, hi))
					or cmp("GT", ru(), tree.const(ut, hi))

				fit = fit and either(fit, c) or c
			end
		else
			local hi = (1 << (bits - 1)) - 1

			if wsig then
				fit = either(cmp("LT", rs(),
						tree.const(st, -hi - 1)),
					cmp("GT", rs(), tree.const(st, hi)))
			else
				fit = cmp("GT", ru(), tree.const(ut, hi))
			end
		end
		if fit then test = either(test, fit) end
	end
	pre[#pre + 1] = self:conv(test, i32)
	return tree.node("SEQ", i32, nil, nil, {arms = pre})
end

return {}
