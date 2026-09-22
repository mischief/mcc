-- SPDX-License-Identifier: ISC
-- i386, AT&T syntax.
--
-- The shape of this file is the amd64 one: register names, the address
-- forms, the difficulty override, and the code tables.  Four things are
-- different enough to say out loud.
--
-- Only four registers have an eight-bit name, so the allocation order is
-- eax, edx, ecx, ebx and nothing else.  esi and edi are held out and used
-- as scratch, which is what r11 is on amd64.  A variable shift needs cl
-- and a divide needs edx, and both are in the order, so those two carry a
-- clobber list and the exchange that goes with it.
--
-- ebx, esi and edi belong to the caller.  The prologue puts all three in
-- the frame and the epilogue takes them back, rather than working out
-- which of them a body touched.
--
-- Nothing travels in a register: every argument is a stack word, a record
-- result is written through a pointer the caller hands over as the first
-- stack word, and the callee pops that word with `ret $4`.
--
-- There is no floating point here.  float and double go through the
-- software runtime, which is what a target with no float registers does,
-- and only the call boundary knows about x87: the ABI hands a floating
-- point result back on the x87 stack, so a call reads st(0) and a return
-- writes it.  long double is double, which the psABI does not say.

local md = require "md"
local peep = require "peep"
local data = require "data"
local tree = require "tree"

-- Scratch registers in allocation order.  Sethi-Ullman numbering decides
-- how many an expression needs, so a wide file means fewer spills; four
-- is all this machine can offer with an eight-bit name on each.
--
-- Past the order are the two the code tables use as scratch and no value
-- is ever allocated to.  They have no eight-bit name, so nothing narrow
-- may be held in one.
local REG = {
	[0] = {"al", "ax", "eax"},
	[1] = {"dl", "dx", "edx"},
	[2] = {"cl", "cx", "ecx"},
	[3] = {"bl", "bx", "ebx"},
	[4] = {nil,  "si", "esi"},
	[5] = {nil,  "di", "edi"},
}

-- Three, not four.  The fourth of the allocation order was ebx, and
-- an expression here is two or three deep, so what the fourth buys is
-- less than what `freeregs` below buys by holding a local.
local NREG = 3
local ECX = 2			-- where the shift count has to be
local TMP = "%esi"		-- the one no value is allocated to

local SLOT = {[1] = 1, [2] = 2, [4] = 3}
local SUFFIX = {[1] = "b", [2] = "w", [4] = "l"}

local function regname(r, size)
	local names = REG[r] or error("out of registers: r" .. r)
	local nm = names[SLOT[size] or error("bad size " .. tostring(size))]

	if not nm then
		error(("no %d-bit name for %%%s on i386")
			:format(size * 8, names[3]), 0)
	end
	return "%" .. nm
end

local function suffix(ty)
	return SUFFIX[ty.size] or error("bad size " .. tostring(ty.size))
end

-- Every immediate is a 32-bit field, so a value the parser is holding as
-- a 64-bit Lua integer has to come down to what the field says.
local function imm(v)
	v = v & 0xffffffff
	if v >= 0x80000000 then v = v - 0x100000000 end
	return v
end

-- The operand text for a node the instruction can address directly.
-- Nothing is position independent here: a name is an absolute address
-- and the linker writes it into the field.
local function addr(g, n)
	local op = n.op
	if op == "CONST" then
		return "$" .. imm(n.val)
	elseif op == "NAME" then
		if n.got then return n.sym .. "@GOT(%ebx)" end
		return n.sym
	elseif op == "AUTO" then
		if n.pin then return regname(n.pin, n.ty.size) end
		return n.off .. "(%ebp)"
	end
	error("cannot address " .. op .. " directly on i386")
end

-- Put the address of something in a register.  A name that is not
-- reached through the GOT is a constant, so the instruction carries
-- it, which is what gcc does.  lea would reach it as a displacement
-- instead, and in sixteen bit mode a displacement is sixteen bits
-- unless an address size prefix says otherwise -- so the linker was
-- being handed R_386_16 where gcc hands it R_386_32, and the
-- instruction was two bytes longer for it.
local function leato(g, e, r)
	if e.op == "NAME" and not e.got then
		g:write(("\tmovl\t$%s,%s\n"):format(e.sym, r))
		return
	end
	g:write(("\tleal\t%s,%s\n"):format(addr(g, e), r))
end

-- An address costs a register, because lea is what builds it.  Every
-- constant fits an immediate field, so none of them costs anything.
local function dcalc(n, nreg)
	if n and (n.op == "ADDR" or n.op == "GOT") then
		return n.need <= nreg and 20 or 24
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

local function branch(g, n, label, sense)
	local pair = JMP[n.op]

	if pair then
		local kind = n.left.ty.kind

		if kind == "uint" or kind == "ptr" then
			pair = UJMP[n.op]
		end
	else
		pair = {"ne", "e"}		-- the value itself, tested
	end
	g:write("\tj" .. pair[sense and 1 or 2] .. "\t" .. label .. "\n")
end

-- A spilled register takes sixteen bytes, so esp stays aligned where a
-- call needs it to be.  `-mpreferred-stack-boundary=2` says four bytes
-- is enough, and then a push and a pop do the same work in four bytes
-- of code instead of twelve.  A spill is the one place worth the
-- trouble: it is the only one a call runs inside, so the peephole
-- cannot close it up.
local PUSHSPILL = false

-- Put a register down on the scratch stack, and take one back.  The
-- name is a register name, not an index, because call setup moves
-- pieces of a record through here as well.
local function stkdown(g, nm)
	if PUSHSPILL then
		g:write("\tpushl\t" .. nm .. "\n")
	else
		g:write("\tsubl\t$16,%esp\n\tmovl\t" .. nm ..
			",(%esp)\n")
	end
end

local function stkup(g, nm)
	if PUSHSPILL then
		g:write("\tpopl\t" .. nm .. "\n")
	else
		g:write("\tmovl\t(%esp)," .. nm .. "\n\taddl\t$16,%esp\n")
	end
end

-- Give back the room one scratch push took.  The code tables say the
-- same thing in their own text; `spec.stackboundary` rewrites those.
local function release(g)
	g:write(PUSHSPILL and "\taddl\t$4,%esp\n" or
		"\taddl\t$16,%esp\n")
end

local function save(g, i) stkdown(g, regname(i, 4)) end
local function restore(g, i) stkup(g, regname(i, 4)) end

-- Bridge a value already in a register to another context.
local function adapt(g, n, ctx, reg)
	if ctx == "stack" then
		stkdown(g, regname(reg, 4))
	elseif ctx == "cc" then
		local r = regname(reg, n.ty.size)

		g:write("\ttest" .. suffix(n.ty) .. "\t" .. r .. "," .. r ..
			"\n")
	end
end

-- Shape "i" is what i386 can name in an instruction: a constant, a
-- global, a frame slot, a symbol address.  An indirection is 16 and so
-- falls out.
local code = {}

code.reg = {
	CONST = {
		-- A constant narrower than four bytes fills the whole
		-- register, the same way a narrow load widens.  What sits
		-- above the value is read as part of it: a shift and a
		-- compare both work at four bytes.
		{"zb", "z", asm = "\txorl\t%W,%W"},
		{"zw", "z", asm = "\txorl\t%W,%W"},
		{"z",  "z", asm = "\txor%z\t%R,%R"},
		{"cb", "z", asm = "\tmovl\t%A,%W"},
		{"cw", "z", asm = "\tmovl\t%A,%W"},
		{"c",  "z", asm = "\tmov%z\t%A,%R"},
	},
	-- A narrow load must widen, or the rest of the register is
	-- whatever happened to be there.
	NAME = {
		{"il", "z", asm = "\tmovl\t%A,%W"},
		{"i",  "z", asm = "\t%I\t%A,%W"},
	},
	AUTO = {
		{"il", "z", asm = "\tmovl\t%A,%W"},
		{"i",  "z", asm = "\t%I\t%A,%W"},
	},
	ADDR = {{"i", "z", asm = function(g, n, reg)
		leato(g, n.left, regname(reg, 4))
	end}},
	-- the loader wrote the address here, so it is a load and not a lea
	GOT = {{"i", "z", asm = "\tmovl\t%A1,%R"}},
	-- The thread pointer is at offset zero of the %gs segment, and the
	-- linker knows where in the block this object sits.  That is the
	-- local exec model, which is what an executable may use.
	TLS = {{"i", "z", asm = function(g, n, reg)
		local r = regname(reg, 4)

		g:write(("\tmovl\t%%gs:0,%s\n"):format(r))
		g:write(("\tleal\t%s@ntpoff(%s),%s\n")
			:format(n.left.sym, r, r))
	end}},
	-- The pointee type on the operand picks the load.
	INDIR = {
		-- Through a pointer the body keeps in a register.
		{"ilpr", "z", asm = "\tmovl\t(%A1),%R"},
		{"iwpr", "z", asm = "\t%I\t(%A1),%W"},
		{"ibpr", "z", asm = "\t%I\t(%A1),%W"},
		{"nlp", "z", ev = "L", asm = "\tmovl\t(%P),%W"},
		{"nwp", "z", ev = "L", asm = "\t%I\t(%P),%W"},
		{"nbp", "z", ev = "L", asm = "\t%I\t(%P),%W"},
	},
	-- A postfix step yields the old value, then adjusts the lvalue.
	POSTADD = {
		{"il", "z", rz = 1,
		 asm = "\tmovl\t%A1,%W\n\taddl\t$%C,%A1"},
		{"i",  "z", rz = 1,
		 asm = "\t%I\t%A1,%W\n\tadd%z1\t$%C,%A1"},
		-- through a pointer: the address goes in the next register
		-- so the loaded value does not overwrite it
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
		local r = regname(reg, 4)

		g:write(("\taddl\t$15,%s\n\tandl\t$-16,%s\n"):format(r, r))
		g:write(("\tsubl\t%s,%%esp\n\tmovl\t%%esp,%s\n")
			:format(r, r))
	end}},
	NEG = {{"n", "z", ev = "L", asm = "\tneg%z\t%R"}},
	NOT = {{"n", "z", ev = "L", asm = "\tnot%z\t%R"}},
}

-- The commutative and difference ops share one shape ladder.
for _, op in ipairs{"ADD", "SUB", "AND", "OR", "XOR"} do
	code.reg[op] = {
		{"n", "i", ev = "L",    asm = "\t%I%z\t%A2,%R"},
		{"n", "e", ev = "L R1", asm = "\t%I%z\t%R1,%R"},
		{"n", "n", ev = "Rs L",
		 asm = "\t%I%z\t(%esp),%R\n\taddl\t$16,%esp"},
	}
end

code.reg.MUL = {
	{"n", "c", ev = "L",    asm = "\timul%z\t%A2,%R,%R"},
	{"n", "i", ev = "L",    asm = "\timul%z\t%A2,%R"},
	{"n", "e", ev = "L R1", asm = "\timul%z\t%R1,%R"},
	{"n", "n", ev = "Rs L",
	 asm = "\timul%z\t(%esp),%R\n\taddl\t$16,%esp"},
}

-- A variable shift count has to be in cl, and ecx is in the allocation
-- order, so the value may be sitting there.  The exchange puts the count
-- where the instruction needs it and the value where it does not; the
-- register it borrows is the next one, which holds nothing.
local function shiftmn(n)
	if n.op == "SHL" then return "shl" end
	return n.ty.kind == "uint" and "shr" or "sar"
end

for _, op in ipairs{"SHL", "SHR"} do
	code.reg[op] = {
		{"n", "c", ev = "L", asm = "\t%I%z\t$%C2,%R"},
		{"n", "e", clob = {ECX}, ev = "L R1",
		 asm = function(g, n, reg)
			local mn = shiftmn(n) .. suffix(n.ty)

			if reg ~= ECX then
				g:write("\tmovl\t" .. regname(reg + 1, 4) ..
					",%ecx\n")
				g:write(("\t%s\t%%cl,%s\n")
					:format(mn, regname(reg, n.ty.size)))
				return
			end
			g:write("\txchgl\t%ecx," ..
				regname(reg + 1, 4) .. "\n")
			g:write(("\t%s\t%%cl,%s\n")
				:format(mn, regname(reg + 1, n.ty.size)))
			g:write("\tmovl\t" .. regname(reg + 1, 4) ..
				",%ecx\n")
		 end},
		{"n", "n", clob = {ECX}, ev = "Rs L",
		 asm = function(g, n, reg)
			local mn = shiftmn(n) .. suffix(n.ty)

			if reg ~= ECX then
				g:write("\tmovl\t(%esp),%ecx\n")
				release(g)
				g:write(("\t%s\t%%cl,%s\n")
					:format(mn, regname(reg, n.ty.size)))
				return
			end
			local t = regname(reg + 1, 4)

			g:write("\tmovl\t%ecx," .. t .. "\n")
			g:write("\tmovl\t(%esp),%ecx\n")
			release(g)
			g:write(("\t%s\t%%cl,%s\n")
				:format(mn, regname(reg + 1, n.ty.size)))
			g:write("\tmovl\t" .. t .. ",%ecx\n")
		 end},
	}
end

-- Divide and remainder read edx:eax and write both, so both carry a
-- clobber list.  The divisor goes to esi first, where no value can be
-- sitting.
for _, want in ipairs{"DIV", "MOD"} do
	local alts = {}

	for _, kind in ipairs{"s", "u"} do
		local mn = kind == "u" and "divl" or "idivl"
		local pre = kind == "u" and "\txorl\t%edx,%edx\n"
			    or "\tcltd\n"
		local out = want == "DIV" and "%eax" or "%edx"
		local tail = "\tmovl\t%R,%eax\n" .. pre ..
			     "\t" .. mn .. "\t" .. TMP ..
			     "\n\tmovl\t" .. out .. ",%R"

		alts[#alts + 1] = {"nl" .. kind, "e", clob = {0, 1},
			ev = "L R1",
			asm = "\tmovl\t%R1," .. TMP .. "\n" .. tail}
		alts[#alts + 1] = {"nl" .. kind, "n", clob = {0, 1},
			ev = "R1s L",
			asm = "\tmovl\t(%esp)," .. TMP ..
			      "\n\taddl\t$16,%esp\n" .. tail}
	end
	code.reg[want] = alts
end

-- The branch reads the flags the compare leaves, so nothing between the
-- two may touch them.  That is why the stack comes back with lea and not
-- add.
code.cc = {}
for op in pairs(JMP) do
	code.cc[op] = {
		{"n", "i", rz = 1, ev = "L",    asm = "\tcmp%z1\t%A2,%R"},
		{"n", "e", rz = 1, ev = "L R1", asm = "\tcmp%z1\t%R1,%R"},
		{"n", "n", rz = 1, ev = "Rs L",
		 asm = "\tcmp%z1\t(%esp),%R\n\tleal\t16(%esp),%esp"},
	}
end

code.eff = {
	POSTADD = {
		{"i",  "z", rz = 1, asm = "\tadd%z1\t$%C,%A1"},
		{"n*", "z", rz = 1, ev = "L*", asm = "\tadd%z1\t$%C,(%P)"},
	},
	ASGN = {
		{"i",  "c",                       asm = "\tmov%z1\t%A2,%A1"},
		{"i",  "n", rz = 1, ev = "R",     asm = "\tmov%z1\t%R,%A1"},
		-- A constant through a pointer is the store alone; the
		-- value needs no register of its own.
		{"n*", "c", rz = 1, ev = "L*",    asm = "\tmov%z1\t%A2,(%P)"},
		{"n*", "n", rz = 1, ev = "R L1*", asm = "\tmov%z1\t%R,(%P1)"},
	},
}

-- An assignment used for its value stores, then leaves the value behind.
code.reg.ASGN = {
	{"i",  "n", rz = 1, ev = "R",     asm = "\tmov%z1\t%R,%A1"},
	{"n*", "n", rz = 1, ev = "R L1*", asm = "\tmov%z1\t%R,(%P1)"},
}

-- Narrowing has to be done, not assumed: a byte in a register is still
-- whatever was there.  Widening from a narrow load is already done,
-- because the load itself widened.
local function convert(g, from, to, reg)
	if to.size >= from.size then return end
	if to.size == 1 or to.size == 2 then
		local mn = (to.size == 1)
			and (to.kind == "uint" and "movzbl" or "movsbl")
			or  (to.kind == "uint" and "movzwl" or "movswl")

		g:write("\t" .. mn .. "\t" .. regname(reg, to.size) ..
			"," .. regname(reg, 4) .. "\n")
	end
end

-- Copy `size` bytes from the address in reg+1 to the address in reg.
-- The byte moves need a register with an eight-bit name, and only the
-- first four have one; past that, eax is borrowed and put back.
local function blockcopy(g, size, reg)
	local d, s = regname(reg, 4), regname(reg + 1, 4)
	local t = reg + 2 <= 3 and reg + 2 or nil
	local BORROW = {[4] = "%eax", [2] = "%ax", [1] = "%al"}
	local off = 0

	if not t then g:write("\tpushl\t%eax\n") end
	for _, w in ipairs{4, 2, 1} do
		local r = t and regname(t, w) or BORROW[w]
		local sfx = SUFFIX[w]

		while size - off >= w do
			g:write(("\tmov%s\t%d(%s),%s\n\tmov%s\t%s,%d(%s)\n")
				:format(sfx, off, s, r, sfx, r, off, d))
			off = off + w
		end
	end
	if not t then g:write("\tpopl\t%eax\n") end
end

-- Inline assembly ------------------------------------------------------
--
-- The constraint letters that name a register, at each width.  A letter
-- this table does not carry means "any register", which the generator
-- allocates.
local ASMREG = {
	a = {"%al", "%ax", "%eax"},
	b = {"%bl", "%bx", "%ebx"},
	c = {"%cl", "%cx", "%ecx"},
	d = {"%dl", "%dx", "%edx"},
	S = {nil,   "%si", "%esi"},
	D = {nil,   "%di", "%edi"},
}

-- Every general register by every name it answers to, for a local bound
-- to one with `register long r __asm__("ebx")`.
local GPR = {
	{"al", "ax", "eax"}, {"cl", "cx", "ecx"},
	{"dl", "dx", "edx"}, {"bl", "bx", "ebx"},
	{nil, "sp", "esp"}, {nil, "bp", "ebp"},
	{nil, "si", "esi"}, {nil, "di", "edi"},
}
local HARD = {}
for _, names in ipairs(GPR) do
	for i = 1, 3 do
		if names[i] then HARD[names[i]] = names end
	end
end

local function hardreg(name, size)
	local n = HARD[(name:gsub("^%%", ""))]

	return n and n[SLOT[size] or 3] and ("%" .. n[SLOT[size] or 3])
		or nil
end

-- Read a machine register a file-scope `register` declaration named.
local function readhard(g, name, reg, size)
	local from = hardreg(name, size)

	if not from then error("no register " .. name) end
	g:write(("\tmovl\t%s,%s\n"):format(from, regname(reg, 4)))
end

-- Which constants a constraint letter takes.  These are the ranges the
-- instructions themselves have: a shift count is five bits, a port
-- number is eight, and an ordinary immediate is the whole word.
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
	if letter == "Z" then return v >= 0 and v <= 0xffffffff end
	return true
end

local function asmreg(letter, size)
	local r = ASMREG[letter]

	return r and r[SLOT[size] or 3]
end

-- Where a named register sits in the allocation order, if it is in it,
-- and whether the ABI asks the callee to preserve it.
local ALLOC = {["%eax"] = 0, ["%edx"] = 1, ["%ecx"] = 2, ["%ebx"] = 3,
	       ["%esi"] = 4, ["%edi"] = 5}
local PRESERVED = {["%ebx"] = true, ["%ebp"] = true, ["%esi"] = true,
		   ["%edi"] = true}
local WIDE = {}
for _, names in ipairs(GPR) do
	for i = 1, 3 do
		if names[i] then WIDE["%" .. names[i]] = "%" .. names[3] end
	end
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
	g:write((push and "\tpushl\t" or "\tpopl\t") .. name .. "\n")
end

-- What a `"=@cc<cond>"` output answers: the condition the template left
-- in the flags, as a zero or a one.
local function asmflag(g, cond, reg, size)
	local names = REG[reg] or error("out of registers: r" .. reg)

	if names[1] then
		local b = "%" .. names[1]

		g:write("\tset" .. cond .. "\t" .. b .. "\n")
		if size > 1 then
			g:write(("\tmovzbl\t%s,%s\n")
				:format(b, regname(reg, 4)))
		end
		return
	end
	-- No eight-bit name: one is borrowed, and the answer is never
	-- the register it came from.
	g:write("\tpushl\t%eax\n\tset" .. cond .. "\t%al\n")
	g:write(("\tmovzbl\t%%al,%s\n"):format(regname(reg, 4)))
	g:write("\tpopl\t%eax\n")
end

local function asmimm(v)
	return "$" .. imm(v)
end

local function rawmove(g, dst, src, size)
	if dst == src then return end
	g:write(("\tmov%s\t%s,%s\n"):format(SUFFIX[size] or "l", src, dst))
end

local function move(g, dst, src, size)
	size = size or 4
	rawmove(g, regname(dst, size), regname(src, size), size)
end

-- The kernel's retpoline thunk, which every indirect branch goes through
-- when the caller asks for one, and the thunk every return goes through.
local THUNK = "__x86_indirect_thunk_esi"
local RETTHUNK = "__x86_return_thunk"

-- Calling convention ---------------------------------------------------
--
-- Nothing travels in a register.  A record result is written through a
-- pointer the caller leaves as the first stack word and the callee pops,
-- which is what `ret $4` is for.
local stackargs = 8			-- the caller's first word, from ebp
local HIDDEN = 4			-- what the callee pops for one

-- How many arguments travel in registers.  System V says none;
-- `-mregparm=n` says the first n, in these three, which is what a
-- kernel's real mode code is built with.  Floating point never goes
-- in one, and a variadic callee is handed everything on the stack.
local ARGREG = {"%eax", "%edx", "%ecx"}
local REGPARM = 0

-- The one record the ABI hands back in registers: a complex pair of
-- floats is eight bytes and comes back in edx:eax.  Every other record,
-- a complex double included, is written through the caller's pointer.
local function eightbytes(ty)
	if not ty.complex or ty.size > 8 then return nil end
	return md.pieces(ty.size, 4)
end

-- How a record splits for an argument, which is not how one splits
-- for a result: with `-mregparm` a record takes as many registers as
-- it has words, or the stack if that many are not left.
local function argpieces(ty)
	return md.pieces(ty.size, 4)
end

local T = {ptrsize = 4, nargreg = 0, nfltreg = 0, vafloat = false,
	   fltspill = false, hiddenarg = true, pairalign = false,
	   varstack = true, fltstack = true,
	   eightbytes = eightbytes, argpieces = argpieces}

-- A function that named `__attribute__((regparm(n)))` has a
-- convention of its own, which is how a kernel writes `asmlinkage`.
local function convof(rp)
	if rp == nil or rp == REGPARM then return T, REGPARM end
	local c = {}

	for k, v in pairs(T) do c[k] = v end
	c.nargreg = rp
	return c, rp
end

-- An argument the machine can name in one instruction: nothing
-- between here and the call can change what it means, so it goes
-- straight into its own register at the end and never touches the
-- stack.  A narrow one is left out: reading four bytes where one was
-- written is a read of whatever is beside it.
local function simplearg(e)
	if not e then return false end
	local op = e.op

	if op == "CONST" then return e.ty.size == 4 end
	if op == "AUTO" or op == "NAME" then
		return e.ty.size == 4 and not e.got
	end
	if op == "ADDR" then
		local c = e.left

		return c and (c.op == "AUTO" or
			      (c.op == "NAME" and not c.got))
	end
	return false
end

local function classify(n)
	local shape = {}
	local wide = n.wide

	for i, a in ipairs(n.args or {}) do
		local w = wide and wide[i]
		local rec = n.recs and n.recs[i]

		-- A float is never in a register here, which is what
		-- x87 means to the classifier.  A wide one is an
		-- address by now, so the node cannot say it is a float.
		-- A soft call is the exception: the runtime takes bit
		-- patterns, and those are ordinary words.
		local flt = not rec and not n.soft and
			((n.wflt and n.wflt[i]) or a.ty.kind == "float")

		shape[i] = {rec = rec, flt = false, x87 = flt or nil,
			    size = rec and rec.size or w or a.ty.size}
	end
	local hidden = n.retrec and not eightbytes(n.retrec) or nil
	local t, rp = convof(n.regparm)
	local dest, _, _, stk = md.classify(t, shape, n.nfixed, hidden)

	return dest, stk, hidden, rp
end

local function retinsn(g, pops)
	if pops then return "\tret\t$" .. pops .. "\n" end
	if g.o.rethunk then return "\tjmp\t" .. RETTHUNK .. "\n" end
	return "\tret\n"
end

local function call(g, n, reg)
	local args = n.args or {}
	local dest, nstack, hidden, rp = classify(n)
	local bytes = ((nstack * 4 + 15) // 16) * 16

	-- Saved registers and stacked arguments sit below the stack
	-- pointer while the rest are worked out, so nothing in an
	-- argument may move it.
	g.nomove = g.nomove + 1
	for i = 0, reg - 1 do
		save(g, i)
	end
	if bytes > 0 then
		g:write("\tsubl\t$" .. bytes .. ",%esp\n")
		if hidden and rp == 0 then
			g:write(("\tleal\t%d(%%ebp),%s\n\tmovl\t%s,(%%esp)\n")
				:format(n.retslot, TMP, TMP))
		end
		for i, d in ipairs(dest) do
			if d.reg or d.pieces then	-- below
			elseif d.mem then
				-- a record: the caller leaves a copy of it
				g:expr(args[i], "reg", reg + 1)
				g:write(("\tleal\t%d(%%esp),%s\n")
					:format(d.stk * 4, regname(reg, 4)))
				blockcopy(g, d.size, reg)
			elseif d.words > 1 then
				-- wider than a register, so the expression
				-- answers with its address
				g:expr(args[i], "reg", reg)
				for k = 0, d.words - 1 do
					g:write(("\tmovl\t%d(%s),%s\n")
						:format(k * 4,
							regname(reg, 4), TMP))
					g:write(("\tmovl\t%s,%d(%%esp)\n")
						:format(TMP,
							(d.stk + k) * 4))
				end
			else
				g:expr(args[i], "reg", reg)
				g:write(("\tmovl\t%s,%d(%%esp)\n")
					:format(regname(reg, 4), d.stk * 4))
			end
		end
	end
	-- The register arguments are worked out onto the stack, so that
	-- computing one cannot disturb another, and come off it into
	-- their registers when there is nothing left to compute.
	local order, straight = {}, {}

	if hidden and rp > 0 then
		g:write(("\tleal\t%d(%%ebp),%s\n"):format(n.retslot, TMP))
		stkdown(g, TMP)
		order[1] = {reg = 0, words = 1}
	end
	for i, d in ipairs(dest) do
		if d.pieces then
			-- a record in registers, one word a register; the
			-- first goes down last so it comes back first
			g:expr(args[i], "reg", reg)
			for k = #d.pieces, 1, -1 do
				g:write(("\tmovl\t%d(%s),%s\n")
					:format(d.pieces[k].off,
						regname(reg, 4), TMP))
				stkdown(g, TMP)
			end
			order[#order + 1] = {reg = d.pieces[1].r,
					     words = #d.pieces}
		elseif d.reg and d.words > 1 then
			-- wider than a register, so the expression
			-- answers with its address; the low word goes
			-- down last so it comes back into the lower
			-- register
			g:expr(args[i], "reg", reg)
			for k = d.words - 1, 0, -1 do
				g:write(("\tmovl\t%d(%s),%s\n")
					:format(k * 4, regname(reg, 4), TMP))
				stkdown(g, TMP)
			end
			order[#order + 1] = d
		elseif d.reg and simplearg(args[i]) then
			straight[#straight + 1] = {d = d, e = args[i]}
		elseif d.reg then
			order[#order + 1] = d
			g:expr(args[i], "stack", reg)
		end
	end
	-- esi is not allocatable, so the address survives the setup
	if not n.direct then
		g:expr(n.left, "reg", reg)
		g:write("\tmovl\t" .. regname(reg, 4) .. "," .. TMP .. "\n")
	end
	for k = #order, 1, -1 do
		local d = order[k]

		for j = 0, (d.words or 1) - 1 do
			stkup(g, ARGREG[d.reg + 1 + j])
		end
	end
	-- The arguments that need no working out.  Nothing left to do
	-- can disturb them, and each names a register of its own, so
	-- the order among them does not matter.
	for _, x in ipairs(straight) do
		local e, r = x.e, x.d.reg

		if e.op == "ADDR" then
			leato(g, e.left, ARGREG[r + 1])
		else
			g:write(("\tmovl\t%s,%s\n")
				:format(addr(g, e), ARGREG[r + 1]))
		end
	end
	if n.direct then
		g:write("\tcall\t" .. n.left.sym .. "\n")
	elseif g.o.retpoline then
		g:write("\tcall\t" .. THUNK .. "\n")
	else
		g:write("\tcall\t*" .. TMP .. "\n")
	end
	-- Wipe the return address the call left below the stack pointer,
	-- which is nothing the rest of the program should be able to read.
	if g.o.retclean then
		g:write("\tmovl\t$0,-4(%esp)\n")
	end
	-- The callee took the hidden pointer off the stack itself, where
	-- it came to it that way.
	local back = bytes - ((hidden and rp == 0) and HIDDEN or 0)

	if back > 0 then
		g:write("\taddl\t$" .. back .. ",%esp\n")
	elseif back < 0 then
		g:write("\tsubl\t$" .. -back .. ",%esp\n")
	end
	if n.retrec then
		-- One handed back in registers goes to the slot the caller
		-- set aside; one written through the hidden pointer is
		-- there already.
		local cls = eightbytes(n.retrec)

		for k, p in ipairs(cls or {}) do
			g:write(("\tmovl\t%s,%d(%%ebp)\n")
				:format(k == 1 and "%eax" or "%edx",
					n.retslot + p.off))
		end
	elseif n.retslot then
		-- A value wider than a register.  The ABI hands a double
		-- back on the x87 stack; the runtime hands a bit pattern
		-- back the way any pair of words comes back.
		-- n.ty is the word here: the real return type is the one
		-- the slot was made for.
		if not n.soft and (n.retty or n.ty).kind == "float" then
			g:write(("\tfstpl\t%d(%%ebp)\n"):format(n.retslot))
		else
			g:write(("\tmovl\t%%eax,%d(%%ebp)\n")
				:format(n.retslot))
			g:write(("\tmovl\t%%edx,%d(%%ebp)\n")
				:format(n.retslot + 4))
		end
	elseif n.ty.kind == "float" and not n.soft then
		-- a float, which also comes back on the x87 stack
		g:write((PUSHSPILL and "\tsubl\t$4,%esp\n" or
			"\tsubl\t$16,%esp\n") .. "\tfstps\t(%esp)\n")
		g:write("\tmovl\t(%esp)," .. regname(reg, 4) .. "\n")
		release(g)
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
	else
		g:write("\tmovl\t%eax," .. regname(reg, 4) .. "\n")
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
local SMASH = "__stack_smash_handler"

-- Where the canary is read from.  A per-cpu one is named through the
-- segment the machine keeps its per-cpu words in; anything else is a
-- plain name.
local function guardat(g)
	local sym = g.o.guardsym or GUARD

	if g.o.guardreg then
		return ("%%%s:%s"):format(g.o.guardreg, sym)
	end
	return sym
end

local function setguard(g, guard, name)
	g:write("\tmovl\t" .. guardat(g) .. "," .. TMP .. "\n")
	g:write(("\tmovl\t%s,%d(%%ebp)\n"):format(TMP, guard.off))
	guard.label = ".Lssp" .. name
	g:write("\t.pushsection\t.rodata\n")
	g:write(guard.label .. ":\n")
	g:write(("\t.asciz\t%q\n"):format(name))
	g:write("\t.popsection\n")
end

local function checkguard(g, guard)
	local bad = ".Lsmash" .. guard.label:sub(6)

	g:write(("\tmovl\t%d(%%ebp),%s\n"):format(guard.off, TMP))
	g:write("\txorl\t" .. guardat(g) .. "," .. TMP .. "\n")
	g:write("\tjne\t" .. bad .. "\n")
	return bad
end

-- The three the convention asks the callee to give back.
local KEEP = {{"%ebx", -4}, {"%esi", -8}, {"%edi", -12}}
local KEPT = 12

-- The names each of them goes by, at every width.
local NAMED = {
	["%ebx"] = {"%ebx", "%bx", "%bl", "%bh"},
	["%esi"] = {"%esi", "%si"},
	["%edi"] = {"%edi", "%di"},
}

-- Which of the three the body touched.  The prologue is written after
-- the body, so the body's text is here to read, and a register a value
-- went into is named in it: nothing in these tables reaches one of the
-- three without naming it, and inline assembly either names one as an
-- operand or declares it, which asmkeep saves around the template.
-- Without the text -- which should not happen -- all three are kept.
--
-- The frame keeps its three words whichever way this goes: the slots
-- below them were handed out while the body was parsed.
local function keepers(g, guard)
	local want = {}

	-- One the body keeps a local in is saved beside the pin, not
	-- here, or it would go in the frame twice.
	local pinned = {}

	for _, k in ipairs(g.pinsave or {}) do
		pinned[regname(k.reg, 4)] = true
	end

	-- The stack guard is read with the scratch register, in the
	-- prologue and again in the epilogue, outside the body both
	-- times.
	if guard then want["%esi"] = true end
	if g.body then
		for line in g.body:lines() do
			for r, names in pairs(NAMED) do
				for _, nm in ipairs(names) do
					if not want[r] and
					   line:find(nm, 1, true) then
						want[r] = true
					end
				end
			end
		end
	else
		for r in pairs(NAMED) do want[r] = true end
	end
	local out = {}

	for _, k in ipairs(KEEP) do
		if want[k[1]] and not pinned[k[1]] then
			out[#out + 1] = k
		end
	end
	return out
end

-- Frame setup is the calling convention, not the code table.  The parser
-- classifies each parameter; this places it.
local function prologue(g, name, frame, params, vabase, static, recret,
			sec, guard)
	-- A section the program asked for by name, which a link script
	-- places where the machine needs it.
	g:write(sec and ("\t.section\t" .. sec .. ",\"ax\",@progbits\n")
		or "\t.text\n")
	if not static then
		g:write("\t.globl\t" .. name .. "\n")
	end
	g:write(name .. ":\n")
	g:landing()
	g.kept = keepers(g, guard)
	-- A body that never names the frame pointer needs no frame.
	-- The prologue is written after the body, so whether it does
	-- is here to read, and nothing below writes one either.
	local bare = not guard and not vabase and not recret and
		#g.kept == 0 and #(g.pinsave or {}) == 0
	local touch = false

	if bare then
		for _, d in ipairs(params or {}) do
			if not d.inplace then bare = false break end
		end
	end
	if bare and g.body then
		for line in g.body:lines() do
			if line:find("%ebp", 1, true) then
				touch = true
				break
			end
		end
		bare = not touch
	end
	g.bare = bare or nil
	if not bare then
		g:write("\tpushl\t%ebp\n\tmovl\t%esp,%ebp\n")
		if frame > 0 then
			g:write("\tsubl\t$" .. frame .. ",%esp\n")
		end
	end
	for _, k in ipairs(g.kept) do
		g:write(("\tmovl\t%s,%d(%%ebp)\n"):format(k[1], k[2]))
	end
	for _, k in ipairs(g.pinsave or {}) do
		g:write(("\tmovl\t%s,%d(%%ebp)\n")
			:format(regname(k.reg, 4), k.off))
	end
	-- Everything that arrived in a register is put away first: what
	-- follows uses those same registers as scratch.
	if recret and recret.ptr and recret.inreg then
		g:write(("\tmovl\t%s,%d(%%ebp)\n")
			:format(ARGREG[1], recret.ptr))
	end
	for _, d in ipairs(params or {}) do
		if d.pieces then
			for _, pc in ipairs(d.pieces) do
				g:write(("\tmovl\t%s,%d(%%ebp)\n")
					:format(ARGREG[pc.r + 1],
						d.off + pc.off))
			end
		elseif d.reg and d.into then
			-- A local kept in a register takes the argument
			-- straight from the one it arrived in; the slot
			-- has no reader and needs no store.
			g:write(("\tmovl\t%s,%s\n"):format(
				ARGREG[d.reg + 1], regname(d.into, 4)))
		elseif d.reg then
			for k = 0, (d.words or 1) - 1 do
				g:write(("\tmovl\t%s,%d(%%ebp)\n")
					:format(ARGREG[d.reg + 1 + k],
						d.off + k * 4))
			end
		end
	end
	if guard then setguard(g, guard, name) end
	-- The caller handed over where to write a record result, as the
	-- first of its stack words.
	if recret and recret.ptr and not recret.inreg then
		g:write(("\tmovl\t%d(%%ebp),%%eax\n"):format(stackargs))
		g:write(("\tmovl\t%%eax,%d(%%ebp)\n"):format(recret.ptr))
	end
	for _, d in ipairs(params or {}) do
		if d.reg or d.pieces then	-- already put away
		elseif d.mem then
			-- a record the caller left on its own stack
			g:write(("\tleal\t%d(%%ebp),%%eax\n"):format(d.off))
			g:write(("\tleal\t%d(%%ebp),%%edx\n")
				:format(stackargs + d.stk * 4))
			blockcopy(g, d.size, 0)
		else
			for k = 0, (d.words or 1) - 1 do
				g:write(("\tmovl\t%d(%%ebp),%%eax\n")
					:format(stackargs + (d.stk + k) * 4))
				g:write(("\tmovl\t%%eax,%d(%%ebp)\n")
					:format(d.off + k * 4))
			end
		end
	end
end

-- The i-th four-byte local, counting from one, past the three registers
-- the frame holds for the caller.
local function slot(i)
	return -4 * i - KEPT
end

-- The frame, kept sixteen-byte aligned and then eight past it: the call
-- that arrived pushed a word and the prologue pushed ebp, so eight more
-- is what puts the stack pointer back on a boundary for the next call.
local function frame(n)
	return ((4 * n + KEPT + 15) // 16) * 16 + 8
end

-- The result is already in the first allocation-order register, which is
-- also the one the ABI returns in.  A floating point result has to go
-- onto the x87 stack, because this compiler keeps it as a bit pattern.
local function epilogue(g, frame_, fltret, wideret, recret, guard)
	if recret and recret.cls then
		-- The result sits in a slot of ours; hand back the pieces.
		-- edx is read first, because eax is the one the loads use.
		for k = #recret.cls, 1, -1 do
			local p = recret.cls[k]

			g:write(("\tmovl\t%d(%%ebp),%s\n")
				:format(recret.off + p.off,
					k == 1 and "%eax" or "%edx"))
		end
	elseif recret then
		-- Through the caller's pointer, and the pointer goes back
		-- in eax as well.
		g:write(("\tmovl\t%d(%%ebp),%%eax\n"):format(recret.ptr))
		g:write(("\tleal\t%d(%%ebp),%%edx\n"):format(recret.off))
		blockcopy(g, recret.size, 0)
		g:write(("\tmovl\t%d(%%ebp),%%eax\n"):format(recret.ptr))
	elseif fltret == 8 then
		-- a double, which is held by address
		g:write("\tfldl\t(%eax)\n")
	elseif fltret == 4 then
		g:write("\tsubl\t$4,%esp\n\tmovl\t%eax,(%esp)\n")
		g:write("\tflds\t(%esp)\n\taddl\t$4,%esp\n")
	elseif wideret then
		-- eax holds the address of the value; the two words go
		-- back in edx:eax, the high one read first
		g:write("\tmovl\t4(%eax),%edx\n\tmovl\t(%eax),%eax\n")
	end
	local pops = recret and recret.ptr and not recret.inreg and HIDDEN
		     or nil
	local bad = guard and checkguard(g, guard)

	for _, k in ipairs(g.pinsave or {}) do
		g:write(("\tmovl\t%d(%%ebp),%s\n")
			:format(k.off, regname(k.reg, 4)))
	end
	for _, k in ipairs(g.kept or KEEP) do
		g:write(("\tmovl\t%d(%%ebp),%s\n"):format(k[2], k[1]))
	end
	g:write((g.bare and "" or "\tleave\n") .. retinsn(g, pops))
	if not bad then return end
	g:write(bad .. ":\n")
	g:write("\tpushl\t$0\n")
	g:write("\tpushl\t$" .. guard.label .. "\n")
	g:write("\tcall\t" .. (g.o.guardfail or SMASH) .. "\n")
end

local function jump(g, label)
	g:write("\tjmp\t" .. label .. "\n")
end

-- GNU labels as values: the address is in a register.
local function jumpto(g, reg)
	if g.o.retpoline then
		g:write("\tmovl\t" .. regname(reg, 4) .. "," .. TMP .. "\n")
		return g:write("\tjmp\t" .. THUNK .. "\n")
	end
	g:write("\tjmp\t*" .. regname(reg, 4) .. "\n")
end

-- What a header is entitled to ask the compiler about the machine.
local predef = {
	__i386__ = "1", __i386 = "1", i386 = "1", __i686__ = "1",
	__ILP32__ = "1", _ILP32 = "1",
	__SIZEOF_POINTER__ = "4", __SIZEOF_LONG__ = "4",
	__SIZEOF_LONG_LONG__ = "8", __SIZEOF_INT__ = "4",
	__SIZEOF_SHORT__ = "2", __SIZEOF_DOUBLE__ = "8",
	__SIZEOF_FLOAT__ = "4", __SIZEOF_SIZE_T__ = "4",
	__SIZEOF_LONG_DOUBLE__ = "8",
	__CHAR_BIT__ = "8", __ORDER_LITTLE_ENDIAN__ = "1234",
	__ORDER_BIG_ENDIAN__ = "4321", __BYTE_ORDER__ = "1234",
	__ELF__ = "1",
}

-- The peephole rules.  Each reads the last few lines and answers with
-- what goes in their place, or nothing to leave them alone.
local MOV = {movb = 1, movw = 2, movl = 4}

local function isreg(x) return x and x:sub(1, 1) == "%" end

-- Which machine register a name stands for, whatever width it was
-- written at: %eax, %ax and %al are one register, and a rule that
-- asks whether a value dies has to know that.
local WHICH = {}
for i, names in pairs{
	[0] = {"al", "ax", "eax"}, {"bl", "bx", "ebx"},
	{"cl", "cx", "ecx"}, {"dl", "dx", "edx"},
	{"si", "esi"}, {"di", "edi"}, {"bp", "ebp"}, {"sp", "esp"},
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
	-- Nothing can reach what stands after an unconditional branch,
	-- and a window never spans a label.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if (a.mnem == "jmp" or a.mnem == "ret") and b.mnem then
			return {a}
		end
	end},

	-- A move from a register to itself.
	{n = 1, f = function(w, i)
		local a = w[i]

		if MOV[a.mnem or ""] and a.a and a.a == a.b then
			return {}
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

	-- A jump to the line below it.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem == "jmp" and b.label and a.a == b.label then
			return {b}
		end
	end},

	-- A value pushed and taken straight back.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem == "pushl" and b.mnem == "popl" then
			if a.a == b.a then return {} end
			return {peep.line(("\tmovl\t%s,%s"):format(a.a, b.a))}
		end
	end},

	-- A value pushed and taken straight back.
	{n = 4, f = function(w, i)
		local a, b, c, d = w[i], w[i + 1], w[i + 2], w[i + 3]

		if a.mnem == "subl" and a.a == "$16" and a.b == "%esp" and
		   b.mnem == "movl" and b.b == "(%esp)" and
		   c.mnem == "movl" and c.a == "(%esp)" and
		   d.mnem == "addl" and d.a == "$16" and d.b == "%esp" then
			if b.a == c.b then return {} end
			return {peep.line(("\tmovl\t%s,%s"):format(b.a, c.b))}
		end
	end},

	-- A value put down and never taken back: the store is dead and
	-- the room it went in comes straight back.  The rule above
	-- leaves this where another rule took the load away first.
	{n = 3, f = function(w, i)
		local a, b, c = w[i], w[i + 1], w[i + 2]

		if a.mnem == "subl" and a.a == "$16" and a.b == "%esp" and
		   MOV[b.mnem or ""] and b.b == "(%esp)" and
		   c.mnem == "addl" and c.a == "$16" and c.b == "%esp" then
			return {}
		end
	end},

	-- An address made by adding a constant, and read once: the
	-- constant is the displacement and the add is nothing.  A
	-- member reached through a pointer is written this way.
	--
	-- Only where the value that was added to dies at once, which
	-- is where the load writes the same register back.  A store
	-- through the address leaves it live, and an instruction that
	-- reads its destination as well as writing it would change
	-- meaning: `addl $8,%eax; addl (%eax),%eax` is not
	-- `addl 8(%eax),%eax`.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem ~= "addl" then return end
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

local spec = md.target{
	name = "i386",
	ptrsize = 4,
	-- The ABI aligns a double and a long long to four, not to their
	-- own width, which no other machine here does.
	maxalign = 4,
	predef = predef,
	charsigned = true,
	alloca = true,
	tls = true,
	nreg = NREG,
	-- ebx is past the allocation order, so no expression is ever
	-- using it, and the ABI asks the callee to give it back, so a
	-- local in it is good over a call as well -- which is what
	-- `freesaved` says.  `keepers` saves it only in a body that
	-- turns out to use it.
	freeregs = {3, 5},
	freesaved = true,
	-- edi is not in the allocation order and no value is ever put
	-- in one, so a local may live there for a whole body.  esi is
	-- the scratch the code tables use and cannot be spared.
	pinregs = {5},
	-- How far an inline asm may reach for scratch: past nreg the
	-- register is one the ABI wants back, so it is saved first.
	nasmreg = 6,
	-- A record never travels in a register here, but one may still be
	-- passed and returned.
	recabi = true,
	eightbytes = eightbytes,
	argpieces = argpieces,
	-- A value wider than a register travels by address.
	wideargs = true,
	peep = peeprules,
	hiddenarg = true,
	-- The ABI hands a floating point result back on the x87 stack
	-- even though no value is ever held in one.
	fltretabi = true,
	regname = regname,
	hwfloat = false,
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
	memreg = function(r) return "(" .. regname(r, 4) .. ")" end,
	jumpto = jumpto,
	asmreg = asmreg,
	-- Where a frame is and what it remembers: the register the
	-- prologue leaves pointing at it, how far from there the return
	-- address sits, and how far the frame before it.
	frameptr = "ebp",
	retaddroff = 4,
	prevframeoff = 0,
	hardreg = hardreg,
	readhard = readhard,
	asmfits = asmfits,
	asmpin = asmpin,
	asmkeep = asmkeep,
	asmimm = asmimm,
	asmflag = asmflag,
	rawmove = rawmove,
	move = move,
	blockcopy = blockcopy,
	convert = convert,
	data = data,
	prologue = prologue,
	stackargs = stackargs,
	nargreg = T.nargreg,
	nfltreg = T.nfltreg,
	vafloat = T.vafloat,
	fltspill = T.fltspill,
	pairalign = false,
	varstack = true,
	fltstack = true,
	epilogue = epilogue,
	slot = slot,
	frame = frame,
	jump = jump,
	code = code,
	trailer = trailer,
}

-- `-mregparm=n` puts the first n integer arguments in eax, edx and
-- ecx, and hands a record result's pointer over in the first of them
-- rather than on the stack, so the callee pops nothing on the way
-- back.  A kernel's real mode code is built that way.
-- `-mpreferred-stack-boundary=n` asks for 2^n byte alignment at a
-- call.  Sixteen is what this machine does by default and is at least
-- what any of them ask for; below four the spill path can be cheaper.
-- Whether a value of this width has a name in this register.  esi and
-- edi have no eight-bit half, so a `char` cannot live in one.
function spec.canhold(r, size)
	local names = REG[r]

	return names ~= nil and names[SLOT[size] or 0] ~= nil
end

function spec.stackboundary(n)
	if n > 2 or PUSHSPILL then return end
	PUSHSPILL = true
	-- The code tables give the room back in their own text.  A
	-- scratch push is four bytes now, so say four there too, or
	-- esp walks up by twelve every time one of them runs.
	for _, tbl in pairs(code) do
		for _, alts in pairs(type(tbl) == "table" and tbl or {}) do
			for _, a in ipairs(type(alts) == "table" and
					   alts or {}) do
				if type(a) == "table" and
				   type(a.asm) == "string" then
					a.asm = a.asm
						:gsub("%$16,%%esp", "$4,%%esp")
						:gsub("16%(%%esp%),%%esp",
						      "4(%%esp),%%esp")
				end
			end
		end
	end
end

function spec.regparm(n)
	if n < 0 or n > #ARGREG then
		error("-mregparm takes 0 to " .. #ARGREG)
	end
	REGPARM, T.nargreg, spec.nargreg = n, n, n
end

return spec
