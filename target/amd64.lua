-- amd64, AT&T syntax.
--
-- Everything machine dependent lives here: register names, the address
-- forms, the difficulty override, and the code tables.  A new target is a
-- file of the same shape; nothing above this reaches into it.

local md = require "md"
local peep = require "peep"
local data = require "data"
local tree = require "tree"

-- Whether long double is the x87 extended type the ABI asks for, or
-- the double it has been until the rest of that is written.  The type
-- itself, its constants and its layout are done; the arithmetic and
-- the calling convention are not.
local LDBL80 = false

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

-- The scalar suffix: sd for a double, ss for a float.
local function fsuf(size)
	return size == 8 and "sd" or "ss"
end

-- The operand text for a node the instruction can address directly.
local function addr(g, n)
	local op = n.op
	if op == "CONST" then
		return "$" .. n.val
	elseif op == "NAME" then
		if n.got then return n.sym .. "@GOTPCREL(%rip)" end
		return n.sym .. "(%rip)"
	elseif op == "AUTO" then
		return n.off .. "(%rbp)"
	end
	error("cannot address " .. op .. " directly on amd64")
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
	g:write("\tsubq\t$16,%rsp\n")
	if g.fdepth[i] then
		g:write("\tmovsd\t" .. fregname(i, 8) .. ",(%rsp)\n")
	else
		g:write("\tmovq\t" .. regname(i, 8) .. ",(%rsp)\n")
	end
end

local function restore(g, i)
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
		if flt then
			g:write("\tmovsd\t" .. fregname(reg, 8) ..
				",(%rsp)\n")
		else
			g:write("\tmovq\t" .. regname(reg, 8) ..
				",(%rsp)\n")
		end
	elseif ctx == "cc" then
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
		{"z", "z",          asm = "\txor%z\t%R,%R"},
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
	ADDR  = {{"i", "z", asm = "\tlea%z\t%A1,%R"}},
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
		{"n*", "n", rz = 1, ev = "R L1*",  asm = "\tmov%z1\t%R,(%P1)"},
	},
}

-- An assignment used for its value stores, then leaves the value behind.
code.reg.ASGN = {
	{"i",  "n", rz = 1, ev = "R",      asm = "\tmov%z1\t%R,%A1"},
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

local function convert(g, from, to, reg)
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
local function blockcopy(g, size, reg)
	local d, s = regname(reg, 8), regname(reg + 1, 8)
	local off = 0
	for _, w in ipairs{8, 4, 2, 1} do
		while size - off >= w do
			local r = regname(reg + 2, w)
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

local function asmimm(v)
	return "$" .. v
end

local function rawmove(g, dst, src, size)
	if dst == src then return end
	g:write(("\tmov%s\t%s,%s\n"):format(SUFFIX[size] or "q", src, dst))
end

local function move(g, dst, src, size, flt)
	size = size or 8
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

-- A call is not a table entry: the argument count varies, so the generator
-- hands the node here.  Everything allocatable is caller saved, so whatever
-- is still live gets saved around it.
local ARGREG = {"%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"}
local ARGREG32 = {"%edi", "%esi", "%edx", "%ecx", "%r8d", "%r9d"}
local NFLTREG = 8

-- An argument the machine can name in one instruction: nothing between
-- here and the call can change what it means, so it goes straight into
-- its own register at the end and never touches the stack.
local function simplearg(e)
	if not e then return false end
	local op = e.op

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
local function eightbytes(ty)
	return md.eightbytes(ty, 16)
end

local T = {ptrsize = 8, nargreg = #ARGREG, nfltreg = NFLTREG,
	   vafloat = true, vaabi = "sysv", fltspill = false, hiddenarg = true,
	   eightbytes = eightbytes}

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
		shape[i] = {flt = not n.soft and a.ty.kind == "float",
			    rec = rec, size = rec and rec.size or a.ty.size}
	end
	-- A record result the return registers cannot hold is written
	-- through a pointer handed over ahead of everything else.
	local hidden = n.retrec and not eightbytes(n.retrec) or nil
	local dest, _, fp, stk = md.classify(T, shape, n.nfixed, hidden)
	return dest, fp, stk, hidden
end

-- The instruction that moves a word between an integer place and an xmm
-- register.  A float is four bytes and a double is eight.
local function fmov(size)
	return size == 8 and "movq" or "movd"
end

-- Push one eight-byte word, read through an address register, in the
-- sixteen-byte frames the stack context uses.  r11 is not allocatable.
local function pushword(g, addr, off)
	g:write("\tsubq\t$16,%rsp\n")
	g:write(("\tmovq\t%d(%s),%%r11\n\tmovq\t%%r11,(%%rsp)\n")
		:format(off, addr))
end

local function call(g, n, reg)
	local args = n.args or {}
	local dest, nflt, nstack, hidden = classify(n)
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
				pushword(g, regname(reg, 8), p.off)
				order[#order + 1] = {flt = p.flt, reg = p.r,
						     size = 8}
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
			g:write("\tmovq\t(%rsp)," .. ARGREG[d.reg + 1] .. "\n")
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
			g:write(("\tleaq\t%s,%s\n")
				:format(addr(g, e.left), ARGREG[r + 1]))
		else
			g:write(("\t%s\t%s,%s\n")
				:format(w == 8 and "movq" or "movl",
					addr(g, e),
					(w == 8 and ARGREG or ARGREG32)[r + 1]))
		end
	end
	-- A variadic callee reads al to learn how many xmm registers it must
	-- save.  A fixed one ignores it.
	g:write("\tmovl\t$" .. nflt .. ",%eax\n")
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
	if n.retrec then
		-- A record that came back in registers is dropped into the
		-- slot the caller set aside; one written through the hidden
		-- pointer is there already.
		local ni, nf = 0, 0
		for _, p in ipairs(eightbytes(n.retrec) or {}) do
			local at = ("%d(%%rbp)"):format(n.retslot + p.off)
			if p.flt then
				g:write(("\tmovq\t%%xmm%d,%s\n"):format(nf, at))
				nf = nf + 1
			else
				g:write(("\tmovq\t%s,%s\n")
					:format(ni == 0 and "%rax" or "%rdx", at))
				ni = ni + 1
			end
		end
	elseif n.ty.kind == "float" then
		-- A soft call answers with a bit pattern in rax; the ABI
		-- answers in xmm0.  Either way it belongs in the float file.
		if n.soft then
			g:write(("\t%s\t%s,%s\n"):format(fmov(n.ty.size),
				regname(reg, n.ty.size == 8 and 8 or 4),
				fregname(reg, n.ty.size)))
		else
			g:write(("\tmov%s\t%%xmm0,%s\n")
				:format(fsuf(n.ty.size), fregname(reg, n.ty.size)))
		end
	else
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
local GUARD = "__guard_local"

local function setguard(g, guard, name)
	g:write("\tmovq\t" .. GUARD .. "(%rip),%r11\n")
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
	g:write("\txorq\t" .. GUARD .. "(%rip),%r11\n")
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
	g:write(name .. ":\n")
	g:landing()
	g:write("\tpushq\t%rbp\n\tmovq\t%rsp,%rbp\n")
	if frame > 0 then
		g:write("\tsubq\t$" .. frame .. ",%rsp\n")
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
					g:write(("\tmovq\t%%xmm%d,%s\n")
						:format(p.r, at))
				else
					g:write(("\tmovq\t%s,%s\n")
						:format(ARGREG[p.r + 1], at))
				end
			end
		elseif d.reg and d.flt then
			g:write(("\t%s\t%%xmm%d,%d(%%rbp)\n")
				:format(fmov(d.size), d.reg, d.off))
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
		for i = 1, NFLTREG do
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
			g:write(("\tmovq\t%d(%%rbp),%%rax\n\tmovq\t%%rax,%d(%%rbp)\n")
				:format(stackargs + d.stk * 8, d.off))
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
	if recret and recret.cls then
		-- The result sits in a slot of ours; hand back the pieces.
		local ni, nf = 0, 0
		for _, p in ipairs(recret.cls) do
			local at = ("%d(%%rbp)"):format(recret.off + p.off)
			if p.flt then
				g:write(("\tmovq\t%s,%%xmm%d\n"):format(at, nf))
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
	elseif fltret then
		g:write(("\tmov%s\t%s,%%xmm0\n")
			:format(fsuf(fltret), fregname(0, fltret)))
	end
	if not guard then
		return g:write("\tleave\n\tret\n")
	end
	-- The check comes after the result is in place, and reads r11,
	-- which no value is ever allocated to.
	local bad = checkguard(g, guard)

	g:write("\tleave\n\tret\n")
	g:write(bad .. ":\n")
	g:write("\tleaq\t" .. guard.label .. "(%rip),%rdi\n")
	g:write("\txorl\t%esi,%esi\n")
	g:write("\tcall\t__stack_smash_handler\n")
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
end

-- The peephole rules.  Each reads the last few lines and answers with
-- what goes in their place, or nothing to leave them alone.
local MOV = {movb = 1, movw = 2, movl = 4, movq = 8}

local function isreg(x) return x and x:sub(1, 1) == "%" end

local peeprules = {
	-- A move from a register to itself.  Every call ends with one,
	-- because the result is already where the caller wanted it.
	{n = 1, f = function(w, i)
		local a = w[i]

		if MOV[a.mnem or ""] and a.a and a.a == a.b then
			return {}
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
	nreg = 6,
	-- How far an inline asm may reach for scratch: past nreg the
	-- register is one the ABI wants back, so it is saved first.
	nasmreg = 11,
	recabi = true,
	ldbl = LDBL80 and "f80" or nil,
	peep = peeprules,
	hiddenarg = true,
	eightbytes = eightbytes,
	regname = regname,
	fregname = fregname,
	hwfloat = true,
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
	asmpin = asmpin,
	asmkeep = asmkeep,
	asmimm = asmimm,
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
	jump = jump,
	code = code,
	trailer = trailer,
}
