-- SPDX-License-Identifier: ISC
-- AArch64, for what target/arm64 produces.
--
-- Every instruction is four bytes and the fields sit in the same places
-- from one to the next, which makes this the plainest of the four.  There
-- is no sizing pass either: `b` reaches a hundred and twenty-eight
-- megabytes and `b.cond` reaches one, and no function this compiler emits
-- comes near either.
--
-- Fifty mnemonics, which is what the target file writes and no more.

local arm64 = {}

local function reg(s)
	if s == "sp" or s == "xzr" or s == "wzr" then return 31 end
	local w, n = s:match("^([wx])(%d+)$")

	if not w or tonumber(n) > 30 then
		error("no register " .. tostring(s))
	end
	return tonumber(n)
end

local function wide(s)
	if s == "sp" then return true end
	return s:sub(1, 1) == "x"
end

-- floating point registers, which only the moves and the argument loads
-- and stores name
local function freg(s)
	local w, n = s:match("^([dsq])(%d+)$")

	if not w then return nil end
	if tonumber(n) > 31 then error("no register " .. s) end
	return tonumber(n), w
end

-- load and store, by mnemonic: the size field, the opc field, and whether
-- the destination is named as an x register
local MEM = {
	ldr   = {nil, 1, nil},		-- size from the register
	str   = {nil, 0, nil},
	ldrb  = {0, 1, false}, strb = {0, 0, false},
	ldrh  = {1, 1, false}, strh = {1, 0, false},
	ldrsb = {0, nil, nil},		-- opc from the register width
	ldrsh = {1, nil, nil},
	ldrsw = {2, 2, true},
}

local COND = {
	eq = 0, ne = 1, hs = 2, lo = 3, mi = 4, pl = 5, vs = 6, vc = 7,
	hi = 8, ls = 9, ge = 10, lt = 11, gt = 12, le = 13, al = 14,
}

-- three-register arithmetic: the opcode with Rd, Rn and Rm zeroed
local ARITH = {
	add  = 0x0b000000, adds = 0x2b000000,
	sub  = 0x4b000000, subs = 0x6b000000,
	["and"] = 0x0a000000, orr = 0x2a000000, eor = 0x4a000000,
	orn  = 0x2a200000, bic = 0x0a200000,
	mul  = 0x1b007c00, madd = 0x1b000000, msub = 0x1b008000,
	sdiv = 0x1ac00c00, udiv = 0x1ac00800,
	lsl  = 0x1ac02000, lsr = 0x1ac02400, asr = 0x1ac02800,
}
-- the add and sub family with a twelve-bit immediate
local ARITHI = {
	add = 0x11000000, adds = 0x31000000,
	sub = 0x51000000, subs = 0x71000000,
}
-- the shifts by a constant are bitfield moves wearing a different name
local SHIFTI = {lsl = true, lsr = true, asr = true}
-- sign and zero extension, likewise
local EXT = {
	-- the second field marks the ones that have a sixty-four bit form
	sxtb = {0x13001c00, 0}, sxth = {0x13003c00, 0},
	sxtw = {0x93407c00, 1},
	uxtb = {0x53001c00, 1}, uxth = {0x53003c00, 1},
}

local function word(a, v)
	a:emit(v & 0xffffffff, 4)
end

-- an operand of the form [reg], [reg,#n], [reg,#n]! or [reg],#n
local function mem(s)
	-- The spaces a macro or the preprocessor leaves behind say
	-- nothing here, and gas reads over them.
	s = s:gsub("%s+", "")
	local base, rest = s:match("^%[(%w+)(.*)$")

	if not base then return nil end
	if rest == "]" then return {base = base, off = 0} end
	local off = rest:match("^,#(-?%d+)%]$")

	if off then return {base = base, off = tonumber(off)} end
	off = rest:match("^,#(-?%d+)%]!$")
	if off then return {base = base, off = tonumber(off), pre = true} end
	off = rest:match("^%],#(-?%d+)$")
	if off then return {base = base, off = tonumber(off), post = true} end
	-- The offset within a page, either of the object itself or of
	-- its slot in the global offset table.  The hash is optional,
	-- which is how gas takes it.
	local sym = rest:match("^,#?:lo12:([%w.$_\128-\255]+)%]$")

	if sym then return {base = base, sym = sym} end
	sym = rest:match("^,#?:got_lo12:([%w.$_\128-\255]+)%]$")
	if sym then return {base = base, sym = sym, got = true} end
	error("bad address " .. s)
end

-- the scaled unsigned form when it fits, the unscaled signed one when it
-- does not, which is the choice the real assembler makes
local function ldst(a, op, size, opc, rt, m, v)
	local base = reg(m.base)
	-- bit 26 says the register is a floating point one
	local V = v and 0x04000000 or 0

	if m.sym then
		a:reloc(m.got and "a64_got_lo12" or
			("a64_ldst" .. (8 << size) .. "_lo12"), m.sym)
		return word(a, size << 30 | 0x39000000 | V | opc << 22 |
			base << 5 | rt)
	end
	if m.pre or m.post then
		a:sfits(m.off, 9, op .. " offset")
		return word(a, size << 30 | 0x38000000 | V | opc << 22 |
			(m.off & 0x1ff) << 12 | (m.pre and 3 or 1) << 10 |
			base << 5 | rt)
	end
	local scale = 1 << size

	if m.off >= 0 and m.off % scale == 0 and m.off // scale <= 4095 then
		return word(a, size << 30 | 0x39000000 | V | opc << 22 |
			(m.off // scale) << 10 | base << 5 | rt)
	end
	a:sfits(m.off, 9, op .. " offset")
	word(a, size << 30 | 0x38000000 | V | opc << 22 |
		(m.off & 0x1ff) << 12 | base << 5 | rt)
end

-- The core splits operands on commas, and a memory operand has commas in
-- it: `[sp,#-16]!` arrives in two pieces.  Put them back.
local function join(ops)
	local out, i = {}, 1

	while i <= #ops do
		local piece = ops[i]

		if piece:sub(1, 1) == "[" then
			while not (piece:find("%]$") or piece:find("%]!$")) do
				i = i + 1
				if not ops[i] then
					error("bad address " .. piece)
				end
				piece = piece .. "," .. ops[i]
			end
			-- a post-index offset follows the bracket
			if piece:sub(-1) == "]" and ops[i + 1] and
			   ops[i + 1]:sub(1, 1) == "#" then
				i = i + 1
				piece = piece .. "," .. ops[i]
			end
		end
		out[#out + 1] = piece
		i = i + 1
	end
	return out
end

function arm64.inst(a, m, ops)
	ops = join(ops)
	-- loads and stores, including the pair forms
	local d = MEM[m]

	if d then
		local f, kind = freg(ops[1])
		local at = mem(ops[2])

		if f then
			local size = kind == "d" and 3 or 2

			return ldst(a, m, size, m == "ldr" and 1 or 0, f,
				at, true)
		end
		local x = wide(ops[1])
		local size = d[1]
		local opc = d[2]

		if m == "ldr" or m == "str" then size = x and 3 or 2 end
		if m == "ldrsb" or m == "ldrsh" then opc = x and 2 or 3 end
		return ldst(a, m, size, opc, reg(ops[1]), at)
	end
	if m == "stp" or m == "ldp" then
		local at = mem(ops[3])
		local x = wide(ops[1])
		local size = x and 3 or 2
		local scale = x and 8 or 4
		local kind = at.pre and 3 or (at.post and 1 or 2)
		local off = at.off // scale

		a:aligned(at.off, scale, m .. " offset")
		a:fits(at.off, -64 * scale, 63 * scale, m .. " offset")
		return word(a, (x and 2 or 0) << 30 | 0x28000000 |
			kind << 23 | (m == "ldp" and 1 or 0) << 22 |
			(off & 0x7f) << 15 | reg(ops[2]) << 10 |
			reg(at.base) << 5 | reg(ops[1]))
	end

	-- movz, movk and movn
	local MOV = {movn = 0, movz = 2, movk = 3}

	if MOV[m] then
		local imm = tonumber(ops[2]:match("^#(-?%d+)$")) or
			error("bad immediate " .. ops[2])
		local sh = tonumber((ops[3] or "lsl #0"):match("#(%d+)")) or 0

		a:ufits(imm, 16, m .. " immediate")
		a:aligned(sh, 16, m .. " shift amount")
		a:fits(sh, 0, wide(ops[1]) and 48 or 16, m .. " shift amount")

		return word(a, (wide(ops[1]) and 1 or 0) << 31 |
			MOV[m] << 29 | 0x12800000 | (sh // 16) << 21 |
			(imm & 0xffff) << 5 | reg(ops[1]))
	end
	if m == "mov" then
		local imm = ops[2]:match("^#(-?%d+)$")
		local x = wide(ops[1])

		if imm then
			local v = tonumber(imm)

			-- a negative value is the complement of a small
			-- one, which is what movn is for
			if v < 0 and ~v <= 0xffff then
				return word(a, (x and 1 or 0) << 31 |
					0x12800000 | (~v & 0xffff) << 5 |
					reg(ops[1]))
			end
			if v < 0 or v > 0xffff then
				error("mov immediate " .. imm)
			end
			return word(a, (x and 1 or 0) << 31 | 2 << 29 |
				0x12800000 | v << 5 | reg(ops[1]))
		end
		-- a move to or from the stack pointer is an add of zero,
		-- because the register number they share means zero
		-- everywhere else
		if ops[1] == "sp" or ops[2] == "sp" then
			return word(a, (x and 1 or 0) << 31 | 0x11000000 |
				reg(ops[2]) << 5 | reg(ops[1]))
		end
		return word(a, (x and 1 or 0) << 31 | 0x2a000000 |
			reg(ops[2]) << 16 | 31 << 5 | reg(ops[1]))
	end

	if EXT[m] then
		local e = EXT[m]
		-- the signed ones widen to whichever register is named, and
		-- the sixty-four bit form sets sf and N together
		local x = wide(ops[1]) and e[2] == 0 and 0x80400000 or 0

		return word(a, e[1] | x | reg(ops[2]) << 5 | reg(ops[1]))
	end
	if m == "neg" then
		return word(a, (wide(ops[1]) and 1 or 0) << 31 | 0x4b000000 |
			reg(ops[2]) << 16 | 31 << 5 | reg(ops[1]))
	end
	if m == "mvn" then
		return word(a, (wide(ops[1]) and 1 or 0) << 31 | 0x2a200000 |
			reg(ops[2]) << 16 | 31 << 5 | reg(ops[1]))
	end

	if m == "cmp" then
		local imm = ops[2]:match("^#(-?%d+)$")
		local x = wide(ops[1])

		if imm then
			local v = tonumber(imm)
			local op, sh = ARITHI.subs, 0

			if v < 0 then op, v = ARITHI.adds, -v end
			if v > 4095 then
				if v % 4096 ~= 0 or v // 4096 > 4095 then
					error("cmp immediate " .. imm)
				end
				v, sh = v // 4096, 1
			end
			return word(a, (x and 1 or 0) << 31 | op |
				sh << 22 | v << 10 | reg(ops[1]) << 5 | 31)
		end
		return word(a, (x and 1 or 0) << 31 | ARITH.subs |
			reg(ops[2]) << 16 | reg(ops[1]) << 5 | 31)
	end

	if ARITH[m] or ARITHI[m] then
		local x = wide(ops[1])
		local imm = ops[3] and ops[3]:match("^#(-?%d+)$")

		if imm and SHIFTI[m] then
			local w = x and 64 or 32
			local n = a:fits(tonumber(imm), 0, w - 1,
				m .. " shift amount")
			local nbit = x and (1 << 22) or 0

			if m == "lsl" then
				return word(a, (x and 1 or 0) << 31 |
					0x53000000 | nbit |
					((w - n) % w) << 16 |
					(w - 1 - n) << 10 |
					reg(ops[2]) << 5 | reg(ops[1]))
			end
			return word(a, (x and 1 or 0) << 31 |
				(m == "asr" and 0x13000000 or 0x53000000) |
				nbit | n << 16 | (w - 1) << 10 |
				reg(ops[2]) << 5 | reg(ops[1]))
		end
		if imm then
			local op = ARITHI[m] or
				error("no immediate form of " .. m)
			local v, sh = tonumber(imm), 0

			if v < 0 then
				op = (m == "add" and ARITHI.sub) or
				     (m == "sub" and ARITHI.add) or
				     error("no negative immediate for " .. m)
				v = -v
			end
			if v > 4095 then
				if v % 4096 ~= 0 or v // 4096 > 4095 then
					error(m .. " immediate " .. imm)
				end
				v, sh = v // 4096, 1
			end
			return word(a, (x and 1 or 0) << 31 | op | sh << 22 |
				v << 10 | reg(ops[2]) << 5 | reg(ops[1]))
		end
		if ops[3] and ops[3]:match("^#:lo12:") then
			a:reloc("a64_add_lo12", ops[3]:match(":lo12:(.*)$"))
			return word(a, (x and 1 or 0) << 31 | ARITHI.add |
				reg(ops[2]) << 5 | reg(ops[1]))
		end
		local base = ARITH[m]

		if m == "msub" then
			return word(a, (x and 1 or 0) << 31 | base |
				reg(ops[3]) << 16 | reg(ops[4]) << 10 |
				reg(ops[2]) << 5 | reg(ops[1]))
		end
		if m == "mul" then
			return word(a, (x and 1 or 0) << 31 | base |
				reg(ops[3]) << 16 | 31 << 10 |
				reg(ops[2]) << 5 | reg(ops[1]))
		end
		-- Register thirty-one means the stack pointer in the
		-- extended-register form and the zero register in the
		-- shifted one, so an add that names sp has to use the
		-- first, with the extension that does nothing.
		if (m == "add" or m == "sub") and
		   (ops[1] == "sp" or ops[2] == "sp") then
			return word(a, (x and 1 or 0) << 31 |
				(m == "sub" and 0x4b200000 or 0x0b200000) |
				reg(ops[3]) << 16 | 3 << 13 |
				reg(ops[2]) << 5 | reg(ops[1]))
		end
		return word(a, (x and 1 or 0) << 31 | base |
			reg(ops[3]) << 16 | reg(ops[2]) << 5 | reg(ops[1]))
	end

	if m == "adrp" then
		-- `:got:sym` asks for the page the table slot is on
		-- rather than the page the object is on.
		local g = ops[2] and ops[2]:match("^:got:([%w.$_\128-\255]+)$")

		a:reloc(g and "a64_got_page" or "a64_adrp", g or ops[2])
		return word(a, 0x90000000 | reg(ops[1]))
	end
	-- Floating point.  ftype is the width: 0 for single, 1 for double.
	local FP2 = {fmul = 0, fdiv = 1, fadd = 2, fsub = 3,
		     fmax = 4, fmin = 5, fmaxnm = 6, fminnm = 7, fnmul = 8}
	local FP1 = {fabs = 1, fneg = 2, fsqrt = 3}
	local FCVTI = {fcvtzs = {3, 0}, fcvtzu = {3, 1}}
	local FCVTF = {scvtf = {0, 2}, ucvtf = {0, 3}}

	if FP2[m] and #ops == 3 then
		local d, kind = freg(ops[1])
		local n = freg(ops[2])
		local r = freg(ops[3])

		return word(a, 0x1e200800 | (kind == "d" and 1 or 0) << 22 |
			r << 16 | FP2[m] << 12 | n << 5 | d)
	end
	if FP1[m] and #ops == 2 then
		local d, kind = freg(ops[1])
		local n = freg(ops[2])

		return word(a, 0x1e204000 | (kind == "d" and 1 or 0) << 22 |
			FP1[m] << 15 | n << 5 | d)
	end
	if m == "fcvt" and #ops == 2 then
		local d, dk = freg(ops[1])
		local n, sk = freg(ops[2])

		-- the width in the instruction is the source's; the
		-- opcode says which one it becomes
		return word(a, 0x1e204000 | (sk == "d" and 1 or 0) << 22 |
			(dk == "d" and 5 or 4) << 15 | n << 5 | d)
	end
	if m == "fcmp" and #ops == 2 then
		local n, kind = freg(ops[1])
		local r, zero = freg(ops[2]), 0

		if not r then
			-- the only immediate it takes is zero
			if not ops[2]:match("^#0%.?0*$") then
				error("fcmp takes a register or #0.0")
			end
			r, zero = 0, 8
		end
		return word(a, 0x1e202000 | (kind == "d" and 1 or 0) << 22 |
			r << 16 | n << 5 | zero)
	end
	if FCVTF[m] and #ops == 2 then
		local d, kind = freg(ops[1])
		local e = FCVTF[m]

		return word(a, 0x1e200000 | (wide(ops[2]) and 1 or 0) << 31 |
			(kind == "d" and 1 or 0) << 22 | e[1] << 19 |
			e[2] << 16 | reg(ops[2]) << 5 | d)
	end
	if FCVTI[m] and #ops == 2 then
		local n, kind = freg(ops[2])
		local e = FCVTI[m]

		return word(a, 0x1e200000 | (wide(ops[1]) and 1 or 0) << 31 |
			(kind == "d" and 1 or 0) << 22 | e[1] << 19 |
			e[2] << 16 | n << 5 | reg(ops[1]))
	end
	if m == "fmov" then
		local f, kind = freg(ops[1])
		local g0, k0 = freg(ops[2])

		-- between two registers of the float file
		if f and g0 then
			return word(a, 0x1e204000 |
				(kind == "d" and 1 or 0) << 22 | g0 << 5 | f)
		end
		if f then
			return word(a, (kind == "d" and 1 or 0) << 31 |
				0x1e260000 | (kind == "d" and 1 or 0) << 22 |
				1 << 16 | reg(ops[2]) << 5 | f)
		end
		local g, k = freg(ops[2])

		return word(a, (k == "d" and 1 or 0) << 31 | 0x1e260000 |
			(k == "d" and 1 or 0) << 22 | g << 5 | reg(ops[1]))
	end
	if m == "svc" then
		local v = tonumber(ops[1]:match("#(-?%d+)")) or 0

		a:ufits(v, 16, m .. " immediate")
		return word(a, 0xd4000001 | (v & 0xffff) << 5)
	end
	if m == "ret" then return word(a, 0xd65f0000 | 30 << 5) end
	if m == "nop" then return word(a, 0xd503201f) end
	if m == "blr" then
		return word(a, 0xd63f0000 | reg(ops[1]) << 5)
	end
	if m == "br" then
		return word(a, 0xd61f0000 | reg(ops[1]) << 5)
	end
	if m == "b" or m == "bl" then
		local rel = a:localhere(ops[1])

		if not rel then
			a:reloc(m == "bl" and "a64_call26" or "a64_jump26",
				ops[1])
			rel = 0
		end
		a:fits(rel, -(1 << 27), (1 << 27) - 4, m .. " offset")
		a:aligned(rel, 4, m .. " offset")
		return word(a, (m == "bl" and 0x94000000 or 0x14000000) |
			((rel >> 2) & 0x3ffffff))
	end
	if m:sub(1, 2) == "b." and COND[m:sub(3)] then
		local rel = a:localhere(ops[1])

		if not rel then
			a:reloc("a64_condbr19", ops[1])
			rel = 0
		end
		a:fits(rel, -(1 << 20), (1 << 20) - 4, m .. " offset")
		a:aligned(rel, 4, m .. " offset")
		return word(a, 0x54000000 | ((rel >> 2) & 0x7ffff) << 5 |
			COND[m:sub(3)])
	end
	if m == "mrs" then
		-- only the counter the inline assembly test reads
		if ops[2] == "cntvct_el0" then
			return word(a, 0xd53be040 | reg(ops[1]))
		end
		error("no system register " .. tostring(ops[2]))
	end
	error("no instruction " .. m)
end

return arm64
