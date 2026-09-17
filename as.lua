-- A RISC-V assembler for what this compiler emits.
--
-- Not a general assembler: it reads the subset the targets in target/riscv
-- produce, which is sixty-three mnemonics and eleven directives.  That is
-- enough to be checked against the real one -- `test/as.lua` assembles every
-- file twice and compares the bytes -- and small enough to run on the machine
-- the code is for.
--
-- The output is sections of bytes plus a symbol table and a list of places
-- that still need an address.  `ld.lua` turns that into something to run.

local buf = require "buf"

local as = {}

local REG = {}
for i = 0, 31 do REG["x" .. i] = i end
for i, n in ipairs{"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
		   "s0", "s1"} do REG[n] = i - 1 end
REG.fp = 8
for i = 0, 7 do REG["a" .. i] = 10 + i end
for i = 2, 11 do REG["s" .. i] = 16 + i end
for i = 3, 6 do REG["t" .. i] = 25 + i end
local FREG = {}
for i = 0, 31 do FREG["f" .. i] = i end
for i = 0, 7 do FREG["fa" .. i] = 10 + i end
for i = 0, 1 do FREG["ft" .. i] = i end
for i = 0, 1 do FREG["fs" .. i] = 8 + i end

-- opcode, funct3, funct7 for the three-register forms
local R = {
	add = {0x33, 0, 0x00},  sub  = {0x33, 0, 0x20},
	sll = {0x33, 1, 0x00},  slt  = {0x33, 2, 0x00},
	sltu = {0x33, 3, 0x00}, ["xor"] = {0x33, 4, 0x00},
	srl = {0x33, 5, 0x00},  sra  = {0x33, 5, 0x20},
	["or"] = {0x33, 6, 0x00}, ["and"] = {0x33, 7, 0x00},
	mul = {0x33, 0, 0x01},  mulh = {0x33, 1, 0x01},
	mulhu = {0x33, 3, 0x01},
	div = {0x33, 4, 0x01},  divu = {0x33, 5, 0x01},
	rem = {0x33, 6, 0x01},  remu = {0x33, 7, 0x01},
	addw = {0x3b, 0, 0x00}, subw = {0x3b, 0, 0x20},
	sllw = {0x3b, 1, 0x00}, srlw = {0x3b, 5, 0x00},
	sraw = {0x3b, 5, 0x20}, mulw = {0x3b, 0, 0x01},
	divw = {0x3b, 4, 0x01}, divuw = {0x3b, 5, 0x01},
	remw = {0x3b, 6, 0x01}, remuw = {0x3b, 7, 0x01},
}

-- register, register, immediate
local I = {
	addi = {0x13, 0}, slti = {0x13, 2}, sltiu = {0x13, 3},
	xori = {0x13, 4}, ori = {0x13, 6}, andi = {0x13, 7},
	addiw = {0x1b, 0},
}
-- the shifts put a function code in the top of the immediate field
local SH = {
	slli = {0x13, 1, 0x00}, srli = {0x13, 5, 0x00},
	srai = {0x13, 5, 0x20},
	slliw = {0x1b, 1, 0x00}, srliw = {0x1b, 5, 0x00},
	sraiw = {0x1b, 5, 0x20},
}
-- register, offset(register)
local LOAD = {
	lb = {0x03, 0}, lh = {0x03, 1}, lw = {0x03, 2}, ld = {0x03, 3},
	lbu = {0x03, 4}, lhu = {0x03, 5}, lwu = {0x03, 6},
	flw = {0x07, 2}, fld = {0x07, 3},
}
local STORE = {
	sb = {0x23, 0}, sh = {0x23, 1}, sw = {0x23, 2}, sd = {0x23, 3},
	fsw = {0x27, 2}, fsd = {0x27, 3},
}
local BRANCH = {
	beq = {0x63, 0}, bne = {0x63, 1}, blt = {0x63, 4},
	bge = {0x63, 5}, bltu = {0x63, 6}, bgeu = {0x63, 7},
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

local function reg(s)
	return REG[s] or error("no register " .. tostring(s))
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

as.liseq = liseq

-- parsing --------------------------------------------------------------

local function split(s)
	local out = {}
	for w in s:gmatch("[^,]+") do out[#out + 1] = w:match("^%s*(.-)%s*$") end
	return out
end

-- "24(sp)" or "sym" or "-8"
local function mem(s)
	local off, base = s:match("^(-?[%w.$_]*)%((%w+)%)$")
	if base then return tonumber(off) or 0, reg(base) end
	return nil
end

local function unescape(s)
	local out, i = {}, 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			local d = s:sub(i + 1, i + 3)
			local o = d:match("^%d%d%d")
			if o then
				out[#out + 1] = string.char(tonumber(o, 8))
				i = i + 4
			else
				out[#out + 1] = s:sub(i + 1, i + 1)
				i = i + 2
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local Asm = {}
Asm.__index = Asm

function as.new(xlen)
	return setmetatable({
		xlen = xlen or 64,
		sec = {},		-- name -> section
		order = {},		-- the order they first appeared
		syms = {},		-- name -> {sec, off, global}
		long = {},		-- branches that need the long form
		cur = nil,
	}, Asm)
end

function Asm:section(name, bss)
	local s = self.sec[name]
	if not s then
		s = {name = name, off = 0, align = 1, bss = bss or false,
		     out = buf.new(), relocs = {}}
		self.sec[name] = s
		self.order[#self.order + 1] = s
	end
	self.cur = s
	return s
end

function Asm:emit(word, n)
	local s = self.cur
	if self.pass == 2 and not s.bss then
		local b = {}
		for i = 0, n - 1 do b[i + 1] = string.char(word >> (8 * i) & 255) end
		s.out:add(table.concat(b))
	end
	s.off = s.off + n
end

function Asm:bytes(str)
	local s = self.cur
	if self.pass == 2 and not s.bss then s.out:add(str) end
	s.off = s.off + #str
end

function Asm:space(n)
	local s = self.cur
	if self.pass == 2 and not s.bss then s.out:add(string.rep("\0", n)) end
	s.off = s.off + n
end

function Asm:align(n)
	local pad = (-self.cur.off) % n
	if self.cur.align < n then self.cur.align = n end
	if pad > 0 then self:space(pad) end
end

function Asm:label(name)
	if self.pass == 1 then
		self.syms[name] = self.syms[name] or {}
		self.syms[name].sec = self.cur
		self.syms[name].off = self.cur.off
	end
end

function Asm:global(name)
	self.syms[name] = self.syms[name] or {}
	self.syms[name].global = true
end

-- Where a symbol is, once the sections have addresses.  During pass two
-- the sections do not have them yet, so a reference to one is recorded and
-- filled in by the linker.
function Asm:reloc(kind, sym, addend, pair)
	self.cur.relocs[#self.cur.relocs + 1] = {
		off = self.cur.off, kind = kind, sym = sym,
		addend = addend or 0, pair = pair,
	}
end

-- instructions --------------------------------------------------------

-- A branch or jump to a label in the same section needs no help from the
-- linker: the distance between two offsets does not move.
function Asm:here(sym)
	local d = self.syms[sym]
	if d and d.sec == self.cur then return d.off - self.cur.off end
	return nil
end

function Asm:inst(m, ops)
	local e = self.emit
	if R[m] then
		local d = R[m]
		return e(self, rtype(d[1], d[2], d[3], reg(ops[1]),
			reg(ops[2]), reg(ops[3])), 4)
	end
	if I[m] then
		local d = I[m]
		return e(self, itype(d[1], d[2], reg(ops[1]), reg(ops[2]),
			tonumber(ops[3])), 4)
	end
	if SH[m] then
		local d = SH[m]
		local sh = tonumber(ops[3]) & 63
		return e(self, itype(d[1], d[2], reg(ops[1]), reg(ops[2]),
			d[3] << 5 | sh), 4)
	end
	if LOAD[m] then
		local d = LOAD[m]
		local off, base = mem(ops[2])
		local rd = (d[1] == 0x07) and freg(ops[1]) or reg(ops[1])
		if not off then error("bad address " .. ops[2]) end
		return e(self, itype(d[1], d[2], rd, base, off), 4)
	end
	if STORE[m] then
		local d = STORE[m]
		local off, base = mem(ops[2])
		local rs = (d[1] == 0x27) and freg(ops[1]) or reg(ops[1])
		if not off then error("bad address " .. ops[2]) end
		return e(self, stype(d[1], d[2], base, rs, off), 4)
	end
	if BRANCH[m] then
		local d = BRANCH[m]
		self.nbr = self.nbr + 1
		local id = self.nbr
		local rel = self:here(ops[3])
		if rel and not self.long[id] and
		   (rel < -4096 or rel > 4094) then
			self.long[id] = true
			self.changed = true
		end
		if self.long[id] then
			local inv = BRANCH[INVERT[m]]
			e(self, btype(inv[1], inv[2], reg(ops[1]),
				reg(ops[2]), 8), 4)
			rel = self:here(ops[3])
			if not rel then
				self:reloc("jal", ops[3])
				rel = 0
			end
			return e(self, jtype(0x6f, 0, rel), 4)
		end
		if not rel then
			self:reloc("branch", ops[3])
			rel = 0
		end
		return e(self, btype(d[1], d[2], reg(ops[1]), reg(ops[2]),
			rel), 4)
	end
	if FMV[m] then
		local d = FMV[m]
		local rd = d[4] == "f" and freg(ops[1]) or reg(ops[1])
		local rs = d[4] == "f" and reg(ops[2]) or freg(ops[2])
		return e(self, rtype(d[1], d[2], d[3], rd, rs, 0), 4)
	end
	if m == "lui" or m == "auipc" then
		return e(self, utype(m == "lui" and 0x37 or 0x17,
			reg(ops[1]), tonumber(ops[2])), 4)
	end
	if m == "jalr" then
		-- `jalr rd` is the one-operand pseudo for jalr ra, rd, 0
		if #ops == 1 then
			return e(self, itype(0x67, 0, 1, reg(ops[1]), 0), 4)
		end
		local off, base = mem(ops[2])
		if off then
			return e(self, itype(0x67, 0, reg(ops[1]), base, off), 4)
		end
		return e(self, itype(0x67, 0, reg(ops[1]), reg(ops[2]),
			tonumber(ops[3]) or 0), 4)
	end
	if m == "jal" then
		local sym = ops[#ops]
		local rd = #ops > 1 and reg(ops[1]) or 1
		local rel = self:here(sym)
		if not rel then
			self:reloc("jal", sym)
			rel = 0
		end
		return e(self, jtype(0x6f, rd, rel), 4)
	end
	if m == "j" then
		local rel = self:here(ops[1])
		if not rel then
			self:reloc("jal", ops[1])
			rel = 0
		end
		return e(self, jtype(0x6f, 0, rel), 4)
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
		local seq = liseq(tonumber(ops[2]), self.xlen)
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
	if m == "la" or m == "call" or m == "tail" then
		local rd = m == "la" and reg(ops[1]) or
			(m == "call" and 1 or 0)
		local sym = m == "la" and ops[2] or ops[1]
		-- a call builds its address in ra, which is where gas puts
		-- it and one fewer register touched
		local tmp = m == "la" and rd or 1
		local rel = self:here(sym)
		if rel then
			e(self, utype(0x17, tmp, hi20(rel)), 4)
			e(self, itype(m == "la" and 0x13 or 0x67, 0, rd, tmp,
				lo12(rel)), 4)
			return
		end
		local hi = self.cur.off
		self:reloc("pcrel_hi20", sym)
		e(self, utype(0x17, tmp, 0), 4)
		-- the low half is measured from the auipc, not from itself
		self:reloc(m == "la" and "pcrel_lo12_i" or "pcrel_lo12_jalr",
			sym, 0, hi)
		if m == "la" then
			e(self, itype(0x13, 0, rd, tmp, 0), 4)
		else
			e(self, itype(0x67, 0, rd, tmp, 0), 4)
		end
		return
	end
	error("no instruction " .. m)
end

-- directives and the two passes ---------------------------------------

local DSIZE = {byte = 1, short = 2, long = 4, quad = 8}

-- A data item is a number, a symbol, or a symbol plus or minus a number.
function Asm:datum(size, text)
	local v = tonumber(text)
	if v then return self:emit(v, size) end
	local sym, sign, off = text:match("^([%w.$_]+)%s*([+-])%s*(%w+)$")
	local addend = 0
	if sym then
		addend = tonumber(off) * (sign == "-" and -1 or 1)
	else
		sym = text:match("^([%w.$_]+)$")
	end
	if not sym then error("bad data item '" .. text .. "'") end
	self:reloc(size == 8 and "abs64" or "abs32", sym, addend)
	self:emit(0, size)
end

function Asm:line(l)
	-- comments, in either spelling
	l = l:gsub("/%*.-%*/", " ")
	l = l:gsub("^%s*[/*#].*$", "")
	local label = l:match("^([%w.$_]+):%s*$")
	if label then return self:label(label) end
	local body = l:match("^%s+(.*)$")
	if not body or body == "" then return end
	body = body:match("^(.-)%s*$")
	if body == "" then return end
	local word, rest = body:match("^(%S+)%s*(.*)$")
	rest = rest:match("^%s*(.-)%s*$")
	if word:sub(1, 1) == "." then
		local d = word:sub(2)
		if d == "text" or d == "data" then
			self:section("." .. d)
		elseif d == "bss" then
			self:section(".bss", true)
		elseif d == "section" then
			local name = rest:match("^(%S+)")
			self:section(name, name == ".bss")
		elseif d == "globl" or d == "global" then
			self:global(rest)
		elseif d == "balign" or d == "align" then
			self:align(tonumber(rest))
		elseif d == "zero" or d == "space" then
			self:space(tonumber(rest))
		elseif d == "ascii" or d == "asciz" then
			local str = rest:match('^"(.*)"$')
			self:bytes(unescape(str))
			if d == "asciz" then self:bytes("\0") end
		elseif DSIZE[d] then
			for _, item in ipairs(split(rest)) do
				self:datum(DSIZE[d], item)
			end
		elseif d == "type" or d == "size" or d == "file" or
		       d == "ident" or d == "local" or d == "option" then
			-- nothing here needs them
		else
			error("no directive ." .. d)
		end
		return
	end
	self:inst(word, split(rest))
end

function Asm:run(text, pass)
	self.pass = pass
	self.cur = nil
	self.nbr = 0
	self.incomment = false
	for _, s in ipairs(self.order) do s.off = 0 end
	self:section(".text")
	local n = 0
	local incomment = false
	for l in text:gmatch("[^\n]*") do
		n = n + 1
		if incomment then
			local rest = l:match("%*/(.*)$")
			if rest then
				incomment = false
				l = rest
			else
				l = ""
			end
		end
		if l:find("/%*") and not l:find("%*/") then
			l = l:gsub("/%*.*$", "")
			incomment = true
		end
		if l ~= "" then
			local ok, err = pcall(self.line, self, l)
			if not ok then
				error(("line %d: %s\n  %s"):format(n, err, l), 0)
			end
		end
	end
	for _, s in ipairs(self.order) do s.size = s.off end
end

-- Assemble a whole file.  Two passes: the first places every label, the
-- second emits the bytes, which it can do because nothing here changes size
-- once its operands are known.
function as.assemble(text, xlen)
	local a = as.new(xlen)
	-- Place the labels, then again if a branch turned out too far to
	-- reach, because widening one moves everything after it.
	repeat
		a.changed = false
		a:run(text, 1)
	until not a.changed
	a:run(text, 2)
	for _, s in ipairs(a.order) do
		s.bytes = s.bss and "" or s.out:text()
	end
	return a
end

return as
