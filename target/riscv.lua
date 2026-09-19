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
local peep = require "peep"
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

	-- Hardware floating point comes with the float file, so the two
	-- stand or fall together: lp64d has both, ilp32 on an ESP32-C
	-- series part has neither and a double travels as bit patterns.
	local hwf = (opt.fltreg or 0) > 0

	-- The scratch float file.  fa0 to fa7 are the ABI's, so this
	-- starts at ft0 and nothing a call sets up can be sitting in one.
	local function fregname(r)
		if r >= 8 then
			error("out of float registers: f" .. r)
		end
		return "ft" .. r
	end

	-- The letters that end a float mnemonic, and the width a shape
	-- asks for.
	local FSFX = {[8] = ".d", [4] = ".s"}

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
	-- A float compare writes 0 or 1 into an integer register and is
	-- quiet on a NaN: every ordered relation answers no, which is what
	-- C asks for.  Inequality is the negation of equality, so it
	-- answers yes, which is also what C asks for.
	local FCMP = {EQ = {"feq"}, NE = {"feq", neg = true},
		      LT = {"flt"}, LE = {"fle"},
		      GT = {"flt", swap = true}, GE = {"fle", swap = true}}

	local function fbranch(g, n, label, sense, reg)
		local t = regname(reg)

		-- The value itself, tested.  Dropping the sign bit makes
		-- the two zeros one, and leaves every NaN nonzero.
		if not FCMP[n.op] then
			local sh = xlen - (n.ty.size * 8 - 1)

			g:write(("\t%s\t%s,%s\n")
				:format(n.ty.size == 8 and "fmv.x.d"
					or "fmv.x.w", t, fregname(reg)))
			g:write(("\tslli\t%s,%s,%d\n"):format(t, t, sh))
			g:write("\t" .. (sense and "bne" or "beq") ..
				"\t" .. t .. ",zero," .. label .. "\n")
			return
		end
		local d = FCMP[n.op]
		local a, b = fregname(reg), fregname(reg + 1)

		if d.swap then a, b = b, a end
		g:write(("\t%s%s\t%s,%s,%s\n")
			:format(d[1], FSFX[n.left.ty.size], t, a, b))
		local want = sense and true or false

		if d.neg then want = not want end
		g:write("\t" .. (want and "bne" or "beq") .. "\t" .. t ..
			",zero," .. label .. "\n")
	end

	local function branch(g, n, label, sense, reg)
		local pair = BR[n.op]
		if hwf and ((pair and n.left.ty.kind == "float") or
			    (not pair and n.ty.kind == "float")) then
			return fbranch(g, n, label, sense, reg)
		end
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

	-- A depth holds a value in one file or the other, never both.
	local function save(g, i)
		g:write("\taddi\tsp,sp,-16\n")
		if g.fdepth[i] then
			g:write("\tfsd\t" .. fregname(i) .. ",0(sp)\n")
		else
			g:write("\t" .. SD .. "\t" .. regname(i) ..
				",0(sp)\n")
		end
	end

	local function restore(g, i)
		if g.fdepth[i] then
			g:write("\tfld\t" .. fregname(i) .. ",0(sp)\n")
		else
			g:write("\t" .. LD .. "\t" .. regname(i) ..
				",0(sp)\n")
		end
		g:write("\taddi\tsp,sp,16\n")
	end

	-- Arguments go in a0 upward, which the allocator also uses, so
	-- anything live is saved first and the values come back off the stack.
	local ARGREG = {"a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"}

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

	-- The ABI facts md.classify needs.  lp64d keeps a float file, but a
	-- variadic argument never uses it, and a float that finds the file
	-- full falls back to an integer register rather than to the stack.
	-- ilp32 on an ESP32-C series part has no float file at all, so a
	-- double travels as its bit pattern and nothing below fires.
	local T = {
		ptrsize = ws,
		nargreg = #ARGREG,
		nfltreg = opt.fltreg or 0,
		vafloat = false,
		fltspill = true,
		recref = true,
		hiddenarg = true,
	}

	-- Every field of a record, in order, with where it sits.  Stops
	-- once there are more than the ABI cares about.
	local function flatten(t, off, out)
		if #out > 2 then return end
		if t.kind == "array" then
			for i = 0, (t.n or 0) - 1 do
				flatten(t.of, off + i * t.of.size, out)
			end
		elseif t.members then
			for _, m in ipairs(t.members) do
				flatten(m.ty, off + m.off, out)
			end
		else
			out[#out + 1] = {off = off, ty = t}
		end
	end

	-- One or two floating point fields go to the float file, and one
	-- float beside one integer to one of each.  Anything else of two
	-- words or less goes to the integer file, and a bigger record
	-- travels as a pointer to a copy the caller makes.  A variadic
	-- argument never reaches the float file.
	local function eightbytes(ty, named)
		if ty.size == 0 or ty.size > 2 * ws then return nil end
		if T.nfltreg > 0 and named ~= false then
			local f, nf, ok = {}, 0, true

			flatten(ty, 0, f)
			for _, m in ipairs(f) do
				if m.ty.kind == "float" then
					nf = nf + 1
					if m.ty.size > 8 then ok = false end
				elseif m.ty.size > ws then
					ok = false
				end
			end
			if ok and nf > 0 and #f <= 2 then
				local out = {}

				for i, m in ipairs(f) do
					out[i] = {off = m.off,
						  size = m.ty.size,
						  flt = m.ty.kind == "float"}
				end
				return out
			end
		end
		return md.pieces(ty.size, ws)
	end

	T.eightbytes = eightbytes

	-- Moves between an integer register and a float one, by width.
	local FMV  = {[8] = "fmv.d.x", [4] = "fmv.w.x"}
	local FMVX = {[8] = "fmv.x.d", [4] = "fmv.x.w"}
	local FLD  = {[8] = "fld", [4] = "flw"}
	local FST  = {[8] = "fsd", [4] = "fsw"}

	local function classify(n)
		local shape = {}
		local wide = n.wide
		for i, a in ipairs(n.args or {}) do
			local w = wide and wide[i]
			local rec = n.recs and n.recs[i]

			shape[i] = {flt = not w and not rec and not n.soft and
					  a.ty.kind == "float",
				    rec = rec,
				    size = rec and rec.size or w or a.ty.size}
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
				if d.mem then
					-- a record the registers could not
					-- hold: leave a copy here
					g:expr(args[i], "reg", reg + 1)
					g:write(("\taddi\t%s,sp,%d\n")
						:format(regname(reg),
							d.stk * ws))
					blockcopy(g, d.size, reg)
				elseif d.stk then
					g:expr(args[i], "reg", reg)
					if d.words > 1 then
						-- the address is in reg; the
						-- two words follow it
						for k = 0, d.words - 1 do
							g:write(("\t%s\tt6,%d(%s)\n\t%s\tt6,%d(sp)\n")
								:format(LD, k * ws,
									regname(reg),
									SD,
									(d.stk + k) * ws))
						end
					elseif hwf and
					       args[i].ty.kind == "float" then
						g:write(("\t%s\t%s,%d(sp)\n")
							:format(FST[args[i].ty.size],
								fregname(reg),
								d.stk * ws))
					else
						g:write(("\t%s\t%s,%d(sp)\n")
							:format(SD, regname(reg),
								d.stk * ws))
					end
				end
			end
		end
		local order, straight = {}, {}
		for i, d in ipairs(dest) do
			if d.pieces then
				-- a record in registers: one push a piece
				g:expr(args[i], "reg", reg)
				for _, p in ipairs(d.pieces) do
					g:write(("\t%s\tt6,%d(%s)\n"):format(
						p.size > 4 and LD or "lw",
						p.off, regname(reg)))
					g:write(("\taddi\tsp,sp,-16\n\t%s\tt6,0(sp)\n")
						:format(SD))
					order[#order + 1] = {flt = p.flt,
							     reg = p.r,
							     size = p.size,
							     words = 1}
				end
			elseif d.reg and not d.flt and d.words == 1 and
			       simplearg(args[i]) then
				straight[#straight + 1] = {d = d, e = args[i]}
			elseif d.reg then
				order[#order + 1] = d
				if d.words > 1 then
					-- push the halves so the low one
					-- comes back into the lower register
					g:expr(args[i], "reg", reg)
					for k = d.words - 1, 0, -1 do
						g:write(("\t%s\tt6,%d(%s)\n\taddi\tsp,sp,-16\n\t%s\tt6,0(sp)\n")
							:format(LD, k * ws,
								regname(reg), SD))
					end
				else
					g:expr(args[i], "stack", reg)
				end
			end
		end
		-- t6 is not allocatable, so the address survives the pops
		if not n.direct then
			g:expr(n.left, "reg", reg)
			g:write("\tmv\tt6," .. regname(reg) .. "\n")
		end
		for k = #order, 1, -1 do
			local d = order[k]
			if d.flt then
				g:write(("\t%s\tfa%d,0(sp)\n")
					:format(FLD[d.size], d.reg))
				g:write("\taddi\tsp,sp,16\n")
			else
				for j = 0, d.words - 1 do
					g:write("\t" .. LD .. "\t" ..
						ARGREG[d.reg + 1 + j] ..
						",0(sp)\n\taddi\tsp,sp,16\n")
				end
			end
		end
		-- The arguments that need no working out.  Nothing left to
		-- do can disturb them, and each names a register of its
		-- own, so the order among them does not matter.
		for _, x in ipairs(straight) do
			local e = x.e
			local r = ARGREG[x.d.reg + 1]
			local w = e.ty.size == 8 and 8 or 4

			if e.op == "CONST" then
				g:write(("\tli\t%s,%d\n"):format(r, e.val))
			elseif e.op == "AUTO" then
				g:write(("\t%s\t%s,%s\n"):format(
					w == 8 and LD or "lw", r,
					frameaddr(g, e.off)))
			elseif e.op == "ADDR" and e.left.op == "AUTO" then
				-- the offset may be past what an immediate
				-- reaches, and the register is free
				if fits12(e.left.off) then
					g:write(("\taddi\t%s,s0,%d\n")
						:format(r, e.left.off))
				else
					g:write(("\tli\t%s,%d\n\tadd\t%s,s0,%s\n")
						:format(r, e.left.off, r, r))
				end
			elseif e.op == "ADDR" then
				g:write(("\tla\t%s,%s\n")
					:format(r, e.left.sym))
			else
				g:write(("\tla\t%s,%s\n"):format(r, e.sym))
				g:write(("\t%s\t%s,0(%s)\n"):format(
					w == 8 and LD or "lw", r, r))
			end
		end
		if n.direct then
			g:write("\tcall\t" .. n.left.sym .. "\n")
		else
			g:write("\tjalr\tt6\n")
		end
		if bytes > 0 then
			g:write("\taddi\tsp,sp," .. bytes .. "\n")
		end
		if n.retrec then
			-- A record that came back in registers goes to the
			-- slot the caller set aside; one written through
			-- the hidden pointer is there already.
			local ni, nf = 0, 0

			for _, p in ipairs(eightbytes(n.retrec) or {}) do
				local at = frameaddr(g, n.retslot + p.off)

				if p.flt then
					g:write(("\t%s\tfa%d,%s\n")
						:format(FST[p.size], nf, at))
					nf = nf + 1
				else
					g:write(("\t%s\t%s,%s\n")
						:format(p.size > 4 and SD
							or "sw",
							ARGREG[ni + 1], at))
					ni = ni + 1
				end
			end
		elseif n.retslot then
			-- a wide result arrives in a0 and a1
			g:write(("\t%s\ta0,%s\n\t%s\ta1,%s\n")
				:format(SD, frameaddr(g, n.retslot),
					SD, frameaddr(g, n.retslot + ws)))
		elseif hwf and n.ty.kind == "float" then
			-- A soft call answers with a bit pattern in a0; the
			-- ABI answers in fa0.  Either way it belongs in the
			-- float file.
			if n.soft then
				g:write(("\t%s\t%s,a0\n")
					:format(FMV[n.ty.size], fregname(reg)))
			else
				g:write(("\tfmv%s\t%s,fa0\n")
					:format(FSFX[n.ty.size],
						fregname(reg)))
			end
		elseif not n.soft and T.nfltreg > 0 and
		       n.ty.kind == "float" then
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
	-- Between the two files, and between the two float widths.  Every
	-- one of these is a single instruction here, unsigned included.
	local function fconvert(g, from, to, reg)
		local f, r = fregname(reg), regname(reg)
		local w = xlen == 64 and "l" or "w"

		if from.kind == "float" and to.kind == "float" then
			if from.size == to.size then return end
			g:write(("\tfcvt%s%s\t%s,%s\n")
				:format(FSFX[to.size], FSFX[from.size], f, f))
		elseif to.kind == "float" then
			g:write(("\tfcvt%s.%s%s\t%s,%s\n")
				:format(FSFX[to.size], w,
					from.kind == "uint" and "u" or "",
					f, r))
		else
			g:write(("\tfcvt.%s%s%s\t%s,%s,rtz\n")
				:format(w, to.kind == "uint" and "u" or "",
					FSFX[from.size], r, f))
		end
	end

	local function convert(g, from, to, reg)
		if hwf and (from.kind == "float" or to.kind == "float") then
			return fconvert(g, from, to, reg)
		end
		if to.size * 8 >= xlen then
			if from.size * 8 < xlen and from.kind == "uint" then
				zeroabove(g, regname(reg), from.size)
			end
			return
		end
		extend(g, regname(reg), to.size, to.kind)
	end

	-- Inline assembly.  No constraint letter here names a register: the
	-- ABI has no fixed-register instructions, so everything is "any".
	local function asmreg()
		return nil
	end

	local ALLOC = {}
	for i = 0, 13 do ALLOC[REG[i]] = i end
	local PRESERVED = {}
	for i = 0, 11 do PRESERVED["s" .. i] = true end

	local function asmpin(name)
		return ALLOC[name], PRESERVED[name]
	end

	-- A preserved register the template destroys goes to a slot below the
	-- frame, which nothing else uses between the two instructions.
	local function asmkeep(g, name, push)
		if push then
			g:write("\taddi\tsp,sp,-16\n\t" .. SD .. "\t" ..
				name .. ",0(sp)\n")
		else
			g:write("\t" .. LD .. "\t" .. name ..
				",0(sp)\n\taddi\tsp,sp,16\n")
		end
	end

	local function asmimm(v)
		return tostring(v)
	end

	local function rawmove(g, dst, src)
		if dst ~= src then
			g:write("\tmv\t" .. dst .. "," .. src .. "\n")
		end
	end

	local function move(g, dst, src, size, flt)
		if flt then
			if dst ~= src then
				g:write(("\tfmv%s\t%s,%s\n")
					:format(FSFX[size or 8],
						fregname(dst), fregname(src)))
			end
			return
		end
		rawmove(g, regname(dst), regname(src))
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
			g:write("\taddi\tsp,sp,-16\n")
			if hwf and n.ty.kind == "float" then
				g:write("\tfsd\t" .. fregname(reg) ..
					",0(sp)\n")
			else
				g:write("\t" .. SD .. "\t" ..
					regname(reg) .. ",0(sp)\n")
			end
		end
		-- cc needs nothing: branch tests the register itself
	end


	local function jump(g, label)
		g:write("\tj\t" .. label .. "\n")
	end

	-- The peephole rules: what the code table cannot see, because it
	-- looks at one tree node at a time.
	local SD, LD2 = ws == 8 and "sd" or "sw", ws == 8 and "ld" or "lw"
	local peeprules = {
		-- A move from a register to itself, which every call ends
		-- with because the result is already where it belongs.
		{n = 1, f = function(w, i)
			local a = w[i]

			if a.mnem == "mv" and a.a and a.a == a.b then
				return {}
			end
		end},

		-- A jump to the line below it.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if a.mnem == "j" and b.label and a.a == b.label then
				return {b}
			end
		end},

		-- A value pushed and taken straight back.
		{n = 4, f = function(w, i)
			local a, b, c, d = w[i], w[i + 1], w[i + 2], w[i + 3]

			if a.mnem == "addi" and a.a == "sp" and
			   a.b == "sp,-16" and
			   b.mnem == SD and b.b == "0(sp)" and
			   c.mnem == LD2 and c.b == "0(sp)" and
			   d.mnem == "addi" and d.a == "sp" and
			   d.b == "sp,16" then
				if b.a == c.a then return {} end
				return {peep.line(("\tmv\t%s,%s")
					:format(c.a, b.a))}
			end
		end},

		-- A store read straight back out of the same place.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if a.mnem == SD and b.mnem == LD2 and
			   a.a == b.a and a.b == b.b and
			   a.b and not a.b:find("(sp)", 1, true) then
				return {a}
			end
		end},

		-- A register written and then written again without being
		-- read in between.
		{n = 2, f = function(w, i)
			local a, b = w[i], w[i + 1]

			if a.mnem == "mv" and a.a and a.b and
			   b.a == a.a and (b.mnem == "mv" or
					   b.mnem == "li") and
			   b.b ~= a.a then
				return {b}
			end
		end},
	}

	-- GNU labels as values: the address is in a register.
	local function jumpto(g, reg)
		g:write("\tjr\t" .. regname(reg) .. "\n")
	end

	local function slot(i)
		return -(2 * ws) - ws * i
	end

	local function frame(n)
		return ((2 * ws + ws * n + 15) // 16) * 16
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
		-- The caller handed over where to write a record result.
		if recret and recret.ptr then
			g:write(("\t%s\ta0,%s\n")
				:format(SD, frameaddr(g, recret.ptr)))
		end
		-- Everything that arrived in a register is put away first:
		-- the copies below use those same registers as scratch.
		for _, d in ipairs(params or {}) do
			if d.pieces then
				for _, p in ipairs(d.pieces) do
					local at = frameaddr(g, d.off + p.off)

					if p.flt then
						g:write(("\t%s\tfa%d,%s\n")
							:format(FST[p.size],
								p.r, at))
					else
						g:write(("\t%s\t%s,%s\n")
							:format(p.size > 4 and
								SD or "sw",
								ARGREG[p.r + 1],
								at))
					end
				end
			elseif d.reg and d.flt then
				g:write(("\t%s\tfa%d,%d(s0)\n")
					:format(FST[d.size], d.reg, d.off))
			elseif d.reg then
				for k = 0, d.words - 1 do
					g:write("\t" .. SD .. "\t" ..
						REG[d.reg + k] .. "," ..
						(d.off + k * ws) .. "(s0)\n")
				end
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
		for _, d in ipairs(params or {}) do
			local stack = not d.reg and not d.pieces

			if d.mem then
				-- s0 is the caller's sp, so what it left on
				-- the stack starts right there
				g:write(("\taddi\t%s,s0,%d\n")
					:format(regname(1), d.stk * ws))
				g:write(("\taddi\t%s,s0,%d\n")
					:format(regname(0), d.off))
				blockcopy(g, d.size, 0)
			elseif d.ref then
				-- The caller handed over a copy it made;
				-- the pointer to it is parked in the first
				-- word of the slot the record wants.
				if stack then
					g:write(("\t%s\tt6,%d(s0)\n\t%s\tt6,%d(s0)\n")
						:format(LD, d.stk * ws,
							SD, d.off))
				end
				g:write(("\t%s\t%s,%s\n"):format(LD,
					regname(1), frameaddr(g, d.off)))
				g:write(("\taddi\t%s,s0,%d\n")
					:format(regname(0), d.off))
				blockcopy(g, d.size, 0)
			elseif stack then
				for k = 0, d.words - 1 do
					g:write(("\t%s\tt6,%d(s0)\n\t%s\tt6,%d(s0)\n")
						:format(LD, (d.stk + k) * ws,
							SD, d.off + k * ws))
				end
			end
		end
	end

	local function epilogue(g, frame, fltret, wideret, recret)
		if recret and recret.cls then
			-- The result sits in a slot of ours; hand back the
			-- pieces.
			local ni, nf = 0, 0

			for _, p in ipairs(recret.cls) do
				local at = frameaddr(g, recret.off + p.off)

				if p.flt then
					g:write(("\t%s\tfa%d,%s\n")
						:format(FLD[p.size], nf, at))
					nf = nf + 1
				else
					g:write(("\t%s\t%s,%s\n")
						:format(p.size > 4 and LD
							or "lw",
							ARGREG[ni + 1], at))
					ni = ni + 1
				end
			end
		elseif recret then
			-- Too big for the registers: write it through the
			-- pointer the caller handed over.
			g:write(("\t%s\t%s,%s\n"):format(LD, regname(0),
				frameaddr(g, recret.ptr)))
			g:write(("\taddi\t%s,s0,%d\n")
				:format(regname(1), recret.off))
			blockcopy(g, recret.size, 0)
			g:write(("\t%s\t%s,%s\n"):format(LD, regname(0),
				frameaddr(g, recret.ptr)))
		elseif wideret then
			-- a0 holds the address of the value; the two words
			-- go back in a0 and a1, the high one read first
			g:write(("\t%s\ta1,%d(a0)\n\t%s\ta0,0(a0)\n")
				:format(LD, ws, LD))
		elseif fltret and hwf then
			g:write(("\tfmv%s\tfa0,%s\n")
				:format(FSFX[fltret], fregname(0)))
		elseif fltret then
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
	-- The address of a global another unit may own.  A real global
	-- offset table is for a shared object, which this target does
	-- not build: everything it links ends up in one image, so the
	-- address is the same PC-relative pair the plain one uses.
	code.reg.GOT = {{"a", "z", asm = "\tla\t%R,%A1"}}
	code.reg.INDIR = {{"n", "z", ev = "L", asm = "\t%I\t%R,0(%P)"}}
	code.reg.NEG = {{"n", "z", ev = "L", asm = "\tneg\t%R,%R"}}
	code.reg.NOT = {{"n", "z", ev = "L", asm = "\tnot\t%R,%R"}}
	-- A postfix step yields the old value, then adjusts the lvalue.
	code.reg.POSTADD = {
		{"i", "z", rz = 1,
		 asm = "\t%I\t%R,%A1\n\taddi\t%R1,%R,%C\n\t%I2\t%R1,%A1"},
		-- a global has to have its address built first
		{"n*", "z", rz = 1, ev = "L1*",
		 asm = "\t%I\t%R,0(%P1)\n\taddi\t%R2,%R,%C" ..
		       "\n\t%I2\t%R2,0(%P1)"},
		{"a", "z", rz = 1,
		 asm = "\tla\t%R1,%A1\n\t%I\t%R,0(%R1)\n" ..
		       "\taddi\t%R2,%R,%C\n\t%I2\t%R2,0(%R1)"},
	}
	code.eff.POSTADD = {
		{"i", "z", rz = 1,
		 asm = "\t%I\t%R,%A1\n\taddi\t%R,%R,%C\n\t%I2\t%R,%A1"},
		{"n*", "z", rz = 1, ev = "L1*",
		 asm = "\t%I\t%R,0(%P1)\n\taddi\t%R,%R,%C" ..
		       "\n\t%I2\t%R,0(%P1)"},
		{"a", "z", rz = 1,
		 asm = "\tla\t%R1,%A1\n\t%I\t%R,0(%R1)\n" ..
		       "\taddi\t%R,%R,%C\n\t%I2\t%R,0(%R1)"},
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

	-- Hardware floating point.  A float lives in the float file at the
	-- same depth as an integer would, so these are the integer rules
	-- again with %F for %R.  They go in front, because the integer
	-- alternatives carry no kind letter and would match a float first.
	if hwf then
		local function ahead(tab, alts)
			for i, a in ipairs(alts) do
				table.insert(tab, i, a)
			end
		end

		for _, w in ipairs{{sz = 8, l = "q", s = ".d",
				    ld = "fld", st = "fsd", mv = "fmv.d.x"},
				   {sz = 4, l = "l", s = ".s",
				    ld = "flw", st = "fsw", mv = "fmv.w.x"}} do
			local nf, ifl = "nf" .. w.l, "if" .. w.l
			local ef, af = "ef" .. w.l, "af" .. w.l
			local ld, st = "\t" .. w.ld .. "\t", "\t" .. w.st .. "\t"

			-- No float immediate: the bits go through an
			-- integer register, which at this depth is free.
			ahead(code.reg.CONST, {{nf, "z",
				asm = function(g, n, r)
				local ir = regname(r)

				if n.val ~= 0 then
					g:write(("\tli\t%s,%d\n")
						:format(ir, n.val))
				else
					ir = "zero"
				end
				g:write(("\t%s\t%s,%s\n")
					:format(w.mv, fregname(r), ir))
			end}})
			ahead(code.reg.AUTO, {{ifl, "z", asm = ld .. "%F,%A"}})
			ahead(code.reg.NAME, {{af, "z",
				asm = "\tla\t%R,%A\n" .. ld .. "%F,0(%R)"}})
			-- An indirection is described by its address, so
			-- the shape says pointer to a float this wide.
			ahead(code.reg.INDIR, {{"n" .. w.l .. "pf", "z",
				ev = "L", asm = ld .. "%F,0(%P)"}})
			ahead(code.reg.NEG, {{nf, "z", ev = "L",
				asm = "\tfneg" .. w.s .. "\t%F,%F"}})
			for op, mn in pairs{ADD = "fadd", SUB = "fsub",
					    MUL = "fmul", DIV = "fdiv"} do
				local x = "\t" .. mn .. w.s .. "\t"

				ahead(code.reg[op], {
					{nf, ef, ev = "L R1",
					 asm = x .. "%F,%F,%F1"},
					{nf, nf, ev = "Rs L",
					 asm = "\tfld\t%F1,0(sp)\n" ..
					       "\taddi\tsp,sp,16\n" ..
					       x .. "%F,%F,%F1"},
				})
			end
			for _, op in ipairs{"EQ", "NE", "LT", "LE",
					    "GT", "GE"} do
				ahead(code.cc[op], {{nf, nf, ev = "L R1"}})
			end
			local store = {
				{ifl, "zf" .. w.l, rz = 1,
				 asm = "\t%I\tzero,%A1"},
				{ifl, nf, rz = 1, ev = "R",
				 asm = st .. "%F,%A1"},
				{"n*f" .. w.l, nf, rz = 1, ev = "R L1*",
				 asm = st .. "%F,0(%P1)"},
				{af, nf, rz = 1, ev = "R",
				 asm = "\tla\t%R1,%A1\n" .. st .. "%F,0(%R1)"},
			}
			ahead(code.eff.ASGN, store)
			ahead(code.reg.ASGN, {store[2], store[3], store[4]})
		end
	end

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

	-- Without this the linker assumes the stack must be executable, and
-- refuses to load the result as a shared object.
local trailer = '\t.section\t.note.GNU-stack,"",@progbits\n'

return md.target{
		name = "riscv" .. xlen,
		xlen = xlen,
		ptrsize = ws,
		predef = predef,
		charsigned = false,
		nreg = 14,
		-- A value wider than a register travels by address.
		wideargs = true,
		regname = regname,
		fregname = hwf and fregname or nil,
		hwfloat = hwf or nil,
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
		peep = peeprules,
		hiddenarg = true,
		eightbytes = eightbytes,
		epilogue = epilogue,
		slot = slot,
		frame = frame,
		jump = jump,
		memreg = function(r)
			return "0(" .. regname(r) .. ")"
		end,
		jumpto = jumpto,
		code = code,
		trailer = trailer,
	}
end

return riscv
