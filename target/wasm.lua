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
local tree = require "tree"
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

-- Unsignedness is in the kind, not a flag: a target that asks for
-- ty.unsigned gets nil every time and signs everything.
local function uns(t)
	return t ~= nil and t.kind == "uint"
end

-- A load and a store name the width they touch: a char is a byte in
-- memory and a whole register once it is read.
local function loadop(t)
	if not t or t.kind == "float" then
		return ((t and t.size or 8) == 4 and "f32" or "f64") .. ".load"
	end
	local reg = t.size == 8 and "i64" or "i32"

	if t.size == 1 then
		return reg .. ".load8_" .. (uns(t) and "u" or "s")
	end
	if t.size == 2 then
		return reg .. ".load16_" .. (uns(t) and "u" or "s")
	end
	if t.size == 4 and reg == "i64" then
		return "i64.load32_" .. (uns(t) and "u" or "s")
	end
	return reg .. ".load"
end

-- `from` is the value's own type where it differs in class from the
-- place: mcc moves a double as a bit pattern, and in wasm the bits
-- decide the instruction rather than what the place is called.
local function storeop(t, from)
	if from and t and (from.kind == "float") ~= (t.kind == "float") then
		t = { kind = from.kind, size = t.size,
			kind = from.kind }
	end
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
	error("wasm: cannot address " .. tostring(op) .. " directly")
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
		    uns(n.ty) and "u" or "s")
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
			cmp = cmp .. (uns(l.ty) and "_u" or "_s")
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
	local fu, tu = uns(from), uns(to)
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
	local nfixed = n.nfixed
	local nvar = nfixed and (#args - nfixed) or 0

	-- A wasm call must match the definition's type exactly, so the
	-- ones past the prototype cannot be extra parameters. They go in
	-- a block on the shadow stack and the callee is handed its
	-- address, which is the one extra parameter a variadic takes.
	local vsize, voff = 0, {}

	if nvar > 0 then
		-- packed the way rt/varargs.c walks them: a word each,
		-- and a doubleword aligned to one
		for i = nfixed + 1, #args do
			local sz = args[i].ty and args[i].ty.size or 8
			local n = (sz + 3) // 4

			if n > 1 and (vsize // 4) % 2 == 1 then
				vsize = vsize + 4
			end
			voff[i] = vsize
			vsize = vsize + n * 4
		end
		vsize = (vsize + 7) // 8 * 8
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
		    "\tglobal.set\t%d\n"):format(SP, vsize, SP))
		for i = nfixed + 1, #args do
			local a = args[i]
			local sz = a.ty and a.ty.size or 8
			local flt = a.ty and a.ty.kind == "float"

			g:expr(a, "reg", reg)
			g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n" ..
			    "\ti32.add\n\tlocal.get\t%s\n\t%s.store\n")
			    :format(SP, voff[i],
			    flt and fregname(reg, sz) or regname(reg, sz),
			    wty(sz, flt)))
		end
	end

	local nnamed = nfixed or #args

	-- Arguments are worked out into a block of their own before any
	-- of them is pushed. Evaluating one can end a basic block -- a
	-- conditional inside an argument does -- and a value on the wasm
	-- stack cannot cross the edge of a block that a label opens,
	-- where a value in memory can.
	local asize, aoff = 0, {}

	for i = 1, nnamed do
		local sz = args[i].ty and args[i].ty.size or 8

		if sz > 4 and asize % 8 ~= 0 then asize = asize + 4 end
		aoff[i] = asize
		asize = asize + ((sz > 4) and 8 or 4)
	end
	asize = (asize + 7) // 8 * 8

	if asize > 0 then
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
		    "\tglobal.set\t%d\n"):format(SP, asize, SP))
		for i = 1, nnamed do
			local a = args[i]
			local sz = a.ty and a.ty.size or 8
			local flt = a.ty and a.ty.kind == "float"

			g:expr(a, "reg", reg)
			g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n" ..
			    "\ti32.add\n\tlocal.get\t%s\n\t%s.store\n")
			    :format(SP, aoff[i],
			    flt and fregname(reg, sz) or regname(reg, sz),
			    wty(sz, flt)))
		end
	end

	-- where a record result is to be written, which the callee takes
	-- before anything it was declared with
	if n.retrec then
		g:write(reach(("f%+d"):format(n.retslot)))
	end

	for i = 1, nnamed do
		local a = args[i]
		local sz = a.ty and a.ty.size or 8
		local flt = a.ty and a.ty.kind == "float"

		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n" ..
		    "\t%s\n"):format(SP, aoff[i],
		    loadop({ kind = flt and "float" or "int", size = sz })))
	end
	if nfixed then
		-- varstack means the callee counts its named parameters
		-- as stack arguments too, and va_start steps past that
		-- many words. The block starts where it lands.
		local back = 0

		for i = 1, nfixed do
			local sz = args[i].ty and args[i].ty.size or 8
			local w = (sz + 3) // 4

			if w > 1 and back % 2 == 1 then back = back + 1 end
			back = back + w
		end
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n")
		    :format(SP, back * 4))
	end

	if n.direct and n.left and n.left.sym then
		-- What this callee looks like, so a name with no body in
		-- the module can be declared as an import.
		local ps = {}

		for i = 1, nnamed do
			local a = args[i]

			ps[#ps + 1] = wty(a.ty and a.ty.size or 8,
			    a.ty and a.ty.kind == "float")
		end
		if nfixed then ps[#ps + 1] = "i32" end
		if n.retrec then table.insert(ps, 1, "i32") end
		g:write(("\t.callsig\t%s\t%s\t->\t%s\n")
		    :format(n.left.sym, table.concat(ps, " "),
		    (n.ty and n.ty.kind ~= "void") and
		    wty(n.ty.size, n.ty.kind == "float") or ""))
		g:write(("\tcall\t@%s\n"):format(n.left.sym))
	else
		-- through a pointer: the index is the value, and the
		-- signature is settled when the module is written
		local ps = {}

		for i = 1, nnamed do
			local a = args[i]

			ps[#ps + 1] = wty(a.ty and a.ty.size or 8,
			    a.ty and a.ty.kind == "float")
		end
		if nfixed then ps[#ps + 1] = "i32" end
		if n.retrec then table.insert(ps, 1, "i32") end
		g:expr(n.left, "reg", reg)
		-- the signature goes with it: a table call names a type
		-- rather than a function
		g:write(("\tlocal.get\t%s\n\tcall_indirect\t%s\t->\t%s\n")
		    :format(regname(reg, 4), table.concat(ps, " "),
		    (not n.retrec and n.ty and n.ty.kind ~= "void") and
		    wty(n.ty.size, n.ty.kind == "float") or ""))
	end

	-- release the argument block, and the variadic one with it
	if nvar > 0 or asize > 0 then
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n" ..
		    "\tglobal.set\t%d\n"):format(SP, vsize + asize, SP))
	end

	local rt = n.ty

	-- a record came back through the pointer, so the call itself
	-- answers nothing
	if n.retrec then rt = nil end
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

	-- A record result is written through a pointer the caller hands
	-- over, and it comes first.
	S.hidden = (recret and recret.ptr) and 1 or 0
	if S.hidden == 1 then ps[#ps + 1] = "i32" end

	for _, d in ipairs(params) do
		-- a record arrives as the address of the caller's copy
		ps[#ps + 1] = d.mem and "i32" or wty(d.size or 8, d.flt)
	end
	-- a variadic takes one more: where the rest of its arguments are
	if vabase then ps[#ps + 1] = "i32" end
	g:write(("\t.params\t%s\n"):format(table.concat(ps, " ")))
	g:write(("\tglobal.get\t%d\n\tlocal.set\t%s\n"):format(SP, fp()))
	g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
	    "\tglobal.set\t%d\n"):format(SP, frame, SP))

	-- Everything arrives as a wasm parameter and C wants it
	-- addressable, so each one is put away in its slot.
	if recret and recret.ptr then
		g:write(reach(("f%+d"):format(recret.ptr)) ..
		    "\tlocal.get\t0\n\ti32.store\n")
	end

	for i, d in ipairs(params) do
		local sz = d.size or 8
		local at = i - 1 + S.hidden

		if d.mem then
			-- the bytes, not the pointer: C says the callee's
			-- copy is its own
			for k = 0, sz - 1 do
				g:write(reach(("f%+d"):format((d.off or 0) + k)))
				g:write(("\tlocal.get\t%d\n\ti32.const\t%d\n" ..
				    "\ti32.add\n\ti32.load8_u\n\ti32.store8\n")
				    :format(at, k))
			end
		else
			g:write(reach(("f%+d"):format(d.off or 0)) ..
			    ("\tlocal.get\t%d\n\t%s.store\n")
			    :format(at, wty(sz, d.flt)))
		end
	end
	if vabase then
		g:write(reach(("f%+d"):format(vabase)) ..
		    ("\tlocal.get\t%d\n\ti32.store\n")
		    :format(#params + S.hidden))
	end
end

local function epilogue(g, frame, fltret, wideret, recret, guard, rty)
	local res = ""

	S.retsize = nil
	if recret then
		-- the result was built in a slot; it goes back through the
		-- pointer the caller handed over, and nothing is returned
		for k = 0, (recret.size or 0) - 1 do
			g:write(reach(("f%+d"):format(recret.ptr)) ..
			    "\ti32.load\n" ..
			    ("\ti32.const\t%d\n\ti32.add\n"):format(k))
			g:write(reach(("f%+d"):format(recret.off + k)) ..
			    "\ti32.load8_u\n\ti32.store8\n")
		end
	elseif rty and rty.kind ~= "void" then
		res = wty(rty.size, rty.kind == "float")
		S.retsize = rty.size
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

-- What class an operand is, which decides which alternative matches.
-- A global is 16 because reaching one costs a constant; an indirection
-- is 16 as well, so a form that wants an address does not take it.
local function dcalc(n, nreg)
	if n then
		if n.op == "NAME" then return 16 end
		if n.op == "INDIR" then return 16 end
		if n.op == "CONST" then return n.val == 0 and 4 or 8 end
	end
	return tree.dcalc(n, nreg)
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

	local function address(g, n, reg)
		g:write(reach(addr(g, n.left or n)) ..
		    ("\tlocal.set\t%s\n"):format(regname(reg, 4)))
	end

	code.reg.ADDR = {
		{ "i", "z", asm = address },
		{ "a", "z", asm = address },
	}

	code.reg.INDIR = { { "n", "z", ev = "L", asm = function(g, n, reg)
		g:write(("\tlocal.get\t%s\n\t%s\n\tlocal.set\t%s\n")
		    :format(regname(reg, 4), loadop(n.ty), rn(n, reg)))
	end } }

	for _, op in ipairs({ "ADD", "SUB", "MUL", "AND", "OR", "XOR",
	    "SHL", "SHR", "DIV", "MOD" }) do
		code.reg[op] = { { "n", "n", ev = "L R1",
		    asm = function(g, n, reg)
			local sz = n.ty and n.ty.size or 8
			local flt = ty(n):sub(1, 1) == "f"
			local nm = flt and fregname or regname
			-- C leaves a shift count its own type, so the
			-- two operands need not be the same width and
			-- wasm insists that they are
			local rsz = (not flt) and n.right and n.right.ty
			    and n.right.ty.size or sz
			local fix = ""

			if rsz ~= sz then
				fix = (sz == 8) and "\ti64.extend_i32_u\n"
				    or "\ti32.wrap_i64\n"
			end
			g:write(("\tlocal.get\t%s\n\tlocal.get\t%s\n%s" ..
			    "\t%s\n\tlocal.set\t%s\n"):format(nm(reg, sz),
			    nm(reg + 1, rsz), fix, mnem(n), nm(reg, sz)))
		end } }
	end

	-- i++ as a statement, and as a value: the old one is what it is
	-- worth, so a value context keeps a copy before adding.
	local function postadd(g, n, reg, keep, ptr)
		local v = n.left
		local t = ty(v)
		local sz = v.ty and v.ty.size or 8
		local r = regname(reg, sz)
		-- through a pointer there is no address to write down, so
		-- the one already in a register is pushed instead
		local a = ptr and ("\tlocal.get\t%s\n"):format(
		    regname(reg + 1, 4)) or reach(addr(g, v))

		-- The old value stays in `r`, which is what a value
		-- context wants, so nothing is stashed anywhere: through
		-- a pointer the next register holds the address and must
		-- keep holding it until the store.
		g:write(a .. ("\t%s\n\tlocal.set\t%s\n")
		    :format(loadop(v.ty), r))
		g:write(a .. ("\tlocal.get\t%s\n\t%s.const\t%d\n" ..
		    "\t%s.add\n\t%s\n")
		    :format(r, t, n.val or 1, t, storeop(v.ty)))
	end

	-- A frame slot first, then an indirection, then a global: an
	-- indirection is the same class as a global, so it has to be
	-- matched before the form that builds a symbol's address.
	local function post(keep)
		local function here(ptr)
			return function(g, n, reg)
				postadd(g, n, reg, keep, ptr)
			end
		end

		return {
			{ "i", "z", asm = here(false) },
			{ "n*", "z", ev = "L1*", asm = here(true) },
			{ "a", "z", asm = here(false) },
		}
	end

	code.eff.POSTADD = post(false)
	code.reg.POSTADD = post(true)

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

	-- The ones wasm has an instruction for, which is why they are
	-- here rather than in the runtime.
	for op, name in pairs({ SQRT = "sqrt", FABS = "abs" }) do
		code.reg[op] = { { "n", "z", ev = "L",
		    asm = function(g, n, reg)
			local sz = n.ty and n.ty.size or 8
			local r = fregname(reg, sz)

			g:write(("\tlocal.get\t%s\n\t%s.%s\n" ..
			    "\tlocal.set\t%s\n"):format(r, ty(n), name, r))
		end } }
	end

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
		local flt = ty(v):sub(1, 1) == "f"

		g:write(reach(addr(g, n.left)) ..
		    ("\tlocal.get\t%s\n\t%s\n")
		    :format(flt and fregname(reg, sz) or regname(reg, sz),
		    storeop(dt, v.ty)))
	end

	-- Through a pointer, where there is no address to write down:
	-- the value first, then the pointer it goes behind.
	local function assignp(g, n, reg)
		local v = n.right
		local sz = v.ty and v.ty.size or 8
		local dt = n.left.ty or v.ty
		local flt = ty(v):sub(1, 1) == "f"

		g:write(("\tlocal.get\t%s\n\tlocal.get\t%s\n\t%s\n")
		    :format(regname(reg + 1, 4),
		    flt and fregname(reg, sz) or regname(reg, sz),
		    storeop(dt, v.ty)))
	end

	-- An indirection is matched before the forms that have an
	-- address, because it has none.
	local asgn = {
		{ "i", "n", ev = "R", asm = assign },
		{ "n*", "n", ev = "R L1*", asm = assignp },
		{ "a", "n", ev = "R", asm = assign },
	}

	code.eff.ASGN = asgn
	code.reg.ASGN = asgn

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
		local u = uns(n.ty)
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
			cmp = cmp .. (uns(l.ty) and "_u" or "_s")
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
	local fu, tu = uns(from), uns(to)
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
	local nfixed = n.nfixed
	local nnamed = nfixed or #args

	-- Arguments go to memory before any is pushed: evaluating one can
	-- end a basic block, and a value on the wasm stack cannot cross
	-- the edge a label opens where a value in memory can. The ones
	-- past the prototype sit above the named ones in the same block,
	-- packed the way rt/varargs.c walks them.
	local off, at = {}, 0

	for i = 1, nnamed do
		local sz = args[i].ty and args[i].ty.size or 8

		if sz > 4 and at % 8 ~= 0 then at = at + 4 end
		off[i] = at
		at = at + ((sz > 4) and 8 or 4)
	end

	local vabase = at

	for i = nnamed + 1, #args do
		local sz = args[i].ty and args[i].ty.size or 8
		local w = (sz + 3) // 4

		-- rt/varargs.c aligns a wide value on its own address, not
		-- on its place in the block, so this must do the same
		if w > 1 and at % 8 ~= 0 then at = at + 4 end
		off[i] = at
		at = at + w * 4
	end

	local block = (at + 7) // 8 * 8

	if block > 0 then
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
		    "\tglobal.set\t%d\n"):format(SP, block, SP))
		for i = 1, #args do
			local a = args[i]
			local sz = a.ty and a.ty.size or 8
			local flt = a.ty and a.ty.kind == "float"

			g:expr(a, "reg", reg)
			g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n" ..
			    "\ti32.add\n\tlocal.get\t%s\n\t%s.store\n")
			    :format(SP, off[i],
			    flt and fregname(reg, sz) or regname(reg, sz),
			    wty(sz, flt)))
		end
	end

	-- where a record result is to be written, which the callee takes
	-- before anything it was declared with
	if n.retrec then
		g:write(reach(("f%+d"):format(n.retslot)))
	end

	for i = 1, nnamed do
		local a = args[i]
		local sz = a.ty and a.ty.size or 8
		local flt = a.ty and a.ty.kind == "float"

		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n" ..
		    "\t%s\n"):format(SP, off[i],
		    loadop({ kind = flt and "float" or "int", size = sz })))
	end

	if nfixed then
		-- varstack means the callee counts its named parameters as
		-- stack arguments too, and va_start steps past that many
		-- words, so the block starts where it lands
		local back = 0

		for i = 1, nfixed do
			local sz = args[i].ty and args[i].ty.size or 8
			local w = (sz + 3) // 4

			if w > 1 and back % 2 == 1 then back = back + 1 end
			back = back + w
		end
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n")
		    :format(SP, vabase - back * 4))
	end

	local ps = {}

	for i = 1, nnamed do
		local a = args[i]

		ps[#ps + 1] = wty(a.ty and a.ty.size or 8,
		    a.ty and a.ty.kind == "float")
	end
	if nfixed then ps[#ps + 1] = "i32" end
	if n.retrec then table.insert(ps, 1, "i32") end

	-- `retty` is what the callee was declared to give back; the
	-- node's own type says a word where the callee says void
	local vty = n.retty or n.ty
	local res = (not n.retrec and vty and vty.kind ~= "void") and
	    wty(vty.size, vty.kind == "float") or ""

	if n.direct and n.left and n.left.sym then
		g:write(("\t.callsig\t%s\t%s\t->\t%s\n")
		    :format(n.left.sym, table.concat(ps, " "), res))
		g:write(("\tcall\t@%s\n"):format(n.left.sym))
	else
		g:expr(n.left, "reg", reg)
		g:write(("\tlocal.get\t%s\n\tcall_indirect\t%s\t->\t%s\n")
		    :format(regname(reg, 4), table.concat(ps, " "), res))
	end

	local rt = vty

	if n.retrec then rt = nil end
	if rt and rt.kind ~= "void" then
		local flt = rt.kind == "float"

		g:write(("\tlocal.set\t%s\n")
		    :format(flt and fregname(reg, rt.size)
		    or regname(reg, rt.size)))
	end

	if block > 0 then
		g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.add\n" ..
		    "\tglobal.set\t%d\n"):format(SP, block, SP))
	end
	-- where a long jump passing through this frame is noticed; the
	-- assembler drops it when the module never calls setjmp
	g:write("\t.unwind\n")
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

	-- A record result is written through a pointer the caller hands
	-- over, and it comes first.
	S.hidden = (recret and recret.ptr) and 1 or 0
	if S.hidden == 1 then ps[#ps + 1] = "i32" end

	for _, d in ipairs(params) do
		-- a record arrives as the address of the caller's copy
		ps[#ps + 1] = d.mem and "i32" or wty(d.size or 8, d.flt)
	end
	-- a variadic takes one more: where the rest of its arguments are
	if vabase then ps[#ps + 1] = "i32" end
	g:write(("\t.params\t%s\n"):format(table.concat(ps, " ")))
	g:write(("\tglobal.get\t%d\n\tlocal.set\t%s\n"):format(SP, fp()))
	g:write(("\tglobal.get\t%d\n\ti32.const\t%d\n\ti32.sub\n" ..
	    "\tglobal.set\t%d\n"):format(SP, frame, SP))

	-- Everything arrives as a wasm parameter and C wants it
	-- addressable, so each one is put away in its slot.
	if recret and recret.ptr then
		g:write(reach(("f%+d"):format(recret.ptr)) ..
		    "\tlocal.get\t0\n\ti32.store\n")
	end

	for i, d in ipairs(params) do
		local sz = d.size or 8
		local at = i - 1 + S.hidden

		if d.mem then
			-- the bytes, not the pointer: C says the callee's
			-- copy is its own
			for k = 0, sz - 1 do
				g:write(reach(("f%+d"):format((d.off or 0) + k)))
				g:write(("\tlocal.get\t%d\n\ti32.const\t%d\n" ..
				    "\ti32.add\n\ti32.load8_u\n\ti32.store8\n")
				    :format(at, k))
			end
		else
			g:write(reach(("f%+d"):format(d.off or 0)) ..
			    ("\tlocal.get\t%d\n\t%s.store\n")
			    :format(at, wty(sz, d.flt)))
		end
	end
	if vabase then
		g:write(reach(("f%+d"):format(vabase)) ..
		    ("\tlocal.get\t%d\n\ti32.store\n")
		    :format(#params + S.hidden))
	end
end

local function epilogue(g, frame, fltret, wideret, recret, guard, rty)
	local res = ""

	S.retsize = nil
	if recret then
		-- the result was built in a slot; it goes back through the
		-- pointer the caller handed over, and nothing is returned
		for k = 0, (recret.size or 0) - 1 do
			g:write(reach(("f%+d"):format(recret.ptr)) ..
			    "\ti32.load\n" ..
			    ("\ti32.const\t%d\n\ti32.add\n"):format(k))
			g:write(reach(("f%+d"):format(recret.off + k)) ..
			    "\ti32.load8_u\n\ti32.store8\n")
		end
	elseif rty and rty.kind ~= "void" then
		res = wty(rty.size, rty.kind == "float")
		S.retsize = rty.size
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

-- What class an operand is, which decides which alternative matches.
-- A global is 16 because reaching one costs a constant; an indirection
-- is 16 as well, so a form that wants an address does not take it.
local function dcalc(n, nreg)
	if n then
		if n.op == "NAME" then return 16 end
		if n.op == "INDIR" then return 16 end
		if n.op == "CONST" then return n.val == 0 and 4 or 8 end
	end
	return tree.dcalc(n, nreg)
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

-- md.target compiles the shapes and the evaluation lists. Without it
-- every alternative matches, because an uncompiled shape is nil and a
-- nil shape fits anything.
return md.target({
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
	-- A record travels as its address, always: wasm has four value
	-- types and none of them is a struct.
	recabi = true,
	hiddenarg = true,
	upward = false,
	vafloat = false,
	varstack = true,
	vastkslot = true,
	fltspill = false,
	-- Named arguments arrive as wasm parameters, which is what a
	-- register file is here: none of them lands on a stack.
	nargreg = 64,
	predef = { __wasm__ = "1", __wasm32__ = "1" },
	move = move,
	rawmove = rawmove,
	jump = jump,
	branch = branch,
	frame = frame,
	slot = slot,
	data = data,
	dcalc = dcalc,
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
})
