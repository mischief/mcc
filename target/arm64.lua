-- AArch64, the ABI Linux uses (AAPCS64).
--
-- It sits between the other two.  Like RISC-V nothing is addressable
-- inside an arithmetic instruction, so the operand classes below `i` carry
-- only constants and every value has to be loaded first.  Like amd64 there
-- are flags, so a comparison and its branch are two instructions and the
-- `cc` table leaves the flags set.
--
-- Three things are its own:
--   * a register is named for the width it is used at, w or x
--   * a global takes two instructions to reach, a page and an offset
--   * only add and sub take a plain immediate.  The logical instructions
--     take a bitmask immediate, which is a small and awkward set, so a
--     constant for one of those is put in a register first.

local md = require "md"
local data = require "data"
local tree = require "tree"

local arm64 = {}

-- x0 to x7 carry arguments and x9 upward are scratch.  x8 is the indirect
-- result register, x16 and x17 belong to the linker's veneers, x18 is the
-- platform's, x29 and x30 are the frame and the return address.  x15 is
-- kept back as somewhere to build an address that is too far to reach.
local REG = {
	[0] = "0", [1] = "1", [2] = "2", [3] = "3",
	[4] = "4", [5] = "5", [6] = "6", [7] = "7",
	[8] = "9", [9] = "10", [10] = "11", [11] = "12",
	[12] = "13", [13] = "14",
}
local TMP = "x15"

local BASE = {
	ADD = "add", SUB = "sub", AND = "and", OR = "orr", XOR = "eor",
	MUL = "mul", SHL = "lsl",
}
-- Only these take a plain immediate; see the note above.
local IMM = {ADD = true, SUB = true, SHL = true, SHR = true}

-- The condition a branch tests, and its opposite.
local CC  = {EQ = {"eq", "ne"}, NE = {"ne", "eq"},
	     LT = {"lt", "ge"},  GE = {"ge", "lt"},
	     GT = {"gt", "le"},  LE = {"le", "gt"}}
local UCC = {EQ = {"eq", "ne"}, NE = {"ne", "eq"},
	     LT = {"lo", "hs"},  GE = {"hs", "lo"},
	     GT = {"hi", "ls"},  LE = {"ls", "hi"}}

local WMN = {[8] = {"ldr", "str", "x"}, [4] = {"ldr", "str", "w"},
	     [2] = {"ldrh", "strh", "w"}, [1] = {"ldrb", "strb", "w"}}

local function fits12(v)
	return v >= 0 and v <= 4095
end

local function regname(r, size)
	local n = REG[r] or error("out of registers: r" .. r)
	return ((size or 8) == 8 and "x" or "w") .. n
end

-- The widest thing a load or store offset can be, which is a scaled
-- unsigned twelve-bit field or a signed nine-bit one.
local function fitsoff(off, size)
	if off >= -256 and off <= 255 then return true end
	return off >= 0 and off % size == 0 and off // size <= 4095
end

-- A constant, in as few instructions as it takes.  movz starts it and
-- movk fills in each sixteen-bit piece that is not already right.
local function loadconst(g, r, v, size)
	local w = size == 8 and 64 or 32
	local m = size == 8 and 0xffffffffffffffff or 0xffffffff

	v = v & m
	if v == 0 then
		return g:write(("\tmov\t%s,#0\n"):format(r))
	end
	-- a negative value is shorter built from its complement
	local neg = size == 8 and ~v or (~v & 0xffffffff)
	local function pieces(x)
		local n = 0

		for i = 0, w - 16, 16 do
			if (x >> i) & 0xffff ~= 0 then n = n + 1 end
		end
		return n
	end
	if pieces(neg) < pieces(v) then
		local first = true

		for i = 0, w - 16, 16 do
			local p = (neg >> i) & 0xffff

			if first and p ~= 0 or (first and i == w - 16) then
				g:write(("\tmovn\t%s,#%d,lsl #%d\n")
					:format(r, p, i))
				first = false
			elseif not first and ((v >> i) & 0xffff) ~= 0xffff then
				g:write(("\tmovk\t%s,#%d,lsl #%d\n")
					:format(r, (v >> i) & 0xffff, i))
			end
		end
		return
	end
	local first = true

	for i = 0, w - 16, 16 do
		local p = (v >> i) & 0xffff

		if p ~= 0 or (first and i == w - 16) then
			g:write(("\t%s\t%s,#%d,lsl #%d\n")
				:format(first and "movz" or "movk", r, p, i))
			first = false
		end
	end
end

function arm64.new()
	local ws = 8

	local function loadmn(ty)
		local u = ty.kind == "uint"

		if ty.size == 1 then return u and "ldrb" or "ldrsb" end
		if ty.size == 2 then return u and "ldrh" or "ldrsh" end
		return "ldr"
	end

	local function storemn(ty)
		return ({[1] = "strb", [2] = "strh"})[ty.size] or "str"
	end

	local function mnem(n, a)
		local op = n.op

		if op == "AUTO" or op == "NAME" or op == "INDIR" then
			return loadmn(n.ty)
		end
		if op == "ASGN" then return storemn(n.ty) end
		if op == "POSTADD" then
			return a and a.store and storemn(n.ty) or loadmn(n.ty)
		end
		local b = BASE[op]
		local u = n.ty.kind == "uint"

		if op == "SHR" then
			b = u and "lsr" or "asr"
		elseif op == "DIV" then
			b = u and "udiv" or "sdiv"
		end
		return b
	end

	-- A value loaded narrower than a register is already in the register
	-- at its own width, so a load names the destination by the width the
	-- instruction writes: everything below eight bytes writes w.
	local function lreg(r, ty)
		return regname(r, ty.size == 8 and 8 or 4)
	end

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

	-- A frame offset past the field the instruction has goes into x15
	-- first, which nothing between here and the instruction touches.
	local function frameaddr(g, off, size, base)
		base = base or "x29"
		if fitsoff(off, size or 8) then
			return ("[%s,#%d]"):format(base, off)
		end
		loadconst(g, TMP, off, 8)
		g:write(("\tadd\t%s,%s,%s\n"):format(TMP, base, TMP))
		return "[" .. TMP .. "]"
	end

	local function addr(g, n)
		local op = n.op

		if op == "AUTO" then
			return frameaddr(g, n.off, n.ty.size)
		elseif op == "CONST" then
			return "#" .. n.val
		elseif op == "NAME" then
			-- A global is a page and an offset, so it cannot be
			-- one operand: its address is built in x15 first.
			-- One template may name one global this way.
			g:write(("\tadrp\t%s,%s\n\tadd\t%s,%s,#:lo12:%s\n")
				:format(TMP, n.sym, TMP, TMP, n.sym))
			return "[" .. TMP .. "]"
		end
		error("cannot address " .. op .. " directly on arm64")
	end

	local function suffix(ty) return "" end

	local function branch(g, n, label, sense, reg)
		local pair = CC[n.op]

		if pair then
			if n.left.ty.kind == "uint" or
			   n.left.ty.kind == "ptr" then
				pair = UCC[n.op]
			end
		else
			pair = {"ne", "eq"}
		end
		g:write(("\tb.%s\t%s\n"):format(pair[sense and 1 or 2], label))
	end

	local function save(g, i)
		g:write(("\tstr\t%s,[sp,#-16]!\n"):format(regname(i, 8)))
	end

	local function restore(g, i)
		g:write(("\tldr\t%s,[sp],#16\n"):format(regname(i, 8)))
	end

	local ARGREG = {}
	for i = 0, 7 do ARGREG[i + 1] = "x" .. i end

	-- AAPCS: a record of up to four members that are all the same
	-- floating point type travels in that many vector registers.  Any
	-- other record of sixteen bytes or less travels in x registers,
	-- whatever it holds, and a bigger one as a pointer to a copy the
	-- caller makes.
	local function eightbytes(ty, named)
		if ty.size == 0 or ty.size > 16 then return nil end
		if named == false then return md.pieces(ty.size, 8) end
		return md.floatrec(ty, 4) or md.pieces(ty.size, 8)
	end

	local T = {
		ptrsize = ws,
		nargreg = 8,
		nfltreg = 8,
		vafloat = true,
		fltspill = false,
		recref = true,
		eightbytes = eightbytes,
	}

	local function classify(n)
		local shape = {}

		for i, a in ipairs(n.args or {}) do
			local rec = n.recs and n.recs[i]

			shape[i] = {flt = not n.soft and a.ty.kind == "float",
				    rec = rec,
				    size = rec and rec.size or a.ty.size}
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
		if bytes > 0 then
			g:write(("\tsub\tsp,sp,#%d\n"):format(bytes))
			for i, d in ipairs(dest) do
				if d.mem then
					-- a record the registers could not
					-- hold: leave a copy here
					g:expr(args[i], "reg", reg + 1)
					addimm(g, regname(reg, 8), "sp",
						d.stk * ws)
					blockcopy(g, d.size, reg)
				elseif d.stk then
					g:expr(args[i], "reg", reg)
					g:write(("\tstr\t%s,[sp,#%d]\n")
						:format(regname(reg, 8),
							d.stk * ws))
				end
			end
		end
		local order = {}

		for i, d in ipairs(dest) do
			if d.pieces then
				-- a record in registers: one push a piece
				g:expr(args[i], "reg", reg)
				for _, p in ipairs(d.pieces) do
					-- read only the piece: the record
					-- may end at a page boundary
					local t = p.size > 4 and TMP or "w15"

					g:write(("\tldr\t%s,[%s,#%d]\n")
						:format(t, regname(reg, 8),
							p.off))
					g:write(("\tstr\t%s,[sp,#-16]!\n")
						:format(TMP))
					order[#order + 1] = {flt = p.flt,
							     reg = p.r,
							     size = p.size}
				end
			elseif d.reg then
				order[#order + 1] = d
				g:expr(args[i], "stack", reg)
			end
		end
		-- A record the return registers cannot hold is written
		-- through a pointer of its own, which x8 carries.
		if n.retrec and not eightbytes(n.retrec) then
			addimm(g, "x8", "x29", n.retslot)
		end
		-- x16 is not allocatable, so the address survives the pops
		if not n.direct then
			g:expr(n.left, "reg", reg)
			g:write(("\tmov\tx16,%s\n"):format(regname(reg, 8)))
		end
		for k = #order, 1, -1 do
			local d = order[k]

			if d.flt then
				g:write(("\tldr\t%s%d,[sp],#16\n")
					:format(d.size == 8 and "d" or "s",
						d.reg))
			else
				g:write(("\tldr\t%s,[sp],#16\n")
					:format(ARGREG[d.reg + 1]))
			end
		end
		if n.direct then
			g:write("\tbl\t" .. n.left.sym .. "\n")
		else
			g:write("\tblr\tx16\n")
		end
		if bytes > 0 then
			g:write(("\tadd\tsp,sp,#%d\n"):format(bytes))
		end
		if n.retrec then
			-- A record that came back in registers goes to the
			-- slot the caller set aside; one written through x8
			-- is there already.
			local ni, nf = 0, 0

			for _, p in ipairs(eightbytes(n.retrec) or {}) do
				local at = frameaddr(g, n.retslot + p.off,
					p.size)

				if p.flt then
					g:write(("\tstr\t%s%d,%s\n")
						:format(p.size == 8 and "d"
							or "s", nf, at))
					nf = nf + 1
				else
					g:write(("\tstr\tx%d,%s\n")
						:format(ni, at))
					ni = ni + 1
				end
			end
		elseif not n.soft and n.ty.kind == "float" then
			g:write(("\tfmov\t%s,%s0\n")
				:format(regname(reg, n.ty.size),
					n.ty.size == 8 and "d" or "s"))
		else
			g:write(("\tmov\t%s,x0\n"):format(regname(reg, 8)))
		end
		for i = reg - 1, 0, -1 do
			restore(g, i)
		end
	end

	-- Anything written to a w register clears the top half of the x
	-- register, so a value narrower than eight bytes lives zero
	-- extended whatever its own sign.  Widening it to eight is
	-- therefore a real instruction for a signed value, and for an
	-- unsigned one only a matter of writing w again.
	local SX = {[1] = "sxtb", [2] = "sxth", [4] = "sxtw"}
	local UX = {[1] = "uxtb", [2] = "uxth"}

	local function convert(g, from, to, reg)
		local x, w = regname(reg, 8), regname(reg, 4)

		if to.size >= 8 then
			if from.size >= 8 then return end
			if from.kind == "uint" then
				if UX[from.size] then
					g:write(("\t%s\t%s,%s\n")
						:format(UX[from.size], w, w))
				else
					g:write(("\tmov\t%s,%s\n")
						:format(w, w))
				end
			else
				g:write(("\t%s\t%s,%s\n")
					:format(SX[from.size], x, w))
			end
			return
		end
		-- narrowing: bring it back to the destination's own width
		if to.size >= 4 then
			return g:write(("\tmov\t%s,%s\n"):format(w, w))
		end
		local mn = to.kind == "uint" and UX[to.size] or SX[to.size]

		g:write(("\t%s\t%s,%s\n"):format(mn, w, w))
	end

	local function asmreg() return nil end

	local ALLOC = {}
	for i = 0, 13 do
		ALLOC["x" .. REG[i]] = i
		ALLOC["w" .. REG[i]] = i
	end
	local PRESERVED = {}
	for i = 19, 28 do
		PRESERVED["x" .. i] = true
		PRESERVED["w" .. i] = true
	end

	local function asmpin(name)
		return ALLOC[name], PRESERVED[name]
	end

	local function asmkeep(g, name, push)
		if push then
			g:write(("\tstr\t%s,[sp,#-16]!\n"):format(name))
		else
			g:write(("\tldr\t%s,[sp],#16\n"):format(name))
		end
	end

	local function asmimm(v) return "#" .. v end

	local function rawmove(g, dst, src)
		if dst ~= src then
			g:write(("\tmov\t%s,%s\n"):format(dst, src))
		end
	end

	local function move(g, dst, src)
		rawmove(g, regname(dst, 8), regname(src, 8))
	end

	local function blockcopy(g, size, reg)
		local d, s = regname(reg, 8), regname(reg + 1, 8)
		local off = 0

		for _, w in ipairs{8, 4, 2, 1} do
			local mn = WMN[w]

			while size - off >= w do
				local t = mn[3] == "x" and TMP or "w15"

				g:write(("\t%s\t%s,[%s,#%d]\n\t%s\t%s,[%s,#%d]\n")
					:format(mn[1], t, s, off,
						mn[2], t, d, off))
				off = off + w
			end
		end
	end

	local function adapt(g, n, ctx, reg)
		if ctx == "stack" then
			g:write(("\tstr\t%s,[sp,#-16]!\n")
				:format(regname(reg, 8)))
		elseif ctx == "cc" then
			-- a value used as a condition sets the flags itself
			g:write(("\tcmp\t%s,#0\n")
				:format(regname(reg, n.ty.size == 8 and 8
					or 4)))
		end
	end

	local function jump(g, label)
		g:write("\tb\t" .. label .. "\n")
	end

	-- GNU labels as values: the address is in a register.
	local function jumpto(g, reg)
		g:write("\tbr\t" .. regname(reg, 8) .. "\n")
	end

	local function slot(i)
		return -(2 * ws) - ws * i
	end

	local function frame(n)
		return ((2 * ws + ws * n + 15) // 16) * 16
	end

	local function addimm(g, dst, src, v)
		if v >= 0 and v <= 4095 then
			g:write(("\tadd\t%s,%s,#%d\n"):format(dst, src, v))
		elseif v < 0 and -v <= 4095 then
			g:write(("\tsub\t%s,%s,#%d\n"):format(dst, src, -v))
		else
			loadconst(g, TMP, v, 8)
			g:write(("\tadd\t%s,%s,%s\n"):format(dst, src, TMP))
		end
	end

	local function prologue(g, name, frame, params, vabase, static,
				recret)
		g:write("\t.text\n")
		if not static then
			g:write("\t.globl\t" .. name .. "\n")
		end
		g:write("\t.align\t2\n" .. name .. ":\n")
		-- The pair is pushed on its own: stp reaches 504 bytes and
		-- a frame is often deeper than that.  x29 is left holding
		-- the caller's stack pointer, so what the caller left above
		-- it is at a positive offset and the locals at a negative
		-- one.
		g:write("\tstp\tx29,x30,[sp,#-16]!\n")
		g:write("\tadd\tx29,sp,#16\n")
		addimm(g, "sp", "sp", -(frame - 16))
		-- x8 held where to write a record result.
		if recret and recret.ptr then
			g:write(("\tstr\tx8,%s\n")
				:format(frameaddr(g, recret.ptr, 8)))
		end
		-- Everything that arrived in a register is put away first:
		-- the copies below use those same registers as scratch.
		for _, d in ipairs(params or {}) do
			if d.pieces then
				for _, p in ipairs(d.pieces) do
					local at = frameaddr(g, d.off + p.off,
						p.size)

					if p.flt then
						g:write(("\tstr\t%s%d,%s\n")
							:format(p.size == 8
								and "d" or
								"s", p.r, at))
					else
						g:write(("\tstr\t%s,%s\n")
							:format(ARGREG[p.r + 1],
								at))
					end
				end
			elseif d.reg and d.flt then
				g:write(("\tstr\t%s%d,%s\n")
					:format(d.size == 8 and "d" or "s",
						d.reg,
						frameaddr(g, d.off, d.size)))
			elseif d.reg then
				g:write(("\tstr\t%s,%s\n")
					:format(ARGREG[d.reg + 1],
						frameaddr(g, d.off, 8)))
			end
		end
		if vabase then
			for i = 1, 8 do
				g:write(("\tstr\t%s,%s\n"):format(ARGREG[i],
					frameaddr(g, vabase + (i - 1) * ws, 8)))
			end
			for i = 1, 8 do
				g:write(("\tstr\td%d,%s\n"):format(i - 1,
					frameaddr(g, vabase + (8 + i - 1) * ws,
						8)))
			end
		end
		for _, d in ipairs(params or {}) do
			local stack = not d.reg and not d.pieces

			if d.mem then
				-- x29 is the caller's sp, so what it left
				-- on the stack starts right there
				addimm(g, regname(1, 8), "x29", d.stk * ws)
				addimm(g, regname(0, 8), "x29", d.off)
				blockcopy(g, d.size, 0)
			elseif d.ref then
				-- The caller handed over a copy it made;
				-- the pointer to it is parked in the first
				-- word of the slot the record wants.
				if stack then
					g:write(("\tldr\t%s,%s\n"):format(
						TMP,
						frameaddr(g, d.stk * ws, 8)))
					g:write(("\tstr\t%s,%s\n"):format(
						TMP, frameaddr(g, d.off, 8)))
				end
				g:write(("\tldr\t%s,%s\n")
					:format(regname(1, 8),
						frameaddr(g, d.off, 8)))
				addimm(g, regname(0, 8), "x29", d.off)
				blockcopy(g, d.size, 0)
			elseif stack then
				g:write(("\tldr\t%s,%s\n"):format(TMP,
					frameaddr(g, d.stk * ws, 8)))
				g:write(("\tstr\t%s,%s\n"):format(TMP,
					frameaddr(g, d.off, 8)))
			end
		end
	end

	local function epilogue(g, frame, fltret, wideret, recret)
		if recret and recret.cls then
			-- The result sits in a slot of ours; hand back the
			-- pieces.
			local ni, nf = 0, 0

			for _, p in ipairs(recret.cls) do
				local at = frameaddr(g, recret.off + p.off,
					p.size)

				if p.flt then
					g:write(("\tldr\t%s%d,%s\n")
						:format(p.size == 8 and "d"
							or "s", nf, at))
					nf = nf + 1
				else
					g:write(("\tldr\tx%d,%s\n")
						:format(ni, at))
					ni = ni + 1
				end
			end
		elseif recret then
			-- Too big for the registers: write it through the
			-- pointer the caller left in x8.
			g:write(("\tldr\t%s,%s\n")
				:format(regname(0, 8),
					frameaddr(g, recret.ptr, 8)))
			addimm(g, regname(1, 8), "x29", recret.off)
			blockcopy(g, recret.size, 0)
		elseif fltret then
			g:write(("\tfmov\t%s0,%s\n")
				:format(fltret == 8 and "d" or "s",
					regname(0, fltret)))
		end
		g:write("\tsub\tsp,x29,#16\n")
		g:write("\tldp\tx29,x30,[sp],#16\n")
		g:write("\tret\n")
	end

	local code = {reg = {}, eff = {}, cc = {}}

	code.reg.CONST = {
		{"n", "z", asm = function(g, n, reg)
			loadconst(g, regname(reg, n.ty.size == 8 and 8 or 4),
				n.val, n.ty.size == 8 and 8 or 4)
		end},
	}
	code.reg.AUTO = {{"i", "z", asm = function(g, n, reg)
		g:write(("\t%s\t%s,%s\n"):format(loadmn(n.ty), lreg(reg, n.ty),
			frameaddr(g, n.off, n.ty.size)))
	end}}
	-- A global is a page and an offset; the same register serves twice.
	code.reg.NAME = {{"a", "z", asm = function(g, n, reg)
		local x = regname(reg, 8)

		g:write(("\tadrp\t%s,%s\n"):format(x, n.sym))
		g:write(("\t%s\t%s,[%s,#:lo12:%s]\n")
			:format(loadmn(n.ty), lreg(reg, n.ty), x, n.sym))
	end}}
	code.reg.ADDR = {
		{"i", "z", asm = function(g, n, reg)
			addimm(g, regname(reg, 8), "x29", n.left.off)
		end},
		{"a", "z", asm = function(g, n, reg)
			local x = regname(reg, 8)

			g:write(("\tadrp\t%s,%s\n"):format(x, n.left.sym))
			g:write(("\tadd\t%s,%s,#:lo12:%s\n")
				:format(x, x, n.left.sym))
		end},
	}
	code.reg.INDIR = {{"n", "z", ev = "L", asm = function(g, n, reg)
		g:write(("\t%s\t%s,[%s]\n"):format(loadmn(n.ty),
			lreg(reg, n.ty), regname(reg, 8)))
	end}}
	code.reg.NEG = {{"n", "z", ev = "L", asm = "\tneg\t%R,%R"}}
	code.reg.NOT = {{"n", "z", ev = "L", asm = "\tmvn\t%R,%R"}}

	for _, op in ipairs{"ADD", "SUB", "AND", "OR", "XOR", "MUL",
			    "SHL", "SHR", "DIV"} do
		local alts = {}

		if IMM[op] then
			alts[#alts + 1] = {"n", "c", imm = true, ev = "L",
					   asm = "\t%I\t%R,%R,#%C2"}
		end
		alts[#alts + 1] = {"n", "e", ev = "L R1",
				   asm = "\t%I\t%R,%R,%R1"}
		alts[#alts + 1] = {"n", "n", ev = "Rs L",
				   asm = "\tldr\t%P1,[sp],#16\n" ..
					 "\t%I\t%R,%R,%R1"}
		code.reg[op] = alts
	end
	-- There is no remainder instruction: divide, then take the product
	-- of the quotient back off.
	code.reg.MOD = {
		{"n", "e", ev = "L R1", asm = function(g, n, reg)
			local a, b = regname(reg, n.ty.size == 8 and 8 or 4),
				regname(reg + 1, n.ty.size == 8 and 8 or 4)
			local t = n.ty.size == 8 and TMP or "w15"

			g:write(("\t%s\t%s,%s,%s\n")
				:format(n.ty.kind == "uint" and "udiv" or
					"sdiv", t, a, b))
			g:write(("\tmsub\t%s,%s,%s,%s\n"):format(a, t, b, a))
		end},
		{"n", "n", ev = "Rs L", asm = function(g, n, reg)
			local w = n.ty.size == 8 and 8 or 4
			local a, b = regname(reg, w), regname(reg + 1, w)
			local t = w == 8 and TMP or "w15"

			g:write(("\tldr\t%s,[sp],#16\n")
				:format(regname(reg + 1, 8)))
			g:write(("\t%s\t%s,%s,%s\n")
				:format(n.ty.kind == "uint" and "udiv" or
					"sdiv", t, a, b))
			g:write(("\tmsub\t%s,%s,%s,%s\n"):format(a, t, b, a))
		end},
	}

	for _, op in ipairs{"EQ", "NE", "LT", "LE", "GT", "GE"} do
		code.cc[op] = {
			{"n", "c", rz = 1, ev = "L", asm = "\tcmp\t%R,#%C2"},
			{"n", "e", rz = 1, ev = "L R1", asm = "\tcmp\t%R,%R1"},
			{"n", "n", rz = 1, ev = "Rs L",
			 asm = "\tldr\t%P1,[sp],#16\n\tcmp\t%R,%R1"},
		}
	end

	code.eff.ASGN = {
		{"i", "n", rz = 1, ev = "R", asm = function(g, n, reg)
			g:write(("\t%s\t%s,%s\n"):format(storemn(n.ty),
				lreg(reg, n.ty),
				frameaddr(g, n.left.off, n.ty.size)))
		end},
		{"n*", "n", rz = 1, ev = "R L1*", asm = function(g, n, reg)
			g:write(("\t%s\t%s,[%s]\n"):format(storemn(n.ty),
				lreg(reg, n.ty), regname(reg + 1, 8)))
		end},
		{"a", "n", rz = 1, ev = "R", asm = function(g, n, reg)
			local x = regname(reg + 1, 8)

			g:write(("\tadrp\t%s,%s\n"):format(x, n.left.sym))
			g:write(("\t%s\t%s,[%s,#:lo12:%s]\n")
				:format(storemn(n.ty), lreg(reg, n.ty), x,
					n.left.sym))
		end},
	}
	code.reg.ASGN = code.eff.ASGN

	code.reg.POSTADD = {
		{"i", "z", rz = 1, asm = function(g, n, reg)
			local at = frameaddr(g, n.left.off, n.ty.size)

			g:write(("\t%s\t%s,%s\n"):format(loadmn(n.ty),
				lreg(reg, n.ty), at))
			addimm(g, lreg(reg + 1, n.ty), lreg(reg, n.ty), n.val)
			g:write(("\t%s\t%s,%s\n"):format(storemn(n.ty),
				lreg(reg + 1, n.ty), at))
		end},
		{"n*", "z", rz = 1, ev = "L1*", asm = function(g, n, reg)
			local p = regname(reg + 1, 8)

			g:write(("\t%s\t%s,[%s]\n"):format(loadmn(n.ty),
				lreg(reg, n.ty), p))
			addimm(g, lreg(reg + 2, n.ty), lreg(reg, n.ty), n.val)
			g:write(("\t%s\t%s,[%s]\n"):format(storemn(n.ty),
				lreg(reg + 2, n.ty), p))
		end},
		{"a", "z", rz = 1, asm = function(g, n, reg)
			local p = regname(reg + 1, 8)

			g:write(("\tadrp\t%s,%s\n"):format(p, n.left.sym))
			g:write(("\tadd\t%s,%s,#:lo12:%s\n")
				:format(p, p, n.left.sym))
			g:write(("\t%s\t%s,[%s]\n"):format(loadmn(n.ty),
				lreg(reg, n.ty), p))
			addimm(g, lreg(reg + 2, n.ty), lreg(reg, n.ty), n.val)
			g:write(("\t%s\t%s,[%s]\n"):format(storemn(n.ty),
				lreg(reg + 2, n.ty), p))
		end},
	}
	code.eff.POSTADD = code.reg.POSTADD

	local predef = {
		__aarch64__ = "1", __AARCH64EL__ = "1", __ARM_64BIT_STATE = "1",
		__SIZEOF_POINTER__ = "8", __SIZEOF_LONG__ = "8",
		__SIZEOF_LONG_LONG__ = "8", __SIZEOF_INT__ = "4",
		__SIZEOF_SHORT__ = "2", __SIZEOF_DOUBLE__ = "8",
		__SIZEOF_FLOAT__ = "4", __SIZEOF_SIZE_T__ = "8",
		__CHAR_BIT__ = "8", __ORDER_LITTLE_ENDIAN__ = "1234",
		__ORDER_BIG_ENDIAN__ = "4321", __BYTE_ORDER__ = "1234",
		__ELF__ = "1", __LP64__ = "1", _LP64 = "1",
		__CHAR_UNSIGNED__ = "1",
	}

	local trailer = '\t.section\t.note.GNU-stack,"",@progbits\n'

	return md.target{
		name = "arm64",
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
		stackargs = 0,
		nargreg = 8,
		nfltreg = T.nfltreg,
		vafloat = T.vafloat,
		fltspill = T.fltspill,
		recabi = true,
		recref = true,
		eightbytes = eightbytes,
		epilogue = epilogue,
		slot = slot,
		frame = frame,
		jump = jump,
		jumpto = jumpto,
		code = code,
		trailer = trailer,
	}
end

return arm64.new()
