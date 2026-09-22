-- SPDX-License-Identifier: ISC
-- WebAssembly, as a machine with a memory and a shadow stack.
--
-- A wasm local has one type where a register holds whatever the node
-- has, so registers are four banks of locals and the width the emitter
-- asks for picks the bank. C locals go in a frame in linear memory: a
-- wasm local has no address and C says one exists. The text written
-- here is one instruction a line, since there is no assembly to be
-- near.

local md = require "md"
local data = require "data"

local NREG = 8

-- Where each bank starts, past whatever parameters the function took.
local BANK = { i32 = 0, i64 = NREG, f32 = 2 * NREG, f64 = 3 * NREG }
local NLOCAL = 4 * NREG

local S = {}			-- per function: nparams, frame size

local function bank(kind, size)
	if kind == "f" then return size == 4 and BANK.f32 or BANK.f64 end
	return size == 8 and BANK.i64 or BANK.i32
end

local function regname(r, size)
	if r >= NREG then error("out of registers: r" .. r) end
	return tostring((S.nparams or 0) + bank("i", size or 8) + r)
end

local function fregname(r, size)
	if r >= NREG then error("out of float registers: r" .. r) end
	return tostring((S.nparams or 0) + bank("f", size or 8) + r)
end

-- The type letter an instruction carries, from a node's type.
local function ty(n)
	local t = n and n.ty

	if not t then return "i32" end
	if t.kind == "float" then return t.size == 4 and "f32" or "f64" end
	return t.size == 8 and "i64" or "i32"
end

local function suffix(size, kind)
	if kind == "float" then return size == 4 and "f32" or "f64" end
	return size == 8 and "i64" or "i32"
end

-- An address is a byte offset from the frame pointer, or a symbol,
-- which the linker step turns into a constant.
local function addr(g, n)
	local op = n.op

	if op == "AUTO" then
		return ("f%+d"):format(n.off or 0)
	end
	if op == "NAME" then
		return "@" .. n.name
	end
	if op == "CONST" then
		return tostring(n.val or 0)
	end
	return "?" .. tostring(op)
end

-- ---- the pieces gen.lua calls ----

local function mnem(n, alt)
	local t = ty(n)
	local op = n.op
	local NAME = {
		ADD = "add", SUB = "sub", MUL = "mul", AND = "and",
		OR = "or", XOR = "xor", SHL = "shl",
	}
	local SIGNED = { DIV = "div", MOD = "rem", SHR = "shr" }

	if NAME[op] then return t .. "." .. NAME[op] end
	if SIGNED[op] then
		local u = n.ty and n.ty.unsigned
		local nm = SIGNED[op] == "rem" and "rem" or SIGNED[op]

		return ("%s.%s_%s"):format(t, nm, u and "u" or "s")
	end
	if op == "INDIR" or op == "AUTO" or op == "NAME" then
		return t .. ".load"
	end
	if op == "ASGN" then return t .. ".store" end
	return t .. ".?" .. tostring(op)
end

local function move(g, dst, src, size, flt)
	if dst == src then return end
	g:write(("\tlocal.get\t%s\n\tlocal.set\t%s\n"):format(src, dst))
end

local function rawmove(g, dst, src)
	move(g, dst, src)
end

-- A jump is a case number and a branch back to the dispatch loop; the
-- structure that reads it is built once the body is known.
local function jump(g, label)
	g:write(("\tgoto\t%s\n"):format(label))
end

local function branch(g, n, label, sense, reg)
	g:write(("\tgoto_if\t%s\t%s\n"):format(sense and "" or "not", label))
end

local function frame(g, size)
	S.frame = size
end

-- Slots are negative from a frame pointer, as everywhere else here; a
-- wasm load offset is unsigned, so the arithmetic is written out.
local function slot(i)
	return -8 * i
end

local function frameof(n)
	return ((8 * n + 15) // 16) * 16
end

-- the local holding this function's frame pointer, past every bank
local function fp()
	return tostring((S.nparams or 0) + NLOCAL)
end

-- Reach an address into the value stack, ready for a load or a store.
local function reach(a)
	local off = a:match("^f([%+%-]%d+)$")

	if off then
		return ("\tlocal.get\t%s\n\ti32.const\t%s\n\ti32.add\n")
		    :format(fp(), off)
	end
	local nm = a:match("^@(.+)$")

	if nm then
		return ("\ti32.const\t@%s\n"):format(nm)
	end
	return ("\ti32.const\t%s\n"):format(a)
end

-- A wasm local keeps its value across a call, so there is nothing a
-- caller has to put anywhere: these exist because gen calls them.
local function save() end
local function restore() end

-- Widen, narrow, and cross between the integers and the floats.
local function convert(g, from, to, reg)
	local fi = from.kind ~= "float"
	local ti = to.kind ~= "float"
	local fs, ts = from.size, to.size
	local fu, tu = from.unsigned, to.unsigned
	local ft = fi and (fs == 8 and "i64" or "i32")
	    or (fs == 4 and "f32" or "f64")
	local tt = ti and (ts == 8 and "i64" or "i32")
	    or (ts == 4 and "f32" or "f64")
	local src = fi and regname(reg, fs) or fregname(reg, fs)
	local dst = ti and regname(reg, ts) or fregname(reg, ts)
	local body

	if fi and ti then
		if ft == tt then
			-- same bank: only a narrowing within i32 does work
			if ts < 4 and ts < fs then
				local bits = 32 - ts * 8

				body = ("\ti32.const\t%d\n\ti32.shl\n" ..
				    "\ti32.const\t%d\n\ti32.shr_%s\n")
				    :format(bits, bits, tu and "u" or "s")
			else
				body = ""
			end
		elseif ft == "i64" then
			body = "\ti32.wrap_i64\n"
		else
			body = ("\ti64.extend_i32_%s\n"):format(fu and "u" or "s")
		end
	elseif fi then
		body = ("\t%s.convert_%s_%s\n"):format(tt, ft, fu and "u" or "s")
	elseif ti then
		body = ("\t%s.trunc_%s_%s\n"):format(tt, ft, tu and "u" or "s")
	elseif ft == tt then
		body = ""
	elseif ft == "f64" then
		body = "\tf32.demote_f64\n"
	else
		body = "\tf64.promote_f32\n"
	end

	if body == "" and src == dst then return end
	g:write(("\tlocal.get\t%s\n"):format(src) .. body ..
	    ("\tlocal.set\t%s\n"):format(dst))
end

-- No bulk memory here, since not every engine has it: a byte at a time
-- through a counted loop the dispatch pass never sees, because it is
-- written as a wasm loop rather than as labels.
local function blockcopy(g, size, reg)
	local dst, src = regname(reg, 4), regname(reg + 1, 4)

	for i = 0, size - 1 do
		g:write(("\tlocal.get\t%s\n\ti32.const\t%d\n\ti32.add\n" ..
		    "\tlocal.get\t%s\n\ti32.const\t%d\n\ti32.add\n" ..
		    "\ti32.load8_u\n\ti32.store8\n")
		    :format(dst, i, src, i))
	end
end

-- ---- the code table ----

-- Every alternative is a function rather than a template: a wasm
-- instruction takes its operands off the value stack, so what a
-- template would interleave has to be written in order instead.
local function tables()
	local code = { reg = {}, eff = {}, cc = {} }

	local function put(g, s) g:write(s) end

	code.reg.CONST = { { "n", "z", asm = function(g, n, reg)
		put(g, ("\t%s.const\t%s\n\tlocal.set\t%s\n")
		    :format(ty(n), tostring(n.val or 0),
		    ty(n):sub(1, 1) == "f" and fregname(reg, n.ty.size)
		    or regname(reg, n.ty and n.ty.size or 8)))
	end } }

	code.reg.AUTO = { { "i", "z", asm = function(g, n, reg)
		put(g, reach(addr(g, n)) ..
		    ("\t%s.load\n\tlocal.set\t%s\n")
		    :format(ty(n), regname(reg, n.ty and n.ty.size or 8)))
	end } }

	code.reg.NAME = { { "a", "z", asm = function(g, n, reg)
		put(g, reach(addr(g, n)) ..
		    ("\t%s.load\n\tlocal.set\t%s\n")
		    :format(ty(n), regname(reg, n.ty and n.ty.size or 8)))
	end } }

	code.reg.ADDR = { { "i", "z", asm = function(g, n, reg)
		put(g, reach(addr(g, n.left or n)) ..
		    ("\tlocal.set\t%s\n"):format(regname(reg, 4)))
	end } }

	code.reg.INDIR = { { "n", "z", ev = "L", asm = function(g, n, reg)
		put(g, ("\tlocal.get\t%s\n\t%s.load\n\tlocal.set\t%s\n")
		    :format(regname(reg, 4), ty(n), regname(reg,
		    n.ty and n.ty.size or 8)))
	end } }

	for _, op in ipairs({ "ADD", "SUB", "MUL", "AND", "OR", "XOR",
	    "SHL", "SHR", "DIV", "MOD" }) do
		code.reg[op] = { { "n", "n", ev = "L R1",
		    asm = function(g, n, reg)
			local sz = n.ty and n.ty.size or 8
			local flt = ty(n):sub(1, 1) == "f"
			local nm = flt and fregname or regname

			put(g, ("\tlocal.get\t%s\n\tlocal.get\t%s\n\t%s\n" ..
			    "\tlocal.set\t%s\n"):format(nm(reg, sz),
			    nm(reg + 1, sz), mnem(n), nm(reg, sz)))
		end } }
	end

	code.eff.ASGN = { { "n", "n", ev = "R", asm = function(g, n, reg)
		local v = n.right
		local sz = v.ty and v.ty.size or 8

		put(g, reach(addr(g, n.left)) ..
		    ("\tlocal.get\t%s\n\t%s.store\n")
		    :format(regname(reg, sz), ty(v)))
	end } }

	code.reg.ASGN = { { "n", "n", ev = "R", asm = function(g, n, reg)
		local v = n.right
		local sz = v.ty and v.ty.size or 8

		put(g, reach(addr(g, n.left)) ..
		    ("\tlocal.get\t%s\n\t%s.store\n")
		    :format(regname(reg, sz), ty(v)))
	end } }

	for _, op in ipairs({ "EQ", "NE", "LT", "LE", "GT", "GE" }) do
		code.cc[op] = { { "n", "n", ev = "L R1" } }
	end

	return code
end

-- This machine has none of these: no fixed registers, and no inline
-- assembly to name one in.
local function none() end

-- Not written yet. Silence would be wasm that validates and runs
-- wrong, which is worse than a stop, so it says so.
local function todo(what)
	return function()
		error("wasm: " .. what .. " is not written yet", 0)
	end
end

return {
	name = "wasm",
	code = tables(),
	mnem = mnem,
	convert = convert,
	blockcopy = blockcopy,
	save = save,
	restore = restore,
	call = todo("the calling convention"),
	adapt = none,
	hardreg = none,
	readhard = none,
	landing = none,
	memreg = function(r) return regname(r, 4) end,
	spillslot = function(g, i) return ("f%+d"):format(-8 * (i + 64)) end,
	ldslot = function(g, r) return ("f%+d"):format(-8 * (r + 64)) end,
	asmreg = none,
	asmpin = none,
	asmkeep = none,
	asmimm = none,
	asmaddr = none,
	asmfits = none,
	asmflag = none,
	stackargs = 0,
	wideargs = true,
	hiddenarg = true,
	upward = false,
	vafloat = false,
	fltspill = false,
	nargreg = 0,
	predef = { __wasm__ = "1", __wasm32__ = "1" },
	move = move,
	rawmove = rawmove,
	jump = jump,
	branch = branch,
	frame = frame,
	slot = slot,
	frameof = frameof,
	reach = reach,
	fp = fp,
	ptrsize = 4,
	charsigned = true,
	nreg = NREG,
	nfltreg = NREG,
	NLOCAL = NLOCAL,
	BANK = BANK,
	state = S,
	regname = regname,
	fregname = fregname,
	suffix = suffix,
	addr = addr,
	ty = ty,
}
