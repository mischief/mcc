-- SPDX-License-Identifier: ISC
-- Read back what target/wasm.lua wrote, and build a module.
--
-- Not an assembler: both sides are here, so the text is one
-- instruction a line. What it does have to do is control flow, since
-- wasm has no goto and the target wrote one.

local wasm = require "wasm"

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
function M.body(text, opts)
	opts = opts or {}
	local body = lines(text)
	local labels, order = scan(body)
	local state = opts.state or 0
	local out = {}

	if #order == 0 then
		for _, s in ipairs(body) do
			out[#out + 1] = M.one(split(s))
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
		else
			out[#out + 1] = M.one(op, arg, opts)
		end
	end
	out[#out + 1] = I("end")		-- the last case
	out[#out + 1] = I("end")		-- the loop
	out[#out + 1] = I("unreachable")
	return table.concat(out)
end

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

		if op:match("^f") then return I(op, tonumber(v)) end
		return I(op, math.tointeger(tonumber(v)) or 0)
	end
	if op:match("%.load") or op:match("%.store") then
		return I(op, opts and opts.align or 2, 0)
	end
	if op == "call" then
		return I(op, (opts.symbol and opts.symbol(a[1])) or
		    tonumber(a[1]) or 0)
	end
	return I(op)
end

-- ---- a whole module ----
--
-- No relocatable object and no link step: the text of every input is
-- read at once, the functions are numbered in the order they appear,
-- and a call by name becomes a call by index.

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
		elseif cur then
			local ps = s:match("^%.params%s*(.*)$")
			local r = s:match("^%.result%s*(.*)$")

			if ps then
				for w in ps:gmatch("%S+") do
					cur.params[#cur.params + 1] = w
				end
			elseif r then
				cur.result = r ~= "" and r or nil
			elseif s:match(":$") or not s:match("^%.") then
				-- a label starts with a dot as a directive
				-- does, and ends with a colon where one
				-- does not
				cur.body[#cur.body + 1] = s
			end
		end
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
	local wasm = require "wasm"
	local m = wasm.new()
	local fs = funcs(text)
	local index, at = {}, 0

	for _, f in ipairs(fs) do
		index[f.name] = at
		at = at + 1
	end

	m:memory(opts.pages or 2)
	-- the shadow stack pointer, starting at the top of what is there
	m:global("i32", true, wasm.instr("i32.const",
	    (opts.pages or 2) * 65536))

	local function symbol(s)
		local nm = s:match("^@(.+)$")

		if nm then
			return index[nm] or
			    error("wasm: no function named " .. nm)
		end
		return tonumber(s)
	end

	for _, f in ipairs(fs) do
		local nparams = #f.params
		-- the four banks in order, then the frame pointer and
		-- the dispatch state
		local decl = { { NREG, "i32" }, { NREG, "i64" },
			{ NREG, "f32" }, { NREG, "f64" }, { 2, "i32" } }

		local map = locals(nparams)
		local body = M.body(table.concat(f.body, "\n"),
		    { state = map["$st"], locals = map, symbol = symbol })
		local ty = m:type(f.params, f.result and { f.result } or {})
		local idx = m:func(ty, decl, body)

		if not f.static then m:export(f.name, "func", idx) end
	end
	m:export("memory", "memory", 0)
	return m:emit()
end

return M
