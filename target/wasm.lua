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

-- Locals are named rather than numbered: a body is generated before
-- its prologue, so the parameter count is not known here, and it is
-- what every bank sits above. as/wasm.lua resolves these once it has
-- read the signature.
local function regname(r, size)
	if r >= NREG then error("out of registers: r" .. r) end
	return ("$%s%d"):format((size or 8) == 8 and "I" or "i", r)
end

local function fregname(r, size)
	if r >= NREG then error("out of float registers: r" .. r) end
	return ("$%s%d"):format((size or 8) == 4 and "f" or "F", r)
end

-- The type letter an instruction carries, from a node's type.
local function ty(n)
	local t = n and n.ty

	if not t then return "i32" end
	if t.kind == "float" then return t.size == 4 and "f32" or "f64" end
	return t.size == 8 and "i64" or "i32"
end

-- A load and a store name the width they touch: a char is a byte in
-- memory and a whole register once it is read.
local function loadop(t)
	if not t or t.kind == "float" then
		return ((t and t.size or 8) == 4 and "f32" or "f64") .. ".load"
	end
	local reg = t.size == 8 and "i64" or "i32"

	if t.size == 1 then
		return reg .. ".load8_" .. (t.unsigned and "u" or "s")
	end
	if t.size == 2 then
		return reg .. ".load16_" .. (t.unsigned and "u" or "s")
	end
	if t.size == 4 and reg == "i64" then
		return "i64.load32_" .. (t.unsigned and "u" or "s")
	end
	return reg .. ".load"
end

local function storeop(t)
	if not t or t.kind == "float" then
		return ((t and t.size or 8) == 4 and "f32" or "f64") .. ".store"
	end
	local reg = t.size == 8 and "i64" or "i32"

	if t.size == 1 then return reg .. ".store8" end
	if t.size == 2 then return reg .. ".store16" end
	if t.size == 4 and reg == "i64" then return "i64.store32" end
	return reg .. ".store"
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
		if n.pin then return regname(n.pin, n.ty.size) end
		return ("f%+d"):format(n.off or 0)
	end
	if op == "NAME" then
		return "@" .. n.sym
	end
	if op == "CONST" then
		return tostring(n.val or 0)
	end
	return "?" .. tostring(op)
end

-- ---- the pieces gen.lua calls ----

-- The instruction for an operator, at the node's type. Only the
-- integers carry a sign: a float divide is div, not div_s.
local NAME = { ADD = "add", SUB = "sub", MUL = "mul", AND = "and",
	OR = "or", XOR = "xor", SHL = "shl" }
local SIGNED = { DIV = "div", MOD = "rem", SHR = "shr" }

local function mnem(n, alt)
	local t = ty(n)
	local op = n.op

	if NAME[op] then return t .. "." .. NAME[op] end
	if SIGNED[op] then
		if t:sub(1, 1) == "f" then
			return t .. "." .. (op == "DIV" and "div" or
			    error("wasm: no float " .. op))
		end
		return ("%s.%s_%s"):format(t, SIGNED[op],
		    (n.ty and n.ty.unsigned) and "u" or "s")
	end
	error("wasm: no instruction for " .. tostring(op))
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

local CMP = { EQ = "eq", NE = "ne", LT = "lt", LE = "le", GT = "gt",
	GE = "ge" }

-- The comparison and the jump together: gen leaves the operands in
-- reg and reg+1 and expects the target to say what to do with them.
local function branch(g, n, label, sense, reg)
	local cmp = CMP[n.op]

	if cmp then
		local l = n.left
		local t = ty(l)
		local flt = t:sub(1, 1) == "f"
		local sz = l.ty and l.ty.size or 8
		local nm = flt and fregname or regname

		if not flt and cmp ~= "eq" and cmp ~= "ne" then
			cmp = cmp .. ((l.ty and l.ty.unsigned) and "_u" or "_s")
		end
		g:write(("\tlocal.get\t%s\n\tlocal.get\t%s\n\t%s.%s\n")
		    :format(nm(reg, sz), nm(reg + 1, sz), t, cmp))
	else
		-- a value tested for being something other than zero
		local t = ty(n)
		local sz = n.ty and n.ty.size or 8

		g:write(("\tlocal.get\t%s\n\t%s.eqz\n\ti32.eqz\n")
		    :format(regname(reg, sz), t))
	end
	if not sense then g:write("\ti32.eqz\n") end
	g:write(("\tgoto_if\t%s\n"):format(label))
end

-- How big a frame with this many slots is, rounded as a stack wants.
local function frame(n)
	return ((8 * n + 15) // 16) * 16
end

-- Slots are negative from a frame pointer, as everywhere else here; a
-- wasm load offset is unsigned, so the arithmetic is written out.
local function slot(i)
	return -8 * i
end

-- the local holding this function's frame pointer, past every bank
local function fp()
	return "$fp"
end

-- Put an address on the value stack, ready for a load or a store.
local function reach(a)
	local off = a:match("^f([%+%-]%d+)$")

	if off then
		return ("\tlocal.get\t%s\n\ti32.const\t%s\n\ti32.add\n")
		    :format(fp(), off)
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
		    "\ti32.load8_u\n\ti32.store8\n"):format(dst, i, src, i))
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
		g:write(("\tlocal.get\t%s\n")
		    :format(flt and fregname(reg, sz) or regname(reg, sz)))
	end

	if n.left and n.left.sym then
		-- What this callee looks like, so a name with no body in
		-- the module can be declared as an import.
		local ps = {}

		for _, a in ipairs(args) do
			ps[#ps + 1] = wty(a.ty and a.ty.size or 8,
			    a.ty and a.ty.kind == "float")
		end
		g:write(("\t.callsig\t%s\t%s\t->\t%s\n")
		    :format(n.left.sym, table.concat(ps, " "),
		    (n.ty and n.ty.kind ~= "void") and
		    wty(n.ty.size, n.ty.kind == "float") or ""))
		g:write(("\tcall\t@%s\n"):format(n.left.sym))
	else
		-- through a pointer: the index is the value, and the
		-- signature is settled when the module is written
		g:expr(n.left, "reg", reg)
		g:write(("\tlocal.get\t%s\n\tcall_indirect\t%s\n")
		    :format(regname(reg, 4), n.sig or 0))
	end

	local rt = n.ty

	if rt and rt.kind ~= "void" then
		local flt = rt.kind == "float"

		g:write(("\tlocal.set\t%s\n")
		    :format(flt and fregname(reg, rt.size)
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

	g:write(("\t.func\t%s\t%s\n"):format(name,
	    static and "static" or "global"))

	-- A wasm function carries its signature, so the parameters are
	-- named here and the result where the epilogue knows it.
	local ps = {}

	for _, d in ipairs(params) do
		ps[#ps + 1] = wty(d.size or 8, d.flt)
	end
	g:write(("\t.params\t%s\n"):format(table.concat(ps, " ")))
	g:write(("\tglobal.get\t%d\n\tlocal.set\t%s\n"):format(SP, fp()))
	g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
	    "\tglobal.set\t%d\n"):format(SP, frame, SP))

	-- Everything arrives as a wasm parameter and C wants it
	-- addressable, so each one is put away in its slot.
	for i, d in ipairs(params) do
		local sz = d.size or 8

		g:write(reach(("f%+d"):format(d.off or 0)) ..
		    ("\tlocal.get\t%d\n\t%s.store\n")
		    :format(i - 1, wty(sz, d.flt)))
	end
end

local function epilogue(g, frame, fltret, wideret, recret, guard, rty)
	local res = ""

	if rty and rty.kind ~= "void" then
		res = wty(rty.size, rty.kind == "float")
		S.retsize = rty.size
	else
		S.retsize = nil
	end
	g:write(("\t.result\t%s\n"):format(res))
	g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n" ..
	    "\tglobal.set\t%d\n"):format(SP, frame, SP))
	if rty and rty.kind == "float" then
		g:write(("\tlocal.get\t%s\n"):format(fregname(0, rty.size)))
	elseif S.retsize then
		g:write(("\tlocal.get\t%s\n"):format(regname(0, S.retsize)))
	end
	g:write("\treturn\n\t.endfunc\n")
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
		g:write(("\t%s.const\t%s\n\tlocal.set\t%s\n")
		    :format(ty(n), n.val or 0, rn(n, reg)))
	end } }

	local function fetch(g, n, reg)
		g:write(reach(addr(g, n)) ..
		    ("\t%s\n\tlocal.set\t%s\n")
		    :format(loadop(n.ty), rn(n, reg)))
	end

	code.reg.AUTO = { { "i", "z", asm = fetch } }
	code.reg.NAME = { { "a", "z", asm = fetch } }

	code.reg.ADDR = { { "i", "z", asm = function(g, n, reg)
		g:write(reach(addr(g, n.left or n)) ..
		    ("\tlocal.set\t%s\n"):format(regname(reg, 4)))
	end } }

	code.reg.INDIR = { { "n", "z", ev = "L", asm = function(g, n, reg)
		g:write(("\tlocal.get\t%s\n\t%s\n\tlocal.set\t%s\n")
		    :format(regname(reg, 4), loadop(n.ty), rn(n, reg)))
	end } }

	for _, op in ipairs({ "ADD", "SUB", "MUL", "AND", "OR", "XOR",
	    "SHL", "SHR", "DIV", "MOD" }) do
		code.reg[op] = { { "n", "n", ev = "L R1",
		    asm = function(g, n, reg)
			local sz = n.ty and n.ty.size or 8
			local nm = ty(n):sub(1, 1) == "f" and fregname
			    or regname

			g:write(("\tlocal.get\t%s\n\tlocal.get\t%s\n" ..
			    "\t%s\n\tlocal.set\t%s\n"):format(nm(reg, sz),
			    nm(reg + 1, sz), mnem(n), nm(reg, sz)))
		end } }
	end

	-- i++ as a statement, and as a value: the old one is what it is
	-- worth, so a value context keeps a copy before adding.
	local function postadd(g, n, reg, keep)
		local v = n.left
		local t = ty(v)
		local sz = v.ty and v.ty.size or 8
		local r = regname(reg, sz)
		local a = reach(addr(g, v))

		g:write(a .. ("\t%s\n\tlocal.set\t%s\n")
		    :format(loadop(v.ty), r))
		if keep then
			g:write(("\tlocal.get\t%s\n\tlocal.set\t%s\n")
			    :format(r, regname(reg + 1, sz)))
		end
		g:write(a .. ("\tlocal.get\t%s\n\t%s.const\t%d\n" ..
		    "\t%s.add\n\t%s\n")
		    :format(r, t, n.val or 1, t, storeop(v.ty)))
		if keep then
			g:write(("\tlocal.get\t%s\n\tlocal.set\t%s\n")
			    :format(regname(reg + 1, sz), r))
		end
	end

	code.eff.POSTADD = { { "n", "z", asm = function(g, n, reg)
		postadd(g, n, reg, false)
	end } }
	code.reg.POSTADD = { { "n", "z", asm = function(g, n, reg)
		postadd(g, n, reg, true)
	end } }

	code.reg.NEG = { { "n", "z", ev = "L", asm = function(g, n, reg)
		local sz = n.ty and n.ty.size or 8
		local t = ty(n)

		if t:sub(1, 1) == "f" then
			g:write(("\tlocal.get\t%s\n\t%s.neg\n" ..
			    "\tlocal.set\t%s\n"):format(fregname(reg, sz),
			    t, fregname(reg, sz)))
		else
			g:write(("\t%s.const\t0\n\tlocal.get\t%s\n" ..
			    "\t%s.sub\n\tlocal.set\t%s\n")
			    :format(t, regname(reg, sz), t, regname(reg, sz)))
		end
	end } }

	code.reg.NOT = { { "n", "z", ev = "L", asm = function(g, n, reg)
		local sz = n.ty and n.ty.size or 8
		local t = ty(n)
		local r = regname(reg, sz)

		g:write(("\tlocal.get\t%s\n\t%s.const\t-1\n\t%s.xor\n" ..
		    "\tlocal.set\t%s\n"):format(r, t, t, r))
	end } }

	local function assign(g, n, reg)
		local v = n.right
		local sz = v.ty and v.ty.size or 8

		local dt = n.left.ty or v.ty

		g:write(reach(addr(g, n.left)) ..
		    ("\tlocal.get\t%s\n\t%s\n")
		    :format(regname(reg, sz), storeop(dt)))
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

local CMP = { EQ = "eq", NE = "ne", LT = "lt", LE = "le", GT = "gt",
	GE = "ge" }

-- The comparison and the jump together: gen leaves the operands in
-- reg and reg+1 and expects the target to say what to do with them.
local function branch(g, n, label, sense, reg)
	local cmp = CMP[n.op]

	if cmp then
		local l = n.left
		local t = ty(l)
		local flt = t:sub(1, 1) == "f"
		local sz = l.ty and l.ty.size or 8
		local nm = flt and fregname or regname

		if not flt and cmp ~= "eq" and cmp ~= "ne" then
			cmp = cmp .. ((l.ty and l.ty.unsigned) and "_u" or "_s")
		end
		g:write(("\tlocal.get\t%s\n\tlocal.get\t%s\n\t%s.%s\n")
		    :format(nm(reg, sz), nm(reg + 1, sz), t, cmp))
	else
		-- a value tested for being something other than zero
		local t = ty(n)
		local sz = n.ty and n.ty.size or 8

		g:write(("\tlocal.get\t%s\n\t%s.eqz\n\ti32.eqz\n")
		    :format(regname(reg, sz), t))
	end
	if not sense then g:write("\ti32.eqz\n") end
	g:write(("\tgoto_if\t%s\n"):format(label))
end

-- How big a frame with this many slots is, rounded as a stack wants.
local function frame(n)
	return ((8 * n + 15) // 16) * 16
end

-- Slots are negative from a frame pointer, as everywhere else here; a
-- wasm load offset is unsigned, so the arithmetic is written out.
local function slot(i)
	return -8 * i
end

-- the local holding this function's frame pointer, past every bank
local function fp()
	return "$fp"
end

-- Put an address on the value stack, ready for a load or a store.
local function reach(a)
	local off = a:match("^f([%+%-]%d+)$")

	if off then
		return ("\tlocal.get\t%s\n\ti32.const\t%s\n\ti32.add\n")
		    :format(fp(), off)
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
		    "\ti32.load8_u\n\ti32.store8\n"):format(dst, i, src, i))
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
		g:write(("\tlocal.get\t%s\n")
		    :format(flt and fregname(reg, sz) or regname(reg, sz)))
	end

	if n.left and n.left.sym then
		-- What this callee looks like, so a name with no body in
		-- the module can be declared as an import.
		local ps = {}

		for _, a in ipairs(args) do
			ps[#ps + 1] = wty(a.ty and a.ty.size or 8,
			    a.ty and a.ty.kind == "float")
		end
		g:write(("\t.callsig\t%s\t%s\t->\t%s\n")
		    :format(n.left.sym, table.concat(ps, " "),
		    (n.ty and n.ty.kind ~= "void") and
		    wty(n.ty.size, n.ty.kind == "float") or ""))
		g:write(("\tcall\t@%s\n"):format(n.left.sym))
	else
		-- through a pointer: the index is the value, and the
		-- signature is settled when the module is written
		g:expr(n.left, "reg", reg)
		g:write(("\tlocal.get\t%s\n\tcall_indirect\t%s\n")
		    :format(regname(reg, 4), n.sig or 0))
	end

	local rt = n.ty

	if rt and rt.kind ~= "void" then
		local flt = rt.kind == "float"

		g:write(("\tlocal.set\t%s\n")
		    :format(flt and fregname(reg, rt.size)
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

	g:write(("\t.func\t%s\t%s\n"):format(name,
	    static and "static" or "global"))

	-- A wasm function carries its signature, so the parameters are
	-- named here and the result where the epilogue knows it.
	local ps = {}

	for _, d in ipairs(params) do
		ps[#ps + 1] = wty(d.size or 8, d.flt)
	end
	g:write(("\t.params\t%s\n"):format(table.concat(ps, " ")))
	g:write(("\tglobal.get\t%d\n\tlocal.set\t%s\n"):format(SP, fp()))
	g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
	    "\tglobal.set\t%d\n"):format(SP, frame, SP))

	-- Everything arrives as a wasm parameter and C wants it
	-- addressable, so each one is put away in its slot.
	for i, d in ipairs(params) do
		local sz = d.size or 8

		g:write(reach(("f%+d"):format(d.off or 0)) ..
		    ("\tlocal.get\t%d\n\t%s.store\n")
		    :format(i - 1, wty(sz, d.flt)))
	end
end

local function epilogue(g, frame, fltret, wideret, recret, guard, rty)
	local res = ""

	if rty and rty.kind ~= "void" then
		res = wty(rty.size, rty.kind == "float")
		S.retsize = rty.size
	else
		S.retsize = nil
	end
	g:write(("\t.result\t%s\n"):format(res))
	g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n" ..
	    "\tglobal.set\t%d\n"):format(SP, frame, SP))
	if rty and rty.kind == "float" then
		g:write(("\tlocal.get\t%s\n"):format(fregname(0, rty.size)))
	elseif S.retsize then
		g:write(("\tlocal.get\t%s\n"):format(regname(0, S.retsize)))
	end
	g:write("\treturn\n\t.endfunc\n")
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
	wideargs = false,
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
	data = data,
	prologue = prologue,
	epilogue = epilogue,
	reach = reach,
	fp = fp,
	ptrsize = 4,
	-- 32-bit pointers over native i64 and f64, which no other
	-- machine here has and parse.lua would otherwise assume away
	native64 = true,
	-- f32 and f64 are value types here, not bit patterns a runtime
	-- takes apart
	hwfloat = true,
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
