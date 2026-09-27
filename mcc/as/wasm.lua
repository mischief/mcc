-- SPDX-License-Identifier: ISC
-- Read back what target/wasm.lua wrote, and build a module.
--
-- Not an assembler: both sides are here, so the text is one
-- instruction a line. What it does have to do is control flow, since
-- wasm has no goto and the target wrote one.

local wasm = require "mcc.wasm"

local M = {}

local I = wasm.instr

-- ---- control flow ----
--
-- Every label is a case of a br_table; every jump sets the case and
-- branches to the top. Bigger and slower than the blocks a relooper
-- would find, and correct for any flow at all, irreducible included.

local function lines(text)
	local out = {}

	for line in text:gmatch("[^\n]+") do
		local s = line:match("^%s*(.-)%s*$")

		if s ~= "" and not s:match("^[;#]") then out[#out + 1] = s end
	end
	return out
end

-- Split an instruction into its mnemonic and immediates.
local function split(s)
	local op, rest = s:match("^(%S+)%s*(.*)$")
	local args = {}

	if not op then return "", args end

	for a in rest:gmatch("%S+") do args[#args + 1] = a end
	return op, args
end

-- Which labels a body names, and where each one starts.
local function scan(body)
	local at, order = {}, {}

	for i, s in ipairs(body) do
		local l = s:match("^(%.?L?[%w_.]+):$")

		if l then
			at[l] = i
			order[#order + 1] = l
		end
	end
	return at, order
end

-- A function body, as bytes. `state` is the local the case number sits
-- in. The code before the first label is a case of its own, since a
-- jump back to that label must not re-run it.
-- Is this a call to setjmp, which is not a call at all?
local function issetjmp(op, a)
	return op == "call" and a[1] and
	    (a[1] == "@setjmp" or a[1] == "@_setjmp")
end

-- A zero of the function's result type, for a frame leaving early.
local function zero(rty)
	if rty == nil or rty == "" then return "" end
	if rty == "i64" then return I("i64.const", 0) end
	if rty == "f32" then return I("f32.const", 0.0) end
	if rty == "f64" then return I("f64.const", 0.0) end
	return I("i32.const", 0)
end

-- Rewrite each setjmp call into the part a function can do and a label
-- to come back to.  The label goes where the call is finished with --
-- after the result is stored and the argument block is given back --
-- so that resuming there leaves the stack pointer alone.  Returns the
-- new body and whether one was found.
local function setjmps(body)
	local out, found, n = {}, false, 0
	local i = 1

	while i <= #body do
		local op, a = split(body[i])

		if issetjmp(op, a) then
			local lbl = ".__sj" .. (n + 1)
			local reg

			n = n + 1
			found = true
			out[#out + 1] = "setjmp_save " .. lbl
			i = i + 1
			-- everything up to this call's unwind check
			while i <= #body do
				local o2, a2 = split(body[i])

				if o2 == ".unwind" then break end
				if o2 == "local.set" and not reg then
					reg = a2[1]
				end
				out[#out + 1] = body[i]
				i = i + 1
			end
			out[#out + 1] = lbl .. ":"
			if reg then
				out[#out + 1] = "setjmp_load " .. reg
			end
		else
			out[#out + 1] = body[i]
			i = i + 1
		end
	end
	return out, found
end

function M.body(text, opts)
	opts = opts or {}
	local body = lines(text)
	local mine = false

	if opts.setjmp then body, mine = setjmps(body) end
	local labels, order = scan(body)
	local state = opts.state or 0
	local out = {}
	local fp = opts.locals and opts.locals["$fp"] or 0
	local rty = opts.result

	-- Reading and writing one of the runtime's words, by name.
	local function word(nm)
		return I("i32.const", opts.dataof("@" .. nm))
	end
	local function unwinding()
		return word("__wasm_unwind") .. M.one("i32.load", {})
	end
	-- Put the stack pointer back where this frame found it, which is
	-- what the epilogue would have done.
	local function unwindret()
		return I("local.get", fp) .. I("global.set", 0) ..
		    zero(rty) .. I("return")
	end

	if #order == 0 then
		for _, s in ipairs(body) do
			local op, arg = split(s)

			if op == ".unwind" then
				if opts.setjmp then
					out[#out + 1] = unwinding() ..
					    I("if", "void") .. unwindret() ..
					    I("end")
				end
			else
				out[#out + 1] = M.one(op, arg, opts)
			end
		end
		-- a body that falls off its end never returned; say so,
		-- because a declared result has to be satisfied somehow
		if body[#body] ~= "return" then
			out[#out + 1] = I("unreachable")
		end
		return table.concat(out)
	end

	-- case 0 is the entry, and each label is the case after it
	local index = {}

	for i, l in ipairs(order) do index[l] = i end

	local ncase = #order + 1
	local pre = { I("i32.const", 0), I("local.set", state),
		I("loop", "void") }

	for _ = 1, ncase + 1 do pre[#pre + 1] = I("block", "void") end

	local tab = {}

	for i = 0, ncase - 1 do tab[#tab + 1] = i end
	pre[#pre + 1] = I("local.get", state)
	pre[#pre + 1] = I("br_table", tab, ncase)
	pre[#pre + 1] = I("end")
	out[#out + 1] = table.concat(pre)

	-- how far out a branch has to reach from inside case `c`
	local function depth(c, extra)
		return ncase - c + (extra or 0)
	end

	local case = 0

	for _, s in ipairs(body) do
		local l = s:match("^(%.?L?[%w_.]+):$")
		local op, arg = split(s)

		if l then
			out[#out + 1] = I("end")
			case = case + 1
		elseif op == "goto" then
			out[#out + 1] = I("i32.const", index[arg[1]])
			out[#out + 1] = I("local.set", state)
			out[#out + 1] = I("br", depth(case))
		elseif op == "goto_if" then
			out[#out + 1] = I("if", "void")
			out[#out + 1] = I("i32.const", index[arg[1]])
			out[#out + 1] = I("local.set", state)
			out[#out + 1] = I("br", depth(case, 1))
			out[#out + 1] = I("end")
		elseif op == "setjmp_save" then
			-- the stack holds the jmp_buf; these stores leave
			-- it there for the call that follows
			out[#out + 1] = word("__wasm_jmpsp") ..
			    I("local.get", fp) .. M.one("i32.store", {}) ..
			    word("__wasm_jmpstate") ..
			    I("i32.const", index[arg[1]]) ..
			    M.one("i32.store", {}) ..
			    word("__wasm_unwindval") .. I("i32.const", 0) ..
			    M.one("i32.store", {}) ..
			    I("call", opts.symbol("@__setjmp_save"))
		elseif op == "setjmp_load" then
			out[#out + 1] = word("__wasm_unwindval") ..
			    M.one("i32.load", {}) ..
			    M.one("local.set", { arg[1] }, opts)
		elseif op == ".unwind" then
			if opts.setjmp and mine then
				-- this frame may be the one jumped to, and
				-- the stack pointer it saved says so
				out[#out + 1] = unwinding() ..
				    I("if", "void") ..
				    word("__wasm_unwindsp") ..
				    M.one("i32.load", {}) ..
				    I("local.get", fp) .. I("i32.eq") ..
				    I("if", "void") ..
				    word("__wasm_unwind") ..
				    I("i32.const", 0) ..
				    M.one("i32.store", {}) ..
				    word("__wasm_unwindstate") ..
				    M.one("i32.load", {}) ..
				    I("local.set", state) ..
				    I("br", depth(case, 2)) ..
				    I("else") .. unwindret() ..
				    I("end") .. I("end")
			elseif opts.setjmp then
				out[#out + 1] = unwinding() ..
				    I("if", "void") .. unwindret() ..
				    I("end")
			end
		else
			out[#out + 1] = M.one(op, arg, opts)
		end
	end
	out[#out + 1] = I("end")		-- the last case
	out[#out + 1] = I("end")		-- the loop
	out[#out + 1] = I("unreachable")
	return table.concat(out)
end

-- Runtime names that are one instruction here, which the call site
-- has already set up the operand for.
local INSTR = {
	__dfloor = "f64.floor", __dceil = "f64.ceil",
	__dtrunc = "f64.trunc", __drint = "f64.nearest",
	__ffloor = "f32.floor", __fceil = "f32.ceil",
	__ftrunc = "f32.trunc", __frint = "f32.nearest",
}

-- One instruction, with its immediates read as the opcode wants them.
function M.one(op, a, opts)
	opts = opts or {}
	if op:match("^local%.") then
		local v = a[1]

		return I(op, opts.locals and opts.locals[v] or tonumber(v))
	end
	if op:match("^global%.") or op == "br" or op == "br_if" then
		return I(op, tonumber(a[1]))
	end
	if op:match("%.const$") then
		local v = a[1]

		-- A float constant arrives as the bit pattern, which is
		-- what every other target writes into .quad, so it is
		-- read back as one rather than as a decimal.
		if op == "f64.const" then
			local bits = math.tointeger(tonumber(v)) or 0

			return I(op, (string.unpack("<d",
			    string.pack("<i8", bits))))
		end
		if op == "f32.const" then
			local bits = (math.tointeger(tonumber(v)) or 0) &
			    0xffffffff

			return I(op, (string.unpack("<f",
			    string.pack("<I4", bits))))
		end
		local at = opts.dataof and opts.dataof(v)

		return I(op, at or math.tointeger(tonumber(v)) or 0)
	end
	if op:match("%.load") or op:match("%.store") then
		-- the natural alignment for the width it touches
		local w = op:match("(%d+)_?[su]?$")
		local a = 2

		if w then a = ({ ["8"] = 0, ["16"] = 1, ["32"] = 2 })[w] or 2
		elseif op:match("^i64%.") or op:match("^f64%.") then a = 3 end
		return I(op, a, 0)
	end
	-- Two of these are instructions rather than functions, and C has
	-- no way to say either.
	if op == "call" then
		local nm = (a[1] or ""):gsub("^@", "")

		if nm == "__wasm_memory_size" then return I("memory.size") end
		if nm == "__wasm_memory_grow" then return I("memory.grow") end
		if INSTR[nm] then return I(INSTR[nm]) end
		-- A call made through a declaration with more parameters
		-- than the definition has, as a runtime calling main(void)
		-- as main(argc, argv) does, leaves the extras on the stack;
		-- wasm wants the types to match, so they are dropped.
		local extra = opts.extra and opts.extra(nm) or 0

		return string.rep(I("drop"), extra) ..
		    I(op, (opts.symbol and opts.symbol(a[1])) or
		    tonumber(a[1]) or 0)
	end
	if op == "call_indirect" then
		local ps, r = {}, nil
		local seen = false

		for _, w in ipairs(a) do
			if w == "->" then seen = true
			elseif seen then r = w
			else ps[#ps + 1] = w end
		end
		return I(op, opts.typeof(ps, r), 0)
	end
	return I(op)
end

-- ---- a whole module ----
--
-- No relocatable object and no link step: the text of every input is
-- read at once, the functions are numbered in the order they appear,
-- and a call by name becomes a call by index.

-- ---- data ----
--
-- The directives are gas's, because data.lua is shared. What comes out
-- is one run of bytes and where each name sits in it.

local ITEM = { byte = 1, short = 2, long = 4, quad = 8 }

local function unescape(s)
	return (s:gsub("\\(%d%d%d)", function(d)
		return string.char(tonumber(d, 8))
	end):gsub("\\(.)", function(c)
		local E = { n = "\n", t = "\t", r = "\r", ["0"] = "\0",
			['"'] = '"', ["\\"] = "\\" }

		return E[c] or c
	end))
end

-- Everything starts above a guard page, so a null pointer is a fault
-- rather than the first object.
local DATABASE = 4096

local function segment(text)
	local out, at = {}, DATABASE
	local sym, incode = {}, false
	local pending = {}

	local function put(b)
		out[#out + 1] = b
		at = at + #b
	end

	for line in text:gmatch("[^\n]+") do
		local s = line:match("^%s*(.-)%s*$")

		-- A function that never returns has no epilogue and so no
		-- .endfunc. A section directive ends its text either way,
		-- since code and data do not interleave.
		if s:match("^%.func%s") then incode = true
		elseif s == ".endfunc" then incode = false
		elseif s:match("^%.section%s") or s == ".data" or
		    s == ".bss" or s == ".text" then
			incode = false
		elseif incode then			-- nothing here
		else
			local name = s:match("^([%w_.$]+):$")
			local dir, rest = s:match("^%.(%a+)%s*(.*)$")

			if name then
				sym[name] = at
			elseif dir == "balign" or dir == "align" then
				local n = tonumber(rest) or 1

				while at % n ~= 0 do put("\0") end
			elseif ITEM[dir] then
				local v = math.tointeger(tonumber(rest))

				if v then
					-- masked and written unsigned, since
					-- a signed pack refuses a value that
					-- fits the field only as a bit
					-- pattern
					local w = ITEM[dir]

					put(w == 8 and string.pack("<i8", v)
					    or string.pack("<I" .. w,
					    v & ((1 << (w * 8)) - 1)))
				else
					-- a name used as an initialiser,
					-- whose address is not known yet
					pending[#pending + 1] =
					    { at = at, sym = rest,
					      size = ITEM[dir] }
					put(string.rep("\0", ITEM[dir]))
				end
			elseif dir == "ascii" or dir == "string" then
				local body = rest:match('^"(.*)"$')

				if body then put(unescape(body)) end
			elseif dir == "zero" or dir == "space" then
				put(string.rep("\0", tonumber(rest) or 0))
			end
		end
	end
	return table.concat(out), sym, pending, at
end

M.segment = segment

local function funcs(text)
	local out, cur = {}, nil

	for line in text:gmatch("[^\n]+") do
		local s = line:match("^%s*(.-)%s*$")
		local name, link = s:match("^%.func%s+(%S+)%s+(%S+)$")

		if name then
			cur = { name = name, static = link == "static",
				params = {}, result = nil, body = {} }
			out[#out + 1] = cur
		elseif s == ".endfunc" then
			cur = nil
		elseif cur and (s:match("^%.section%s") or s == ".data" or
		    s == ".bss") then
			-- no epilogue, so no .endfunc: the data that
			-- follows is not part of the body
			cur = nil
		elseif cur then
			local cs = s:match("^%.callsig%s+(.*)$")

			if cs then
				cur.sigs = cur.sigs or {}
				local nm, rest = cs:match("^(%S+)%s*(.*)$")
				local ps, r = rest:match("^(.-)%s*%->%s*(.*)$")
				local list = {}

				for w in (ps or ""):gmatch("%S+") do
					list[#list + 1] = w
				end
				cur.sigs[nm] = { params = list,
					result = (r ~= "" and r) or nil }
				goto continue
			end

			local ps = s:match("^%.params%s*(.*)$")
			local r = s:match("^%.result%s*(.*)$")

			if ps then
				for w in ps:gmatch("%S+") do
					cur.params[#cur.params + 1] = w
				end
			elseif r then
				cur.result = r ~= "" and r or nil
			elseif s:match("^%.callsig") then	-- taken above
			elseif s == ".unwind" then
				-- a directive the body keeps, since it
				-- marks a place in the code
				cur.body[#cur.body + 1] = s
			elseif s:match(":$") or not s:match("^%.") then
				-- a label starts with a dot as a directive
				-- does, and ends with a colon where one
				-- does not
				cur.body[#cur.body + 1] = s
			end
		end
		::continue::
	end
	return out
end

-- The target's four banks, then the frame pointer and the dispatch
-- state after them. A name resolves to an index only once the
-- parameter count is known, which is why the target writes names.
local NREG = 8
local BANK = { i = 0, I = NREG, f = 2 * NREG, F = 3 * NREG }
local NBANK = 4 * NREG

local function locals(nparams)
	local map = {}

	for b, base in pairs(BANK) do
		for r = 0, NREG - 1 do
			map["$" .. b .. r] = nparams + base + r
		end
	end
	map["$fp"] = nparams + NBANK
	map["$st"] = nparams + NBANK + 1
	return map
end

function M.module(text, opts)
	opts = opts or {}
	local wasm = require "mcc.wasm"
	local m = wasm.new()
	local fs = funcs(text)
	local index, at = {}, 0
	local defined, want, shown = {}, {}, {}

	for _, f in ipairs(fs) do
		defined[f.name] = true
		for nm, sig in pairs(f.sigs or {}) do
			want[nm] = want[nm] or sig
		end
	end

	-- Only a module that calls setjmp pays for the unwind checks, so
	-- the whole text is asked once before any body is written.
	local usesjmp = false

	for _, f in ipairs(fs) do
		f.text = table.concat(f.body, "\n")
		if f.text:match("call%s+@_?setjmp%f[%s\0]") then
			usesjmp = true
		end
	end

	-- A function that never returns has no epilogue and so says no
	-- result, but C still gave it one and its callers push for it.
	-- The call sites know what it is.
	for _, f in ipairs(fs) do
		if f.result == nil and want[f.name] then
			f.result = want[f.name].result
		end
	end

	-- A name called but never defined is the host's, and the
	-- signature the call sites gave says what it looks like.
	local imports = {}
	-- These two are written as instructions, so no host supplies them.
	local builtin = {
		__wasm_memory_size = true,
		__wasm_memory_grow = true,
		setjmp = usesjmp, _setjmp = usesjmp,
	}

	for k in pairs(INSTR) do builtin[k] = true end

	for nm, sig in pairs(want) do
		if not defined[nm] and not builtin[nm] then
			imports[#imports + 1] = nm
		end
	end
	table.sort(imports)
	-- What import_module, import_name and export_name asked for.
	local asimport, asexport = {}, {}

	for nm, mod, field in ("\n" .. text):gmatch("\n%s*%.wasmimport%s+(%S+)%s+(%S+)%s+(%S+)") do
		asimport[nm] = { mod, field }
	end
	for nm, as in ("\n" .. text):gmatch("\n%s*%.wasmexport%s+(%S+)%s+(%S+)") do
		asexport[nm] = as
	end
	for _, nm in ipairs(imports) do
		local sig = want[nm]
		-- A name beginning `__wasi_` is the WASI interface, which
		-- is a module of its own; the rest are the embedder's.
		local mod, field = "env", nm
		local w = nm:match("^__wasi_(.+)$")

		if w then mod, field = "wasi_snapshot_preview1", w end
		if asimport[nm] then mod, field = asimport[nm][1], asimport[nm][2] end
		index[nm] = m:import(mod, field,
		    m:type(sig.params, sig.result and { sig.result } or {}))
		at = at + 1
	end

	local arity = {}

	for _, f in ipairs(fs) do
		index[f.name] = at
		arity[f.name] = #f.params
		at = at + 1
	end

	local bytes, sym, pending, top = segment(text)

	-- A function used as a value is a table index, since wasm has no
	-- address for code; anything else is an address in the data.
	-- Slot zero is left empty: a function pointer is a table index
	-- and C says a null pointer is zero, so nothing may live there.
	local slot, nslot = {}, 1

	local function slotof(nm)
		if not slot[nm] then
			slot[nm] = nslot
			nslot = nslot + 1
		end
		return slot[nm]
	end

	-- Anything a name stood for inside the data itself, now that
	-- every name has an address.
	if #pending > 0 then
		local b = { bytes }

		bytes = table.concat(b)
		for _, r in ipairs(pending) do
			-- an initialiser may name a place inside an
			-- object, as `streams+1044` does
			local nm, off = r.sym:match("^([^-+]+)([-+]%d+)$")

			nm = nm or r.sym
			off = tonumber(off) or 0
			local v = sym[nm] or (index[nm] and slotof(nm))

			if not v then
				error("wasm: no object named " .. nm)
			end
			v = v + off
			local at = r.at - DATABASE

			bytes = bytes:sub(1, at) ..
			    string.pack("<i" .. r.size, v) ..
			    bytes:sub(at + r.size + 1)
		end
	end

	-- Data, then the stack, then the heap: the stack is a fixed
	-- block so that growing the memory only ever adds room the heap
	-- can use, and the two never reach each other.
	-- a megabyte: Lua nests two hundred C calls of a few KB each
	local stack = opts.stack or (1024 * 1024)
	local stacktop = ((top + stack) + 15) // 16 * 16

	sym.__heap_base = stacktop
	local pages = opts.pages or ((stacktop + 65535) // 65536 + 1)

	m:memory(pages)
	m:global("i32", true, wasm.instr("i32.const", stacktop))
	if #bytes > 0 then m:segment(DATABASE, bytes) end

	local function symbol(s)
		local nm = s:match("^@(.+)$")

		if nm then
			return index[nm] or
			    error("wasm: no function named " .. nm)
		end
		return tonumber(s)
	end

	local function dataof(s)
		local nm = s:match("^@(.+)$")

		if not nm then return nil end
		if sym[nm] then return sym[nm] end
		if index[nm] then return slotof(nm) end
		if os.getenv("WASM_LIST_UNDEF") then
			io.stderr:write("UNDEF ", nm, "\n")
			return 0
		end
		error("wasm: no object named " .. nm)
	end

	for _, f in ipairs(fs) do
		local nparams = #f.params
		-- the four banks in order, then the frame pointer and
		-- the dispatch state
		local decl = { { NREG, "i32" }, { NREG, "i64" },
			{ NREG, "f32" }, { NREG, "f64" }, { 2, "i32" } }

		local map = locals(nparams)
		local body = M.body(f.text,
		    { state = map["$st"], locals = map, symbol = symbol,
		      dataof = dataof, setjmp = usesjmp,
		      extra = function(nm)
			local d, c = arity[nm], f.sigs and f.sigs[nm]

			if not d or not c then return 0 end
			return math.max(0, #c.params - d)
		      end,
		      result = f.result,
		      typeof = function(ps, r)
			return m:type(ps, r and { r } or {})
		      end })
		local ty = m:type(f.params, f.result and { f.result } or {})
		local idx = m:func(ty, decl, body)

		-- An export name is unique in a module, so a name defined
		-- twice -- a runtime file given on the command line as
		-- well as carried -- is exported once.
		if not f.static and not shown[f.name] then
			shown[f.name] = true
			m:export(f.name, "func", idx)
		end
		local as = asexport[f.name]

		if as and not shown[as] then
			shown[as] = true
			m:export(as, "func", idx)
		end
	end
	-- The table, in the order names were asked for. It exists even
	-- when empty: a call_indirect names a table, and a module with
	-- none is one the engine will not load.
	local entries = { 0 }

	for nm, i in pairs(slot) do entries[i + 1] = index[nm] end
	m:table(entries)
	m:export("memory", "memory", 0)
	return m:emit()
end

return M
