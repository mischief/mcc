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

local function slot(g, off)
	return ("f%+d"):format(off)
end

return {
	name = "wasm",
	mnem = mnem,
	move = move,
	rawmove = rawmove,
	jump = jump,
	branch = branch,
	frame = frame,
	slot = slot,
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
