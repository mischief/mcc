-- SPDX-License-Identifier: ISC
-- Xtensa LX7, the windowed ABI, which is what an ESP32-S3 runs.
--
-- Two things here are unlike the other targets.
--
-- The register window does the caller saving.  A `call8` rotates the window
-- by eight, so the callee sees this function's a8 to a15 as its own a0 to
-- a7, and a2 to a7 here survive the call untouched.  That makes six scratch
-- registers that never need saving, and it is why no alternative in this
-- file carries a clobber list.
--
-- The stack pointer must not move after `entry`.  The sixteen bytes below it
-- are the window's base save area, and moving a1 means moving them, which is
-- what the MOVSP instruction is for.  Rather than pay that on every spill,
-- the frame carries its own areas at fixed offsets: the outgoing stack
-- arguments where the ABI puts them, then a spill area for operands the
-- register file cannot hold, then the locals.
--
-- Constants and addresses are `movi`, which the assembler turns into a
-- literal pool entry and an `l32r` when the value does not fit.  Branches out
-- of range are relaxed by the assembler too.  A call8 reaches 512 KiB, so
-- under `-mlongcalls` a call loads its target's address and uses callx8.

local md = require "mcc.md"
local peep = require "mcc.peep"
local data = require "mcc.data"
local tree = require "mcc.tree"

local REG = {[0] = "a2", "a3", "a4", "a5", "a6", "a7"}
local TEMP, TEMP2 = "a8", "a9"
local longcall = false
local ARGREG = {"a10", "a11", "a12", "a13", "a14", "a15"}

-- Frame, in bytes from the stack pointer.
local NOUT, NSPILL = 8, 24
local OUT = 0
local SPILL = OUT + NOUT * 4
local LOCALS = SPILL + NSPILL * 4
local SAVE = 32			-- the base and extra save areas at the top

local function regname(r)
	return REG[r] or error("out of registers: r" .. r)
end

local function fits8(v)
	return v >= -128 and v <= 127
end

-- A load or store offset is scaled by the width, so the range differs.
local function fitsoff(off, size)
	if size == 1 then return off >= 0 and off <= 255 end
	if size == 2 then return off >= 0 and off <= 510 and off % 2 == 0 end
	return off >= 0 and off <= 1020 and off % 4 == 0
end

local function loadmn(ty)
	if ty.size == 1 then return "l8ui" end
	if ty.size == 2 then return ty.kind == "uint" and "l16ui" or "l16si" end
	return "l32i"
end

local function storemn(ty)
	return ({[1] = "s8i", [2] = "s16i", [4] = "s32i"})[ty.size] or "s32i"
end

local BASE = {ADD = "add", SUB = "sub", AND = "and", OR = "or",
	      XOR = "xor", MUL = "mull"}

local function mnem(n, a)
	local op = n.op
	if op == "AUTO" or op == "NAME" or op == "INDIR" then
		return loadmn(n.ty)
	end
	if op == "ASGN" then return storemn(n.ty) end
	if op == "POSTADD" then
		return a and a.store and storemn(n.ty) or loadmn(n.ty)
	end
	local u = n.ty.kind == "uint"
	if op == "DIV" then return u and "quou" or "quos" end
	if op == "MOD" then return u and "remu" or "rems" end
	local b = BASE[op]
	if b and a and a.imm then b = b .. "i" end
	return b
end

-- The branch taken when the comparison holds; the one for when it fails
-- is the same comparison with the opposite sense.
local BR = {EQ = "beq", NE = "bne", LT = "blt", GE = "bge",
	    GT = "blt", LE = "bge"}
local UBR = {EQ = "beq", NE = "bne", LT = "bltu", GE = "bgeu",
	     GT = "bltu", LE = "bgeu"}
local NOT = {EQ = "NE", NE = "EQ", LT = "GE", GE = "LT", GT = "LE", LE = "GT"}
local SWAP = {GT = true, LE = true}

local function branch(g, n, label, sense, reg)
	local op = n.op
	if not BR[op] then
		g:write("\t" .. (sense and "bnez" or "beqz") .. "\t" ..
			regname(reg) .. "," .. label .. "\n")
		return
	end
	local tab = n.left.ty.kind ~= "int" and UBR or BR
	local a, b = regname(reg), regname(reg + 1)
	if SWAP[op] then a, b = b, a end
	g:write("\t" .. tab[sense and op or NOT[op]] .. "\t" .. a .. "," ..
		b .. "," .. label .. "\n")
end

-- Nothing but a small constant can appear inside an instruction, and a
-- global has to have its address built first.
local function dcalc(n, nreg)
	if n then
		if n.op == "CONST" then
			if n.val == 0 then return 4 end
			if fits8(n.val) then return 8 end
			return n.need <= nreg and 20 or 24
		end
		if n.op == "NAME" then return 16 end
		if n.op == "ADDR" then
			return n.need <= nreg and 20 or 24
		end
	end
	return tree.dcalc(n, nreg)
end

-- A frame reference whose offset is past the field needs the address in a
-- register first.  a8 is not allocatable, so it can carry it.
local function frameaddr(g, off, size)
	if fitsoff(off, size) then
		return "a1," .. off
	end
	g:write(("\tmovi\t%s,%d\n\tadd\t%s,a1,%s\n"):format(TEMP, off,
		TEMP, TEMP))
	return TEMP .. ",0"
end

local function addr(g, n)
	local op = n.op
	if op == "AUTO" then
		return frameaddr(g, n.off, n.ty.size)
	elseif op == "NAME" then
		return n.sym
	elseif op == "CONST" then
		return tostring(n.val)
	elseif op == "ADDR" then
		return addr(g, n.left)
	end
	error("cannot address " .. op .. " directly on xtensa")
end

local function suffix()
	return ""
end

local function spillslot(i)
	return SPILL + i * 4
end

-- A call needs no register saving here, because the window does it.
-- A statement expression does: its code starts from the first register
-- and runs where it stood, so whatever was live goes to the spill area
-- and comes back.  They nest, so the slots are a stack.
local function save(g, i)
	g:write(("\ts32i\t%s,a1,%d\n"):format(regname(i),
		spillslot(g.spill)))
	g.spill = g.spill + 1
	assert(g.spill <= NSPILL, "expression too deep for the spill area")
end

local function restore(g, i)
	g.spill = g.spill - 1
	g:write(("\tl32i\t%s,a1,%d\n"):format(regname(i),
		spillslot(g.spill)))
end

local function adapt(g, n, ctx, reg)
	if ctx == "stack" then
		g:write(("\ts32i\t%s,a1,%d\n"):format(regname(reg),
			spillslot(g.spill)))
		g.spill = g.spill + 1
		assert(g.spill <= NSPILL, "expression too deep for the spill area")
	end
end

local function move(g, dst, src)
	if dst ~= src then
		g:write("\tmov\t" .. regname(dst) .. "," .. regname(src) .. "\n")
	end
end

local function rawmove(g, dst, src)
	if dst ~= src then
		g:write("\tmov\t" .. dst .. "," .. src .. "\n")
	end
end

-- A load or store takes eight bits of offset scaled by its size.  Past
-- that both pointers move on, and are put back at the end, since the
-- caller may use them.  No piece is wider than the alignment `al`.
local function copy(g, size, d, s, al)
	local off, moved = 0, 0
	for _, w in ipairs{4, 2, 1} do
		local ld = w == 4 and "l32i" or (w == 2 and "l16ui" or "l8ui")
		local st = w == 4 and "s32i" or (w == 2 and "s16i" or "s8i")
		while w <= al and size - off >= w do
			while off - moved > 255 * w do
				g:write(("\taddmi\t%s,%s,256\n\taddmi\t%s,%s,256\n")
					:format(d, d, s, s))
				moved = moved + 256
			end
			g:write(("\t%s\t%s,%s,%d\n\t%s\t%s,%s,%d\n")
				:format(ld, TEMP, s, off - moved, st, TEMP, d,
					off - moved))
			off = off + w
		end
	end
	for _ = 1, moved // 256 do
		g:write(("\taddmi\t%s,%s,-256\n\taddmi\t%s,%s,-256\n")
			:format(d, d, s, s))
	end
end

local function blockcopy(g, size, reg, al)
	copy(g, size, regname(reg), regname(reg + 1), al or 4)
end

-- A value narrower than a register is kept sign or zero extended, which is
-- what the loads produce.  There is no signed byte load, so that one takes
-- an explicit sign extension.
local function convert(g, from, to, reg)
	local r = regname(reg)
	if to.size >= from.size then return end
	if to.size == 1 then
		if to.kind == "uint" then
			g:write(("\textui\t%s,%s,0,8\n"):format(r, r))
		else
			g:write(("\tsext\t%s,%s,7\n"):format(r, r))
		end
	elseif to.size == 2 then
		if to.kind == "uint" then
			g:write(("\textui\t%s,%s,0,16\n"):format(r, r))
		else
			g:write(("\tsext\t%s,%s,15\n"):format(r, r))
		end
	end
end

-- Inline assembly: no constraint letter names a register here.
local function asmreg()
	return nil
end

local ALLOC = {}
for i = 0, 5 do ALLOC[REG[i]] = i end

local function asmpin(name)
	return ALLOC[name], false
end

local function asmkeep()
end

local function asmimm(v)
	return tostring(v)
end

-- The ABI facts md.classify needs.  No float register file, and a value
-- twice the register width takes an even aligned pair.
-- A record result of four words or less comes back in registers, and
-- a bigger one through a pointer the caller hands over.  There is no
-- float file, so no piece is ever floating point.
local function eightbytes(ty)
	if ty.size > 16 then return nil end
	return md.pieces(ty.size, 4)
end

-- A record argument of six words or less travels in registers, all of
-- it or none, from a register as aligned as the record up to sixteen
-- bytes.  One that does not fit goes whole on the stack, and so does
-- every argument after it.
local function argpieces(ty)
	if ty.size > 24 then return nil end
	return md.pieces(ty.size, 4)
end

local T = {ptrsize = 4, nargreg = #ARGREG, nfltreg = 0, vafloat = false,
	   fltspill = false, hiddenarg = true, eightbytes = eightbytes,
	   argpieces = argpieces, recalign = 16, regstop = true}

-- A record result too big for the registers is written through a
-- pointer the caller hands over in the first argument register.
local function viaptr(n)
	return n.retrec ~= nil and eightbytes(n.retrec) == nil
end

local function classify(n)
	local shape = {}
	local wide = n.wide
	for i, a in ipairs(n.args or {}) do
		local rec = n.recs and n.recs[i]

		shape[i] = {rec = rec, flt = false,
			    size = rec and rec.size or
				   (wide and wide[i]) or a.ty.size}
	end
	return md.classify(T, shape, n.nfixed, viaptr(n))
end

-- An argument the machine can name in one instruction: nothing between
-- here and the call can change what it means, so it goes straight into
-- its own register at the end.
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

-- One word of a record into dst.  A load must be aligned to its size, so
-- a record aligned to less than a word is put together from the halves
-- or the bytes; TEMP2 holds each one on the way.
local function loadpiece(g, dst, base, off, size, al)
	local w = al >= 4 and 4 or al
	local ld = w == 4 and "l32i" or (w == 2 and "l16ui" or "l8ui")

	g:write(("\t%s\t%s,%s,%d\n"):format(ld, dst, base, off))
	for k = w, size - 1, w do
		g:write(("\t%s\t%s,%s,%d\n\tslli\t%s,%s,%d\n\tor\t%s,%s,%s\n")
			:format(ld, TEMP2, base, off + k, TEMP2, TEMP2, 8 * k,
				dst, dst, TEMP2))
	end
end

local function call(g, n, reg)
	local args = n.args or {}
	local dest, _, _, nstack = classify(n)
	-- Every argument is computed into a scratch register and left in the
	-- spill area, because a nested call would take the argument
	-- registers back before this one could use them.  The stack ones
	-- are put where the ABI wants them only at the end, for the same
	-- reason.  The window keeps a2 to a7, so nothing else is saved.
	-- A record that goes on the stack leaves only its address there.
	local base = g.spill
	local straight = {}
	for i, d in ipairs(dest) do
		-- An argument the machine can name in one instruction
		-- needs no spill: nothing between here and the call can
		-- change what it means.
		if d.reg and not d.pieces and not d.mem and d.words == 1 and
		   simplearg(args[i]) then
			straight[#straight + 1] = {d = d, e = args[i]}
			goto next
		end
		g:expr(args[i], "reg", reg)
		d.stage = g.spill
		if d.pieces then
			local al = n.recs[i].align or 1

			for _, p in ipairs(d.pieces) do
				loadpiece(g, TEMP, regname(reg), p.off, p.size,
					  al)
				g:write(("\ts32i\t%s,a1,%d\n")
					:format(TEMP, spillslot(g.spill)))
				g.spill = g.spill + 1
			end
		elseif d.mem then
			g:write(("\ts32i\t%s,a1,%d\n")
				:format(regname(reg), spillslot(g.spill)))
			g.spill = g.spill + 1
		else
			-- A value wider than a register is named by its
			-- address, and every word of it is read through that.
			for k = 0, d.words - 1 do
				local from = regname(reg)

				if d.words > 1 then
					g:write(("\tl32i\t%s,%s,%d\n")
						:format(TEMP, from, k * 4))
					from = TEMP
				end
				g:write(("\ts32i\t%s,a1,%d\n")
					:format(from, spillslot(g.spill)))
				g.spill = g.spill + 1
			end
		end
		::next::
	end
	assert(g.spill <= NSPILL, "call too deep for the spill area")
	if not n.direct then
		g:expr(n.left, "reg", reg)
		g:write("\tmov\t" .. TEMP2 .. "," .. regname(reg) .. "\n")
	end
	-- More stack arguments than the frame has room for: the stack
	-- pointer moves down for this call, and everything in the frame is
	-- that much further from it until it comes back.  MOVSP takes the
	-- caller's save area along.
	local extra = 0
	if nstack > NOUT then
		extra = ((nstack - NOUT) * 4 + 15) // 16 * 16
		g:write(("\tmovi\t%s,%d\n\tsub\t%s,a1,%s\n\tmovsp\ta1,%s\n")
			:format(TEMP, extra, TEMP, TEMP, TEMP))
	end
	-- The stack ones first: until the argument registers are loaded,
	-- they are free to carry words.
	for i, d in ipairs(dest) do
		if d.stage and d.mem then
			local ad = frameaddr(g, spillslot(d.stage) + extra, 4)

			g:write(("\tl32i\ta14,%s\n"):format(ad))
			g:write(("\tmovi\ta13,%d\n\tadd\ta13,a13,a1\n")
				:format(OUT + d.stk * 4))
			copy(g, n.recs[i].size, "a13", "a14",
			     n.recs[i].align or 1)
		elseif d.stage then
			local nw = d.pieces and #d.pieces or d.words

			for k = 0, nw - 1 do
				local p = d.pieces and d.pieces[k + 1]
				local stk = p and p.stk
				if not p and not d.reg then stk = d.stk + k end

				if stk then
					local from = frameaddr(g,
						spillslot(d.stage + k) + extra, 4)
					g:write(("\tl32i\ta15,%s\n"):format(from))
					local to = frameaddr(g, OUT + stk * 4, 4)
					g:write(("\ts32i\ta15,%s\n"):format(to))
				end
			end
		end
	end
	for _, d in ipairs(dest) do
		local nw = d.stage and not d.mem and
			(d.pieces and #d.pieces or d.words) or 0

		for k = 0, nw - 1 do
			local r = d.pieces and d.pieces[k + 1].r or
				  (d.reg and d.reg + k)

			if r then
				g:write(("\tl32i\t%s,%s\n")
					:format(ARGREG[r + 1], frameaddr(g,
						spillslot(d.stage + k) + extra, 4)))
			end
		end
	end
	g.spill = base
	-- The arguments that need no working out, once nothing left to do
	-- can disturb them.
	for _, x in ipairs(straight) do
		local e = x.e
		local r = ARGREG[x.d.reg + 1]

		if e.op == "CONST" then
			g:write(("\tmovi\t%s,%d\n"):format(r, e.val))
		elseif e.op == "AUTO" then
			g:write(("\tl32i\t%s,%s\n")
				:format(r, frameaddr(g, e.off + extra, 4)))
		elseif e.op == "ADDR" and e.left.op == "AUTO" then
			g:write(("\tmovi\t%s,%d\n\tadd\t%s,a1,%s\n")
				:format(r, e.left.off + extra, r, r))
		elseif e.op == "ADDR" then
			g:write(("\tmovi\t%s,%s\n"):format(r, e.left.sym))
		else
			g:write(("\tmovi\t%s,%s\n"):format(r, e.sym))
			g:write(("\tl32i\t%s,%s,0\n"):format(r, r))
		end
	end
	if viaptr(n) then
		g:write(("\tmovi\ta10,%d\n\tadd\ta10,a1,a10\n")
			:format(n.retslot + extra))
	end
	if n.direct and longcall then
		g:write(("\tmovi\t%s,%s\n\tcallx8\t%s\n")
			:format(TEMP2, n.left.sym, TEMP2))
	elseif n.direct then
		g:write("\tcall8\t" .. n.left.sym .. "\n")
	else
		g:write("\tcallx8\t" .. TEMP2 .. "\n")
	end
	if extra > 0 then
		g:write(("\tmovi\t%s,%d\n\tadd\t%s,a1,%s\n\tmovsp\ta1,%s\n")
			:format(TEMP, extra, TEMP, TEMP, TEMP))
	end
	if n.retrec then
		-- A record that came back in registers goes to the slot the
		-- caller set aside; one written through the hidden pointer
		-- is there already.
		for i, p in ipairs(eightbytes(n.retrec) or {}) do
			g:write(("\ts32i\t%s,%s\n")
				:format(ARGREG[i],
					frameaddr(g, n.retslot + p.off, 4)))
		end
	elseif n.retslot then
		g:write(("\ts32i\ta10,%s\n"):format(frameaddr(g, n.retslot, 4)))
		g:write(("\ts32i\ta11,%s\n")
			:format(frameaddr(g, n.retslot + 4, 4)))
	end
	g:write("\tmov\t" .. regname(reg) .. ",a10\n")
end

local function slot(i)
	return LOCALS + 4 * (i - 1)
end

local function frame(n)
	local f = LOCALS + 4 * n + SAVE
	return ((f + 15) // 16) * 16
end

local function prologue(g, name, frame, params, vabase, static, recret,
			sec)
	-- A section the program asked for by name, which a link script
	-- places where the machine needs it.
	g:write(sec and ("\t.section\t" .. sec .. ",\"ax\",@progbits\n")
		or "\t.text\n")
	if not static then
		g:write("\t.globl\t" .. name .. "\n")
	end
	g:write("\t.align\t4\n" .. name .. ":\n")
	if frame <= 32760 then
		g:write("\tentry\ta1," .. frame .. "\n")
	else
		-- ENTRY cannot reach; take the rest off with MOVSP, which is
		-- the only safe way to move the stack pointer
		g:write("\tentry\ta1,32\n")
		g:write(("\tmovi\t%s,%d\n\tsub\t%s,a1,%s\n\tmovsp\ta1,%s\n")
			:format(TEMP, frame - 32, TEMP, TEMP, TEMP))
	end
	-- The caller handed over where to write a record result.
	if recret and recret.ptr then
		g:write(("\ts32i\t%s,%s\n")
			:format(REG[0], frameaddr(g, recret.ptr, 4)))
	end
	for _, d in ipairs(params or {}) do
		local nw = d.pieces and #d.pieces or d.words

		for k = 0, nw - 1 do
			local r = d.pieces and d.pieces[k + 1].r or
				  (d.reg and d.reg + k)

			if r then
				g:write(("\ts32i\t%s,%s\n")
					:format(REG[r],
						frameaddr(g, d.off + k * 4, 4)))
			else
				-- the caller left them at its own stack
				-- pointer, which is this frame's top
				g:write(("\tl32i\t%s,%s\n"):format(TEMP,
					frameaddr(g, frame + (d.stk + k) * 4, 4)))
				g:write(("\ts32i\t%s,%s\n"):format(TEMP,
					frameaddr(g, d.off + k * 4, 4)))
			end
		end
	end
	if vabase then
		-- the incoming argument registers, which are this window's
		-- own a2 to a7, not the outgoing a10 to a15
		for i = 1, #ARGREG do
			g:write(("\ts32i\t%s,%s\n"):format(REG[i - 1],
				frameaddr(g, vabase + (i - 1) * 4, 4)))
		end
		-- and where the caller left the rest, which is its own stack
		-- pointer and so this frame's top
		if fits8(frame) then
			g:write(("\taddi\t%s,a1,%d\n"):format(TEMP, frame))
		else
			g:write(("\tmovi\t%s,%d\n\tadd\t%s,a1,%s\n")
				:format(TEMP, frame, TEMP, TEMP))
		end
		g:write(("\ts32i\t%s,%s\n"):format(TEMP,
			frameaddr(g, vabase + #ARGREG * 4, 4)))
	end
end

local function epilogue(g, frame, fltret, wideret, recret)
	if recret and recret.cls then
		-- The result sits in a slot of ours; hand back the pieces.
		for i, p in ipairs(recret.cls) do
			g:write(("\tl32i\t%s,%s\n")
				:format(REG[i - 1],
					frameaddr(g, recret.off + p.off, 4)))
		end
	elseif recret then
		-- Too big for the registers: write it through the pointer
		-- the caller handed over.
		g:write(("\tl32i\t%s,%s\n")
			:format(regname(0), frameaddr(g, recret.ptr, 4)))
		if fits8(recret.off) then
			g:write(("\taddi\t%s,a1,%d\n")
				:format(regname(1), recret.off))
		else
			g:write(("\tmovi\t%s,%d\n\tadd\t%s,a1,%s\n")
				:format(TEMP, recret.off, regname(1), TEMP))
		end
		blockcopy(g, recret.size, 0)
		g:write(("\tl32i\t%s,%s\n")
			:format(regname(0), frameaddr(g, recret.ptr, 4)))
	elseif wideret then
		g:write("\tl32i\ta3,a2,4\n\tl32i\ta2,a2,0\n")
	end
	g:write("\tretw\n")
end

local function jump(g, label)
	g:write("\tj\t" .. label .. "\n")
end

-- The peephole rules: what the code table cannot see, because it looks
-- at one tree node at a time.
local peeprules = {
	-- A move from a register to itself, which every call ends with
	-- because the result is already where it belongs.
	{n = 1, f = function(w, i)
		local a = w[i]

		if a.mnem == "mov" and a.a and a.a == a.b then return {} end
	end},

	-- A jump to the line below it.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem == "j" and b.label and a.a == b.label then
			return {b}
		end
	end},

	-- A store read straight back out of the same place.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem == "s32i" and b.mnem == "l32i" and
		   a.a == b.a and a.b == b.b then
			return {a}
		end
	end},

	-- A register written and then written again without being read
	-- in between.
	{n = 2, f = function(w, i)
		local a, b = w[i], w[i + 1]

		if a.mnem == "mov" and a.a and a.b and b.a == a.a and
		   (b.mnem == "mov" or b.mnem == "movi") and
		   b.b ~= a.a then
			return {b}
		end
	end},
}

-- GNU labels as values: the address is in a register.
local function jumpto(g, reg)
	g:write("\tjx\t" .. regname(reg) .. "\n")
end

local code = {reg = {}, eff = {}, cc = {}}

code.reg.CONST = {
	{"z", "z", asm = "\tmovi\t%R,0"},
	{"n", "z", asm = "\tmovi\t%R,%A"},
}
-- There is no signed byte load, so that one takes an explicit sign
-- extension after it.
code.reg.AUTO = {
	{"ibs", "z", asm = "\tl8ui\t%R,%A\n\tsext\t%R,%R,7"},
	{"i",   "z", asm = "\t%I\t%R,%A"},
}
code.reg.NAME = {
	{"abs", "z",
	 asm = "\tmovi\t%R,%A\n\tl8ui\t%R,%R,0\n\tsext\t%R,%R,7"},
	{"a",   "z", asm = "\tmovi\t%R,%A\n\t%I\t%R,%R,0"},
}
code.reg.ADDR = {
	{"i", "z", asm = function(g, n, reg)
		local off, r = n.left.off, regname(reg)
		if fits8(off) then
			g:write(("\taddi\t%s,a1,%d\n"):format(r, off))
		else
			g:write(("\tmovi\t%s,%d\n\tadd\t%s,a1,%s\n")
				:format(r, off, r, r))
		end
	end},
	{"a", "z", asm = "\tmovi\t%R,%A1"},
}
code.reg.INDIR = {
	{"nbsp", "z", ev = "L", asm = "\tl8ui\t%R,%P,0\n\tsext\t%R,%R,7"},
	{"n", "z", ev = "L", asm = "\t%I\t%R,%P,0"},
}
code.reg.NEG = {{"n", "z", ev = "L", asm = "\tneg\t%R,%R"}}
code.reg.NOT = {{"n", "z", ev = "L",
		 asm = "\tmovi\t" .. TEMP .. ",-1\n\txor\t%R,%R," .. TEMP}}

code.reg.POSTADD = {
	{"i", "z", rz = 1,
	 asm = "\t%I\t%R,%A1\n\taddi\t%R1,%R,%C\n\t%I2\t%R1,%A1"},
	{"n*", "z", rz = 1, ev = "L1*",
	 asm = "\t%I\t%R,%P1,0\n\taddi\t%R2,%R,%C\n\t%I2\t%R2,%P1,0"},
	{"a", "z", rz = 1,
	 asm = "\tmovi\t%R1,%A1\n\t%I\t%R,%R1,0\n" ..
	       "\taddi\t%R2,%R,%C\n\t%I2\t%R2,%R1,0"},
}
code.eff.POSTADD = {
	{"i", "z", rz = 1,
	 asm = "\t%I\t%R,%A1\n\taddi\t%R,%R,%C\n\t%I2\t%R,%A1"},
	{"n*", "z", rz = 1, ev = "L1*",
	 asm = "\t%I\t%R,%P1,0\n\taddi\t%R,%R,%C\n\t%I2\t%R,%P1,0"},
	{"a", "z", rz = 1,
	 asm = "\tmovi\t%R1,%A1\n\t%I\t%R,%R1,0\n" ..
	       "\taddi\t%R,%R,%C\n\t%I2\t%R,%R1,0"},
}

-- The operators share one list of alternatives; only ADD has an
-- immediate form in front of it.
local BINREG = {"n", "e", ev = "L R1", asm = "\t%I\t%R,%R,%R1"}
local BINSTK = {"n", "n", ev = "Rs L",
		asm = "\tl32i\t%R1,a1,%S\n\t%I\t%R,%R,%R1"}
local BIN = {BINREG, BINSTK}

code.reg.ADD = {{"n", "c", imm = true, ev = "L", asm = "\t%I\t%R,%R,%C2"},
		BINREG, BINSTK}
for _, op in ipairs{"SUB", "AND", "OR", "XOR", "MUL", "DIV", "MOD"} do
	code.reg[op] = BIN
end

-- The shift amount lives in a special register, so a variable shift is two
-- instructions and an immediate one has its own opcode.  A logical right
-- shift by a constant is EXTUI, whose second field is the width that is
-- kept, which no template can work out.
local function shiftimm(g, n, reg)
	local r = regname(reg)
	local k = n.right.val & 31
	if n.op == "SHL" then
		g:write(k == 0 and "" or ("\tslli\t%s,%s,%d\n"):format(r, r, k))
	elseif n.ty.kind == "uint" then
		-- SRLI shifts by at most fifteen and EXTUI keeps at most
		-- sixteen bits, so between them they cover the range
		if k == 0 then
			return
		elseif k <= 15 then
			g:write(("\tsrli\t%s,%s,%d\n"):format(r, r, k))
		else
			g:write(("\textui\t%s,%s,%d,%d\n")
				:format(r, r, k, 32 - k))
		end
	else
		g:write(("\tsrai\t%s,%s,%d\n"):format(r, r, k))
	end
end

local function shiftreg(g, n, reg, other)
	local r = regname(reg)
	if n.op == "SHL" then
		g:write(("\tssl\t%s\n\tsll\t%s,%s\n"):format(other, r, r))
	elseif n.ty.kind == "uint" then
		g:write(("\tssr\t%s\n\tsrl\t%s,%s\n"):format(other, r, r))
	else
		g:write(("\tssr\t%s\n\tsra\t%s,%s\n"):format(other, r, r))
	end
end

code.reg.SHL = {
	{"n", "c", ev = "L", asm = shiftimm},
	{"n", "e", ev = "L R1", asm = function(g, n, reg)
		shiftreg(g, n, reg, regname(reg + 1))
	end},
	{"n", "n", ev = "Rs L", asm = function(g, n, reg)
		g.spill = g.spill - 1
		g:write(("\tl32i\t%s,a1,%d\n")
			:format(regname(reg + 1), spillslot(g.spill)))
		shiftreg(g, n, reg, regname(reg + 1))
	end},
}
code.reg.SHR = code.reg.SHL

local CMP = {{"n", "n", ev = "L R1"}}
for _, op in ipairs{"EQ", "NE", "LT", "LE", "GT", "GE"} do
	code.cc[op] = CMP
end

code.eff.ASGN = {
	{"i",  "n", rz = 1, ev = "R",  asm = "\t%I\t%R,%A1"},
	{"n*", "n", rz = 1, ev = "R L1*", asm = "\t%I\t%R,%P1,0"},
	{"a",  "n", rz = 1, ev = "R",
	 asm = "\tmovi\t%R1,%A1\n\t%I\t%R,%R1,0"},
}
code.reg.ASGN = code.eff.ASGN

local predef = {
	__XTENSA__ = "1", __xtensa__ = "1",
	__XTENSA_WINDOWED_ABI__ = "1",
	__SIZEOF_POINTER__ = "4", __SIZEOF_LONG__ = "4",
	__SIZEOF_LONG_LONG__ = "8", __SIZEOF_INT__ = "4",
	__SIZEOF_SHORT__ = "2", __SIZEOF_DOUBLE__ = "8",
	__SIZEOF_FLOAT__ = "4", __SIZEOF_SIZE_T__ = "4",
	__CHAR_BIT__ = "8", __ORDER_LITTLE_ENDIAN__ = "1234",
	__ORDER_BIG_ENDIAN__ = "4321", __BYTE_ORDER__ = "1234",
	__ELF__ = "1",
	__CHAR_UNSIGNED__ = "1",
}

-- Without this the linker assumes the stack must be executable, and
-- refuses to load the result as a shared object.
local trailer = '\t.section\t.note.GNU-stack,"",@progbits\n'

return md.target{
	name = "xtensa",
	ptrsize = 4,
	predef = predef,
	-- plain char is unsigned here, as it is on RISC-V
	charsigned = false,
	nreg = 6,
	-- A value wider than a register travels by address.
	wideargs = true,
	upward = true,
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
	longcalls = function(on) longcall = on end,
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
	vastkslot = true,
	nargreg = #ARGREG,
	nfltreg = 0,
	vafloat = false,
	fltspill = false,
	hiddenarg = true,
	recabi = true,
	argpieces = argpieces,
	recalign = 16,
	regstop = true,
	vaalign = true,
	peep = peeprules,
	eightbytes = eightbytes,
	spillslot = spillslot,
	epilogue = epilogue,
	slot = slot,
	frame = frame,
	jump = jump,
	memreg = function(r) return regname(r) .. ", 0" end,
	jumpto = jumpto,
	code = code,
	trailer = trailer,
}
