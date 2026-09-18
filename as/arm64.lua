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

	if not w then error("no register " .. tostring(s)) end
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
	local base, rest = s:match("^%[(%w+)(.*)$")

	if not base then return nil end
	if rest == "]" then return {base = base, off = 0} end
	local off = rest:match("^,#(-?%d+)%]$")

	if off then return {base = base, off = tonumber(off)} end
	off = rest:match("^,#(-?%d+)%]!$")
	if off then return {base = base, off = tonumber(off), pre = true} end
	off = rest:match("^%],#(-?%d+)$")
	if off then return {base = base, off = tonumber(off), post = true} end
	local sym = rest:match("^,#:lo12:([%w.$_]+)%]$")
	if sym then return {base = base, sym = sym} end
	error("bad address " .. s)
end

-- the scaled unsigned form when it fits, the unscaled signed one when it
-- does not, which is the choice the real assembler makes
local function ldst(a, op, size, opc, rt, m, v)
	local base = reg(m.base)
	-- bit 26 says the register is a floating point one
	local V = v and 0x04000000 or 0

	if m.sym then
		a:reloc("a64_ldst" .. (8 << size) .. "_lo12", m.sym)
		return word(a, size << 30 | 0x39000000 | V | opc << 22 |
			base << 5 | rt)
	end
	if m.pre or m.post then
		return word(a, size << 30 | 0x38000000 | V | opc << 22 |
			(m.off & 0x1ff) << 12 | (m.pre and 3 or 1) << 10 |
			base << 5 | rt)
	end
	local scale = 1 << size

	if m.off >= 0 and m.off % scale == 0 and m.off // scale <= 4095 then
		return word(a, size << 30 | 0x39000000 | V | opc << 22 |
			(m.off // scale) << 10 | base << 5 | rt)
	end
	if m.off < -256 or m.off > 255 then
		error("offset out of range " .. m.off)
	end
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

		if off < -64 or off > 63 then
			error("pair offset out of range " .. at.off)
		end
		return word(a, (x and 2 or 0) << 30 | 0x28000000 |
			kind << 23 | (m == "ldp" and 1 or 0) << 22 |
			(off & 0x7f) << 15 | reg(ops[2]) << 10 |
			reg(at.base) << 5 | reg(ops[1]))
	end

	-- movz, movk and movn
	local MOV = {movn = 0, movz = 2, movk = 3}

	if MOV[m] then
		local imm = tonumber(ops[2]:match("^#(-?%d+)$"))
		local sh = tonumber((ops[3] or "lsl #0"):match("#(%d+)")) or 0

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
			local n = tonumber(imm)
			local w = x and 64 or 32
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
		a:reloc("a64_adrp", ops[2])
		return word(a, 0x90000000 | reg(ops[1]))
	end
	if m == "fmov" then
		local f, kind = freg(ops[1])

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
		local v = tonumber(ops[1]:match("#(%d+)")) or 0

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
		return word(a, (m == "bl" and 0x94000000 or 0x14000000) |
			((rel >> 2) & 0x3ffffff))
	end
	if m:sub(1, 2) == "b." and COND[m:sub(3)] then
		local rel = a:localhere(ops[1])

		if not rel then
			a:reloc("a64_condbr19", ops[1])
			rel = 0
		end
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
