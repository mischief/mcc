-- SPDX-License-Identifier: ISC
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
local peep = require "peep"
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

-- Read a machine register a name is bound to: a file-scope `register`
-- declaration, or the one the prologue points at the frame.
local function readhard(g, name, reg, size)
	local n = name:gsub("^%%", "")

	if not (n:match("^x%d+$") or n == "sp" or n == "lr" or n == "fp") then
		error("no register " .. name)
	end
	g:write(("\tmov\t%s,%s\n"):format(regname(reg, size == 4 and 4 or 8),
		n))
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

	-- The scratch float file.  d0 to d7 are the ABI's and d8 to d15 are
	-- the callee's, so this starts at d16 and nothing has to be saved
	-- around a call but what is live.
	local function fregname(r, size)
		if r >= 8 then
			error("out of float registers: f" .. r)
		end
		return ((size or 8) == 8 and "d" or "s") .. (16 + r)
	end

	-- A float compare sets all four flags, and an unordered pair
	-- leaves N clear, C set and V set.  These are the conditions that
	-- answer no to that, which is what C asks of every relation but
	-- inequality -- and ne answers yes, which is what C asks of that.
	local FCC = {EQ = {"eq", "ne"}, NE = {"ne", "eq"},
		     LT = {"mi", "pl"},  GE = {"ge", "lt"},
		     GT = {"gt", "le"},  LE = {"ls", "hi"}}

	local function branch(g, n, label, sense, reg)
		local pair = CC[n.op]

		if pair then
			local kind = n.left.ty.kind

			if kind == "float" then
				pair = FCC[n.op]
			elseif kind == "uint" or kind == "ptr" then
				pair = UCC[n.op]
			end
		else
			pair = {"ne", "eq"}
		end
		g:write(("\tb.%s\t%s\n"):format(pair[sense and 1 or 2], label))
	end

	-- A depth holds a value in one file or the other, never both.
	local function save(g, i)
		if g.fdepth[i] then
			g:write(("\tstr\t%s,[sp,#-16]!\n")
				:format(fregname(i, 8)))
		else
			g:write(("\tstr\t%s,[sp,#-16]!\n")
				:format(regname(i, 8)))
		end
	end

	local function restore(g, i)
		if g.fdepth[i] then
			g:write(("\tldr\t%s,[sp],#16\n")
				:format(fregname(i, 8)))
		else
			g:write(("\tldr\t%s,[sp],#16\n")
				:format(regname(i, 8)))
		end
	end

	local ARGREG = {}
	for i = 0, 7 do ARGREG[i + 1] = "x" .. i end

	-- Add a constant to a register, which the call below needs before
	-- this file gets to defining it.
	local addimm

	-- An argument the machine can name in one instruction or two:
	-- nothing between here and the call can change what it means, so
	-- it goes straight into its own register at the end.
	local function simplearg(e)
		if not e then return false end
		local op = e.op

		if op == "CONST" then return true end
		if op == "AUTO" then return true end
		if op == "NAME" then return not e.got end
		if op == "ADDR" then
			local c = e.left

			return c and (c.op == "AUTO" or
				      (c.op == "NAME" and not c.got))
		end
		return false
	end

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
						:format(args[i].ty.kind ==
							"float" and
							fregname(reg,
								args[i].ty.size)
							or regname(reg, 8),
							d.stk * ws))
				end
			end
		end
		local order, straight = {}, {}

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
			elseif d.reg and not d.flt and simplearg(args[i]) then
				straight[#straight + 1] = {d = d, e = args[i]}
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
		-- The arguments that need no working out.  Nothing left to
		-- do can disturb them, and each names a register of its
		-- own, so the order among them does not matter.
		for _, x in ipairs(straight) do
			local e = x.e
			local w = e.ty.size == 8 and 8 or 4
			local r = (w == 8 and "x" or "w") .. x.d.reg

			if e.op == "CONST" then
				loadconst(g, r, e.val, w)
			elseif e.op == "AUTO" then
				g:write(("\tldr\t%s,%s\n")
					:format(r, frameaddr(g, e.off, w)))
			elseif e.op == "ADDR" and e.left.op == "AUTO" then
				addimm(g, "x" .. x.d.reg, "x29", e.left.off)
			else
				-- a global: its address is a page and an
				-- offset, and then the value is read
				local sym = e.op == "ADDR" and e.left.sym or
					e.sym

				g:write(("\tadrp\tx%d,%s\n")
					:format(x.d.reg, sym))
				g:write(("\tadd\tx%d,x%d,#:lo12:%s\n")
					:format(x.d.reg, x.d.reg, sym))
				if e.op ~= "ADDR" then
					g:write(("\tldr\t%s,[x%d]\n")
						:format(r, x.d.reg))
				end
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
		elseif n.ty.kind == "float" then
			-- A soft call answers with a bit pattern in x0; the
			-- ABI answers in d0.  Either way it belongs in the
			-- float file.
			-- the ABI answers in x0 or in d0, whatever depth
			-- this is
			g:write(("\tfmov\t%s,%s\n")
				:format(fregname(reg, n.ty.size),
					n.soft and
					(n.ty.size == 8 and "x0" or "w0")
					or ((n.ty.size == 8 and "d" or "s")
					    .. "0")))
		elseif n.ty.size == 1 or n.ty.size == 2 then
			-- The callee owes only the low bits of a narrow
			-- answer and the rest is whatever was in the
			-- register.  Every other way a value reaches one
			-- leaves it widened, so this one has to as well.
			local uns = n.ty.kind == "uint" or n.ty.isbool

			g:write(("\t%sxt%s\t%s,w0\n")
				:format(uns and "u" or "s",
					n.ty.size == 1 and "b" or "h",
					regname(reg, 4)))
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

	-- Between the two files, and between the two float widths.  Every
	-- one of these is a single instruction, unsigned included.
	local function fconvert(g, from, to, reg)
		if from.kind == "float" and to.kind == "float" then
			if from.size == to.size then return end
			g:write(("\tfcvt\t%s,%s\n")
				:format(fregname(reg, to.size),
					fregname(reg, from.size)))
		elseif to.kind == "float" then
			g:write(("\t%s\t%s,%s\n")
				:format(from.kind == "uint" and "ucvtf"
					or "scvtf", fregname(reg, to.size),
					regname(reg, 8)))
		else
			g:write(("\t%s\t%s,%s\n")
				:format(to.kind == "uint" and "fcvtzu"
					or "fcvtzs", regname(reg, 8),
					fregname(reg, from.size)))
		end
	end

	local function convert(g, from, to, reg)
		local x, w = regname(reg, 8), regname(reg, 4)

		if from.kind == "float" or to.kind == "float" then
			return fconvert(g, from, to, reg)
		end
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

	local function move(g, dst, src, size, flt)
		if flt then
			if dst ~= src then
				g:write(("\tfmov\t%s,%s\n")
					:format(fregname(dst, size),
						fregname(src, size)))
			end
			return
		end
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
				:format(n.ty.kind == "float"
					and fregname(reg, n.ty.size)
					or regname(reg, 8)))
		elseif ctx == "cc" and n.ty.kind == "float" then
			-- A NaN is unordered, which leaves Z clear, so the
			-- ne the branch falls back on counts it as true.
			g:write(("\tfcmp\t%s,#0.0\n")
				:format(fregname(reg, n.ty.size)))
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
	-- The peephole rules: what the code table cannot see, because it
	-- looks at one tree node at a time.
	local peeprules = {
		-- Nothing can reach what stands after an unconditional
		-- branch, and a window never spans a label.  It is bytes for
		-- nothing either way, and a validator that walks the code
		-- says so out loud.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if (a.mnem == "b" or a.mnem == "ret") and b.mnem then
				return {a}
			end
		end},

		-- A move from a register to itself, which every call ends
		-- with because the result is already where it belongs.
		{n = 1, f = function(w, i)
			local a = w[i]

			if a.mnem == "mov" and a.a and a.a == a.b then
				return {}
			end
		end},

		-- A branch to the line below it.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if a.mnem == "b" and b.label and a.a == b.label then
				return {b}
			end
		end},

		-- A value pushed and taken straight back.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			-- Only between two registers of the same file and
			-- the same width: anything else is a different
			-- instruction, or none.
			local function kind(r)
				local c = r and r:sub(1, 1)

				if c == "x" or c == "w" then return "g" end
				return c
			end

			local k = kind(a.a)

			if a.mnem == "str" and a.b == "[sp,#-16]!" and
			   b.mnem == "ldr" and b.b == "[sp],#16" and
			   k == kind(b.a) and
			   (k == "g" or k == "d" or k == "s") then
				if a.a == b.a then return {} end
				return {peep.line(("\t%s\t%s,%s")
					:format(k == "g" and "mov" or "fmov",
						b.a, a.a))}
			end
		end},

		-- A store read straight back out of the same place.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if a.mnem == "str" and b.mnem == "ldr" and
			   a.a == b.a and a.b == b.b and
			   a.b and a.b:sub(1, 4) ~= "[sp," then
				return {a}
			end
		end},

		-- A register written and then written again without being
		-- read in between.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if a.mnem == "mov" and a.a and a.b and
			   b.a == a.a and b.mnem ~= "cmp" and
			   b.b ~= a.a and (b.mnem == "mov" or
					   b.mnem == "movz") then
				return {b}
			end
		end},
	}

	local function jumpto(g, reg)
		g:write("\tbr\t" .. regname(reg, 8) .. "\n")
	end

	local function slot(i)
		return -(2 * ws) - ws * i
	end

	local function frame(n)
		return ((2 * ws + ws * n + 15) // 16) * 16
	end

	function addimm(g, dst, src, v)
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
				recret, sec)
		-- A section the program asked for by name, which a link
		-- script places where the machine needs it.
		g:write(sec and ("\t.section\t" .. sec ..
			",\"ax\",@progbits\n") or "\t.text\n")
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
			local d = fltret == 8 and "d" or "s"

			g:write(("\tfmov\t%s0,%s\n")
				:format(d, fregname(0, fltret)))
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
	-- The address of a global another unit may own.  A real global
	-- offset table is for a shared object, which this target does
	-- not build: everything it links ends up in one image, so the
	-- address is the same page and offset pair the plain one uses.
	code.reg.GOT = {{"a", "z", asm = function(g, n, reg)
		local x = regname(reg, 8)

		g:write(("\tadrp\t%s,%s\n"):format(x, n.left.sym))
		g:write(("\tadd\t%s,%s,#:lo12:%s\n")
			:format(x, x, n.left.sym))
	end}}
	code.reg.INDIR = {{"n", "z", ev = "L", asm = function(g, n, reg)
		g:write(("\t%s\t%s,[%s]\n"):format(loadmn(n.ty),
			lreg(reg, n.ty), regname(reg, 8)))
	end}}
	-- GNU alloca, and the room a variable length array takes.  The
	-- size is rounded up so the stack keeps its alignment, and the
	-- frame pointer puts the stack back on return.  Two shifts do
	-- the rounding, so nothing turns on a bitmask immediate.
	code.reg.ALLOCA = {{"n", "z", ev = "L", asm = function(g, n, reg)
		local x = regname(reg, 8)

		if g.nomove > 0 then
			error("alloca in an expression that uses the " ..
			      "stack is not supported", 0)
		end
		g:write(("\tadd\t%s,%s,#15\n"):format(x, x))
		g:write(("\tlsr\t%s,%s,#4\n"):format(x, x))
		g:write(("\tlsl\t%s,%s,#4\n"):format(x, x))
		g:write(("\tsub\tsp,sp,%s\n"):format(x))
		g:write(("\tadd\t%s,sp,#0\n"):format(x))
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

	-- Hardware floating point.  A float lives in the float file at the
	-- same depth as an integer would, so these are the integer rules
	-- again with %F for %R.  They go in front, because the integer
	-- alternatives carry no kind letter and would match a float first.
	do
		local function ahead(tab, alts)
			for i, a in ipairs(alts) do
				table.insert(tab, i, a)
			end
		end

		for _, w in ipairs{{sz = 8, l = "q"}, {sz = 4, l = "l"}} do
			local sz = w.sz
			local nf, ifl = "nf" .. w.l, "if" .. w.l
			local ef, af = "ef" .. w.l, "af" .. w.l

			-- No float immediate wide enough: the bits go
			-- through the integer register at this depth,
			-- which holds nothing while a float sits beside it.
			ahead(code.reg.CONST, {{nf, "z",
				asm = function(g, n, r)
				loadconst(g, regname(r, sz), n.val, sz)
				g:write(("\tfmov\t%s,%s\n")
					:format(fregname(r, sz),
						regname(r, sz)))
			end}})
			ahead(code.reg.AUTO, {{ifl, "z",
				asm = function(g, n, r)
				g:write(("\tldr\t%s,%s\n")
					:format(fregname(r, sz),
						frameaddr(g, n.off, sz)))
			end}})
			ahead(code.reg.NAME, {{af, "z",
				asm = function(g, n, r)
				local x = regname(r, 8)

				g:write(("\tadrp\t%s,%s\n"):format(x, n.sym))
				g:write(("\tldr\t%s,[%s,#:lo12:%s]\n")
					:format(fregname(r, sz), x, n.sym))
			end}})
			ahead(code.reg.INDIR, {{"n" .. w.l .. "pf", "z",
				ev = "L", asm = function(g, n, r)
				g:write(("\tldr\t%s,[%s]\n")
					:format(fregname(r, sz),
						regname(r, 8)))
			end}})
			ahead(code.reg.NEG, {{nf, "z", ev = "L",
				asm = "\tfneg\t%F,%F"}})
			code.reg.SQRT = code.reg.SQRT or {}
			ahead(code.reg.SQRT, {{nf, "z", ev = "L",
				asm = "\tfsqrt\t%F,%F"}})
			code.reg.FABS = code.reg.FABS or {}
			ahead(code.reg.FABS, {{nf, "z", ev = "L",
				asm = "\tfabs\t%F,%F"}})
			for op, mn in pairs{ADD = "fadd", SUB = "fsub",
					    MUL = "fmul", DIV = "fdiv"} do
				local x = "\t" .. mn .. "\t"

				ahead(code.reg[op], {
					{nf, ef, ev = "L R1",
					 asm = x .. "%F,%F,%F1"},
					{nf, nf, ev = "Rs L",
					 asm = "\tldr\t%F1,[sp],#16\n" ..
					       x .. "%F,%F,%F1"},
				})
			end
			for _, op in ipairs{"EQ", "NE", "LT", "LE",
					    "GT", "GE"} do
				ahead(code.cc[op], {
					{nf, ef, rz = 1, ev = "L R1",
					 asm = "\tfcmp\t%F,%F1"},
					{nf, nf, rz = 1, ev = "Rs L",
					 asm = "\tldr\t%F1,[sp],#16\n" ..
					       "\tfcmp\t%F,%F1"},
				})
			end
			local store = {
				{ifl, nf, rz = 1, ev = "R",
				 asm = function(g, n, r)
					g:write(("\tstr\t%s,%s\n")
						:format(fregname(r, sz),
							frameaddr(g,
								n.left.off,
								sz)))
				end},
				{"n*f" .. w.l, nf, rz = 1, ev = "R L1*",
				 asm = function(g, n, r)
					g:write(("\tstr\t%s,[%s]\n")
						:format(fregname(r, sz),
							regname(r + 1, 8)))
				end},
				{af, nf, rz = 1, ev = "R",
				 asm = function(g, n, r)
					local x = regname(r + 1, 8)

					g:write(("\tadrp\t%s,%s\n")
						:format(x, n.left.sym))
					g:write(("\tstr\t%s,[%s,#:lo12:%s]\n")
						:format(fregname(r, sz), x,
							n.left.sym))
				end},
			}
			-- reg.ASGN and eff.ASGN are one table here
			ahead(code.eff.ASGN, store)
		end
	end

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
		asmreg = asmreg,
		asmpin = asmpin,
		asmkeep = asmkeep,
		asmimm = asmimm,
		rawmove = rawmove,
		move = move,
		blockcopy = blockcopy,
		convert = convert,
		data = data,
		-- Where a frame is and what it remembers: the register
		-- the prologue leaves pointing at it, how far from there
		-- the return address sits, and how far the frame before.
		readhard = readhard,
		frameptr = "x29",
		retaddroff = -8,
		prevframeoff = -16,
		prologue = prologue,
		stackargs = 0,
		nargreg = 8,
		nfltreg = T.nfltreg,
		vafloat = T.vafloat,
		fltspill = T.fltspill,
		recabi = true,
	alloca = true,
		recref = true,
		peep = peeprules,
		eightbytes = eightbytes,
		epilogue = epilogue,
		slot = slot,
		frame = frame,
		jump = jump,
		memreg = function(r)
			return "[" .. regname(r, 8) .. "]"
		end,
		jumpto = jumpto,
		code = code,
		trailer = trailer,
	}
end

return arm64.new()
