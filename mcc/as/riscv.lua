-- SPDX-License-Identifier: ISC
-- RISC-V, for what the targets in target/riscv produce.
--
-- Sixty-three mnemonics, which is enough to be checked against the real
-- assembler: `test/as.lua` assembles every file twice and compares the
-- bytes.

local riscv = {}

local REG = {}
for i = 0, 31 do REG["x" .. i] = i end
for i, n in ipairs{"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
		   "s0", "s1"} do REG[n] = i - 1 end
REG.fp = 8
for i = 0, 7 do REG["a" .. i] = 10 + i end
for i = 2, 11 do REG["s" .. i] = 16 + i end
for i = 3, 6 do REG["t" .. i] = 25 + i end
-- The float ABI names do not run straight through the file: the saved
-- ones are split either side of the arguments, and the temporaries
-- either side of everything.
local FREG = {}
for i = 0, 31 do FREG["f" .. i] = i end
for i = 0, 7 do FREG["ft" .. i] = i end
for i = 0, 1 do FREG["fs" .. i] = 8 + i end
for i = 0, 7 do FREG["fa" .. i] = 10 + i end
for i = 2, 11 do FREG["fs" .. i] = 18 + (i - 2) end
for i = 8, 11 do FREG["ft" .. i] = 28 + (i - 8) end

-- An opcode, funct3 and funct7, packed in one number so that a table of
-- them holds no table per mnemonic.  opfields takes them apart.
local function op(opcode, f3, f7)
	return opcode | f3 << 7 | (f7 or 0) << 10
end

local function opfields(d)
	return d & 0x7f, d >> 7 & 7, d >> 10
end

-- opcode, funct3, funct7 for the three-register forms
local R = {
	add = op(0x33, 0, 0x00),  sub  = op(0x33, 0, 0x20),
	sll = op(0x33, 1, 0x00),  slt  = op(0x33, 2, 0x00),
	sltu = op(0x33, 3, 0x00), ["xor"] = op(0x33, 4, 0x00),
	srl = op(0x33, 5, 0x00),  sra  = op(0x33, 5, 0x20),
	["or"] = op(0x33, 6, 0x00), ["and"] = op(0x33, 7, 0x00),
	mul = op(0x33, 0, 0x01),  mulh = op(0x33, 1, 0x01),
	mulhu = op(0x33, 3, 0x01),
	div = op(0x33, 4, 0x01),  divu = op(0x33, 5, 0x01),
	rem = op(0x33, 6, 0x01),  remu = op(0x33, 7, 0x01),
	addw = op(0x3b, 0, 0x00), subw = op(0x3b, 0, 0x20),
	sllw = op(0x3b, 1, 0x00), srlw = op(0x3b, 5, 0x00),
	sraw = op(0x3b, 5, 0x20), mulw = op(0x3b, 0, 0x01),
	divw = op(0x3b, 4, 0x01), divuw = op(0x3b, 5, 0x01),
	remw = op(0x3b, 6, 0x01), remuw = op(0x3b, 7, 0x01),
}

-- register, register, immediate
local I = {
	addi = op(0x13, 0), slti = op(0x13, 2), sltiu = op(0x13, 3),
	xori = op(0x13, 4), ori = op(0x13, 6), andi = op(0x13, 7),
	addiw = op(0x1b, 0),
}
-- the shifts put a function code in the top of the immediate field
local SH = {
	slli = op(0x13, 1, 0x00), srli = op(0x13, 5, 0x00),
	srai = op(0x13, 5, 0x20),
	slliw = op(0x1b, 1, 0x00), srliw = op(0x1b, 5, 0x00),
	sraiw = op(0x1b, 5, 0x20),
}
-- register, offset(register)
local LOAD = {
	lb = op(0x03, 0), lh = op(0x03, 1), lw = op(0x03, 2), ld = op(0x03, 3),
	lbu = op(0x03, 4), lhu = op(0x03, 5), lwu = op(0x03, 6),
	flw = op(0x07, 2), fld = op(0x07, 3),
}
local STORE = {
	sb = op(0x23, 0), sh = op(0x23, 1), sw = op(0x23, 2), sd = op(0x23, 3),
	fsw = op(0x27, 2), fsd = op(0x27, 3),
}
local BRANCH = {
	beq = op(0x63, 0), bne = op(0x63, 1), blt = op(0x63, 4),
	bge = op(0x63, 5), bltu = op(0x63, 6), bgeu = op(0x63, 7),
}
-- A branch reaches four kilobytes.  Past that it becomes the opposite
-- branch over a jump, which is what the real assembler does too.
local INVERT = {beq = "bne", bne = "beq", blt = "bge", bge = "blt",
		bltu = "bgeu", bgeu = "bltu"}
-- moves between the two register files
local FMV = {
	["fmv.x.w"] = {0x53, 0, 0x70, "x"}, ["fmv.w.x"] = {0x53, 0, 0x78, "f"},
	["fmv.x.d"] = {0x53, 0, 0x71, "x"}, ["fmv.d.x"] = {0x53, 0, 0x79, "f"},
}

-- OP-FP.  The seven-bit function code is a five-bit operation with the
-- format in its low two bits: 0 for single, 1 for double.  The rounding
-- mode field says "as the rounding mode register says" unless an operand
-- names one.
local OPFP = 0x53
local FMT = {s = 0, d = 1}
local FARITH = {fadd = 0x00, fsub = 0x01, fmul = 0x02, fdiv = 0x03}
local FSGNJ = {fsgnj = 0, fsgnjn = 1, fsgnjx = 2}
-- The three moves are a sign injection with one register named twice.
local FSGNP = {fmv = 0, fneg = 1, fabs = 2}
local FMINMAX = {fmin = 0, fmax = 1}
local FCMP = {fle = 0, flt = 1, feq = 2}
local FIW = {w = 0, wu = 1, l = 2, lu = 3}
local RM = {rne = 0, rtz = 1, rdn = 2, rup = 3, rmm = 4, dyn = 7}

-- The control and status registers a kernel names.  A number stands
-- for itself, so a register this table has not heard of is still
-- reachable.
local CSR = {
	fflags = 0x001, frm = 0x002, fcsr = 0x003,
	cycle = 0xc00, time = 0xc01, instret = 0xc02,
	cycleh = 0xc80, timeh = 0xc81, instreth = 0xc82,
	sstatus = 0x100, sie = 0x104, stvec = 0x105,
	scounteren = 0x106, sscratch = 0x140, sepc = 0x141,
	scause = 0x142, stval = 0x143, sip = 0x144, satp = 0x180,
	mvendorid = 0xf11, marchid = 0xf12, mimpid = 0xf13,
	mhartid = 0xf14,
	mstatus = 0x300, misa = 0x301, medeleg = 0x302, mideleg = 0x303,
	mie = 0x304, mtvec = 0x305, mcounteren = 0x306,
	mscratch = 0x340, mepc = 0x341, mcause = 0x342, mtval = 0x343,
	mip = 0x344,
}
-- `csrrw rd, csr, rs` and the five others, by their funct3.
local CSROP = {csrrw = 1, csrrs = 2, csrrc = 3,
	       csrrwi = 5, csrrsi = 6, csrrci = 7, csrr = 2}
-- The forms that leave the answer nowhere: `csrw csr, rs`.
local CSRPSEUDO = {csrw = 1, csrs = 2, csrc = 3,
		   csrwi = 5, csrsi = 6, csrci = 7}
-- Reading one counter, which is a read of a fixed register.
local COUNTER = {rdcycle = 0xc00, rdtime = 0xc01, rdinstret = 0xc02,
		 rdcycleh = 0xc80, rdtimeh = 0xc81, rdinstreth = 0xc82}

local function reg(s)
	return REG[s] or error("no register " .. tostring(s))
end

-- A branch against zero: which real branch it is, and whether the
-- register goes on the right rather than the left.
local BZ = {beqz = {"beq"}, bnez = {"bne"}, bltz = {"blt"},
	    bgez = {"bge"}, bgtz = {"blt", true}, blez = {"bge", true}}
-- The ones written the other way round, which swap their registers.
local BSWAP = {bgt = "blt", ble = "bge", bgtu = "bltu", bleu = "bgeu"}
-- Waiting, and coming back from a trap.
local TRAP = {wfi = 0x10500073, mret = 0x30200073, sret = 0x10200073,
	      uret = 0x00200073, ebreak = 0x00100073,
	      ["sfence.vma"] = 0x12000073}

-- The name of a numbered register, for a pseudo that stands for a real
-- instruction with a register moved or x0 put in.
local RNAME = {}
for k, v in pairs(REG) do
	if RNAME[v] == nil or #k < #RNAME[v] then RNAME[v] = k end
end

local function regname(n) return RNAME[n] or ("x" .. n) end

local function csrno(a, s)
	if s == nil then error("a csr is wanted here") end
	return CSR[s] or tonumber(s) or a:absexpr(s) or
		error("no csr " .. tostring(s))
end

local function freg(s)
	return FREG[s] or error("no float register " .. tostring(s))
end

local function rtype(op, f3, f7, rd, rs1, rs2)
	return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
end

local function itype(op, f3, rd, rs1, imm)
	return (imm & 0xfff) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
end

local function stype(op, f3, rs1, rs2, imm)
	return ((imm >> 5) & 0x7f) << 25 | rs2 << 20 | rs1 << 15 |
	       f3 << 12 | (imm & 0x1f) << 7 | op
end

local function btype(op, f3, rs1, rs2, imm)
	return ((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3f) << 25 |
	       rs2 << 20 | rs1 << 15 | f3 << 12 |
	       ((imm >> 1) & 0xf) << 8 | ((imm >> 11) & 1) << 7 | op
end

local function utype(op, rd, imm)
	return (imm & 0xfffff) << 12 | rd << 7 | op
end

local function jtype(op, rd, imm)
	return ((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3ff) << 21 |
	       ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xff) << 12 |
	       rd << 7 | op
end

-- `%hi(sym)` and the rest: which half of which address is wanted.  The
-- pc-relative pair names the label of its own auipc rather than the
-- symbol, so the two are tied together by where that stood.
local UPPER = {hi = "hi20", pcrel_hi = "pcrel_hi20",
	       got_pcrel_hi = "got_hi20"}
local LOWER = {lo = "lo12_i", pcrel_lo = "pcrel_lo12_i"}

local function specifier(s)
	if s == nil then return nil end
	return s:match("^%%([%w_]+)%(([^()]*)%)$")
end

-- The two halves of a symbol's address, as auipc and addi take them: the
-- low half is signed, so the high half is rounded to match.
-- Lua's >> is logical, and this one has to be arithmetic.
local function hi20(v) return ((v + 0x800) // 4096) & 0xfffff end
local function lo12(v) return (v + 0x800) % 4096 - 0x800 end

-- How many instructions `li rd, v` takes, and what they are.  The usual
-- recursive form: build the high bits, then shift and add the rest.
local function liseq(v, xlen, inner)
	if xlen == 32 then
		v = ((v + 0x80000000) & 0xffffffff) - 0x80000000
	end
	local lo = lo12(v)
	if v >= -2048 and v <= 2047 then
		-- inside a longer sequence the real assembler uses the
		-- 32-bit add, which is the same value and a different opcode
		return {{(inner and xlen == 64) and "addiw" or "addi", v}}
	end
	if xlen == 32 or (v >= -0x80000000 and v <= 0x7fffffff) then
		local out, hi = {}, hi20(v)
		if hi ~= 0 then out[#out + 1] = {"lui", hi} end
		if lo ~= 0 or hi == 0 then
			out[#out + 1] = {xlen == 32 and "addi" or "addiw", lo}
		end
		return out
	end
	-- Wider than a signed word: take the low twelve bits off, build the
	-- rest by the same rule, and shift it back.  Trailing zeros go into
	-- the shift rather than into another instruction.
	local hi = (v - lo) // 4096
	local shift = 12
	while hi ~= 0 and hi % 2 == 0 do
		hi = hi // 2
		shift = shift + 1
	end
	local out = liseq(hi, xlen, true)
	out[#out + 1] = {"slli", shift}
	if lo ~= 0 then out[#out + 1] = {"addi", lo} end
	return out
end

-- A number, or an expression that works out to one.  A name defined
-- further down the file is not known to the pass that places labels,
-- and the width does not turn on it, so zero holds the place.
local function imm(self, s)
	local v = tonumber(s) or self:absexpr(s or "")

	if math.type(v) == "integer" then return v end
	if v == nil and self.pass < 2 then return 0 end
	error("bad immediate " .. tostring(s))
end

-- The twelve-bit signed field of the I and S forms.
local function imm12(self, v, m, what)
	return self:sfits(v, 12, m .. " " .. (what or "immediate"))
end

-- What `li` loads: any value of 64 bits, signed or not.  Lua wraps a
-- hexadecimal number too wide for an integer and makes a float of a
-- decimal one, so both are read here.
local function livalue(self, s)
	local hex = s and s:match("^0[xX]0*(%x+)$")

	if hex and #hex > 16 then
		error("li immediate " .. s .. " is wider than 64 bits")
	end
	local dec = s and s:match("^0*(%d+)$")

	if dec and (#dec > 20 or (#dec == 20 and
	    dec > "18446744073709551615")) then
		error("li immediate " .. s .. " is wider than 64 bits")
	end
	if dec and #dec >= 19 then
		local v = 0

		for d in dec:gmatch("%d") do v = v * 10 + tonumber(d) end
		return v
	end
	local v = tonumber(s)

	if v and math.type(v) ~= "integer" then
		error("li immediate " .. s .. " is wider than 64 bits")
	end
	return v or imm(self, s)
end

-- The distance of a jal, which reaches a megabyte either way.
local function jrel(self, rel, m)
	self:fits(rel, -0x100000, 0xffffe, m .. " offset")
	return self:aligned(rel, 2, m .. " offset")
end

-- "24(sp)" or "sym" or "-8"
local function mem(self, s)
	-- `%lo(sym)(reg)` and its kin: the offset is half of an address
	-- rather than a number, so it comes back as the specifier.
	local spec, base = s:match("^(%%[%w_]+%([^()]*%))%((%w+)%)$")

	if base then return 0, reg(base), spec end
	local off, b2 = s:match("^(.-)%s*%((%w+)%)$")

	if not b2 then return nil end
	if off == "" then return 0, reg(b2) end
	return imm(self, off), reg(b2)
end

-- The low half of an address.  `%lo(sym)` names the symbol; the
-- pc-relative form names the label of the auipc that took the high
-- half, and the linker needs the offset of that instruction.
local function lowreloc(self, how, sym, form)
	form = form or "lo12_i"
	if how == "lo" then
		return self:reloc(form, sym)
	end
	if how ~= "pcrel_lo" then error("no relocation " .. tostring(how)) end
	local at = (self.pcrel or {})[sym]

	if not at then
		local d = self.syms[sym]

		at = d and d.sec == self.cur and d.off or nil
	end
	if not at then
		error("%pcrel_lo names no auipc: " .. tostring(sym))
	end
	self:reloc(form == "lo12_s" and "pcrel_lo12_s" or "pcrel_lo12_i",
		sym, 0, at)
end

-- One OP-FP instruction, from a mnemonic already split on its dots.
-- Returns true when it wrote one, so the caller can go on looking.
local function fpinsn(self, e, base, a1, a2, ops)
	local function put(f5, fmt, rm, rd, rs1, rs2)
		e(self, rtype(OPFP, rm, f5 << 2 | fmt, rd, rs1, rs2), 4)
		return true
	end
	-- A rounding mode may be named after the operands.
	local function mode(i)
		local nm = ops[i]

		if nm == nil then return 7 end
		return RM[nm] or error("no rounding mode " .. nm)
	end

	if a2 == "" and FMT[a1] then
		local fmt = FMT[a1]

		if FARITH[base] then
			return put(FARITH[base], fmt, mode(4), freg(ops[1]),
				freg(ops[2]), freg(ops[3]))
		end
		if base == "fsqrt" then
			return put(0x0b, fmt, mode(3), freg(ops[1]),
				freg(ops[2]), 0)
		end
		if FSGNJ[base] then
			return put(0x04, fmt, FSGNJ[base], freg(ops[1]),
				freg(ops[2]), freg(ops[3]))
		end
		if FSGNP[base] then
			local r = freg(ops[2])

			return put(0x04, fmt, FSGNP[base], freg(ops[1]), r, r)
		end
		if FMINMAX[base] then
			return put(0x05, fmt, FMINMAX[base], freg(ops[1]),
				freg(ops[2]), freg(ops[3]))
		end
		if FCMP[base] then
			return put(0x14, fmt, FCMP[base], reg(ops[1]),
				freg(ops[2]), freg(ops[3]))
		end
		if base == "fclass" then
			return put(0x1c, fmt, 1, reg(ops[1]), freg(ops[2]), 0)
		end
		return false
	end
	if base ~= "fcvt" then return false end
	-- Between the two float widths, or between a float and an integer.
	if FMT[a1] and FMT[a2] then
		-- Widening is exact, so the field says round to nearest
		-- rather than "ask the register", which is what an
		-- assembler writes and a disassembler expects.
		local rm = FMT[a1] > FMT[a2] and 0 or mode(3)

		return put(0x08, FMT[a1], rm, freg(ops[1]),
			freg(ops[2]), FMT[a2])
	end
	if FIW[a1] and FMT[a2] then
		return put(0x18, FMT[a2], mode(3), reg(ops[1]),
			freg(ops[2]), FIW[a1])
	end
	if FMT[a1] and FIW[a2] then
		return put(0x1a, FMT[a1], mode(3), freg(ops[1]),
			reg(ops[2]), FIW[a2])
	end
	return false
end

-- The labels a pc-relative pair needs are numbered from the start of
-- each pass, so the same one comes out every time.
function riscv.startpass(a)
	a.npcrel = 0
end

function riscv.inst(self, m, ops)
	local e = self.emit
	if R[m] then
		local opc, f3, f7 = opfields(R[m])
		return e(self, rtype(opc, f3, f7, reg(ops[1]),
			reg(ops[2]), reg(ops[3])), 4)
	end
	if I[m] then
		local opc, f3 = opfields(I[m])
		local how, sym = specifier(ops[3])

		if how then
			lowreloc(self, how, sym, "lo12_i")
			return e(self, itype(opc, f3, reg(ops[1]),
				reg(ops[2]), 0), 4)
		end
		local v = imm12(self, imm(self, ops[3]), m)

		return e(self, itype(opc, f3, reg(ops[1]), reg(ops[2]),
			v), 4)
	end
	if SH[m] then
		local opc, f3, f7 = opfields(SH[m])
		-- the word forms and every form on rv32 shift by 0..31
		local w = (opc == 0x1b or self.xlen == 32) and 5 or 6
		local sh = self:ufits(imm(self, ops[3]), w,
			m .. " shift amount")
		return e(self, itype(opc, f3, reg(ops[1]), reg(ops[2]),
			f7 << 5 | sh), 4)
	end
	if LOAD[m] then
		local opc, f3 = opfields(LOAD[m])
		local off, base, spec = mem(self, ops[2])
		local rd = (opc == 0x07) and freg(ops[1]) or reg(ops[1])
		if not off then error("bad address " .. ops[2]) end
		if spec then lowreloc(self, specifier(spec)) end
		imm12(self, off, m, "offset")
		return e(self, itype(opc, f3, rd, base, off), 4)
	end
	if STORE[m] then
		local opc, f3 = opfields(STORE[m])
		local off, base, spec = mem(self, ops[2])
		local rs = (opc == 0x27) and freg(ops[1]) or reg(ops[1])
		if not off then error("bad address " .. ops[2]) end
		if spec then
			-- Both halves of the specifier are wanted, and a
			-- call truncates all but the last argument.
			local how, sym = specifier(spec)

			lowreloc(self, how, sym, "lo12_s")
		end
		imm12(self, off, m, "offset")
		return e(self, stype(opc, f3, base, rs, off), 4)
	end
	if BRANCH[m] then
		local opc, f3 = opfields(BRANCH[m])
		self.nbr = self.nbr + 1
		local id = self.nbr
		local rel = self:localhere(ops[3])
		if rel and not self.long[id] and self.pass == 1 and
		   (rel < -4096 or rel > 4094) then
			self.pending[id] = true
		end
		if self.long[id] then
			local iopc, if3 = opfields(BRANCH[INVERT[m]])
			e(self, btype(iopc, if3, reg(ops[1]),
				reg(ops[2]), 8), 4)
			rel = self:localhere(ops[3])
			if not rel then
				self:reloc("jal", ops[3])
				rel = 0
			end
			return e(self, jtype(0x6f, 0, jrel(self, rel, m)), 4)
		end
		if not rel then
			self:reloc("branch", ops[3])
			rel = 0
		end
		self:fits(rel, -4096, 4094, m .. " offset")
		self:aligned(rel, 2, m .. " offset")
		return e(self, btype(opc, f3, reg(ops[1]), reg(ops[2]),
			rel), 4)
	end
	if FMV[m] then
		local d = FMV[m]
		local rd = d[4] == "f" and freg(ops[1]) or reg(ops[1])
		local rs = d[4] == "f" and reg(ops[2]) or freg(ops[2])
		return e(self, rtype(d[1], d[2], d[3], rd, rs, 0), 4)
	end
	if m:sub(1, 1) == "f" and m:find(".", 1, true) then
		local base, a1, a2 = m:match("^(%a+)%.(%a+)%.?(%a*)$")

		if base and fpinsn(self, e, base, a1, a2, ops) then return end
	end
	if m == "lui" or m == "auipc" then
		-- `%hi(sym)` and its kin name half of an address, which
		-- only the linker knows.  The other half comes from the
		-- addi or the load that follows.
		local how, sym = specifier(ops[2])

		if how then
			local kind = UPPER[how]

			if not kind then
				error("no relocation " .. how)
			end
			if how == "pcrel_hi" or how == "got_pcrel_hi" then
				self.pcrel = self.pcrel or {}
				self.pcrel[sym] = self.cur.off
			end
			self:reloc(kind, sym)
			return e(self, utype(m == "lui" and 0x37 or 0x17,
				reg(ops[1]), 0), 4)
		end
		local v = self:ufits(imm(self, ops[2]), 20, m .. " immediate")

		return e(self, utype(m == "lui" and 0x37 or 0x17,
			reg(ops[1]), v), 4)
	end
	if m == "jalr" then
		-- `jalr rd` is the one-operand pseudo for jalr ra, rd, 0
		if #ops == 1 then
			return e(self, itype(0x67, 0, 1, reg(ops[1]), 0), 4)
		end
		local off, base = mem(self, ops[2])
		if off then
			imm12(self, off, m, "offset")
			return e(self, itype(0x67, 0, reg(ops[1]), base, off), 4)
		end
		off = ops[3] and imm12(self, imm(self, ops[3]), m, "offset")
		return e(self, itype(0x67, 0, reg(ops[1]), reg(ops[2]),
			off or 0), 4)
	end
	if m == "jal" then
		local sym = ops[#ops]
		local rd = #ops > 1 and reg(ops[1]) or 1
		local rel = self:localhere(sym)
		if not rel then
			self:reloc("jal", sym)
			rel = 0
		end
		return e(self, jtype(0x6f, rd, jrel(self, rel, m)), 4)
	end
	if m == "j" then
		local rel = self:localhere(ops[1])
		if not rel then
			self:reloc("jal", ops[1])
			rel = 0
		end
		return e(self, jtype(0x6f, 0, jrel(self, rel, m)), 4)
	end
	-- A branch against zero, and the two that read their registers
	-- the other way round.  Each is one of the six real branches
	-- with an operand moved or x0 put in.
	if BZ[m] and #ops == 2 then
		local d = BZ[m]
		local r = reg(ops[1])
		local a, b = d[2] and 0 or r, d[2] and r or 0

		return riscv.inst(self, d[1], {regname(a), regname(b),
			ops[2]})
	end
	if BSWAP[m] and #ops == 3 then
		return riscv.inst(self, BSWAP[m], {ops[2], ops[1], ops[3]})
	end
	-- Waiting for an interrupt, and coming back from a trap.
	if TRAP[m] and #ops == 0 then
		return e(self, TRAP[m], 4)
	end
	-- The control and status registers.  `csrrw` and its kin take a
	-- register; the i forms take a five bit number in its place.
	-- Everything else here is one of those with x0 on a side.
	if CSROP[m] or CSRPSEUDO[m] or COUNTER[m] then
		local op, rd, csr, src = nil, 0, nil, 0

		if COUNTER[m] then
			op, rd, csr = 2, reg(ops[1]), COUNTER[m]
		elseif m == "csrr" then
			op, rd, csr = 2, reg(ops[1]), csrno(self, ops[2])
		elseif CSRPSEUDO[m] then
			op, csr = CSRPSEUDO[m], csrno(self, ops[1])
			src = ops[2]
		else
			op, rd = CSROP[m], reg(ops[1])
			csr, src = csrno(self, ops[2]), ops[3]
		end
		local v = 0

		if src ~= 0 and src ~= nil then
			if op >= 5 then
				v = self:ufits(imm(self, src), 5,
					m .. " csr immediate")
			else
				v = reg(src)
			end
		end
		self:ufits(csr, 12, m .. " csr")
		return e(self, itype(0x73, op, rd, v, csr), 4)
	end
	if m == "ecall" or m == "scall" then
		return e(self, itype(0x73, 0, 0, 0, 0), 4)
	end
	if m == "ebreak" then
		return e(self, itype(0x73, 0, 0, 0, 1), 4)
	end
	if m == "fence" then
		return e(self, itype(0x0f, 0, 0, 0, 0x0ff), 4)
	end
	if m == "ret" then
		return e(self, itype(0x67, 0, 0, 1, 0), 4)
	end
	-- `jr rs` is jalr zero, rs, 0
	if m == "jr" then
		return e(self, itype(0x67, 0, 0, reg(ops[1]), 0), 4)
	end
	if m == "nop" then
		return e(self, itype(0x13, 0, 0, 0, 0), 4)
	end
	if m == "mv" then
		return e(self, itype(0x13, 0, reg(ops[1]), reg(ops[2]), 0), 4)
	end
	if m == "neg" then
		return e(self, rtype(0x33, 0, 0x20, reg(ops[1]), 0,
			reg(ops[2])), 4)
	end
	if m == "negw" then
		return e(self, rtype(0x3b, 0, 0x20, reg(ops[1]), 0,
			reg(ops[2])), 4)
	end
	if m == "not" then
		return e(self, itype(0x13, 4, reg(ops[1]), reg(ops[2]), -1), 4)
	end
	if m == "sext.w" then
		return e(self, itype(0x1b, 0, reg(ops[1]), reg(ops[2]), 0), 4)
	end
	if m == "seqz" then
		return e(self, itype(0x13, 3, reg(ops[1]), reg(ops[2]), 1), 4)
	end
	if m == "snez" then
		return e(self, rtype(0x33, 3, 0, reg(ops[1]), 0,
			reg(ops[2])), 4)
	end
	if m == "li" then
		local rd = reg(ops[1])
		local seq = liseq(livalue(self, ops[2]), self.xlen)
		local src = rd
		for i, step in ipairs(seq) do
			local k, v = step[1], step[2]
			if k == "lui" then
				e(self, utype(0x37, rd, v), 4)
			elseif k == "addi" then
				e(self, itype(0x13, 0, rd,
					i == 1 and 0 or src, v), 4)
			elseif k == "addiw" then
				e(self, itype(0x1b, 0, rd,
					i == 1 and 0 or src, v), 4)
			elseif k == "slli" then
				e(self, itype(0x13, 1, rd, src, v), 4)
			end
			src = rd
		end
		return
	end
	-- `lla` is the form that never reads a table.  `la` here is
	-- already that, because nothing this target links has one.
	if m == "lla" then m = "la" end
	if m == "la" or m == "call" or m == "tail" then
		local rd = m == "la" and reg(ops[1]) or
			(m == "call" and 1 or 0)
		local sym = m == "la" and ops[2] or ops[1]
		-- a call builds its address in ra, which is where gas puts
		-- it and one fewer register touched
		local tmp = m == "la" and rd or 1
		local rel = self:localhere(sym)
		if rel then
			self:fits(rel, -0x80000800, 0x7ffff7ff, m .. " offset")
			e(self, utype(0x17, tmp, hi20(rel)), 4)
			e(self, itype(m == "la" and 0x13 or 0x67, 0, rd, tmp,
				lo12(rel)), 4)
			return
		end
		local hi = self.cur.off
		-- The low half names the auipc that took the high half,
		-- not the symbol, so the pair needs a label of its own.
		-- That is what the ABI says and what another linker
		-- reading this object will look for.
		self.npcrel = (self.npcrel or 0) + 1
		local lbl = (".Lpcrel%d"):format(self.npcrel)

		self:label(lbl)
		self:reloc("pcrel_hi20", sym)
		e(self, utype(0x17, tmp, 0), 4)
		self:reloc(m == "la" and "pcrel_lo12_i" or "pcrel_lo12_jalr",
			lbl, 0, hi)
		if m == "la" then
			e(self, itype(0x13, 0, rd, tmp, 0), 4)
		else
			e(self, itype(0x67, 0, rd, tmp, 0), 4)
		end
		return
	end
	error("no instruction " .. m)
end


riscv.liseq = liseq

-- `#` starts a comment on this machine, anywhere on the line.
riscv.hash = true

return riscv
