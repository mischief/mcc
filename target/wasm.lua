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
local ir = require "wasmir"

local E = ir.emit

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
	E(g, ir.get(src), ir.set(dst))
end

local function rawmove(g, dst, src)
	move(g, dst, src)
end

-- A jump is a case number and a branch back to the dispatch loop; the
-- structure that reads it is built once the body is known.
local function jump(g, label)
	E(g, ir.jump(label))
end

local function branch(g, n, label, sense, reg)
	E(g, ir.jumpif(label))
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

-- Put an address on the value stack, ready for a load or a store.
local function reach(a)
	local off = a:match("^f([%+%-]%d+)$")

	if off then
		return { ir.get(fp()), ir.konst("i32", off),
			ir.binop("i32", "add") }
	end
	return { ir.konst("i32", a) }
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

				body = { ir.konst("i32", bits),
					ir.binop("i32", "shl"),
					ir.konst("i32", bits),
					ir.binop("i32", "shr_" ..
					    (tu and "u" or "s")) }
			else
				body = {}
			end
		elseif ft == "i64" then
			body = { ir.op("i32.wrap_i64") }
		else
			body = { ir.op("i64.extend_i32_" ..
			    (fu and "u" or "s")) }
		end
	elseif fi then
		body = { ir.op(("%s.convert_%s_%s")
		    :format(tt, ft, fu and "u" or "s")) }
	elseif ti then
		body = { ir.op(("%s.trunc_%s_%s")
		    :format(tt, ft, tu and "u" or "s")) }
	elseif ft == tt then
		body = {}
	elseif ft == "f64" then
		body = { ir.op("f32.demote_f64") }
	else
		body = { ir.op("f64.promote_f32") }
	end

	if #body == 0 and src == dst then return end
	E(g, ir.get(src), body, ir.set(dst))
end

-- No bulk memory here, since not every engine has it: a byte at a time
-- through a counted loop the dispatch pass never sees, because it is
-- written as a wasm loop rather than as labels.
local function blockcopy(g, size, reg)
	local dst, src = regname(reg, 4), regname(reg + 1, 4)

	for i = 0, size - 1 do
		E(g, ir.get(dst), ir.konst("i32", i), ir.binop("i32", "add"),
		    ir.get(src), ir.konst("i32", i), ir.binop("i32", "add"),
		    ir.op("i32.load8_u"), ir.op("i32.store8"))
	end
end

-- Arguments are what a wasm call takes: values on the value stack, in
-- order. Every expression here leaves that stack balanced and its
-- result in a local, so one register serves every argument -- each is
-- pushed before the next is computed.
local function call(g, n, reg)
	local args = n.args or {}

	for _, a in ipairs(args) do
		local sz = a.ty and a.ty.size or 8
		local flt = a.ty and a.ty.kind == "float"

		g:expr(a, "reg", reg)
		E(g, ir.get(flt and fregname(reg, sz) or regname(reg, sz)))
	end

	if n.left and n.left.sym then
		E(g, ir.call(n.left.sym))
	else
		-- through a pointer: the index is the value, and the
		-- signature is settled when the module is written
		g:expr(n.left, "reg", reg)
		E(g, ir.get(regname(reg, 4)),
		    ir.op("call_indirect", n.sig or 0))
	end

	local rt = n.ty

	if rt and rt.kind ~= "void" then
		local flt = rt.kind == "float"

		E(g, ir.set(flt and fregname(reg, rt.size)
		    or regname(reg, rt.size)))
	end
end

-- The shadow stack pointer is a global, because a wasm local is gone
-- when the function is and C says a frame outlives the expression that
-- made it.
local SP = 0

local function wty(size, flt)
	if flt then return size == 4 and "f32" or "f64" end
	return size == 8 and "i64" or "i32"
end

local function prologue(g, name, frame, params, vabase, static, recret,
    sec, guard)
	params = params or {}
	S.nparams = #params
	S.frame = frame
	S.name = name

	E(g, ir.func(name, static and "static" or "global"),
	    ir.gget(SP), ir.set(fp()),
	    ir.gget(SP), ir.konst("i32", frame), ir.binop("i32", "sub"),
	    ir.gset(SP))

	-- Everything arrives as a wasm parameter and C wants it
	-- addressable, so each one is put away in its slot.
	for i, d in ipairs(params) do
		local sz = d.size or 8

		E(g, reach(("f%+d"):format(d.off or 0)), ir.get(i - 1),
		    ir.store(wty(sz, d.flt)))
	end
end

local function epilogue(g, frame, fltret, wideret, recret, guard)
	E(g, ir.gget(SP), ir.konst("i32", frame), ir.binop("i32", "add"),
	    ir.gset(SP))
	if fltret then
		E(g, ir.get(fregname(0, fltret)))
	elseif S.retsize then
		E(g, ir.get(regname(0, S.retsize)))
	end
	E(g, ir.ret(), ir.endfunc())
end

-- ---- the code table ----

-- Every alternative is a function rather than a template: a wasm
-- instruction takes its operands off the value stack, so what a
-- template would interleave has to be written in order instead.
local function tables()
	local code = { reg = {}, eff = {}, cc = {} }

	-- Which bank a node's result lives in.
	local function rn(n, reg)
		local sz = n.ty and n.ty.size or 8

		if ty(n):sub(1, 1) == "f" then return fregname(reg, sz) end
		return regname(reg, sz)
	end

	code.reg.CONST = { { "n", "z", asm = function(g, n, reg)
		E(g, ir.konst(ty(n), n.val or 0), ir.set(rn(n, reg)))
	end } }

	code.reg.AUTO = { { "i", "z", asm = function(g, n, reg)
		E(g, reach(addr(g, n)), ir.load(ty(n)), ir.set(rn(n, reg)))
	end } }

	code.reg.NAME = { { "a", "z", asm = function(g, n, reg)
		E(g, reach(addr(g, n)), ir.load(ty(n)), ir.set(rn(n, reg)))
	end } }

	code.reg.ADDR = { { "i", "z", asm = function(g, n, reg)
		E(g, reach(addr(g, n.left or n)), ir.set(regname(reg, 4)))
	end } }

	code.reg.INDIR = { { "n", "z", ev = "L", asm = function(g, n, reg)
		E(g, ir.get(regname(reg, 4)), ir.load(ty(n)),
		    ir.set(rn(n, reg)))
	end } }

	for _, op in ipairs({ "ADD", "SUB", "MUL", "AND", "OR", "XOR",
	    "SHL", "SHR", "DIV", "MOD" }) do
		code.reg[op] = { { "n", "n", ev = "L R1",
		    asm = function(g, n, reg)
			local sz = n.ty and n.ty.size or 8
			local nm = ty(n):sub(1, 1) == "f" and fregname
			    or regname

			E(g, ir.get(nm(reg, sz)), ir.get(nm(reg + 1, sz)),
			    ir.op(mnem(n)), ir.set(nm(reg, sz)))
		end } }
	end

	local function assign(g, n, reg)
		local v = n.right
		local sz = v.ty and v.ty.size or 8

		E(g, reach(addr(g, n.left)), ir.get(regname(reg, sz)),
		    ir.store(ty(v)))
	end

	code.eff.ASGN = { { "n", "n", ev = "R", asm = assign } }
	code.reg.ASGN = { { "n", "n", ev = "R", asm = assign } }

	for _, op in ipairs({ "EQ", "NE", "LT", "LE", "GT", "GE" }) do
		code.cc[op] = { { "n", "n", ev = "L R1" } }
	end

	return code
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
	E(g, ir.get(src), ir.set(dst))
end

local function rawmove(g, dst, src)
	move(g, dst, src)
end

-- A jump is a case number and a branch back to the dispatch loop; the
-- structure that reads it is built once the body is known.
local function jump(g, label)
	E(g, ir.jump(label))
end

local function branch(g, n, label, sense, reg)
	E(g, ir.jumpif(label))
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

-- Put an address on the value stack, ready for a load or a store.
local function reach(a)
	local off = a:match("^f([%+%-]%d+)$")

	if off then
		return { ir.get(fp()), ir.konst("i32", off),
			ir.binop("i32", "add") }
	end
	return { ir.konst("i32", a) }
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

				body = { ir.konst("i32", bits),
					ir.binop("i32", "shl"),
					ir.konst("i32", bits),
					ir.binop("i32", "shr_" ..
					    (tu and "u" or "s")) }
			else
				body = {}
			end
		elseif ft == "i64" then
			body = { ir.op("i32.wrap_i64") }
		else
			body = { ir.op("i64.extend_i32_" ..
			    (fu and "u" or "s")) }
		end
	elseif fi then
		body = { ir.op(("%s.convert_%s_%s")
		    :format(tt, ft, fu and "u" or "s")) }
	elseif ti then
		body = { ir.op(("%s.trunc_%s_%s")
		    :format(tt, ft, tu and "u" or "s")) }
	elseif ft == tt then
		body = {}
	elseif ft == "f64" then
		body = { ir.op("f32.demote_f64") }
	else
		body = { ir.op("f64.promote_f32") }
	end

	if #body == 0 and src == dst then return end
	E(g, ir.get(src), body, ir.set(dst))
end

-- No bulk memory here, since not every engine has it: a byte at a time
-- through a counted loop the dispatch pass never sees, because it is
-- written as a wasm loop rather than as labels.
local function blockcopy(g, size, reg)
	local dst, src = regname(reg, 4), regname(reg + 1, 4)

	for i = 0, size - 1 do
		E(g, ir.get(dst), ir.konst("i32", i), ir.binop("i32", "add"),
		    ir.get(src), ir.konst("i32", i), ir.binop("i32", "add"),
		    ir.op("i32.load8_u"), ir.op("i32.store8"))
	end
end

-- Arguments are what a wasm call takes: values on the value stack, in
-- order. Every expression here leaves that stack balanced and its
-- result in a local, so one register serves every argument -- each is
-- pushed before the next is computed.
local function call(g, n, reg)
	local args = n.args or {}

	for _, a in ipairs(args) do
		local sz = a.ty and a.ty.size or 8
		local flt = a.ty and a.ty.kind == "float"

		g:expr(a, "reg", reg)
		E(g, ir.get(flt and fregname(reg, sz) or regname(reg, sz)))
	end

	if n.left and n.left.sym then
		E(g, ir.call(n.left.sym))
	else
		-- through a pointer: the index is the value, and the
		-- signature is settled when the module is written
		g:expr(n.left, "reg", reg)
		E(g, ir.get(regname(reg, 4)),
		    ir.op("call_indirect", n.sig or 0))
	end

	local rt = n.ty

	if rt and rt.kind ~= "void" then
		local flt = rt.kind == "float"

		E(g, ir.set(flt and fregname(reg, rt.size)
		    or regname(reg, rt.size)))
	end
end

-- The shadow stack pointer is a global, because a wasm local is gone
-- when the function is and C says a frame outlives the expression that
-- made it.
local SP = 0

local function wty(size, flt)
	if flt then return size == 4 and "f32" or "f64" end
	return size == 8 and "i64" or "i32"
end

local function prologue(g, name, frame, params, vabase, static, recret,
    sec, guard)
	params = params or {}
	S.nparams = #params
	S.frame = frame
	S.name = name

	E(g, ir.func(name, static and "static" or "global"),
	    ir.gget(SP), ir.set(fp()),
	    ir.gget(SP), ir.konst("i32", frame), ir.binop("i32", "sub"),
	    ir.gset(SP))

	-- Everything arrives as a wasm parameter and C wants it
	-- addressable, so each one is put away in its slot.
	for i, d in ipairs(params) do
		local sz = d.size or 8

		E(g, reach(("f%+d"):format(d.off or 0)), ir.get(i - 1),
		    ir.store(wty(sz, d.flt)))
	end
end

local function epilogue(g, frame, fltret, wideret, recret, guard)
	E(g, ir.gget(SP), ir.konst("i32", frame), ir.binop("i32", "add"),
	    ir.gset(SP))
	if fltret then
		E(g, ir.get(fregname(0, fltret)))
	elseif S.retsize then
		E(g, ir.get(regname(0, S.retsize)))
	end
	E(g, ir.ret(), ir.endfunc())
end

-- ---- the code table ----

-- Every alternative is a function rather than a template: a wasm
-- instruction takes its operands off the value stack, so what a
-- template would interleave has to be written in order instead.

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
	call = call,
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
	prologue = prologue,
	epilogue = epilogue,
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
