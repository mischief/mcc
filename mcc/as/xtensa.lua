-- SPDX-License-Identifier: ISC
-- Xtensa LX7, for what target/xtensa produces.
--
-- Every instruction here is the wide, 24-bit form; the narrow encodings buy
-- space and nothing else, and leaving them out keeps one size for one
-- mnemonic.  Bytes go out low first.
--
-- Two things need more than a table.
--
-- A constant that will not fit in `movi` becomes an `l32r`, which reads a
-- word near the code.  `l32r` only reaches backwards, so the pool has to
-- come before the code that uses it: comp writes `.align 4` before every
-- function, and that is where a pool goes.  Its size is not known until the
-- function has been read, so the placing pass runs again whenever a pool
-- changes size.
--
-- A conditional branch reaches 128 bytes, which a function outgrows at once.
-- Past that it becomes the opposite branch over a `j`, and the same repeated
-- pass settles it.

local xtensa = {}

local REG = {}
for i = 0, 15 do REG["a" .. i] = i end
REG.sp = 1

local function reg(s)
	return REG[s] or error("no register " .. tostring(s))
end

-- op2, op1 for the three-register forms; r, s and t are the operands
local RRR = {
	["and"] = {1, 0}, ["or"] = {2, 0}, ["xor"] = {3, 0},
	add = {8, 0}, sub = {12, 0},
	addx2 = {9, 0}, addx4 = {10, 0}, addx8 = {11, 0},
	subx2 = {13, 0}, subx4 = {14, 0}, subx8 = {15, 0},
	mull = {8, 2}, muluh = {10, 2}, mulsh = {11, 2},
	quou = {12, 2}, quos = {13, 2}, remu = {14, 2}, rems = {15, 2},
	src = {8, 1},
}
-- r, s: the shift amount comes from the shift-amount register
local SHIFT = {sll = {10, 1}, srl = {9, 1}, sra = {11, 1}}
-- the load and store forms, by the r field and the scale of the offset
local MEM = {
	l8ui = {0, 1}, l16ui = {1, 2}, l32i = {2, 4},
	s8i = {4, 1}, s16i = {5, 2}, s32i = {6, 4},
	l16si = {9, 2}, l32ai = {11, 4}, s32ri = {15, 4},
}
-- r field, and the field pair the offset lands in
local BRANCH = {
	bnone = 0, beq = 1, blt = 2, bltu = 3, ball = 4,
	bany = 8, bne = 9, bge = 10, bgeu = 11, bnall = 12,
}
local INVERT = {beq = "bne", bne = "beq", blt = "bge", bge = "blt",
		bltu = "bgeu", bgeu = "bltu", beqz = "bnez", bnez = "beqz"}
-- the m field of the BZ group
local BZ = {beqz = 0, bnez = 1, bltz = 2, bgez = 3}
-- the special registers this compiler's runtime asks for, by number
local SR = {
	lbeg = 0, lend = 1, lcount = 2, sar = 3,
	windowbase = 72, windowstart = 73,
	ps = 230, epc1 = 177, excsave1 = 209, exccause = 232,
}

local function rrr(a, op2, op1, r, s, t)
	a:emit(op2 << 20 | op1 << 16 | r << 12 | s << 8 | t << 4, 3)
end

local function rri8(a, op0, imm8, r, s, t)
	a:emit((imm8 & 0xff) << 16 | r << 12 | s << 8 | t << 4 | op0, 3)
end

-- the twelve-bit branch group, and `entry`, which shares its shape
local function bri12(a, imm12, s, m, n)
	a:emit((imm12 & 0xfff) << 12 | s << 8 | m << 6 | n << 4 | 6, 3)
end

-- Where a label is, relative to here.  The pass that places labels meets
-- a forward one before it knows the answer, so it takes zero and asks for
-- another pass.
--
-- A global label defined here is used as it stands: this target has no
-- relocation for a branch, so there is nothing else to write, and a
-- weak definition another unit replaces is not offered.
local function rel(a, sym)
	local d = a:here(sym)
	if d then return d end
	if a.pass < 2 then
		if a.pass == 1 then a.changed = true end
		return 0
	end
	error("no label " .. sym)
end

local function signed(v, bits)
	local half = 1 << (bits - 1)
	return v >= -half and v < half
end

-- literal pools -------------------------------------------------------

function xtensa.init(a)
	a.lit = {}		-- pool number -> the words in it
	a.litat = {}		-- pool number -> where it starts
end

-- One pool per function.  The pass that places labels runs on the sizes the
-- pass before it worked out, so the first time round every pool is empty.
function xtensa.startpass(a, pass)
	a.pool = 0
	a.oldlit = a.lit
	if pass == 1 then a.lit = {} end
end

function xtensa.endpass(a, pass)
	if pass ~= 1 then return end
	for k, p in pairs(a.lit) do
		local was = a.oldlit[k]
		if not was or was.n ~= p.n then a.changed = true end
	end
	for k, p in pairs(a.oldlit) do
		if not a.lit[k] and p.n > 0 then a.changed = true end
	end
end

local function flush(a)
	a.pool = a.pool + 1
	a:align(4)
	a.litat[a.pool] = a.cur.off
	local p = a.oldlit[a.pool]
	if not p or p.n == 0 then return end
	if a.pass ~= 2 then return a:space(p.n * 4) end
	for i = 1, p.n do
		local e = p[i]
		if e.sym then
			a:reloc("abs32", e.sym)
			a:emit(0, 4)
		else
			a:emit(e.val & 0xffffffff, 4)
		end
	end
end

-- Where in the pool this value is, adding it if it is not there yet.
local function litref(a, key, val, sym)
	local p = a.lit[a.pool]

	-- the sweep that only places labels must not change the pool it is
	-- placing them against
	if not p then
		if a.pass == 0 then return 1 end
		p = {n = 0, idx = {}}
		a.lit[a.pool] = p
	end
	local i = p.idx[key]
	if not i then
		if a.pass == 0 then return 1 end
		i = p.n + 1
		p.n, p.idx[key], p[i] = i, i, {val = val, sym = sym}
	end
	return i
end

-- l32r reads a word between 4 and 262144 bytes back, from the instruction's
-- address rounded up to a word.
local function l32r(a, t, at)
	local off = at - ((a.cur.off + 3) & ~3)
	if a.pass == 2 and (off > -4 or off < -262144 or off % 4 ~= 0) then
		error("literal out of reach")
	end
	a:emit((((off + 0x40000) >> 2) & 0xffff) << 8 | t << 4 | 1, 3)
end

function xtensa.directive(a, d, rest)
	-- comp writes `.align` only where a function starts, which is the
	-- one place a pool can sit without anything running into it.  Data
	-- is aligned with `.balign`, which does not carry a pool.
	if d == "align" and a.cur then
		a:align(tonumber(rest))
		flush(a)
		return true
	end
	return false
end

-- instructions --------------------------------------------------------

function xtensa.inst(a, m, ops)
	local d = RRR[m]
	if d then
		return rrr(a, d[1], d[2], reg(ops[1]), reg(ops[2]),
			reg(ops[3]))
	end
	d = SHIFT[m]
	if d then
		-- sll takes its operand in s, the right shifts in t
		if m == "sll" then
			return rrr(a, d[1], d[2], reg(ops[1]), reg(ops[2]), 0)
		end
		return rrr(a, d[1], d[2], reg(ops[1]), 0, reg(ops[2]))
	end
	d = MEM[m]
	if d then
		local off = tonumber(ops[3])
		if off % d[2] ~= 0 or off // d[2] > 255 or off < 0 then
			error(("offset %d out of range for %s"):format(off, m))
		end
		return rri8(a, 2, off // d[2], d[1], reg(ops[2]), reg(ops[1]))
	end
	d = BRANCH[m]
	if d then
		a.nbr = a.nbr + 1
		local id = a.nbr
		local at = rel(a, ops[3])
		if not a.long[id] and a.pass == 1 and
		   not signed(at - 4, 8) then
			a.pending[id] = true
		end
		if not a.long[id] then
			return rri8(a, 7, at - 4, d, reg(ops[1]),
				reg(ops[2]))
		end
		-- the opposite branch over a jump: it lands two bytes past
		-- the jump's own end, which is six bytes on from here
		rri8(a, 7, 2, BRANCH[INVERT[m]], reg(ops[1]), reg(ops[2]))
		return xtensa.inst(a, "j", {ops[3]})
	end
	d = BZ[m]
	if d then
		a.nbr = a.nbr + 1
		local id = a.nbr
		local at = rel(a, ops[2])
		if not a.long[id] and a.pass == 1 and
		   not signed(at - 4, 12) then
			a.pending[id] = true
		end
		if not a.long[id] then
			return bri12(a, at - 4, reg(ops[1]), d, 1)
		end
		bri12(a, 2, reg(ops[1]), BZ[INVERT[m]], 1)
		return xtensa.inst(a, "j", {ops[2]})
	end
	if m == "j" then
		local at = rel(a, ops[1])
		if a.pass == 2 and not signed(at - 4, 18) then
			error("jump too far")
		end
		return a:emit(((at - 4) & 0x3ffff) << 6 | 6, 3)
	end
	if m == "call8" or m == "call4" or m == "call0" then
		local n = m == "call8" and 2 or (m == "call4" and 1 or 0)
		-- A global name may be replaced by another unit, so a
		-- call to one keeps its relocation even when the
		-- definition is right here.
		local at = a:localhere(ops[1])
		if not at then
			a:reloc("xt_call", ops[1])
			at = 4			-- patched by the linker
		end
		-- the target is measured from this instruction's address
		-- rounded down to a word
		local off = (at + a.cur.off % 4 - 4) >> 2
		return a:emit((off & 0x3ffff) << 6 | n << 4 | 5, 3)
	end
	if m == "callx8" or m == "callx4" or m == "callx0" then
		local k = m == "callx8" and 0xe or
			(m == "callx4" and 0xd or 0xc)
		return a:emit(reg(ops[1]) << 8 | k << 4, 3)
	end
	if m == "entry" then
		local n = tonumber(ops[2])
		if n % 8 ~= 0 or n < 0 or n > 32760 then
			error("entry frame " .. n)
		end
		return bri12(a, n // 8, reg(ops[1]), 0, 3)
	end
	if m == "mov" then
		local s = reg(ops[2])
		return rrr(a, 2, 0, reg(ops[1]), s, s)
	end
	if m == "neg" or m == "abs" then
		return rrr(a, 6, 0, reg(ops[1]), m == "abs" and 1 or 0,
			reg(ops[2]))
	end
	if m == "ssr" or m == "ssl" then
		return rrr(a, 4, 0, m == "ssl" and 1 or 0, reg(ops[1]), 0)
	end
	if m == "ssai" then
		local n = tonumber(ops[1])
		return rrr(a, 4, 0, 4, n & 15, (n >> 4) & 1)
	end
	if m == "slli" then
		local n = tonumber(ops[3])
		if n < 1 or n > 31 then error("slli by " .. n) end
		return rrr(a, (32 - n) >> 4, 1, reg(ops[1]), reg(ops[2]),
			(32 - n) & 15)
	end
	if m == "srli" then
		local n = tonumber(ops[3])
		if n < 0 or n > 15 then error("srli by " .. n) end
		return rrr(a, 4, 1, reg(ops[1]), n, reg(ops[2]))
	end
	if m == "srai" then
		local n = tonumber(ops[3])
		if n < 0 or n > 31 then error("srai by " .. n) end
		return rrr(a, 2 | (n >> 4), 1, reg(ops[1]), n & 15,
			reg(ops[2]))
	end
	if m == "sext" then
		local n = tonumber(ops[3])
		if n < 7 or n > 22 then error("sext at " .. n) end
		return rrr(a, 2, 3, reg(ops[1]), reg(ops[2]), n - 7)
	end
	if m == "extui" then
		local sa, sz = tonumber(ops[3]), tonumber(ops[4])
		if sz < 1 or sz > 16 or sa < 0 or sa > 31 then
			error("extui " .. sa .. "," .. sz)
		end
		return rrr(a, sz - 1, 4 | (sa >> 4), reg(ops[1]), sa & 15,
			reg(ops[2]))
	end
	if m == "addi" or m == "addmi" then
		local n = tonumber(ops[3])
		if m == "addmi" then n = n >> 8 end
		if not signed(n, 8) then error(m .. " by " .. n) end
		return rri8(a, 2, n, m == "addi" and 12 or 13, reg(ops[2]),
			reg(ops[1]))
	end
	if m == "movi" then
		local t = reg(ops[1])
		local v = tonumber(ops[2])
		if v and signed(v, 12) then
			return rri8(a, 2, v & 0xff, 10, (v >> 8) & 15, t)
		end
		local i = litref(a, ops[2], v, not v and ops[2] or nil)
		return l32r(a, t, (a.litat[a.pool] or 0) + (i - 1) * 4)
	end
	if m == "l32r" then
		return l32r(a, reg(ops[1]), a.cur.off + rel(a, ops[2]))
	end
	-- the window spill handlers, whose offset is a word count
	if m == "s32e" or m == "l32e" then
		local n = tonumber(ops[3])
		if n % 4 ~= 0 or n < -64 or n > -4 then
			error(m .. " offset " .. n)
		end
		return rrr(a, m == "s32e" and 4 or 0, 9, n // 4 + 16,
			reg(ops[2]), reg(ops[1]))
	end
	if m == "rsr" or m == "wsr" or m == "xsr" then
		local sr = SR[ops[2]] or tonumber(ops[2]) or
			error("no special register " .. ops[2])
		return rrr(a, m == "rsr" and 0 or (m == "wsr" and 1 or 6), 3,
			sr >> 4, sr & 15, reg(ops[1]))
	end
	if m == "rfwo" or m == "rfwu" then
		return rrr(a, 0, 0, 3, m == "rfwo" and 4 or 5, 0)
	end
	if m == "simcall" then return a:emit(0x005100, 3) end
	if m == "rsync" then return a:emit(0x002010, 3) end
	if m == "esync" then return a:emit(0x002020, 3) end
	if m == "dsync" then return a:emit(0x002030, 3) end
	if m == "extw" then return a:emit(0x0020d0, 3) end
	if m == "ill" then return a:emit(0, 3) end
	if m == "ret" then return a:emit(0x000080, 3) end
	if m == "retw" then return a:emit(0x000090, 3) end
	if m == "nop" then return a:emit(0x0020f0, 3) end
	if m == "jx" then return a:emit(reg(ops[1]) << 8 | 0xa0, 3) end
	if m == "memw" then return a:emit(0x0020c0, 3) end
	if m == "isync" then return a:emit(0x002000, 3) end
	error("no instruction " .. m)
end

-- `#` starts a comment on this machine, anywhere on the line.
xtensa.hash = true

return xtensa
