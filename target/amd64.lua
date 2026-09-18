-- amd64, AT&T syntax.
--
-- Everything machine dependent lives here: register names, the address
-- forms, the difficulty override, and the code tables.  A new target is a
-- file of the same shape; nothing above this reaches into it.

local md = require "md"
local data = require "data"
local tree = require "tree"

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

local function branch(g, n, label, sense, reg)
	local pair = JMP[n.op]
	if pair then
		if n.left.ty.kind == "uint" or n.left.ty.kind == "ptr" then
			pair = UJMP[n.op]
		end
	else
		pair = {"ne", "e"}		-- the value itself, tested
	end
	g:write("\tj" .. pair[sense and 1 or 2] .. "\t" .. label .. "\n")
end

-- Every stack slot is sixteen bytes, so rsp is always aligned where a call
-- needs it to be.
local function save(g, i)
	g:write("\tsubq\t$16,%rsp\n\tmovq\t" .. regname(i, 8) .. ",(%rsp)\n")
end

local function restore(g, i)
	g:write("\tmovq\t(%rsp)," .. regname(i, 8) .. "\n\taddq\t$16,%rsp\n")
end

-- Bridge a value already in a register to another context.
local function adapt(g, n, ctx, reg)
	if ctx == "stack" then
		g:write("\tsubq\t$16,%rsp\n\tmovq\t" ..
			regname(reg, 8) .. ",(%rsp)\n")
	elseif ctx == "cc" then
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

-- Narrowing has to be done, not assumed: a byte in a register is still
-- whatever was there.  Widening from a narrow load is already done, because
-- the load itself widened.
-- A value narrower than a register is held sign or zero extended to 32
-- bits, which is what the loads produce.  Widening to 64 has to finish the
-- job; narrowing has to redo it at the new width.
local function convert(g, from, to, reg)
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
	       ["%r8"] = 3, ["%r9"] = 4, ["%r10"] = 5}
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

local function move(g, dst, src, size)
	size = size or 8
	rawmove(g, regname(dst, size), regname(src, size), size)
end

-- A call is not a table entry: the argument count varies, so the generator
-- hands the node here.  Everything allocatable is caller saved, so whatever
-- is still live gets saved around it.
local ARGREG = {"%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"}
local NFLTREG = 8

-- The ABI facts md.classify needs.  SysV keeps the two register files
-- independent, uses them for variadic arguments too, and sends a floating
-- point argument to the stack once the float file is full.
local T = {ptrsize = 8, nargreg = #ARGREG, nfltreg = NFLTREG,
	   vafloat = true, fltspill = false}

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
		shape[i] = {flt = not n.soft and a.ty.kind == "float",
			    size = a.ty.size}
	end
	local dest, _, fp, stk = md.classify(T, shape, n.nfixed)
	return dest, fp, stk
end

-- The instruction that moves a word between an integer place and an xmm
-- register.  A float is four bytes and a double is eight.
local function fmov(size)
	return size == 8 and "movq" or "movd"
end

local function call(g, n, reg)
	local args = n.args or {}
	local dest, nflt, nstack = classify(n)
	local bytes = ((nstack * 8 + 15) // 16) * 16
	for i = 0, reg - 1 do
		save(g, i)
	end
	-- Arguments that did not fit a register go in a block of their own,
	-- which stays put while the register arguments are computed on top.
	if bytes > 0 then
		g:write("\tsubq\t$" .. bytes .. ",%rsp\n")
		for i, d in ipairs(dest) do
			if d.stk then
				g:expr(args[i], "reg", reg)
				g:write(("\tmovq\t%s,%d(%%rsp)\n")
					:format(regname(reg, 8), d.stk * 8))
			end
		end
	end
	local order = {}
	for i, d in ipairs(dest) do
		if d.reg then
			order[#order + 1] = i
			g:expr(args[i], "stack", reg)
		end
	end
	-- r11 is not allocatable, so the address survives the argument pops
	if not n.direct then
		g:expr(n.left, "reg", reg)
		g:write("\tmovq\t" .. regname(reg, 8) .. ",%r11\n")
	end
	for k = #order, 1, -1 do
		local d = dest[order[k]]
		if d.flt then
			g:write(("\t%s\t(%%rsp),%%xmm%d\n")
				:format(fmov(d.size), d.reg))
		else
			g:write("\tmovq\t(%rsp)," .. ARGREG[d.reg + 1] .. "\n")
		end
		g:write("\taddq\t$16,%rsp\n")
	end
	-- A variadic callee reads al to learn how many xmm registers it must
	-- save.  A fixed one ignores it.
	g:write("\tmovl\t$" .. nflt .. ",%eax\n")
	if n.direct then
		g:write("\tcall\t" .. n.left.sym .. "\n")
	else
		g:write("\tcall\t*%r11\n")
	end
	if bytes > 0 then
		g:write("\taddq\t$" .. bytes .. ",%rsp\n")
	end
	if not n.soft and n.ty.kind == "float" then
		local w = n.ty.size == 8 and 8 or 4
		g:write(("\t%s\t%%xmm0,%s\n")
			:format(fmov(n.ty.size), regname(reg, w)))
	else
		g:write("\tmovq\t%rax," .. regname(reg, 8) .. "\n")
	end
	for i = reg - 1, 0, -1 do
		restore(g, i)
	end
end

-- Frame setup is the calling convention, not the code table.  The parser
-- classifies each parameter; this places it.  Structs are not passed by
-- value.
local function prologue(g, name, frame, params, vabase, static)
	g:write("\t.text\n")
	if not static then
		g:write("\t.globl\t" .. name .. "\n")
	end
	g:write(name .. ":\n")
	g:write("\tpushq\t%rbp\n\tmovq\t%rsp,%rbp\n")
	if frame > 0 then
		g:write("\tsubq\t$" .. frame .. ",%rsp\n")
	end
	for _, d in ipairs(params or {}) do
		if d.reg and d.flt then
			g:write(("\t%s\t%%xmm%d,%d(%%rbp)\n")
				:format(fmov(d.size), d.reg, d.off))
		elseif d.reg then
			g:write("\tmovq\t" .. ARGREG[d.reg + 1] .. "," ..
				d.off .. "(%rbp)\n")
		else
			-- the caller left it above the return address
			g:write(("\tmovq\t%d(%%rbp),%%rax\n\tmovq\t%%rax,%d(%%rbp)\n")
				:format(stackargs + d.stk * 8, d.off))
		end
	end
	-- A variadic function keeps every argument register, integer file
	-- first, so the walker has somewhere to read them from.
	if vabase then
		for i = 1, #ARGREG do
			g:write(("\tmovq\t%s,%d(%%rbp)\n")
				:format(ARGREG[i], vabase + (i - 1) * 8))
		end
		for i = 1, NFLTREG do
			g:write(("\tmovq\t%%xmm%d,%d(%%rbp)\n")
				:format(i - 1,
					vabase + (#ARGREG + i - 1) * 8))
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
local function epilogue(g, frame, fltret)
	if fltret then
		g:write(("\t%s\t%s,%%xmm0\n")
			:format(fmov(fltret), regname(0, fltret)))
	end
	g:write("\tleave\n\tret\n")
end

local function jump(g, label)
	g:write("\tjmp\t" .. label .. "\n")
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
	__CHAR_BIT__ = "8", __ORDER_LITTLE_ENDIAN__ = "1234",
	__ORDER_BIG_ENDIAN__ = "4321", __BYTE_ORDER__ = "1234",
	__ELF__ = "1",
}

-- Without this the linker assumes the stack must be executable, and
-- refuses to load the result as a shared object.
local trailer = '\t.section\t.note.GNU-stack,"",@progbits\n'

return md.target{
	name = "amd64",
	ptrsize = 8,
	predef = predef,
	charsigned = true,
	nreg = 6,
	regname = regname,
	suffix = suffix,
	addr = addr,
	dcalc = dcalc,
	mnem = mnem,
	branch = branch,
	adapt = adapt,
	save = save,
	restore = restore,
	call = call,
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
	fltspill = T.fltspill,
	epilogue = epilogue,
	slot = slot,
	frame = frame,
	jump = jump,
	code = code,
	trailer = trailer,
}
