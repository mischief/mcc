-- RISC-V, one description for both widths.
--
-- `riscv.new{xlen = 64}` or `{xlen = 32}`.  rv32 is what an ESP32-C series
-- part runs; rv64 is what the UEFI platform runs.  The two differ in pointer
-- width, in the load and store mnemonics, and in whether 32-bit arithmetic
-- needs the w forms.
--
-- Three things differ from amd64 and they all show up in the description,
-- not above it:
--   * nothing is addressable inside an arithmetic instruction, so the
--     operand classes below `i` carry only constants
--   * there are no flags, so the cc table only evaluates and `branch` emits
--     the compare and the jump as one instruction
--   * register names do not change with width

local md = require "md"
local data = require "data"
local tree = require "tree"

local riscv = {}

local REG = {
	[0] = "a0", [1] = "a1", [2] = "a2", [3] = "a3",
	[4] = "a4", [5] = "a5", [6] = "a6", [7] = "a7",
	[8] = "t0", [9] = "t1", [10] = "t2", [11] = "t3",
	[12] = "t4", [13] = "t5",
}

local BASE = {
	ADD = "add", SUB = "sub", AND = "and", OR = "or", XOR = "xor",
	MUL = "mul", SHL = "sll",
}
-- Only these take a w form for 32-bit results on rv64.
local WIDE = {ADD = true, SUB = true, MUL = true, SHL = true, SHR = true,
	      DIV = true, MOD = true}
-- Only these have an immediate form.  There is no subi or muli.
local IMM = {ADD = true, AND = true, OR = true, XOR = true,
	     SHL = true, SHR = true}

local BR  = {EQ = {"beq", "bne"}, NE = {"bne", "beq"},
	     LT = {"blt", "bge"},  GE = {"bge", "blt"},
	     GT = {"blt", "bge"},  LE = {"bge", "blt"}}
local UBR = {EQ = {"beq", "bne"}, NE = {"bne", "beq"},
	     LT = {"bltu", "bgeu"}, GE = {"bgeu", "bltu"},
	     GT = {"bltu", "bgeu"}, LE = {"bgeu", "bltu"}}
-- GT and LE branch with the operands swapped.
local SWAP = {GT = true, LE = true}

-- Load and store mnemonics by width, for the block copy.  The widest one
-- is a register wide, so rv32 never reaches the eight-byte pair.
local WMN = {[8] = {"ld", "sd"}, [4] = {"lw", "sw"},
	     [2] = {"lh", "sh"}, [1] = {"lb", "sb"}}

local function fits12(v)
	return v >= -2048 and v <= 2047
end

function riscv.new(opt)
	local xlen = opt.xlen or 64
	local ws = xlen // 8
	local LD = xlen == 64 and "ld" or "lw"
	local SD = xlen == 64 and "sd" or "sw"

	local function regname(r)
		return REG[r] or error("out of registers: r" .. r)
	end

	local function loadmn(ty)
		local u = ty.kind == "uint"
		if ty.size == 1 then return u and "lbu" or "lb" end
		if ty.size == 2 then return u and "lhu" or "lh" end
		-- A 32-bit value lives in a register sign extended whatever
		-- its signedness, because that is what the w instructions
		-- produce and what the ABI asks for.
		if ty.size == 4 then return "lw" end
		return "ld"
	end

	local function storemn(ty)
		return ({[1] = "sb", [2] = "sh", [4] = "sw", [8] = "sd"})[ty.size]
	end

	local function mnem(n, a)
		local op = n.op
		if op == "AUTO" or op == "NAME" or op == "INDIR" then
			return loadmn(n.ty)
		end
		if op == "ASGN" then
			return storemn(n.ty)
		end
		if op == "POSTADD" then
			return a and a.store and storemn(n.ty) or loadmn(n.ty)
		end
		if op == "ADDR" then
			return n.left.op == "NAME" and "la" or "addi"
		end
		local b = BASE[op]
		local u = n.ty.kind == "uint"
		if op == "SHR" then
			b = u and "srl" or "sra"
		elseif op == "DIV" then
			b = u and "divu" or "div"
		elseif op == "MOD" then
			b = u and "remu" or "rem"
		end
		if not b then return nil end
		if a and a.imm then b = b .. "i" end
		if xlen == 64 and n.ty.size == 4 and WIDE[op] then
			b = b .. "w"
		end
		return b
	end

	-- A global needs its address built before it can be touched, so it sits
	-- one class above a frame slot.  A constant is cheap only while it fits
	-- the twelve-bit field.  An address always costs a register.
	local function dcalc(n, nreg)
		if n then
			if n.op == "CONST" then
				if n.val == 0 then return 4 end
				if fits12(n.val) then return 8 end
				return n.need <= nreg and 20 or 24
			end
			if n.op == "NAME" then return 16 end
			if n.op == "ADDR" then
				return n.need <= nreg and 20 or 24
			end
		end
		return tree.dcalc(n, nreg)
	end

	-- A load or store whose frame offset is past the 12-bit field needs
	-- the address in a register first.  t6 is not allocatable, so it can
	-- carry it, and nothing between here and the instruction touches it.
	local function frameaddr(g, off, base)
		base = base or "s0"
		if fits12(off) then
			return off .. "(" .. base .. ")"
		end
		g:write(("\tli\tt6,%d\n\tadd\tt6,%s,t6\n"):format(off, base))
		return "0(t6)"
	end

	local function addr(g, n)
		local op = n.op
		if op == "AUTO" then
			return frameaddr(g, n.off)
		elseif op == "NAME" then
			return n.sym
		elseif op == "CONST" then
			-- A 32-bit value lives in a register sign extended,
			-- so an unsigned constant past the signed range has
			-- to be written the way the w instructions leave it.
			local v = n.val
			if n.ty.size == 4 and v > 2147483647 then
				v = v - 4294967296
			end
			return tostring(v)
		elseif op == "ADDR" then
			return addr(g, n.left)
		end
		error("cannot address " .. op .. " directly on riscv")
	end

	local function suffix(ty)
		return ""
	end

	-- No flags: the comparison and the jump are one instruction, so the cc
	-- table only leaves the operands in registers.
	local function branch(g, n, label, sense, reg)
		local pair = BR[n.op]
		if not pair then
			g:write("\t" .. (sense and "bne" or "beq") .. "\t" ..
				regname(reg) .. ",zero," .. label .. "\n")
			return
		end
		if n.left.ty.kind ~= "int" then
			pair = UBR[n.op]
		end
		local rhs = "zero"
		if not (n.right.op == "CONST" and n.right.val == 0) then
			rhs = regname(reg + 1)
		end
		local a, b = regname(reg), rhs
		if SWAP[n.op] then a, b = b, a end
		g:write("\t" .. pair[sense and 1 or 2] .. "\t" .. a .. "," .. b ..
			"," .. label .. "\n")
	end

	local function save(g, i)
		g:write("\taddi\tsp,sp,-16\n\t" .. SD .. "\t" ..
			regname(i) .. ",0(sp)\n")
	end

	local function restore(g, i)
		g:write("\t" .. LD .. "\t" .. regname(i) ..
			",0(sp)\n\taddi\tsp,sp,16\n")
	end

	-- Arguments go in a0 upward, which the allocator also uses, so
	-- anything live is saved first and the values come back off the stack.
	local ARGREG = {"a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"}

	-- The ABI facts md.classify needs.  lp64d keeps a float file, but a
	-- variadic argument never uses it, and a float that finds the file
	-- full falls back to an integer register rather than to the stack.
	-- ilp32 on an ESP32-C series part has no float file at all, so a
	-- double travels as its bit pattern and nothing below fires.
	local T = {
		nargreg = #ARGREG,
		nfltreg = opt.fltreg or 0,
		vafloat = false,
		fltspill = true,
	}

	-- Moves between an integer register and a float one, by width.
	local FMV  = {[8] = "fmv.d.x", [4] = "fmv.w.x"}
	local FMVX = {[8] = "fmv.x.d", [4] = "fmv.x.w"}
	local FLD  = {[8] = "fld", [4] = "flw"}
	local FST  = {[8] = "fsd", [4] = "fsw"}

	local function classify(n)
		local shape = {}
		for i, a in ipairs(n.args or {}) do
			shape[i] = {flt = not n.soft and a.ty.kind == "float",
				    size = a.ty.size}
		end
		return md.classify(T, shape, n.nfixed)
	end

	local function call(g, n, reg)
		local args = n.args or {}
		local dest, _, _, nstack = classify(n)
		local bytes = ((nstack * ws + 15) // 16) * 16
		for i = 0, reg - 1 do
			save(g, i)
		end
		-- Arguments that did not fit a register go in a block of
		-- their own, which stays put while the rest are computed.
		if bytes > 0 then
			g:write("\taddi\tsp,sp,-" .. bytes .. "\n")
			for i, d in ipairs(dest) do
				if d.stk then
					g:expr(args[i], "reg", reg)
					g:write(("\t%s\t%s,%d(sp)\n"):format(
						SD, regname(reg), d.stk * ws))
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
		-- t6 is not allocatable, so the address survives the pops
		if not n.direct then
			g:expr(n.left, "reg", reg)
			g:write("\tmv\tt6," .. regname(reg) .. "\n")
		end
		for k = #order, 1, -1 do
			local d = dest[order[k]]
			if d.flt then
				g:write(("\t%s\tfa%d,0(sp)\n")
					:format(FLD[d.size], d.reg))
			else
				g:write("\t" .. LD .. "\t" ..
					ARGREG[d.reg + 1] .. ",0(sp)\n")
			end
			g:write("\taddi\tsp,sp,16\n")
		end
		if n.direct then
			g:write("\tcall\t" .. n.left.sym .. "\n")
		else
			g:write("\tjalr\tt6\n")
		end
		if bytes > 0 then
			g:write("\taddi\tsp,sp," .. bytes .. "\n")
		end
		if not n.soft and T.nfltreg > 0 and n.ty.kind == "float" then
			g:write(("\t%s\t%s,fa0\n")
				:format(FMVX[n.ty.size], regname(reg)))
		else
			g:write("\tmv\t" .. regname(reg) .. ",a0\n")
		end
		for i = reg - 1, 0, -1 do
			restore(g, i)
		end
	end

	-- Zero every bit above the given width.
	local function zeroabove(g, r, size)
		local sh = xlen - size * 8
		if sh <= 0 then return end
		if size == 1 then
			g:write("\tandi\t" .. r .. "," .. r .. ",255\n")
		else
			g:write(("\tslli\t%s,%s,%d\n\tsrli\t%s,%s,%d\n")
				:format(r, r, sh, r, r, sh))
		end
	end

	-- The canonical form of a value narrower than a register: a 32-bit
	-- one is sign extended whatever its signedness, which is what the w
	-- instructions and lw produce; a narrower one follows its own type,
	-- which is what lb and lbu produce.
	local function extend(g, r, size, kind)
		if xlen - size * 8 <= 0 then return end
		if size == 4 then
			g:write("\tsext.w\t" .. r .. "," .. r .. "\n")
		elseif kind == "uint" then
			zeroabove(g, r, size)
		else
			local sh = xlen - size * 8
			g:write(("\tslli\t%s,%s,%d\n\tsrai\t%s,%s,%d\n")
				:format(r, r, sh, r, r, sh))
		end
	end

	-- Widening to a full register only needs work for an unsigned value,
	-- whose canonical form leaves the top of the register set.  Narrowing
	-- recanonicalizes to the destination type.
	local function convert(g, from, to, reg)
		if to.size * 8 >= xlen then
			if from.size * 8 < xlen and from.kind == "uint" then
				zeroabove(g, regname(reg), from.size)
			end
			return
		end
		extend(g, regname(reg), to.size, to.kind)
	end

	local function blockcopy(g, size, reg)
		local d, s = regname(reg), regname(reg + 1)
		local tmp = regname(reg + 2)
		local off = 0
		for _, w in ipairs{ws, 4, 2, 1} do
			local mn = WMN[w]
			while mn and size - off >= w do
				g:write(("\t%s\t%s,%d(%s)\n\t%s\t%s,%d(%s)\n")
					:format(mn[1], tmp, off, s,
						mn[2], tmp, off, d))
				off = off + w
			end
		end
	end

	local function adapt(g, n, ctx, reg)
		if ctx == "stack" then
			g:write("\taddi\tsp,sp,-16\n\t" .. SD .. "\t" ..
				regname(reg) .. ",0(sp)\n")
		end
		-- cc needs nothing: branch tests the register itself
	end


	local function jump(g, label)
		g:write("\tj\t" .. label .. "\n")
	end

	local function slot(i)
		return -(2 * ws) - ws * i
	end

	local function frame(n)
		return ((2 * ws + ws * n + 15) // 16) * 16
	end

	local function prologue(g, name, frame, params, vabase, static)
		g:write("\t.text\n")
		if not static then
			g:write("\t.globl\t" .. name .. "\n")
		end
		g:write(name .. ":\n")
		if fits12(-frame) then
			g:write("\taddi\tsp,sp,-" .. frame .. "\n")
		else
			g:write("\tli\tt6," .. frame ..
				"\n\tsub\tsp,sp,t6\n")
		end
		g:write("\t" .. SD .. "\tra," ..
			frameaddr(g, frame - ws, "sp") .. "\n")
		g:write("\t" .. SD .. "\ts0," ..
			frameaddr(g, frame - 2 * ws, "sp") .. "\n")
		if fits12(frame) then
			g:write("\taddi\ts0,sp," .. frame .. "\n")
		else
			g:write("\tli\tt6," .. frame ..
				"\n\tadd\ts0,sp,t6\n")
		end
		for _, d in ipairs(params or {}) do
			if d.reg and d.flt then
				g:write(("\t%s\tfa%d,%d(s0)\n")
					:format(FST[d.size], d.reg, d.off))
			elseif d.reg then
				g:write("\t" .. SD .. "\t" .. REG[d.reg] ..
					"," .. d.off .. "(s0)\n")
			else
				-- s0 is the caller's sp, so the arguments it
				-- left on the stack start right there
				g:write(("\t%s\tt6,%d(s0)\n\t%s\tt6,%d(s0)\n")
					:format(LD, d.stk * ws, SD, d.off))
			end
		end
		-- A variadic function keeps every argument register.
		if vabase then
			for i = 1, 8 do
				g:write(("\t%s\t%s,%d(s0)\n")
					:format(SD, REG[i - 1],
						vabase + (i - 1) * ws))
			end
		end
	end

	local function epilogue(g, frame, fltret)
		if fltret then
			g:write(("\t%s\tfa0,%s\n")
				:format(FMV[fltret], regname(0)))
		end
		g:write("\t" .. LD .. "\tra," ..
			frameaddr(g, frame - ws, "sp") .. "\n")
		g:write("\t" .. LD .. "\ts0," ..
			frameaddr(g, frame - 2 * ws, "sp") .. "\n")
		if fits12(frame) then
			g:write("\taddi\tsp,sp," .. frame .. "\n")
		else
			g:write("\tli\tt6," .. frame ..
				"\n\tadd\tsp,sp,t6\n")
		end
		g:write("\tret\n")
	end

	local code = {reg = {}, eff = {}, cc = {}}

	code.reg.CONST = {
		{"z", "z", asm = "\tmv\t%R,zero"},
		{"n", "z", asm = "\tli\t%R,%A"},
	}
	code.reg.AUTO = {{"i", "z", asm = "\t%I\t%R,%A"}}
	-- A global takes its address first; the same register serves twice.
	code.reg.NAME = {{"a", "z", asm = "\tla\t%R,%A\n\t%I\t%R,0(%R)"}}
	-- The shapes describe the operand, which is the thing being addressed:
	-- a frame slot is class 12, a global is 16.
	code.reg.ADDR = {
		-- The frame offset may be past the 12-bit field, and then
		-- it takes a register of its own rather than an immediate.
		{"i", "z", asm = function(g, n, reg)
			local off, r = n.left.off, regname(reg)
			if fits12(off) then
				g:write(("\taddi\t%s,s0,%d\n"):format(r, off))
			else
				g:write(("\tli\t%s,%d\n\tadd\t%s,s0,%s\n")
					:format(r, off, r, r))
			end
		end},
		{"a", "z", asm = "\tla\t%R,%A1"},
	}
	code.reg.INDIR = {{"n", "z", ev = "L", asm = "\t%I\t%R,0(%P)"}}
	code.reg.NEG = {{"n", "z", ev = "L", asm = "\tneg\t%R,%R"}}
	code.reg.NOT = {{"n", "z", ev = "L", asm = "\tnot\t%R,%R"}}
	-- A postfix step yields the old value, then adjusts the lvalue.
	code.reg.POSTADD = {
		{"i", "z", rz = 1,
		 asm = "\t%I\t%R,%A1\n\taddi\t%R1,%R,%C\n\t%I2\t%R1,%A1"},
		{"n*", "z", rz = 1, ev = "L1*",
		 asm = "\t%I\t%R,0(%P1)\n\taddi\t%R2,%R,%C" ..
		       "\n\t%I2\t%R2,0(%P1)"},
	}
	code.eff.POSTADD = {
		{"i", "z", rz = 1,
		 asm = "\t%I\t%R,%A1\n\taddi\t%R,%R,%C\n\t%I2\t%R,%A1"},
		{"n*", "z", rz = 1, ev = "L1*",
		 asm = "\t%I\t%R,0(%P1)\n\taddi\t%R,%R,%C" ..
		       "\n\t%I2\t%R,0(%P1)"},
	}

	-- Divide, remainder and variable shifts are ordinary three-operand
	-- instructions here, so none of them needs a fixed register.
	for _, op in ipairs{"ADD", "SUB", "AND", "OR", "XOR", "MUL",
			    "SHL", "SHR", "DIV", "MOD"} do
		local alts = {}
		if IMM[op] then
			alts[#alts + 1] = {"n", "c", imm = true, ev = "L",
					   asm = "\t%I\t%R,%R,%C2"}
		end
		alts[#alts + 1] = {"n", "e", ev = "L R1",
				   asm = "\t%I\t%R,%R,%R1"}
		alts[#alts + 1] = {"n", "n", ev = "Rs L",
				   asm = "\t" .. LD .. "\t%R1,0(sp)\n" ..
					 "\taddi\tsp,sp,16\n" ..
					 "\t%I\t%R,%R,%R1"}
		code.reg[op] = alts
	end

	for _, op in ipairs{"EQ", "NE", "LT", "LE", "GT", "GE"} do
		code.cc[op] = {
			{"n", "z", ev = "L"},
			{"n", "n", ev = "L R1"},
		}
	end

	-- An indirection is class 16 like a global, so it has to be matched
	-- before the form that builds a symbol's address.
	code.eff.ASGN = {
		{"i",  "z", rz = 1,            asm = "\t%I\tzero,%A1"},
		{"i",  "n", rz = 1, ev = "R",  asm = "\t%I\t%R,%A1"},
		{"n*", "n", rz = 1, ev = "R L1*", asm = "\t%I\t%R,0(%P1)"},
		{"a",  "n", rz = 1, ev = "R",
		 asm = "\tla\t%R1,%A1\n\t%I\t%R,0(%R1)"},
	}
	-- Used for its value, an assignment must leave one behind, so the
	-- store-zero form is not available here.
	code.reg.ASGN = {
		{"i",  "n", rz = 1, ev = "R",  asm = "\t%I\t%R,%A1"},
		{"n*", "n", rz = 1, ev = "R L1*", asm = "\t%I\t%R,0(%P1)"},
		{"a",  "n", rz = 1, ev = "R",
		 asm = "\tla\t%R1,%A1\n\t%I\t%R,0(%R1)"},
	}

	-- What a header is entitled to ask the compiler about the machine.
	local predef = {
		__riscv = "1",
		__riscv_xlen = tostring(xlen),
		__SIZEOF_POINTER__ = tostring(ws),
		__SIZEOF_LONG__ = tostring(ws),
		__SIZEOF_LONG_LONG__ = "8",
		__SIZEOF_INT__ = "4", __SIZEOF_SHORT__ = "2",
		__SIZEOF_DOUBLE__ = "8", __SIZEOF_FLOAT__ = "4",
		__SIZEOF_SIZE_T__ = tostring(ws),
		__CHAR_BIT__ = "8", __ORDER_LITTLE_ENDIAN__ = "1234",
		__ORDER_BIG_ENDIAN__ = "4321", __BYTE_ORDER__ = "1234",
		__ELF__ = "1",
		__CHAR_UNSIGNED__ = "1",
	}
	if xlen == 64 then
		predef.__LP64__ = "1"
		predef._LP64 = "1"
		predef.__riscv_flen = "64"
		predef.__riscv_float_abi_double = "1"
	else
		predef.__riscv_float_abi_soft = "1"
	end

	return md.target{
		name = "riscv" .. xlen,
		xlen = xlen,
		ptrsize = ws,
		predef = predef,
		charsigned = false,
		nreg = 14,
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
		blockcopy = blockcopy,
		convert = convert,
		data = data,
		prologue = prologue,
		stackargs = 0,
		nargreg = 8,
		nfltreg = T.nfltreg,
		vafloat = T.vafloat,
		fltspill = T.fltspill,
		epilogue = epilogue,
		slot = slot,
		frame = frame,
		jump = jump,
		code = code,
	}
end

return riscv
