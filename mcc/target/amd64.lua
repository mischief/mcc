-- SPDX-License-Identifier: ISC
-- amd64, AT&T syntax.
--
-- Everything machine dependent lives here: register names, the address
-- forms, the difficulty override, and the code tables.  A new target is a
-- file of the same shape; nothing above this reaches into it.

local md = require "mcc.md"
local peep = require "mcc.peep"
local data = require "mcc.data"
local tree = require "mcc.tree"

-- Whether long double is the x87 extended type the ABI asks for, or
-- the double it has been until the rest of that is written.  The type
-- itself, its constants and its layout are done; the arithmetic and
-- the calling convention are not.
local LDBL80 = true

-- Scratch registers in allocation order.  Sethi-Ullman numbering decides how
-- many an expression needs, so a wide file means fewer spills.
--
-- rcx, rdx and r11 are held out of the order on purpose.  A variable shift
-- reads cl, a divide reads and writes rdx, and both need a scratch that no
-- value can be sitting in.  Keeping them unallocatable is cheaper than
-- teaching the allocator to move values out of the way.
local REG = {
	[0] = {"al",   "ax",   "eax",  "rax"},
	[1] = {"sil",  "si",   "esi",  "rsi"},
	[2] = {"dil",  "di",   "edi",  "rdi"},
	[3] = {"r8b",  "r8w",  "r8d",  "r8"},
	[4] = {"r9b",  "r9w",  "r9d",  "r9"},
	[5] = {"r10b", "r10w", "r10d", "r10"},
	-- Past the allocation order: an inline asm with a long clobber
	-- list may borrow one of these, saved around the template.
	[6] = {"bl",   "bx",   "ebx",  "rbx"},
	[7] = {"r12b", "r12w", "r12d", "r12"},
	[8] = {"r13b", "r13w", "r13d", "r13"},
	[9] = {"r14b", "r14w", "r14d", "r14"},
	[10] = {"r15b", "r15w", "r15d", "r15"},
}

local SLOT = {[1] = 1, [2] = 2, [4] = 3, [8] = 4}
local SUFFIX = {[1] = "b", [2] = "w", [4] = "l", [8] = "q"}

local function regname(r, size)
	local names = REG[r] or error("out of registers: r" .. r)
	return "%" .. names[SLOT[size] or error("bad size " .. tostring(size))]
end

local function suffix(ty)
	return SUFFIX[ty.size]
end

-- The float file.  xmm0 through xmm7 are the ABI's, so the scratch file
-- starts above them and nothing a call sets up can be sitting in one.
local NFREG = 8

local function fregname(r, _)
	if r >= NFREG then error("out of float registers: f" .. r) end
	return "%xmm" .. (8 + r)
end

-- A vector register for an asm operand, from the top of the file the
-- float expressions start at: a statement leaves none of them live.
local function vregname(r, size)
	return (size == 32 and "%%ymm%d" or "%%xmm%d"):format(8 + r)
end

-- One unaligned move of a whole vector, either way.
local function vmove(g, from, to, size)
	g:write(("\t%s\t%s,%s\n"):format(size == 32 and "vmovdqu" or
		"movdqu", from, to))
end

-- The scalar suffix: sd for a double, ss for a float.
local function fsuf(size)
	return size == 8 and "sd" or "ss"
end

-- The extended float file, which is frame slots rather than registers:
-- x87 is a stack, and a stack does not answer to a depth.  Sixteen
-- bytes each, indexed by the same depth, and nothing a call does can
-- touch one.  The parser hands out the area the first time it is asked.
local function ldslot(g, r, off)
	if r >= 8 then
		error("out of extended float slots: f" .. r)
	end
	return (g.x87base() + 16 * r + (off or 0)) .. "(%rbp)"
end

-- A name with a constant offset, as the assembler writes it.
local function plusoff(n)
	local off = n.off

	if not off or off == 0 then return "" end
	return (off > 0 and "+" or "") .. off
end

-- The operand text for a node the instruction can address directly.
local function addr(g, n)
	local op = n.op
	if op == "CONST" then
		return "$" .. n.val
	elseif op == "NAME" then
		if n.got then return n.sym .. "@GOTPCREL(%rip)" end
		return n.sym .. plusoff(n) .. "(%rip)"
	elseif op == "AUTO" then
		if n.pin then return regname(n.pin, n.ty.size) end
		return n.off .. "(%rbp)"
	end
	error("cannot address " .. op .. " directly on amd64")
end

-- Put the address of something in a register.  lea reaches a name
-- from where the code stands, which is the same place only while the
-- two are within two gigabytes of each other.  Under
-- `-mcmodel=kernel` a link script may put them further apart:
-- openbsd names the physical addresses of the kernel's own sections,
-- and the text that reads them sits at the top of the address space,
-- so the lea cannot reach and the link fails saying the relocation is
-- out of range.  There the address is a constant the instruction
-- carries, which is what gcc does for that model.
--
-- Everywhere else lea stands.  This compiler's ordinary output is
-- linked into a PIE by the toolchains it runs under, and an absolute
-- relocation against a name the object does not define is what a PIE
-- will not take.
local function leato(g, e, r)
	if e.op == "NAME" and not e.got and not g.o.pic and
	   g.o.cmodel == "kernel" then
		g:write(("\tmovq\t$%s%s,%s\n"):format(e.sym, plusoff(e), r))
		return
	end
	g:write(("\tleaq\t%s,%s\n"):format(addr(g, e), r))
end

-- An address always costs a register here, because lea is what keeps the
-- reference position independent.  A constant past the 32-bit immediate
-- field costs one too, because only movabs can carry it.
local function dcalc(n, nreg)
	if n then
		if n.op == "ADDR" or n.op == "GOT" then
			return n.need <= nreg and 20 or 24
		end
		if n.op == "CONST" and
		   (n.val < -2147483648 or n.val > 2147483647) then
			return n.need <= nreg and 20 or 24
		end
	end
	return tree.dcalc(n, nreg)
end

local MNEM = {
	ADD = "add", SUB = "sub", AND = "and", OR = "or", XOR = "xor",
	MUL = "imul", SHL = "shl",
}

-- A narrow load must say how it widens, which the shape cannot.
local LOAD = {
	[1] = {int = "movsbl", uint = "movzbl"},
	[2] = {int = "movswl", uint = "movzwl"},
}

local function mnem(n, a)
	if n.op == "SHR" then
		return n.ty.kind == "uint" and "shr" or "sar"
	end
	if n.op == "INDIR" or n.op == "AUTO" or n.op == "NAME"
	or n.op == "POSTADD" then
		local w = LOAD[n.ty.size]
		return w and (w[n.ty.kind] or w.int) or nil
	end
	return MNEM[n.op]
end

local JMP = {
	EQ = {"e",  "ne"},
	NE = {"ne", "e"},
	LT = {"l",  "ge"},
	LE = {"le", "g"},
	GT = {"g",  "le"},
	GE = {"ge", "l"},
}
local UJMP = {
	EQ = {"e",  "ne"},
	NE = {"ne", "e"},
	LT = {"b",  "ae"},
	LE = {"be", "a"},
	GT = {"a",  "be"},
	GE = {"ae", "b"},
}

-- A float compare leaves the unsigned flags, and sets all three when the
-- operands are unordered.  Every ordered question therefore needs the
-- parity flag asked first: without it a NaN answers "below" and "equal".
local function fbr(g, label, sense, pair)
	if sense then
		local skip = g:newlabel()

		g:write("\tjp\t" .. skip .. "\n")
		g:write("\tj" .. pair[1] .. "\t" .. label .. "\n")
		g:write(skip .. ":\n")
	else
		g:write("\tjp\t" .. label .. "\n")
		g:write("\tj" .. pair[2] .. "\t" .. label .. "\n")
	end
end

local function branch(g, n, label, sense, reg)
	local pair = JMP[n.op]
	if pair then
		local kind = n.left.ty.kind

		if kind == "float" then
			-- Every relation but one is true only when the
			-- operands are ordered, so parity rules the branch
			-- out.  Inequality is the other way about: a NaN
			-- is unequal to everything, itself included.
			if n.op == "NE" then
				return fbr(g, label, not sense, {"e", "ne"})
			end
			return fbr(g, label, sense, UJMP[n.op])
		elseif kind == "uint" or kind == "ptr" then
			pair = UJMP[n.op]
		end
	elseif n.ty.kind == "float" then
		-- The value itself, compared against zero by adapt.  A NaN
		-- is neither equal nor unequal on ZF, and is true in C, so
		-- the parity flag decides it.
		return fbr(g, label, not sense, {"e", "ne"})
	else
		pair = {"ne", "e"}		-- the value itself, tested
	end
	g:write("\tj" .. pair[sense and 1 or 2] .. "\t" .. label .. "\n")
end

-- Every stack slot is sixteen bytes, so rsp is always aligned where a call
-- needs it to be.
-- A depth holds a value in one file or the other, never both, so only
-- one half of the slot is ever written.
local function save(g, i)
	-- An extended float sits in the frame, which a call leaves alone.
	if g.fdepth[i] == "x" then return end
	g:write("\tsubq\t$16,%rsp\n")
	if g.fdepth[i] then
		g:write("\tmovsd\t" .. fregname(i, 8) .. ",(%rsp)\n")
	else
		g:write("\tmovq\t" .. regname(i, 8) .. ",(%rsp)\n")
	end
end

local function restore(g, i)
	if g.fdepth[i] == "x" then return end
	if g.fdepth[i] then
		g:write("\tmovsd\t(%rsp)," .. fregname(i, 8) .. "\n")
	else
		g:write("\tmovq\t(%rsp)," .. regname(i, 8) .. "\n")
	end
	g:write("\taddq\t$16,%rsp\n")
end

-- Bridge a value already in a register to another context.
local function fzero(g)
	local l = g:newlabel()
	g:write("\t.pushsection\t.rodata\n\t.p2align\t3\n")
	g:write(l .. ":\n\t.quad\t0\n\t.popsection\n")
	return l
end

local function adapt(g, n, ctx, reg)
	local flt = n.ty.kind == "float"

	if ctx == "stack" then
		g:write("\tsubq\t$16,%rsp\n")
		if n.ty.x87 then
			g:write("\tfldt\t" .. ldslot(g, reg) .. "\n")
			g:write("\tfstpt\t(%rsp)\n")
		elseif flt then
			g:write("\tmovsd\t" .. fregname(reg, 8) ..
				",(%rsp)\n")
		else
			g:write("\tmovq\t" .. regname(reg, 8) ..
				",(%rsp)\n")
		end
	elseif ctx == "cc" then
		if n.ty.x87 then
			-- against zero, and the parity flag says NaN
			g:write("\tfldz\n")
			g:write("\tfldt\t" .. ldslot(g, reg) .. "\n")
			g:write("\tfucomip\t%st(1),%st\n")
			g:write("\tfstp\t%st(0)\n")
			return
		end
		if flt then
			-- Against zero, so that branch can read the
			-- parity flag and let a NaN count as true.
			g:write(("\tucomi%s\t%s(%%rip),%s\n")
				:format(fsuf(n.ty.size), fzero(g),
					fregname(reg, n.ty.size)))
			return
		end
		local r = regname(reg, n.ty.size)
		g:write("\ttest" .. suffix(n.ty) .. "\t" .. r .. "," .. r .. "\n")
	end
end

-- Shape "i" is what amd64 can name in an instruction: a constant, a global,
-- a frame slot, a symbol address.  An indirection is 16 and so falls out.
local code = {}

code.reg = {
	CONST = {
		-- A constant narrower than four bytes fills the whole
		-- 32-bit register, the same way a narrow load widens.
		-- What sits above the value is read as part of it: a
		-- shift and a compare both work at four bytes.
		{"zb", "z",         asm = "\txorl\t%W,%W"},
		{"zw", "z",         asm = "\txorl\t%W,%W"},
		{"z", "z",          asm = "\txor%z\t%R,%R"},
		{"cb", "z",         asm = "\tmovl\t%A,%W"},
		{"cw", "z",         asm = "\tmovl\t%A,%W"},
		{"c", "z",          asm = "\tmov%z\t%A,%R"},
		{"n", "z",          asm = "\tmovabsq\t%A,%P"},
	},
	-- A narrow load must widen, or the rest of the register is whatever
	-- happened to be there.
	NAME  = {
		{"iq", "z", asm = "\tmovq\t%A,%R"},
		{"il", "z", asm = "\tmovl\t%A,%W"},
		{"i",  "z", asm = "\t%I\t%A,%W"},
	},
	AUTO  = {
		{"iq", "z", asm = "\tmovq\t%A,%R"},
		{"il", "z", asm = "\tmovl\t%A,%W"},
		{"i",  "z", asm = "\t%I\t%A,%W"},
	},
	-- A name's address, where the code is not position independent,
	-- is a constant the machine can carry in an instruction.  lea
	-- reaches it from where the code stands instead, which is the
	-- same place only while the two are within two gigabytes of
	-- each other.  A link script may put them further apart:
	-- openbsd names the physical addresses of the kernel's own
	-- sections, and the text that reads them sits at the top of the
	-- address space, so the lea cannot reach and the link fails
	-- saying the relocation is out of range.
	ADDR  = {{"i", "z", asm = function(g, n, reg)
		leato(g, n.left, regname(reg, 8))
	end}},
	-- the loader wrote the address here, so it is a load and not a lea
	GOT   = {{"i", "z", asm = "\tmovq\t%A1,%R"}},
	-- The thread pointer is at offset zero of the %fs segment, and
	-- the linker knows where in the block this object sits.  That is
	-- the local exec model, which is what an executable may use.
	TLS   = {{"i", "z", asm = function(g, n, reg)
		local r = regname(reg, 8)

		g:write(("\tmovq\t%%fs:0,%s\n"):format(r))
		g:write(("\tleaq\t%s@tpoff(%s),%s\n")
			:format(n.left.sym, r, r))
	end}},
	-- The pointee type on the operand picks the load, exactly as the
	-- 1972 table did with its "abp" descriptor.
	INDIR = {
		-- A constant from an address, which is a member of a
		-- record or an element of an array: the constant is the
		-- displacement.  From a register the body keeps a local
		-- in, there is nothing to work out first.
		-- An element of an array, base and index and scale in
		-- the address.  From a register the body keeps the base
		-- in, only the index is worked out.
		{"nqpxr", "z", ev = "Li", asm = "\tmovq\t(%B1,%P,%X1),%R"},
		{"nlpxr", "z", ev = "Li", asm = "\tmovl\t(%B1,%P,%X1),%W"},
		{"nwpxr", "z", ev = "Li", asm = "\t%I\t(%B1,%P,%X1),%W"},
		{"nbpxr", "z", ev = "Li", asm = "\t%I\t(%B1,%P,%X1),%W"},
		{"nqpx", "z", ev = "Lx L1i", asm = "\tmovq\t(%P,%P1,%X1),%R"},
		{"nlpx", "z", ev = "Lx L1i", asm = "\tmovl\t(%P,%P1,%X1),%W"},
		{"nwpx", "z", ev = "Lx L1i", asm = "\t%I\t(%P,%P1,%X1),%W"},
		{"nbpx", "z", ev = "Lx L1i", asm = "\t%I\t(%P,%P1,%X1),%W"},
		{"nqpor", "z", asm = "\tmovq\t%O1(%B1),%R"},
		{"nlpor", "z", asm = "\tmovl\t%O1(%B1),%W"},
		{"nwpor", "z", asm = "\t%I\t%O1(%B1),%W"},
		{"nbpor", "z", asm = "\t%I\t%O1(%B1),%W"},
		{"nqpo", "z", ev = "Lo", asm = "\tmovq\t%O1(%P),%R"},
		{"nlpo", "z", ev = "Lo", asm = "\tmovl\t%O1(%P),%W"},
		{"nwpo", "z", ev = "Lo", asm = "\t%I\t%O1(%P),%W"},
		{"nbpo", "z", ev = "Lo", asm = "\t%I\t%O1(%P),%W"},
		-- Through a pointer the body keeps in a register: the
		-- register is the address, so there is nothing to load
		-- first.  This is what a loop over a string costs when
		-- the pointer does not go back to the frame each time.
		{"iqpr", "z", asm = "\tmovq\t(%A1),%R"},
		{"ilpr", "z", asm = "\tmovl\t(%A1),%W"},
		{"iwpr", "z", asm = "\t%I\t(%A1),%W"},
		{"ibpr", "z", asm = "\t%I\t(%A1),%W"},
		{"nqp", "z", ev = "L", asm = "\tmovq\t(%P),%R"},
		{"nlp", "z", ev = "L", asm = "\tmovl\t(%P),%W"},
		{"nwp", "z", ev = "L", asm = "\t%I\t(%P),%W"},
		{"nbp", "z", ev = "L", asm = "\t%I\t(%P),%W"},
	},
	-- A postfix step yields the old value, then adjusts the lvalue.
	POSTADD = {
		{"iq", "z", rz = 1,
		 asm = "\tmovq\t%A1,%R\n\taddq\t$%C,%A1"},
		{"il", "z", rz = 1,
		 asm = "\tmovl\t%A1,%W\n\taddl\t$%C,%A1"},
		{"i",  "z", rz = 1,
		 asm = "\t%I\t%A1,%W\n\tadd%z1\t$%C,%A1"},
		-- through a pointer: the address goes in the next register so
		-- the loaded value does not overwrite it
		{"n*q", "z", rz = 1, ev = "L1*",
		 asm = "\tmovq\t(%P1),%R\n\taddq\t$%C,(%P1)"},
		{"n*l", "z", rz = 1, ev = "L1*",
		 asm = "\tmovl\t(%P1),%W\n\taddl\t$%C,(%P1)"},
		{"n*",  "z", rz = 1, ev = "L1*",
		 asm = "\t%I\t(%P1),%W\n\tadd%z1\t$%C,(%P1)"},
	},
	-- alloca: round the size up to keep the stack aligned, take that
	-- much off the stack pointer, and answer with what is left.  The
	-- frame pointer puts the stack back on return, so the block lives
	-- as long as the call does.
	ALLOCA = {{"n", "z", ev = "L", asm = function(g, n, reg)
		if g.nomove > 0 then
			error("alloca in an expression that uses the " ..
			      "stack is not supported", 0)
		end
		local r = regname(reg, 8)

		g:write(("\taddq\t$15,%s\n\tandq\t$-16,%s\n")
			:format(r, r))
		g:write(("\tsubq\t%s,%%rsp\n\tmovq\t%%rsp,%s\n")
			:format(r, r))
	end}},
	NEG = {{"n", "z", ev = "L", asm = "\tneg%z\t%R"}},
	NOT = {{"n", "z", ev = "L", asm = "\tnot%z\t%R"}},
}

-- The commutative and difference ops share one shape ladder.
for _, op in ipairs{"ADD", "SUB", "AND", "OR", "XOR"} do
	code.reg[op] = {
		{"n", "i", ev = "L",     asm = "\t%I%z\t%A2,%R"},
		{"n", "e", ev = "L R1",  asm = "\t%I%z\t%R1,%R"},
		{"n", "n", ev = "Rs L",  asm = "\t%I%z\t(%rsp),%R\n\taddq\t$16,%rsp"},
	}
end

-- A pointer and a scaled index is one lea, the shift done by the
-- address.
table.insert(code.reg.ADD, 1,
	{"nq", "nk", ev = "L R1k", asm = "\tleaq\t(%P,%P1,%X2),%P"})
table.insert(code.reg.ADD, 1,
	{"nk", "nq", ev = "R L1k", asm = "\tleaq\t(%P,%P1,%X1),%P"})

code.reg.MUL = {
	{"n", "c", ev = "L",    asm = "\timul%z\t%A2,%R,%R"},
	{"n", "i", ev = "L",    asm = "\timul%z\t%A2,%R"},
	{"n", "e", ev = "L R1", asm = "\timul%z\t%R1,%R"},
	{"n", "n", ev = "Rs L", asm = "\timul%z\t(%rsp),%R\n\taddq\t$16,%rsp"},
}

-- A variable shift count has to be in cl, which no value can occupy.
for _, op in ipairs{"SHL", "SHR"} do
	code.reg[op] = {
		{"n", "c", ev = "L",    asm = "\t%I%z\t$%C2,%R"},
		{"n", "e", ev = "L R1", asm = "\tmovq\t%P1,%rcx\n\t%I%z\t%cl,%R"},
		{"n", "n", ev = "Rs L",
		 asm = "\tmovq\t(%rsp),%rcx\n\taddq\t$16,%rsp" ..
		       "\n\t%I%z\t%cl,%R"},
	}
end

-- Divide and remainder read rdx:rax and write both.  The divisor goes to
-- r11 first so it cannot be sitting in a register the instruction destroys.
local DIV = {
	[8] = {acc = "%rax", rem = "%rdx", tmp = "%r11",
	       ext = "\tcqto\n", zero = "\txorl\t%edx,%edx\n", z = "q"},
	[4] = {acc = "%eax", rem = "%edx", tmp = "%r11d",
	       ext = "\tcltd\n", zero = "\txorl\t%edx,%edx\n", z = "l"},
}

for _, want in ipairs{"DIV", "MOD"} do
	local alts = {}
	for _, size in ipairs{8, 4} do
		for _, kind in ipairs{"s", "u"} do
			local d = DIV[size]
			local mn = kind == "u" and "div" or "idiv"
			local pre = kind == "u" and d.zero or d.ext
			local out = want == "DIV" and d.acc or d.rem
			local body =
				"\tmov" .. d.z .. "\t%R1," .. d.tmp .. "\n" ..
				"\tmov" .. d.z .. "\t%R," .. d.acc .. "\n" ..
				pre ..
				"\t" .. mn .. d.z .. "\t" .. d.tmp .. "\n" ..
				"\tmov" .. d.z .. "\t" .. out .. ",%R"
			local sh = "n" .. (size == 8 and "q" or "l") .. kind
			alts[#alts + 1] = {sh, "e", clob = {0}, ev = "L R1",
					   asm = body}
			alts[#alts + 1] = {sh, "n", clob = {0}, ev = "R1s L",
					   asm = "\tmovq\t(%rsp),%r11\n" ..
						 "\taddq\t$16,%rsp\n" ..
						 "\tmov" .. d.z .. "\t%R," .. d.acc ..
						 "\n" .. pre ..
						 "\t" .. mn .. d.z .. "\t" .. d.tmp ..
						 "\n\tmov" .. d.z .. "\t" .. out .. ",%R"}
		end
	end
	code.reg[want] = alts
end

-- The branch reads the flags the compare leaves, so nothing between the two
-- may touch them.  That is why the stack comes back with lea and not add.
code.cc = {}
for op in pairs{EQ = 1, NE = 1, LT = 1, LE = 1, GT = 1, GE = 1} do
	code.cc[op] = {
		{"n", "i", rz = 1, ev = "L",    asm = "\tcmp%z1\t%A2,%R"},
		{"n", "e", rz = 1, ev = "L R1", asm = "\tcmp%z1\t%R1,%R"},
		{"n", "n", rz = 1, ev = "Rs L",
		 asm = "\tcmp%z1\t(%rsp),%R\n\tleaq\t16(%rsp),%rsp"},
	}
end

code.eff = {
	POSTADD = {
		{"i",  "z", rz = 1, asm = "\tadd%z1\t$%C,%A1"},
		{"n*", "z", rz = 1, ev = "L*",
		 asm = "\tadd%z1\t$%C,(%P)"},
	},
	ASGN = {
		{"i",  "c",                        asm = "\tmov%z1\t%A2,%A1"},
		{"i",  "n", rz = 1, ev = "R",      asm = "\tmov%z1\t%R,%A1"},
		-- To an address and a constant, the constant as the
		-- displacement.
		{"n*xr", "c", rz = 1, ev = "L*i",  asm = "\tmov%z1\t%A2,(%B1,%P,%X1)"},
		{"n*xr", "n", rz = 1, ev = "R L1*i",
		 asm = "\tmov%z1\t%R,(%B1,%P1,%X1)"},
		{"n*x", "c", rz = 1, ev = "L*x L1*i",
		 asm = "\tmov%z1\t%A2,(%P,%P1,%X1)"},
		{"n*or", "c", rz = 1,              asm = "\tmov%z1\t%A2,%O1(%B1)"},
		{"n*or", "n", rz = 1, ev = "R",    asm = "\tmov%z1\t%R,%O1(%B1)"},
		{"n*o", "c", rz = 1, ev = "L*o",   asm = "\tmov%z1\t%A2,%O1(%P)"},
		{"n*o", "n", rz = 1, ev = "R L1*o",
		 asm = "\tmov%z1\t%R,%O1(%P1)"},
		-- A constant through a pointer is the store alone; the
		-- value needs no register of its own.
		{"n*", "c", rz = 1, ev = "L*",     asm = "\tmov%z1\t%A2,(%P)"},
		{"n*", "n", rz = 1, ev = "R L1*",  asm = "\tmov%z1\t%R,(%P1)"},
	},
}

-- An assignment used for its value stores, then leaves the value behind.
code.reg.ASGN = {
	{"i",  "n", rz = 1, ev = "R",      asm = "\tmov%z1\t%R,%A1"},
	{"n*or", "n", rz = 1, ev = "R",    asm = "\tmov%z1\t%R,%O1(%B1)"},
	{"n*o", "n", rz = 1, ev = "R L1*o", asm = "\tmov%z1\t%R,%O1(%P1)"},
	{"n*", "n", rz = 1, ev = "R L1*",  asm = "\tmov%z1\t%R,(%P1)"},
}

-- Hardware floating point.  A float lives in the float file at the same
-- depth as an integer would, so these rules are the integer ones again
-- with %F for %R and the scalar mnemonics.  They go in front of the
-- integer alternatives, which carry no kind letter and would otherwise
-- match a float first.

-- The two widths, and the letters each is spelled with.
local FW = {{sz = 8, l = "q", s = "sd", d = "quad", a = 3},
	    {sz = 4, l = "l", s = "ss", d = "long", a = 2}}

-- A float constant has no immediate form, so it is assembled into
-- .rodata and read back from there.
local function frodata(g, bits, w)
	local l = g:newlabel()

	g:write("\t.pushsection\t.rodata\n\t.p2align\t" .. w.a .. "\n")
	g:write(l .. ":\n\t." .. w.d .. "\t" .. bits .. "\n")
	g:write("\t.popsection\n")
	return l
end

local function ahead(tab, alts)
	for i, a in ipairs(alts) do table.insert(tab, i, a) end
end

for _, w in ipairs(FW) do
	local n, i, sz = "nf" .. w.l, "if" .. w.l, w.sz
	local mem, reg = "imf" .. w.l, "ef" .. w.l
	local mov = "\tmov" .. w.s .. "\t"

	ahead(code.reg.CONST, {{n, "z", asm = function(g, nd, r)
		g:write(mov .. frodata(g, nd.val, w) .. "(%rip)," ..
			fregname(r, sz) .. "\n")
	end}})
	ahead(code.reg.NAME, {{i, "z", asm = mov .. "%A,%F"}})
	ahead(code.reg.AUTO, {{i, "z", asm = mov .. "%A,%F"}})
	ahead(code.reg.INDIR, {{"n" .. w.l .. "pf", "z", ev = "L",
				asm = mov .. "(%P),%F"}})
	-- The sign bit alone, flipped where no value can be sitting.
	code.reg.SQRT = code.reg.SQRT or {}
	ahead(code.reg.SQRT, {{n, "z", ev = "L",
		asm = "\tsqrt" .. w.s .. "\t%F,%F"}})
	-- No scalar absolute value: the sign bit is cleared where no
	-- value can be sitting.
	code.reg.FABS = code.reg.FABS or {}
	ahead(code.reg.FABS, {{n, "z", ev = "L", asm = function(g, _, r)
		local f = fregname(r, sz)

		if sz == 8 then
			g:write("\tmovq\t" .. f .. ",%r11\n")
			g:write("\tbtrq\t$63,%r11\n")
			g:write("\tmovq\t%r11," .. f .. "\n")
		else
			g:write("\tmovd\t" .. f .. ",%r11d\n")
			g:write("\tandl\t$2147483647,%r11d\n")
			g:write("\tmovd\t%r11d," .. f .. "\n")
		end
	end}})
	ahead(code.reg.NEG, {{n, "z", ev = "L", asm = function(g, _, r)
		local f = fregname(r, sz)

		if sz == 8 then
			g:write("\tmovq\t" .. f .. ",%r11\n")
			g:write("\tbtcq\t$63,%r11\n")
			g:write("\tmovq\t%r11," .. f .. "\n")
		else
			g:write("\tmovd\t" .. f .. ",%r11d\n")
			g:write("\txorl\t$-2147483648,%r11d\n")
			g:write("\tmovd\t%r11d," .. f .. "\n")
		end
	end}})
	for op, mn in pairs{ADD = "add", SUB = "sub", MUL = "mul",
			    DIV = "div"} do
		local x = "\t" .. mn .. w.s .. "\t"

		ahead(code.reg[op], {
			{n, mem, ev = "L",     asm = x .. "%A2,%F"},
			{n, reg, ev = "L R1",  asm = x .. "%F1,%F"},
			{n, n,   ev = "Rs L",
			 asm = x .. "(%rsp),%F\n\taddq\t$16,%rsp"},
		})
	end
	for op in pairs(JMP) do
		local u = "\tucomi" .. w.s .. "\t"

		ahead(code.cc[op], {
			{n, mem, rz = 1, ev = "L",    asm = u .. "%A2,%F"},
			{n, reg, rz = 1, ev = "L R1", asm = u .. "%F1,%F"},
			{n, n,   rz = 1, ev = "Rs L",
			 asm = u .. "(%rsp),%F\n\tleaq\t16(%rsp),%rsp"},
		})
	end
	-- Storing zero needs no register and no constant pool.
	local store = {
		{i, "zf", asm = "\tmov" .. w.l .. "\t$0,%A1"},
		{i, n, rz = 1, ev = "R", asm = mov .. "%F,%A1"},
		{"n*f" .. w.l, n, rz = 1, ev = "R L1*",
		 asm = mov .. "%F,(%P1)"},
	}
	ahead(code.eff.ASGN, store)
	ahead(code.reg.ASGN, {store[2], store[3]})
end

-- A two-byte float only moves: the parser does its arithmetic in a
-- float.  pinsrw loads one into the low word of a register; a store
-- goes out through r11, which is not allocatable.
do
	local hw = {a = 1, d = "short"}
	local st = "\tmovd\t%F,%r11d\n\tmovw\t%r11w,"

	ahead(code.reg.CONST, {{"nfw", "z", asm = function(g, nd, r)
		g:write("\tpinsrw\t$0," .. frodata(g, nd.val & 0xffff, hw) ..
			"(%rip)," .. fregname(r, 2) .. "\n")
	end}})
	ahead(code.reg.NAME, {{"ifw", "z", asm = "\tpinsrw\t$0,%A,%F"}})
	ahead(code.reg.AUTO, {{"ifw", "z", asm = "\tpinsrw\t$0,%A,%F"}})
	ahead(code.reg.INDIR, {{"nwpf", "z", ev = "L",
				asm = "\tpinsrw\t$0,(%P),%F"}})
	local store = {
		{"ifw", "zf", asm = "\tmovw\t$0,%A1"},
		{"ifw", "nfw", rz = 1, ev = "R", asm = st .. "%A1"},
		{"n*fw", "nfw", rz = 1, ev = "R L1*", asm = st .. "(%P1)"},
	}
	ahead(code.eff.ASGN, store)
	ahead(code.reg.ASGN, {store[2], store[3]})
end

-- The extended float.  Every value of one lives in a frame slot and
-- every operation loads it, works on the x87 stack, and puts it back.
-- That is slower than keeping values on the stack between operations
-- and very much simpler: a stack does not answer to a depth, and
-- nothing here has to know how deep the x87 stack is.
if LDBL80 then
	local function ld(g, r) return "\tfldt\t" .. ldslot(g, r) .. "\n" end
	local function st(g, r) return "\tfstpt\t" .. ldslot(g, r) .. "\n" end

	-- The ten bytes of a constant, in a slot of their own.
	code.reg.CONST = code.reg.CONST or {}
	ahead(code.reg.CONST, {{"nft", "z", asm = function(g, n, r)
		local l = g:newlabel()

		g:write("\t.pushsection\t.rodata\n\t.p2align\t4\n")
		g:write(l .. ":\n\t.quad\t" .. n.val ..
			"\n\t.short\t" .. n.hi .. "\n\t.zero\t6\n")
		g:write("\t.popsection\n")
		g:write("\tfldt\t" .. l .. "(%rip)\n")
		g:write(st(g, r))
	end}})
	for _, op in ipairs{"NAME", "AUTO"} do
		ahead(code.reg[op], {{"ift", "z", asm = function(g, n, r)
			g:write("\tfldt\t" .. addr(g, n) .. "\n")
			g:write(st(g, r))
		end}})
	end
	ahead(code.reg.INDIR, {{"ntpf", "z", ev = "L",
		asm = function(g, n, r)
		g:write("\tfldt\t(" .. regname(r, 8) .. ")\n")
		g:write(st(g, r))
	end}})
	for op, mn in pairs{NEG = "fchs", FABS = "fabs", SQRT = "fsqrt"} do
		code.reg[op] = code.reg[op] or {}
		ahead(code.reg[op], {{"nft", "z", ev = "L",
			asm = function(g, _, r)
			g:write(ld(g, r) .. "\t" .. mn .. "\n" .. st(g, r))
		end}})
	end
	-- st(0) is the right hand side and st(1) the left.  The popping
	-- form answers into st(1); the reversed spelling is the one that
	-- takes st(0) from it rather than the other way about, which is
	-- what C asks for and what gcc writes.
	for op, mn in pairs{ADD = "faddp", SUB = "fsubrp", MUL = "fmulp",
			    DIV = "fdivrp"} do
		local function two(g, r, r2)
			return ld(g, r) .. ld(g, r2) ..
			       "\t" .. mn .. "\t%st,%st(1)\n" .. st(g, r)
		end

		ahead(code.reg[op], {
			{"nft", "eft", ev = "L R1", asm = function(g, _, r)
				g:write(two(g, r, r + 1))
			end},
			{"nft", "nft", ev = "Rs L", asm = function(g, _, r)
				g:write(ld(g, r))
				g:write("\tfldt\t(%rsp)\n")
				g:write("\t" .. mn .. "\t%st,%st(1)\n")
				g:write(st(g, r))
				g:write("\taddq\t$16,%rsp\n")
			end},
		})
	end
	-- The compare leaves the unsigned flags and sets the parity flag
	-- on a NaN, exactly as the scalar sse compares do, so branch needs
	-- nothing new.
	for op in pairs(JMP) do
		local function cmp(g, lhs, rhs)
			return rhs .. lhs ..
			       "\tfucomip\t%st(1),%st\n\tfstp\t%st(0)\n"
		end

		ahead(code.cc[op], {
			{"nft", "eft", rz = 1, ev = "L R1",
			 asm = function(g, _, r)
				g:write(cmp(g, ld(g, r), ld(g, r + 1)))
			end},
			{"nft", "nft", rz = 1, ev = "Rs L",
			 asm = function(g, _, r)
				g:write("\tfldt\t(%rsp)\n")
				g:write(ld(g, r))
				g:write("\tfucomip\t%st(1),%st\n")
				g:write("\tfstp\t%st(0)\n")
				g:write("\tleaq\t16(%rsp),%rsp\n")
			end},
		})
	end
	-- The store leaves the value where it was: it is a copy that goes
	-- out, so an assignment used for its value needs nothing more.
	local store = {
		{"ift", "nft", rz = 1, ev = "R", asm = function(g, n, r)
			g:write(ld(g, r))
			g:write("\tfstpt\t" .. addr(g, n.left) .. "\n")
		end},
		{"n*ft", "nft", rz = 1, ev = "R L1*",
		 asm = function(g, _, r)
			g:write(ld(g, r))
			g:write("\tfstpt\t(" .. regname(r + 1, 8) .. ")\n")
		end},
	}
	ahead(code.eff.ASGN, store)
	ahead(code.reg.ASGN, {store[1], store[2]})
end

-- Narrowing has to be done, not assumed: a byte in a register is still
-- whatever was there.  Widening from a narrow load is already done, because
-- the load itself widened.
-- A value narrower than a register is held sign or zero extended to 32
-- bits, which is what the loads produce.  Widening to 64 has to finish the
-- job; narrowing has to redo it at the new width.
-- Two to the sixty-third, the point either conversion between a double
-- and an unsigned word has to fold at: it is the first value the signed
-- instruction cannot reach.
local P63 = {[8] = "0x43e0000000000000", [4] = "0x5f000000"}

local function fconvert(g, from, to, reg)
	local w = to.kind == "float" and to.size or from.size
	local sfx = fsuf(w)
	local f = fregname(reg, w)
	local r, r32 = regname(reg, 8), regname(reg, 4)

	if from.kind == "float" and to.kind == "float" then
		if from.size == to.size then return end
		g:write(("\tcvt%s2%s\t%s,%s\n")
			:format(fsuf(from.size), fsuf(to.size),
				fregname(reg, from.size),
				fregname(reg, to.size)))
		return
	end
	if to.kind == "float" then
		if from.kind ~= "uint" then
			g:write(("\tcvtsi2%sq\t%s,%s\n"):format(sfx, r, f))
			return
		end
		-- Unsigned, and the instruction is signed: a value with the
		-- top bit set is halved, rounded odd so nothing is lost,
		-- converted, and doubled back.
		local big, done = g:newlabel(), g:newlabel()

		g:write("\ttestq\t" .. r .. "," .. r .. "\n")
		g:write("\tjs\t" .. big .. "\n")
		g:write(("\tcvtsi2%sq\t%s,%s\n"):format(sfx, r, f))
		g:write("\tjmp\t" .. done .. "\n")
		g:write(big .. ":\n")
		g:write("\tmovq\t" .. r .. ",%r11\n")
		g:write("\tshrq\t$1,%r11\n")
		g:write("\tandl\t$1," .. r32 .. "\n")
		g:write("\torq\t" .. r .. ",%r11\n")
		g:write(("\tcvtsi2%sq\t%%r11,%s\n"):format(sfx, f))
		g:write(("\tadd%s\t%s,%s\n"):format(sfx, f, f))
		g:write(done .. ":\n")
		return
	end
	-- To an integer, always at word width: the caller narrows.
	if to.kind ~= "uint" then
		g:write(("\tcvtt%s2siq\t%s,%s\n"):format(sfx, f, r))
		return
	end
	local big, done = g:newlabel(), g:newlabel()
	local l = g:newlabel()

	g:write("\t.pushsection\t.rodata\n\t.p2align\t" ..
		(w == 8 and 3 or 2) .. "\n")
	g:write(l .. ":\n\t." .. (w == 8 and "quad" or "long") ..
		"\t" .. P63[w] .. "\n\t.popsection\n")
	g:write(("\tcomi%s\t%s(%%rip),%s\n"):format(sfx, l, f))
	g:write("\tjae\t" .. big .. "\n")
	g:write(("\tcvtt%s2siq\t%s,%s\n"):format(sfx, f, r))
	g:write("\tjmp\t" .. done .. "\n")
	g:write(big .. ":\n")
	g:write(("\tsub%s\t%s(%%rip),%s\n"):format(sfx, l, f))
	g:write(("\tcvtt%s2siq\t%s,%s\n"):format(sfx, f, r))
	g:write("\tbtcq\t$63," .. r .. "\n")
	g:write(done .. ":\n")
end

-- A ten-byte constant in .rodata, for the two conversions that need
-- one: the point an unsigned word folds at, and twice it.
local function tconst(g, exp)
	local l = g:newlabel()

	g:write("\t.pushsection\t.rodata\n\t.p2align\t4\n")
	g:write(l .. ":\n\t.quad\t-9223372036854775808\n\t.short\t" ..
		exp .. "\n\t.zero\t6\n\t.popsection\n")
	return l .. "(%rip)"
end

-- Truncate what is on the x87 stack into the slot, which C asks for
-- and the unit does not do by default.  The rounding mode lives in the
-- control word, so it is saved, changed and put back; the two words
-- fit in the slot above the ten bytes of value.
local function ttrunc(g, reg)
	local cw, tmp = ldslot(g, reg, 10), ldslot(g, reg, 12)
	local w = regname(reg, 2)

	g:write("\tfnstcw\t" .. cw .. "\n")
	g:write("\tmovw\t" .. cw .. "," .. w .. "\n")
	g:write("\torw\t$3072," .. w .. "\n")
	g:write("\tmovw\t" .. w .. "," .. tmp .. "\n")
	g:write("\tfldcw\t" .. tmp .. "\n")
	g:write("\tfistpll\t" .. ldslot(g, reg) .. "\n")
	g:write("\tfldcw\t" .. cw .. "\n")
end

local function tconvert(g, from, to, reg)
	local at = ldslot(g, reg)
	local r = regname(reg, 8)

	if from.x87 and to.x87 then return end
	if to.x87 then
		if from.kind == "float" then
			g:write(("\tmov%s\t%s,%s\n")
				:format(fsuf(from.size),
					fregname(reg, from.size), at))
			g:write(("\tfld%s\t%s\n")
				:format(from.size == 8 and "l" or "s", at))
			g:write("\tfstpt\t" .. at .. "\n")
			return
		end
		g:write("\tmovq\t" .. r .. "," .. at .. "\n")
		g:write("\tfildll\t" .. at .. "\n")
		if from.kind == "uint" then
			-- fildll reads a signed word, so a value with the
			-- top bit set comes back short by two to the
			-- sixty-fourth.
			local done = g:newlabel()

			g:write("\ttestq\t" .. r .. "," .. r .. "\n")
			g:write("\tjns\t" .. done .. "\n")
			g:write("\tfldt\t" .. tconst(g, 16447) .. "\n")
			g:write("\tfaddp\t%st,%st(1)\n")
			g:write(done .. ":\n")
		end
		g:write("\tfstpt\t" .. at .. "\n")
		return
	end
	-- From the extended type.
	if to.kind == "float" then
		g:write("\tfldt\t" .. at .. "\n")
		g:write(("\tfst%s\t%s\n")
			:format(to.size == 8 and "pl" or "ps", at))
		g:write(("\tmov%s\t%s,%s\n")
			:format(fsuf(to.size), at, fregname(reg, to.size)))
		return
	end
	g:write("\tfldt\t" .. at .. "\n")
	if to.kind ~= "uint" then
		ttrunc(g, reg)
		g:write("\tmovq\t" .. at .. "," .. r .. "\n")
		return
	end
	-- Unsigned, and the instruction is signed: a value past the
	-- signed range folds at two to the sixty-third and comes back.
	local big, done = g:newlabel(), g:newlabel()
	local c = tconst(g, 16446)

	g:write("\tfldt\t" .. c .. "\n")
	g:write("\tfucomip\t%st(1),%st\n")
	g:write("\tjbe\t" .. big .. "\n")
	ttrunc(g, reg)
	g:write("\tmovq\t" .. at .. "," .. r .. "\n")
	g:write("\tjmp\t" .. done .. "\n")
	g:write(big .. ":\n")
	g:write("\tfldt\t" .. c .. "\n")
	g:write("\tfsubrp\t%st,%st(1)\n")
	ttrunc(g, reg)
	g:write("\tmovq\t" .. at .. "," .. r .. "\n")
	g:write("\tbtcq\t$63," .. r .. "\n")
	g:write(done .. ":\n")
end

local function convert(g, from, to, reg)
	if from.x87 or to.x87 then
		return tconvert(g, from, to, reg)
	end
	if from.kind == "float" or to.kind == "float" then
		return fconvert(g, from, to, reg)
	end
	if to.size >= from.size then
		if to.size == 8 and from.size < 8 then
			if from.kind == "uint" then
				g:write("\tmovl\t" .. regname(reg, 4) ..
					"," .. regname(reg, 4) .. "\n")
			else
				g:write("\tmovslq\t" .. regname(reg, 4) ..
					"," .. regname(reg, 8) .. "\n")
			end
		end
		return
	end
	if to.size == 1 or to.size == 2 then
		local mn = (to.size == 1)
			and (to.kind == "uint" and "movzbl" or "movsbl")
			or  (to.kind == "uint" and "movzwl" or "movswl")
		g:write("\t" .. mn .. "\t" .. regname(reg, to.size) ..
			"," .. regname(reg, 4) .. "\n")
	end
end

-- Copy `size` bytes from the address in reg+1 to the address in reg.  Small
-- records are the common case, so this unrolls rather than loops.
--
-- The word in flight goes through r11, which no expression is ever
-- given and the ABI does not ask back.  It used to borrow the
-- register two above the one it was handed, which put every register
-- up to two past the allocation order out of reach of anything else.
local COPYTMP = {[8] = "%r11", [4] = "%r11d", [2] = "%r11w", [1] = "%r11b"}

local function blockcopy(g, size, reg)
	local d, s = regname(reg, 8), regname(reg + 1, 8)
	local off = 0
	for _, w in ipairs{8, 4, 2, 1} do
		while size - off >= w do
			local r = COPYTMP[w]
			local sfx = SUFFIX[w]
			g:write(("\tmov%s\t%d(%s),%s\n\tmov%s\t%s,%d(%s)\n")
				:format(sfx, off, s, r, sfx, r, off, d))
			off = off + w
		end
	end
end

-- Inline assembly ------------------------------------------------------
--
-- The constraint letters that name a register, at each width.  A letter this
-- table does not carry means "any register", which the generator allocates.
local ASMREG = {
	a = {"%al",  "%ax", "%eax", "%rax"},
	b = {"%bl",  "%bx", "%ebx", "%rbx"},
	c = {"%cl",  "%cx", "%ecx", "%rcx"},
	d = {"%dl",  "%dx", "%edx", "%rdx"},
	S = {"%sil", "%si", "%esi", "%rsi"},
	D = {"%dil", "%di", "%edi", "%rdi"},
}

-- Every general register by every name it answers to, for a local
-- bound to one with `register long r __asm__("r10")`.
local GPR = {
	{"al", "ax", "eax", "rax"}, {"cl", "cx", "ecx", "rcx"},
	{"dl", "dx", "edx", "rdx"}, {"bl", "bx", "ebx", "rbx"},
	{"spl", "sp", "esp", "rsp"}, {"bpl", "bp", "ebp", "rbp"},
	{"sil", "si", "esi", "rsi"}, {"dil", "di", "edi", "rdi"},
}
for i = 8, 15 do
	GPR[#GPR + 1] = {"r" .. i .. "b", "r" .. i .. "w",
			 "r" .. i .. "d", "r" .. i}
end
local HARD = {}
for _, names in ipairs(GPR) do
	for _, nm in ipairs(names) do HARD[nm] = names end
end

local function hardreg(name, size)
	local n = HARD[(name:gsub("^%%", ""))]

	return n and ("%" .. n[SLOT[size] or 4]) or nil
end

-- Read a machine register a file-scope `register` declaration named.
local function readhard(g, name, reg, size)
	local from = hardreg(name, size)

	if not from then error("no register " .. name) end
	g:write(("\t%s\t%s,%s\n")
		:format(size == 8 and "movq" or "movl", from,
			regname(reg, size == 8 and 8 or 4)))
end

-- Which constants a constraint letter takes.  These are the ranges the
-- instructions themselves have: a shift count is five bits, a port
-- number is eight, and the immediate of an ordinary instruction is
-- thirty two bits sign extended.
local function asmfits(letter, v)
	if letter == "I" then return v >= 0 and v <= 31 end
	if letter == "J" then return v >= 0 and v <= 63 end
	if letter == "K" then return v >= -128 and v <= 127 end
	if letter == "L" then
		return v == 0xff or v == 0xffff or v == 0xffffffff
	end
	if letter == "M" then return v >= 0 and v <= 3 end
	if letter == "N" then return v >= 0 and v <= 255 end
	if letter == "O" then return v >= 0 and v <= 127 end
	if letter == "e" then
		return v >= -0x80000000 and v <= 0x7fffffff
	end
	if letter == "Z" then return v >= 0 and v <= 0xffffffff end
	return true
end

local function asmreg(letter, size)
	local r = ASMREG[letter]
	return r and r[SLOT[size] or 4]
end

-- Where a named register sits in the allocation order, if it is in it, and
-- whether the ABI asks the callee to preserve it.
local ALLOC = {["%rax"] = 0, ["%rsi"] = 1, ["%rdi"] = 2,
	       ["%r8"] = 3, ["%r9"] = 4, ["%r10"] = 5,
	       ["%rbx"] = 6, ["%r12"] = 7, ["%r13"] = 8,
	       ["%r14"] = 9, ["%r15"] = 10}
local PRESERVED = {["%rbx"] = true, ["%rbp"] = true, ["%r12"] = true,
		   ["%r13"] = true, ["%r14"] = true, ["%r15"] = true}
local WIDE = {}
for _, names in pairs(ASMREG) do
	for _, nm in ipairs(names) do WIDE[nm] = names[4] end
end

local function asmpin(name)
	if name:sub(1, 1) ~= "%" then name = "%" .. name end
	name = WIDE[name] or name
	return ALLOC[name], PRESERVED[name]
end

-- Save a register the template destroys and the ABI wants back.
local function asmkeep(g, name, push)
	if name:sub(1, 1) ~= "%" then name = "%" .. name end
	name = WIDE[name] or name
	g:write((push and "\tpushq\t" or "\tpopq\t") .. name .. "\n")
end

-- What a `"=@cc<cond>"` output answers: the condition the template
-- left in the flags, as a zero or a one.
local function asmflag(g, cond, reg, size)
	local b = regname(reg, 1)

	g:write("\tset" .. cond .. "\t" .. b .. "\n")
	if size > 1 then
		g:write(("\tmovzbl\t%s,%s\n"):format(b, regname(reg, 4)))
	end
end

local function asmimm(v)
	return "$" .. v
end

-- `%a` on an operand asks for it as an address, and an address here
-- is written relative to the instruction.
local function asmaddr(v)
	return v .. "(%rip)"
end

-- A float on or off the x87 stack, for a template that names it with
-- t or u.  An extended one lives in a slot; a float or a double lives
-- in an SSE register and crosses through a word on the stack.
local function asmx87(g, r, push, ty)
	if not ty or ty.x87 then
		g:write((push and "\tfldt\t" or "\tfstpt\t") ..
			ldslot(g, r) .. "\n")
		return
	end
	local w, mv = "l", "movsd"

	if ty.size == 4 then w, mv = "s", "movss" end
	g:write("\tsubq\t$8,%rsp\n")
	if push then
		g:write(("\t%s\t%s,(%%rsp)\n\tfld%s\t(%%rsp)\n")
			:format(mv, fregname(r), w))
	else
		g:write(("\tfstp%s\t(%%rsp)\n\t%s\t(%%rsp),%s\n")
			:format(w, mv, fregname(r)))
	end
	g:write("\taddq\t$8,%rsp\n")
end

-- Take one off the x87 stack and keep nothing: an input the template
-- was handed and did not consume.
local function asmx87drop(g, k)
	g:write(("\tfstp\t%%st(%d)\n"):format(k))
end

local function rawmove(g, dst, src, size)
	if dst == src then return end
	g:write(("\tmov%s\t%s,%s\n"):format(SUFFIX[size] or "q", src, dst))
end

local function move(g, dst, src, size, flt)
	size = size or 8
	if size == 16 and flt then
		if dst == src then return end
		g:write("\tfldt\t" .. ldslot(g, src) .. "\n")
		g:write("\tfstpt\t" .. ldslot(g, dst) .. "\n")
		return
	end
	if flt then
		if dst == src then return end
		g:write(("\tmov%s\t%s,%s\n"):format(fsuf(size),
			fregname(src, size), fregname(dst, size)))
		return
	end
	rawmove(g, regname(dst, size), regname(src, size), size)
end

-- The kernel's retpoline thunk, which every indirect branch goes through
-- when the caller asks for one.
local THUNK = "__x86_indirect_thunk_r11"

-- And the one every return goes through when the caller asks, which is
-- how a kernel keeps the return stack buffer out of the guess.
local RETTHUNK = "__x86_return_thunk"

local function retinsn(g)
	if g.o.rethunk then return "\tjmp\t" .. RETTHUNK .. "\n" end
	return "\tret\n"
end

-- A call is not a table entry: the argument count varies, so the generator
-- hands the node here.  Everything allocatable is caller saved, so whatever
-- is still live gets saved around it.
local ARGREG = {"%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"}
local ARGREG32 = {"%edi", "%esi", "%edx", "%ecx", "%r8d", "%r9d"}
local NFLTREG = 8

-- An argument the machine can name in one instruction: nothing between
-- here and the call can change what it means, so it goes straight into
-- its own register at the end and never touches the stack.
-- A pointer an argument can be worked out from in its own register: a
-- local, the register one is kept in, or a name.
local function simplebase(e)
	return e and e.ty and e.ty.size == 8 and
		(e.op == "AUTO" or (e.op == "NAME" and not e.got))
end

-- The same plus a constant that fits the displacement.
local function simpleoff(e)
	return e and e.op == "ADD" and e.ty.size == 8 and e.right and
		e.right.op == "CONST" and type(e.right.val) == "number" and
		e.right.val >= -2147483648 and e.right.val <= 2147483647 and
		simplebase(e.left)
end

local function simplearg(e)
	if not e then return false end
	local op = e.op

	if simpleoff(e) then return true end
	-- a word or a long read from one of those, or from a base
	if op == "INDIR" and (e.ty.size == 8 or e.ty.size == 4) and
	   e.ty.kind ~= "float" and not e.bf and
	   (simpleoff(e.left) or simplebase(e.left)) then
		return true
	end
	if op == "CONST" then
		return e.val >= -2147483648 and e.val <= 2147483647
	end
	if op == "AUTO" then return true end
	if op == "NAME" then return not e.got end
	if op == "ADDR" then
		local c = e.left

		return c and (c.op == "AUTO" or
			      (c.op == "NAME" and not c.got))
	end
	return false
end

-- The ABI facts md.classify needs.  SysV keeps the two register files
-- independent, uses them for variadic arguments too, and sends a floating
-- point argument to the stack once the float file is full.
-- SysV splits a record of sixteen bytes or less into eight-byte pieces,
-- and sends anything bigger to the stack.  A variadic argument follows
-- the same rule as a named one.
-- A vector of sixteen bytes or fewer is one piece in one xmm register,
-- the SSE and SSEUP classes together; a wider one goes in memory, as it
-- does for gcc without -mavx.
local function argpieces(ty)
	if ty.vector then
		if ty.size > 16 then return nil end
		return {{off = 0, size = ty.size, flt = true}}
	end
	return md.eightbytes(ty, 16)
end

-- A result also has the x87 class: a long double _Complex comes back
-- on the x87 stack, the real part on top, and a record that holds one
-- long double comes back in st(0).  As an argument either goes in
-- memory, which argpieces says by answering nil.
local function eightbytes(ty)
	if ty.complex and ty.complex.x87 then return {x87pair = true} end
	local p, x87 = argpieces(ty)
	if x87 then return {x87one = true} end
	return p
end

local T = {ptrsize = 8, nargreg = #ARGREG, nfltreg = NFLTREG,
	   vafloat = true, vaabi = "sysv", fltspill = false, hiddenarg = true,
	   eightbytes = eightbytes, argpieces = argpieces}

-- The Microsoft convention, which UEFI firmware speaks.  Four argument
-- registers, the integer and float files stepping together so that an
-- argument's place is its position, and a record that is not the width
-- of a register handed over by address.  The caller leaves four words
-- below the stacked arguments for the callee to spill into.
local MSARG = {"%rcx", "%rdx", "%r8", "%r9"}
local MSARG32 = {"%ecx", "%edx", "%r8d", "%r9d"}
local MSSHADOW = 4

local function msonepiece(ty)
	local n = ty.size

	if n ~= 1 and n ~= 2 and n ~= 4 and n ~= 8 then return nil end
	return {{off = 0, size = n}}
end

local MST = {ptrsize = 8, nargreg = #MSARG, nfltreg = #MSARG,
	     vafloat = true, fltspill = false, hiddenarg = true,
	     positional = true, shadow = MSSHADOW, recref = true,
	     eightbytes = msonepiece}

-- Where the caller left its first stack argument, from the frame pointer.
local stackargs = 16
local nargreg = #ARGREG

-- SysV argument classification, in the one form this compiler produces:
-- every argument is a single eight-byte word, integer or floating point.
-- A call into the float runtime is marked soft and passes bit patterns as
-- integers.
local function classify(n)
	local shape = {}
	for i, a in ipairs(n.args or {}) do
		local rec = n.recs and n.recs[i]
		shape[i] = {flt = not n.soft and a.ty.kind == "float" and
				  not a.ty.x87,
			    x87 = a.ty.x87 or nil,
			    rec = rec, size = rec and rec.size or a.ty.size}
	end
	-- A record result the return registers cannot hold is written
	-- through a pointer handed over ahead of everything else.
	local ms = n.msabi and MST or nil
	local hidden = n.retrec and
		not (ms and msonepiece or eightbytes)(n.retrec) or nil
	local dest, _, fp, stk = md.classify(ms or T, shape, n.nfixed,
		hidden)
	return dest, fp, stk, hidden
end

-- Which register file the convention names its arguments in.
local function argregs(ms)
	if ms then return MSARG, MSARG32 end
	return ARGREG, ARGREG32
end

-- The instruction that moves a word between an integer place and an xmm
-- register.  A float is four bytes and a double is eight.
local function fmov(size)
	if size == 16 then return "movdqu" end
	return size == 8 and "movq" or "movd"
end

-- The same for a piece of a record: eight bytes, or a whole vector.
local function pmov(size)
	return size == 16 and "movdqu" or "movq"
end

-- Push one eight-byte word, read through an address register, in the
-- sixteen-byte frames the stack context uses.  r11 is not allocatable.
local function pushword(g, addr, off, size)
	g:write("\tsubq\t$16,%rsp\n")
	for k = 0, (size or 8) - 1, 8 do
		g:write(("\tmovq\t%d(%s),%%r11\n\tmovq\t%%r11,%d(%%rsp)\n")
			:format(off + k, addr, k))
	end
end

local function call(g, n, reg)
	local args = n.args or {}
	local dest, nflt, nstack, hidden = classify(n)
	local AR, AR32 = argregs(n.msabi)
	-- The shadow words are already counted in nstack, so a call with
	-- no stacked argument still leaves room for them.
	local bytes = ((nstack * 8 + 15) // 16) * 16

	-- Saved registers and stacked arguments sit below the stack
	-- pointer while the rest are worked out, so nothing in an argument
	-- may move it.
	g.nomove = g.nomove + 1
	for i = 0, reg - 1 do
		save(g, i)
	end
	-- Arguments that did not fit a register go in a block of their own,
	-- which stays put while the register arguments are computed on top.
	if bytes > 0 then
		g:write("\tsubq\t$" .. bytes .. ",%rsp\n")
		for i, d in ipairs(dest) do
			if d.mem then
				-- a record too big for registers: the
				-- caller leaves a copy of it on the stack
				g:expr(args[i], "reg", reg + 1)
				g:write(("\tleaq\t%d(%%rsp),%s\n")
					:format(d.stk * 8, regname(reg, 8)))
				blockcopy(g, d.size, reg)
			elseif d.stk and d.x87 then
				g:expr(args[i], "reg", reg)
				g:write("\tfldt\t" .. ldslot(g, reg) .. "\n")
				g:write(("\tfstpt\t%d(%%rsp)\n")
					:format(d.stk * 8))
			elseif d.stk then
				g:expr(args[i], "reg", reg)
				if args[i].ty.kind == "float" then
					g:write(("\tmov%s\t%s,%d(%%rsp)\n")
						:format(fsuf(args[i].ty.size),
							fregname(reg,
								args[i].ty.size),
							d.stk * 8))
				else
					g:write(("\tmovq\t%s,%d(%%rsp)\n")
						:format(regname(reg, 8),
							d.stk * 8))
				end
			end
		end
	end
	local order = {}
	if hidden then
		g:write("\tsubq\t$16,%rsp\n")
		g:write(("\tleaq\t%d(%%rbp),%%r11\n\tmovq\t%%r11,(%%rsp)\n")
			:format(n.retslot))
		order[1] = {reg = 0, size = 8}
	end
	local straight = {}
	for i, d in ipairs(dest) do
		if d.pieces then
			-- a record in registers: one push for each piece
			g:expr(args[i], "reg", reg)
			for _, p in ipairs(d.pieces) do
				local sz = p.size == 16 and 16 or 8

				pushword(g, regname(reg, 8), p.off, sz)
				order[#order + 1] = {flt = p.flt, reg = p.r,
						     size = sz}
			end
		elseif d.reg and not d.flt and simplearg(args[i]) then
			straight[#straight + 1] = {d = d, e = args[i]}
		elseif d.reg then
			order[#order + 1] = d
			g:expr(args[i], "stack", reg)
		end
	end
	-- r11 is not allocatable, so the address survives the argument pops
	if not n.direct then
		g:expr(n.left, "reg", reg)
		g:write("\tmovq\t" .. regname(reg, 8) .. ",%r11\n")
	end
	for k = #order, 1, -1 do
		local d = order[k]
		if d.flt then
			g:write(("\t%s\t(%%rsp),%%xmm%d\n")
				:format(fmov(d.size), d.reg))
		else
			g:write("\tmovq\t(%rsp)," .. AR[d.reg + 1] .. "\n")
		end
		g:write("\taddq\t$16,%rsp\n")
	end
	-- The arguments that need no working out.  Nothing left to do can
	-- disturb them, and each names a register of its own, so the order
	-- among them does not matter.
	for _, x in ipairs(straight) do
		local e, r = x.e, x.d.reg
		local w = e.ty.size == 8 and 8 or 4

		if e.op == "ADDR" then
			leato(g, e.left, AR[r + 1])
		elseif e.op == "ADD" or e.op == "INDIR" then
			-- the pointer into the argument's own register,
			-- then the constant or the load through it
			local a = e.op == "INDIR" and e.left or e
			local base = a.op == "ADD" and a.left or a
			local k = a.op == "ADD" and a.right.val or 0
			local dst = AR[r + 1]

			if e.op == "ADD" and base.op == "AUTO" and base.pin then
				g:write(("\tleaq\t%d(%s),%s\n"):format(k,
					regname(base.pin, 8), dst))
			else
				local from = base.op == "AUTO" and base.pin and
					regname(base.pin, 8)

				if not from then
					g:write(("\tmovq\t%s,%s\n")
						:format(addr(g, base), dst))
					from = dst
				end
				if e.op == "ADD" then
					g:write(("\tleaq\t%d(%s),%s\n")
						:format(k, from, dst))
				else
					g:write(("\t%s\t%d(%s),%s\n"):format(
						w == 8 and "movq" or "movl", k,
						from, (w == 8 and AR or AR32)[r + 1]))
				end
			end
		else
			g:write(("\t%s\t%s,%s\n")
				:format(w == 8 and "movq" or "movl",
					addr(g, e),
					(w == 8 and AR or AR32)[r + 1]))
		end
	end
	-- A variadic callee reads al to learn how many xmm registers it must
	-- save.  A fixed one ignores it.  The Microsoft convention says
	-- nothing about al, so a call that speaks it leaves al alone.
	-- A callee with a prototype that is not variadic reads nothing
	-- in al.
	if not n.msabi and not n.proto then
		g:write("\tmovl\t$" .. nflt .. ",%eax\n")
	end
	if n.direct then
		g:write("\tcall\t" .. n.left.sym .. "\n")
	elseif g.o.retpoline then
		-- The thunk jumps to what r11 holds, without leaving the
		-- branch predictor anything to guess with.
		g:write("\tcall\t" .. THUNK .. "\n")
	else
		g:write("\tcall\t*%r11\n")
	end
	-- Wipe the return address the call left below the stack pointer,
	-- which is nothing the rest of the program should be able to read.
	if g.o.retclean then
		g:write("\tmovq\t$0,-8(%rsp)\n")
	end
	if bytes > 0 then
		g:write("\taddq\t$" .. bytes .. ",%rsp\n")
	end
	if n.retrec and eightbytes(n.retrec) and
	   eightbytes(n.retrec).x87pair then
		g:write(("\tfstpt\t%d(%%rbp)\n\tfstpt\t%d(%%rbp)\n")
			:format(n.retslot, n.retslot + 16))
	elseif n.retrec and eightbytes(n.retrec) and
	   eightbytes(n.retrec).x87one then
		g:write(("\tfstpt\t%d(%%rbp)\n"):format(n.retslot))
	elseif n.retrec then
		-- A record that came back in registers is dropped into the
		-- slot the caller set aside; one written through the hidden
		-- pointer is there already.
		local ni, nf = 0, 0
		for _, p in ipairs(eightbytes(n.retrec) or {}) do
			local at = ("%d(%%rbp)"):format(n.retslot + p.off)
			if p.flt then
				g:write(("\t%s\t%%xmm%d,%s\n")
					:format(pmov(p.size), nf, at))
				nf = nf + 1
			else
				g:write(("\tmovq\t%s,%s\n")
					:format(ni == 0 and "%rax" or "%rdx", at))
				ni = ni + 1
			end
		end
	elseif n.ty.x87 then
		-- The extended type comes back on the x87 stack.
		g:write("\tfstpt\t" .. ldslot(g, reg) .. "\n")
	elseif n.ty.kind == "float" then
		-- A soft call answers with a bit pattern in rax; the ABI
		-- answers in xmm0.  Either way it belongs in the float file.
		if n.soft then
			-- the ABI answers in rax, whatever depth this is
			g:write(("\t%s\t%s,%s\n"):format(fmov(n.ty.size),
				n.ty.size == 8 and "%rax" or "%eax",
				fregname(reg, n.ty.size)))
		else
			g:write(("\tmov%s\t%%xmm0,%s\n")
				:format(fsuf(n.ty.size), fregname(reg, n.ty.size)))
		end
	elseif n.ty.kind == "void" then
		-- nothing came back
	elseif n.ty.size == 1 or n.ty.size == 2 then
		-- The callee owes only the low bits of a narrow answer and
		-- the rest is whatever was in the register.  Every other
		-- way a value reaches one leaves it widened, so this one
		-- has to as well.
		local uns = n.ty.kind == "uint" or n.ty.isbool

		g:write(("\tmov%s%s\t%s,%s\n"):format(uns and "z" or "s",
			n.ty.size == 1 and "bl" or "wl",
			n.ty.size == 1 and "%al" or "%ax",
			regname(reg, 4)))
	elseif reg ~= 0 then
		-- at depth zero the answer is where it has to be
		g:write("\tmovq\t%rax," .. regname(reg, 8) .. "\n")
	end
	for i = reg - 1, 0, -1 do
		restore(g, i)
	end
	g.nomove = g.nomove - 1
end

-- The stack protector.  The prologue drops a copy of a value the loader
-- randomised just under the return address; the epilogue reads it back
-- and calls the handler when it came back changed.
-- The name of the value and the name of the handler.  A kernel asks
-- for the two the platform settles on with
-- `-mstack-protector-guard=global`, and defines both itself.
local GUARD = "__guard_local"
local SMASH = "__stack_smash_handler"

-- Where the canary is read from.  A per-cpu one is named through the
-- segment the machine keeps its per-cpu words in; anything else is a
-- plain name, reached from where the code stands.
local function guardat(g)
	local sym = g.o.guardsym or GUARD

	if g.o.guardreg then
		return ("%%%s:%s"):format(g.o.guardreg, sym)
	end
	return sym .. "(%rip)"
end

local function setguard(g, guard, name)
	g:write("\tmovq\t" .. guardat(g) .. ",%r11\n")
	g:write(("\tmovq\t%%r11,%d(%%rbp)\n"):format(guard.off))
	-- The handler names the function it was called from.
	guard.label = ".Lssp" .. name
	g:write("\t.pushsection\t.rodata\n")
	g:write(guard.label .. ":\n")
	g:write(("\t.asciz\t%q\n"):format(name))
	g:write("\t.popsection\n")
end

local function checkguard(g, guard)
	local bad = ".Lsmash" .. guard.label:sub(6)

	g:write(("\tmovq\t%d(%%rbp),%%r11\n"):format(guard.off))
	g:write("\txorq\t" .. guardat(g) .. ",%r11\n")
	g:write("\tjne\t" .. bad .. "\n")
	return bad
end

-- Frame setup is the calling convention, not the code table.  The parser
-- classifies each parameter; this places it.  Structs are not passed by
-- value.
local function prologue(g, name, frame, params, vabase, static, recret,
			sec, guard)
	-- A section the program asked for by name, which a link
	-- script places where the machine needs it.
	g:write(sec and ("\t.section\t" .. sec .. ",\"ax\",@progbits\n")
		or "\t.text\n")
	if not static then
		g:write("\t.globl\t" .. name .. "\n")
	end
	-- A function starts on sixteen bytes, as the system compiler's
	-- do: where the code falls in the fetch window otherwise moves
	-- its speed by a tenth from one build to the next.
	g:write("\t.p2align\t4\n" .. name .. ":\n")
	g:landing()
	g:write("\tpushq\t%rbp\n\tmovq\t%rsp,%rbp\n")
	if frame > 0 then
		g:write("\tsubq\t$" .. frame .. ",%rsp\n")
	end
	-- The registers this body keeps a local in belong to the
	-- caller, so its copy goes in the frame first.
	for _, k in ipairs(g.pinsave or {}) do
		g:write(("\tmovq\t%s,%d(%%rbp)\n")
			:format(regname(k.reg, 8), k.off))
	end
	if guard then setguard(g, guard, name) end
	-- The caller handed over where to write a record result.
	if recret and recret.ptr then
		g:write(("\tmovq\t%s,%d(%%rbp)\n")
			:format(ARGREG[1], recret.ptr))
	end
	-- Everything that arrived in a register is put away first: the
	-- copies below use those same registers as scratch.
	for _, d in ipairs(params or {}) do
		if d.pieces then
			-- a record in registers, one piece a register
			for _, p in ipairs(d.pieces) do
				local at = ("%d(%%rbp)"):format(d.off + p.off)
				if p.flt then
					g:write(("\t%s\t%%xmm%d,%s\n")
						:format(pmov(p.size), p.r, at))
				else
					g:write(("\tmovq\t%s,%s\n")
						:format(ARGREG[p.r + 1], at))
				end
			end
		elseif d.reg and d.flt then
			g:write(("\t%s\t%%xmm%d,%d(%%rbp)\n")
				:format(fmov(d.size), d.reg, d.off))
		elseif d.reg and d.into then
			-- A local kept in a register takes the argument
			-- straight from the one it arrived in; the slot
			-- has no reader and needs no store.
			g:write(("\tmovq\t%s,%s\n"):format(
				ARGREG[d.reg + 1], regname(d.into, 8)))
		elseif d.reg then
			g:write("\tmovq\t" .. ARGREG[d.reg + 1] .. "," ..
				d.off .. "(%rbp)\n")
		end
	end
	-- A variadic function keeps every argument register in the System V
	-- save area: the six integer ones, then the eight floating point
	-- ones sixteen bytes apart, which is the layout the system's own
	-- va_list walks.
	if vabase then
		for i = 1, #ARGREG do
			g:write(("\tmovq\t%s,%d(%%rbp)\n")
				:format(ARGREG[i], vabase + (i - 1) * 8))
		end
		for i = 1, (g.o.nosse and 0 or NFLTREG) do
			g:write(("\tmovq\t%%xmm%d,%d(%%rbp)\n")
				:format(i - 1,
					vabase + #ARGREG * 8 + (i - 1) * 16))
		end
	end
	for _, d in ipairs(params or {}) do
		if d.mem then
			-- a record the caller left on its own stack
			g:write(("\tleaq\t%d(%%rbp),%%rax\n")
				:format(d.off))
			g:write(("\tleaq\t%d(%%rbp),%%rsi\n")
				:format(stackargs + d.stk * 8))
			blockcopy(g, d.size, 0)
		elseif not d.reg and not d.pieces then
			-- the caller left it above the return address
			for k = 0, (d.words or 1) - 1 do
				g:write(("\tmovq\t%d(%%rbp),%%rax\n" ..
					 "\tmovq\t%%rax,%d(%%rbp)\n")
					:format(stackargs + (d.stk + k) * 8,
						d.off + k * 8))
			end
		end
	end
end

-- The i-th eight-byte local, counting from one.
local function slot(i)
	return -8 * i
end

-- The result is already in the first allocation-order register, which is
-- also the one the ABI returns in.  A floating point result has to cross
-- into xmm0 first, because this compiler keeps it as a bit pattern.
local function epilogue(g, frame, fltret, wideret, recret, guard)
	if recret and recret.cls and recret.cls.x87pair then
		g:write(("\tfldt\t%d(%%rbp)\n\tfldt\t%d(%%rbp)\n")
			:format(recret.off + 16, recret.off))
	elseif recret and recret.cls and recret.cls.x87one then
		g:write(("\tfldt\t%d(%%rbp)\n"):format(recret.off))
	elseif recret and recret.cls then
		-- The result sits in a slot of ours; hand back the pieces.
		local ni, nf = 0, 0
		for _, p in ipairs(recret.cls) do
			local at = ("%d(%%rbp)"):format(recret.off + p.off)
			if p.flt then
				g:write(("\t%s\t%s,%%xmm%d\n")
					:format(pmov(p.size), at, nf))
				nf = nf + 1
			else
				g:write(("\tmovq\t%s,%s\n")
					:format(at, ni == 0 and "%rax" or
						"%rdx"))
				ni = ni + 1
			end
		end
	elseif recret then
		-- Too big for the registers: write it through the caller's
		-- pointer, and hand that pointer back as the ABI asks.
		g:write(("\tmovq\t%d(%%rbp),%%rax\n"):format(recret.ptr))
		g:write(("\tleaq\t%d(%%rbp),%%rsi\n"):format(recret.off))
		blockcopy(g, recret.size, 0)
		g:write(("\tmovq\t%d(%%rbp),%%rax\n"):format(recret.ptr))
	elseif fltret == 16 then
		-- the extended type goes back on the x87 stack
		g:write("\tfldt\t" .. ldslot(g, 0) .. "\n")
	elseif fltret then
		g:write(("\tmov%s\t%s,%%xmm0\n")
			:format(fsuf(fltret), fregname(0, fltret)))
	end
	-- What the caller had in the registers this body kept a local
	-- in.  After the result is in place: one of them may be where
	-- the result came from.
	for _, k in ipairs(g.pinsave or {}) do
		g:write(("\tmovq\t%d(%%rbp),%s\n")
			:format(k.off, regname(k.reg, 8)))
	end
	if not guard then
		return g:write("\tleave\n" .. retinsn(g))
	end
	-- The check comes after the result is in place, and reads r11,
	-- which no value is ever allocated to.
	local bad = checkguard(g, guard)

	g:write("\tleave\n" .. retinsn(g))
	g:write(bad .. ":\n")
	g:write("\tleaq\t" .. guard.label .. "(%rip),%rdi\n")
	g:write("\txorl\t%esi,%esi\n")
	g:write("\tcall\t" .. (g.o.guardfail or SMASH) .. "\n")
end

local function jump(g, label)
	g:write("\tjmp\t" .. label .. "\n")
end

-- GNU labels as values: the address is in a register.
local function jumpto(g, reg)
	if g.o.retpoline then
		g:write("\tmovq\t" .. regname(reg, 8) .. ",%r11\n")
		return g:write("\tjmp\t" .. THUNK .. "\n")
	end
	g:write("\tjmp\t*" .. regname(reg, 8) .. "\n")
end

-- Where an indirect branch is allowed to arrive, for the hardware that
-- checks.  It reads as a nop on a machine that does not.
local function landing(g)
	g:write("\tendbr64\n")
end

-- Frame bytes for n eight-byte locals, kept sixteen-byte aligned.
local function frame(n)
	return ((8 * n + 15) // 16) * 16
end

-- The widths a plain store writes.
local STW = {movb = 1, movw = 2, movl = 4, movq = 8, movd = 4, movss = 4,
	     movsd = 8}

-- The label a line defines, and the rest of the line after it.
local function labeldef(l)
	local name, rest = l:match("^%s*([%w_.$]+):(.*)$")

	return name, rest or l
end

-- Colour the words in `share` so that two whose values are wanted at the
-- same time never meet.  Liveness runs over the blocks the labels and the
-- jumps cut the text into.  A line that names a label is taken to jump
-- there, which covers the tables inline asm writes into other sections.
-- Only a plain store at least as wide as every value the word holds
-- ends a value; any other mention reads it.
local function framecolor(lines, refs, share, whole)
	local nl = #lines
	local named, numbered = {}, {}

	for i, l in ipairs(lines) do
		local name = labeldef(l)

		if name then
			if name:match("^%d+$") then
				local t = numbered[name] or {}

				numbered[name] = t
				t[#t + 1] = i
			else
				named[name] = i
			end
		end
	end
	-- Where the labels a line names are defined.
	local function targets(i, l)
		local _, rest = labeldef(l)
		local out

		if rest:match("^%s+call") then return nil end
		for tok in rest:gmatch("[%w_.$]+") do
			local at = named[tok]
			local num, dir = tok:match("^(%d+)([bf])$")

			if num and numbered[num] then
				for _, p in ipairs(numbered[num]) do
					if dir == "b" and p <= i then
						at = p
					elseif dir == "f" and p > i then
						at = at or p
					end
				end
			end
			if at then
				out = out or {}
				out[#out + 1] = at
			end
		end
		return out
	end

	-- Cut into blocks.
	local lead, jumps, stop = {[1] = true}, {}, {}
	for i, l in ipairs(lines) do
		local name = labeldef(l)
		local _, rest = labeldef(l)
		local op = rest:match("^%s+([%a%d]+)")

		if name then lead[i] = true end
		jumps[i] = targets(i, l)
		if jumps[i] or (op and (op:match("^j") or op:match("^ret"))) then
			lead[i + 1] = true
		end
		if op == "jmp" or (op and op:match("^ret")) then
			stop[i] = true
		end
	end
	local bstart, bof = {}, {}
	for i = 1, nl do
		if lead[i] then bstart[#bstart + 1] = i end
		bof[i] = #bstart
	end
	local nb = #bstart
	local function bend(b) return (bstart[b + 1] or nl + 1) - 1 end

	-- What each line kills and reads.
	local kill, use = {}, {}
	for i = 1, nl do
		local r = refs[i]

		if r then
			local l = lines[i]
			local op, d = l:match("^%s+(mov%a*)%s+[^,(]*,%s*(%-%d+)%(%%rbp%)%s*$")
			local k

			if op and STW[op] then
				local a = tonumber(d)

				if share[a] and STW[op] >= (whole[a] or 9) then
					k = a
				end
			end
			for _, a in ipairs(r) do
				local w = (a // 8) * 8

				if share[w] and w ~= k then
					use[i] = use[i] or {}
					use[i][w] = true
				end
			end
			kill[i] = k
		end
	end

	local succ = {}
	for b = 1, nb do
		local s, e = {}, bend(b)

		if not stop[e] and b < nb then s[b + 1] = true end
		for i = bstart[b], e do
			for _, t in ipairs(jumps[i] or {}) do s[bof[t]] = true end
		end
		succ[b] = s
	end

	-- Upward-exposed reads and kills per block, then the fixed point.
	local ue, kl = {}, {}
	for b = 1, nb do
		local u, k = {}, {}

		for i = bend(b), bstart[b], -1 do
			if kill[i] then u[kill[i]] = nil k[kill[i]] = true end
			for w in pairs(use[i] or {}) do u[w] = true end
		end
		ue[b], kl[b] = u, k
	end
	local livein = {}
	for b = 1, nb do livein[b] = {} end
	local changed = true
	while changed do
		changed = false
		for b = nb, 1, -1 do
			local li = livein[b]

			for w in pairs(ue[b]) do
				if not li[w] then li[w] = true changed = true end
			end
			for s in pairs(succ[b]) do
				for w in pairs(livein[s]) do
					if not li[w] and not kl[b][w] then
						li[w] = true
						changed = true
					end
				end
			end
		end
	end

	-- Two words meet when one is named while the other is live.
	local edge = {}
	for w in pairs(share) do edge[w] = {} end
	for b = 1, nb do
		local live = {}

		for s in pairs(succ[b]) do
			for w in pairs(livein[s]) do live[w] = true end
		end
		for i = bend(b), bstart[b], -1 do
			local k, u = kill[i], use[i]

			if k or u then
				local function meet(x)
					for y in pairs(live) do
						if y ~= x then
							edge[x][y] = true
							edge[y][x] = true
						end
					end
				end
				if k then meet(k) live[k] = nil end
				for w in pairs(u or {}) do meet(w) end
				for w in pairs(u or {}) do live[w] = true end
			end
		end
	end

	local order = {}
	for w in pairs(share) do order[#order + 1] = w end
	table.sort(order, function(a, b) return a > b end)
	local color, ncolor = {}, 0
	for _, w in ipairs(order) do
		local taken = {}

		for y in pairs(edge[w]) do
			if color[y] then taken[color[y]] = true end
		end
		local c = 1
		while taken[c] do c = c + 1 end
		color[w] = c
		if c > ncolor then ncolor = c end
	end
	return {color = color, n = ncolor}
end

-- Give the finished body the smallest frame it can have.  `objs` lists
-- every slot the parser handed out as offset, words and the store width
-- that replaces the value.  A word that only single-word objects cover
-- and whose address is never taken may share its place with another
-- whose value is never wanted at the same time; one nothing names goes.
-- Everything else keeps a place of its own, in the same order.
-- Answers the text and the number of words saved.
-- A frame holding an object that wants sixteen-byte alignment keeps
-- its layout: moving words could split the alignment.
local function compact(text, objs, n, guard, align)
	if align and next(align) then return text, 0 end
	local multi, single, whole = {}, {}, {}

	for i = 1, #objs, 3 do
		local off, words, w = objs[i], objs[i + 1], objs[i + 2]

		for k = 0, words - 1 do
			local at = off + 8 * k

			if words > 1 or w < 0 then
				multi[at] = true
			else
				single[at] = true
				if w > (whole[at] or 0) then whole[at] = w end
			end
		end
	end

	local lines = {}
	for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
	if lines[#lines] == "" then lines[#lines] = nil end

	-- The words each line names, and which of them lose their address.
	local refs, used, escaped = {}, {}, {}
	for i, l in ipairs(lines) do
		local r
		for d in l:gmatch("(%-%d+)%(%%rbp") do
			local w = (tonumber(d) // 8) * 8

			if w >= -8 * n then
				r = r or {}
				r[#r + 1] = tonumber(d)
				used[w] = true
				if l:match("^%s+lea") then escaped[w] = true end
			end
		end
		refs[i] = r
	end

	-- A jump to an address in a register, or a call that returns
	-- twice, goes where no label says.
	local blind = text:find("jmp%s+%*") or
		text:find("call%s+[%w_]*setjmp") or
		text:find("call%s+[%w_]*vfork") or
		text:find("call%s+[%w_]*getcontext") or
		text:find("call%s+[%w_]*savectx")
	local share = {}
	if not blind then
		for w in pairs(used) do
			if single[w] and not multi[w] and not escaped[w] and
			   w ~= guard then
				share[w] = true
			end
		end
	end

	-- The fixed words keep their order nearest the frame pointer; a
	-- word no object covers belongs to the generator and stays too.
	local place, nfixed = {}, 0
	for i = 1, n do
		local w = -8 * i

		if not share[w] and
		   (used[w] or multi[w] or not single[w] or w == guard) then
			nfixed = nfixed + 1
			place[w] = -8 * nfixed
		end
	end

	local ncolor = 0
	if next(share) then
		ncolor = framecolor(lines, refs, share, whole)
		for w, c in pairs(ncolor.color) do
			place[w] = -8 * (nfixed + c)
		end
		ncolor = ncolor.n
	end

	local changed = false
	for w, p in pairs(place) do
		if w ~= p then changed = true break end
	end
	local total = nfixed + ncolor
	if not changed and total == n then return text, 0 end

	for i, l in ipairs(lines) do
		if refs[i] then
			lines[i] = l:gsub("(%-%d+)(%(%%rbp)", function(d, rest)
				local a = tonumber(d)
				local w = (a // 8) * 8
				local p = place[w]

				if not p or w < -8 * n then return nil end
				return (p + a - w) .. rest
			end)
		end
	end
	text = table.concat(lines, "\n") .. "\n"
	local old, new = frame(n), frame(total)
	local pro = "\tmovq\t%rsp,%rbp\n\tsubq\t$" .. old .. ",%rsp\n"
	local at = text:find(pro, 1, true)

	if at then
		local repl = "\tmovq\t%rsp,%rbp\n" ..
			(new > 0 and "\tsubq\t$" .. new .. ",%rsp\n" or "")

		text = text:sub(1, at - 1) .. repl .. text:sub(at + #pro)
	else
		-- Without the prologue in hand the frame keeps its size.
		assert(total <= n)
	end
	return text, n - total
end

-- What a header is entitled to ask the compiler about the machine.
local predef = {
	__x86_64__ = "1", __x86_64 = "1", __amd64__ = "1", __amd64 = "1",
	__LP64__ = "1", _LP64 = "1",
	__SIZEOF_POINTER__ = "8", __SIZEOF_LONG__ = "8",
	__SIZEOF_LONG_LONG__ = "8", __SIZEOF_INT__ = "4",
	__SIZEOF_SHORT__ = "2", __SIZEOF_DOUBLE__ = "8",
	__SIZEOF_FLOAT__ = "4", __SIZEOF_SIZE_T__ = "8",
	__SIZEOF_INT128__ = "16",
	__CHAR_BIT__ = "8", __ORDER_LITTLE_ENDIAN__ = "1234",
	__ORDER_BIG_ENDIAN__ = "4321", __BYTE_ORDER__ = "1234",
	__ELF__ = "1",
}

if LDBL80 then
	-- Sixteen bytes, with ten bytes of value in them.
	predef.__SIZEOF_LONG_DOUBLE__ = "16"
	predef.__LDBL_MANT_DIG__ = "64"
	predef.__LDBL_DIG__ = "18"
	predef.__LDBL_MIN_EXP__ = "(-16381)"
	predef.__LDBL_MAX_EXP__ = "16384"
	predef.__LDBL_MIN_10_EXP__ = "(-4931)"
	predef.__LDBL_MAX_10_EXP__ = "4932"
	predef.__LDBL_DECIMAL_DIG__ = "21"
	predef.__LDBL_EPSILON__ = "1.08420217248550443400745280086994171e-19L"
	predef.__LDBL_MIN__ = "3.36210314311209350626267781732175260e-4932L"
	predef.__LDBL_MAX__ = "1.18973149535723176502126385303097021e+4932L"
	predef.__LDBL_NORM_MAX__ = predef.__LDBL_MAX__
	predef.__LDBL_DENORM_MIN__ =
		"3.64519953188247460252840593361941982e-4951L"
end

-- The peephole rules.  Each reads the last few lines and answers with
-- what goes in their place, or nothing to leave them alone.
local MOV = {movb = 1, movw = 2, movl = 4, movq = 8}

local function isreg(x) return x and x:sub(1, 1) == "%" end

-- Which machine register a name stands for, whatever width it was
-- written at: %rax, %eax, %ax and %al are one register, and a rule
-- that asks whether a value dies has to know that.
local WHICH = {}
for i, names in pairs{
	[0] = {"al", "ax", "eax", "rax"},
	{"bl", "bx", "ebx", "rbx"}, {"cl", "cx", "ecx", "rcx"},
	{"dl", "dx", "edx", "rdx"}, {"sil", "si", "esi", "rsi"},
	{"dil", "di", "edi", "rdi"}, {"bpl", "bp", "ebp", "rbp"},
	{"spl", "sp", "esp", "rsp"},
	{"r8b", "r8w", "r8d", "r8"}, {"r9b", "r9w", "r9d", "r9"},
	{"r10b", "r10w", "r10d", "r10"}, {"r11b", "r11w", "r11d", "r11"},
	{"r12b", "r12w", "r12d", "r12"}, {"r13b", "r13w", "r13d", "r13"},
	{"r14b", "r14w", "r14d", "r14"}, {"r15b", "r15w", "r15d", "r15"},
} do
	for _, n in ipairs(names) do WHICH["%" .. n] = i end
end

-- The branch that asks the opposite question.
local INVCC = {}
for a, b in pairs{e = "ne", l = "ge", le = "g", b = "ae", be = "a",
		  s = "ns", p = "np", o = "no", c = "nc"} do
	INVCC["j" .. a], INVCC["j" .. b] = "j" .. b, "j" .. a
end
for k, v in pairs(INVCC) do INVCC[k] = v:sub(2) end

local peeprules = {
	-- Nothing can reach what stands after an unconditional
	-- branch, and a window never spans a label.  It is bytes for
	-- nothing either way, and a validator that walks the code
	-- says so out loud.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if (a.mnem == "jmp" or a.mnem == "ret") and b.mnem then
			return {a}
		end
	end},

	-- A move from a register to itself.  Every call ends with one,
	-- because the result is already where the caller wanted it.
	-- Not movl: that one clears the upper half, and it is how an
	-- unsigned int is widened after a 64-bit add.
	{n = 1, f = function(w, i)
		local a = w[i]

		if MOV[a.mnem or ""] and a.mnem ~= "movl" and a.a and
		   a.a == a.b then
			return {}
		end
	end},

	-- The same register stored to the same frame slot twice in a
	-- row.  Locals that share a slot each take their copy, and
	-- READ_ONCE's statement expression makes three.  A second
	-- write of the value just written changes nothing.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem and MOV[a.mnem] and a.mnem == b.mnem and
		   a.a == b.a and a.b == b.b and a.a and a.a:match("^%%") and
		   a.b and a.b:match("%(%%rbp%)$") then
			return {a}
		end
	end},

	-- A branch over a branch: the test turns around and the jump in
	-- the middle is what is left.  The generator writes this for
	-- every `if` whose body the code table could not fall into.
	{n = 3, f = function(w, i)
		local a, b, c = w[i], w[i + 1], w[i + 2]
		local inv = a.mnem and INVCC[a.mnem]

		if inv and b.mnem == "jmp" and b.a and c.label and
		   a.a == c.label then
			return {peep.line("\tj" .. inv .. "\t" .. b.a), c}
		end
	end},

	-- A jump to the line below it.  The end of every function has one,
	-- because a return is written as a jump to the epilogue.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem == "jmp" and b.label and a.a == b.label then
			return {b}
		end
	end},

	-- A value pushed and taken straight back.  An argument computed
	-- while the one before it is still on the stack leaves this.
	{n = 4, f = function(w, i)
		local a, b, c, d = w[i], w[i + 1], w[i + 2], w[i + 3]

		if a.mnem == "subq" and a.a == "$16" and a.b == "%rsp" and
		   b.mnem == "movq" and b.b == "(%rsp)" and
		   c.mnem == "movq" and c.a == "(%rsp)" and
		   d.mnem == "addq" and d.a == "$16" and d.b == "%rsp" then
			if b.a == c.b then return {} end
			return {peep.line(("\tmovq\t%s,%s"):format(b.a, c.b))}
		end
	end},

	-- A value put down and never taken back: the store is dead and
	-- the room it went in comes straight back.  The rule above
	-- leaves this where another rule took the load away first.
	{n = 3, f = function(w, i)
		local a, b, c = w[i], w[i + 1], w[i + 2]

		if a.mnem == "subq" and a.a == "$16" and a.b == "%rsp" and
		   MOV[b.mnem or ""] and b.b == "(%rsp)" and
		   c.mnem == "addq" and c.a == "$16" and c.b == "%rsp" then
			return {}
		end
	end},

	-- An address made by adding a constant, and read once: the
	-- constant is the displacement and the add is nothing.  A
	-- member reached through a pointer is written this way, so
	-- `p->a * p->b + p->c` writes it three times.
	--
	-- The add may go only where its result dies at once, which is
	-- where the load writes the same register back.  A store
	-- through the address leaves it live and is not touched, and
	-- neither is an instruction that reads its destination as well
	-- as writing it: `addq $8,%rax; addq (%rax),%rax` is not
	-- `addq 8(%rax),%rax`.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem ~= "addq" and a.mnem ~= "addl" then return end
		local k = a.a and a.a:match("^%$(%-?%d+)$")

		if not k or k == "0" or not isreg(a.b) then return end
		if not (b.mnem and b.mnem:sub(1, 3) == "mov") then return end
		if b.a ~= "(" .. a.b .. ")" or not isreg(b.b) then return end
		if WHICH[b.b] == nil or WHICH[b.b] ~= WHICH[a.b] then
			return
		end
		return {peep.line(("\t%s\t%s(%s),%s")
			:format(b.mnem, k, a.b, b.b))}
	end},

	-- A move back the way it came.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if MOV[a.mnem or ""] and a.mnem == b.mnem and
		   isreg(a.a) and isreg(a.b) and
		   a.a == b.b and a.b == b.a then
			return {a}
		end
	end},

	-- A store read straight back out of the same place.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if MOV[a.mnem or ""] and a.mnem == b.mnem and
		   isreg(a.a) and a.b and not isreg(a.b) and
		   a.b == b.a and a.a == b.b then
			return {a}
		end
	end},
}

-- Without this the linker assumes the stack must be executable, and
-- refuses to load the result as a shared object.
local trailer = '\t.section\t.note.GNU-stack,"",@progbits\n'

return md.target{
	name = "amd64",
	ptrsize = 8,
	predef = predef,
	charsigned = true,
	alloca = true,
	tls = true,
	-- Three, not six.  Measured over 192 KB of Lua, the output is
	-- byte for byte the same at six, five, four and three, and
	-- grows by 96 bytes at two: a Sethi-Ullman expression is two
	-- or three deep and the rest was never reached.  What the
	-- other three buy is `freeregs` below.
	nreg = 3,
	-- Past the evaluator, where the allocator over a recorded body
	-- keeps locals.  r10 is caller-saved, so it needs no save, and
	-- holds only a local never live across a call.  r8 and r9 carry
	-- the fifth and sixth argument, so a call sets them up before it
	-- runs and a local there dies though it never crosses the call;
	-- blockcopy has r11.  r13 to r15 are the callee's to give back.
	freeregs = {5, 8, 9, 10},
	-- The three of those the ABI asks the callee to give back,
	-- which hold a local across a call or a record copy.
	-- blockcopy reaches no higher than r12; see pinregs.
	savedregs = {[8] = true, [9] = true, [10] = true},
	-- A held local is read in place by templates written for a
	-- word or a long; a byte or a half there would need widening.
	canhold = function(reg, size) return size >= 4 end,
	-- How text already written names a frame slot.
	frameref = "(%-?%d+)%(%%rbp%)",
	-- A name may carry a constant offset: `g+12(%rip)` is an operand.
	nameoff = true,
	-- Past the allocation order, so no expression is ever using
	-- one, and the ABI asks the callee to give them back, so a
	-- value in one survives a call.  What a local kept in a
	-- register is kept in.
	--
	-- Not six or seven.  blockcopy borrows the two registers above
	-- the one it is given, and it may be given the last of the
	-- allocation order, so it reaches index seven -- which is r12.
	-- A record copied by value would land on a local kept there.
	pinregs = {8, 9, 10},
	-- How far an inline asm may reach for scratch: past nreg the
	-- register is one the ABI wants back, so it is saved first.
	nasmreg = 11,
	recabi = true,
	ldbl = LDBL80 and "f80" or nil,
	peep = peeprules,
	hiddenarg = true,
	eightbytes = eightbytes,
	argpieces = argpieces,
	-- rbp is on a sixteen-byte boundary.
	framebias = 0,
	regname = regname,
	fregname = fregname,
	vregname = vregname, vmove = vmove,
	ldslot = LDBL80 and ldslot or nil,
	asmx87 = LDBL80 and asmx87 or nil,
	asmx87drop = LDBL80 and asmx87drop or nil,
	hwfloat = true,
	half = true,
	-- The registers an exception handler's data arrives in, in DWARF
	-- numbering: rax and rdx.
	ehregs = {0, 1},
	suffix = suffix,
	addr = addr,
	dcalc = dcalc,
	mnem = mnem,
	branch = branch,
	adapt = adapt,
	save = save,
	restore = restore,
	call = call,
	-- A place named through a register, for an asm memory operand.
	memreg = function(r) return "(" .. regname(r, 8) .. ")" end,
	jumpto = jumpto,
	landing = landing,
	asmreg = asmreg,
	-- Where a frame is and what it remembers: the register the
	-- prologue leaves pointing at it, how far from there the
	-- return address sits, and how far the frame before it.
	frameptr = "rbp",
	retaddroff = 8,
	prevframeoff = 0,
	hardreg = hardreg,
	readhard = readhard,
	asmfits = asmfits,
	asmpin = asmpin,
	asmkeep = asmkeep,
	asmimm = asmimm,
	asmaddr = asmaddr,
	asmflag = asmflag,
	rawmove = rawmove,
	move = move,
	blockcopy = blockcopy,
	convert = convert,
	data = data,
	prologue = prologue,
	stackargs = stackargs,
	nargreg = nargreg,
	nfltreg = NFLTREG,
	vafloat = T.vafloat,
	vaabi = T.vaabi,
	fltspill = T.fltspill,
	epilogue = epilogue,
	slot = slot,
	frame = frame,
	compact = compact,
	jump = jump,
	code = code,
	trailer = trailer,
}
