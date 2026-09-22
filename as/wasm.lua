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
	if op == "call" then
		return I(op, (opts.symbol and opts.symbol(a[1])) or
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
	local wasm = require "wasm"
	local m = wasm.new()
	local fs = funcs(text)
	local index, at = {}, 0
	local defined, want = {}, {}

	for _, f in ipairs(fs) do
		defined[f.name] = true
		for nm, sig in pairs(f.sigs or {}) do
			want[nm] = want[nm] or sig
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

	for nm, sig in pairs(want) do
		if not defined[nm] then imports[#imports + 1] = nm end
	end
	table.sort(imports)
	for _, nm in ipairs(imports) do
		local sig = want[nm]

		index[nm] = m:import("env", nm,
		    m:type(sig.params, sig.result and { sig.result } or {}))
		at = at + 1
	end

	for _, f in ipairs(fs) do
		index[f.name] = at
		at = at + 1
	end

	local bytes, sym, pending, top = segment(text)

	-- A function used as a value is a table index, since wasm has no
	-- address for code; anything else is an address in the data.
	local slot, nslot = {}, 0

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
			local v = sym[r.sym] or
			    (index[r.sym] and slotof(r.sym)) or 0
			local at = r.at - DATABASE

			bytes = bytes:sub(1, at) ..
			    string.pack("<i" .. r.size, v) ..
			    bytes:sub(at + r.size + 1)
		end
	end

	-- the stack lives above the data, and the memory above both
	local stack = opts.stack or (64 * 1024)
	local need = top + stack
	local pages = opts.pages or ((need + 65535) // 65536 + 1)

	m:memory(pages)
	m:global("i32", true, wasm.instr("i32.const", top + stack))
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
		local body = M.body(table.concat(f.body, "\n"),
		    { state = map["$st"], locals = map, symbol = symbol,
		      dataof = dataof,
		      typeof = function(ps, r)
			return m:type(ps, r and { r } or {})
		      end })
		local ty = m:type(f.params, f.result and { f.result } or {})
		local idx = m:func(ty, decl, body)

		if not f.static then m:export(f.name, "func", idx) end
	end
	-- the table, in the order names were asked for
	if nslot > 0 then
		local entries = {}

		for nm, i in pairs(slot) do entries[i + 1] = index[nm] end
		m:table(entries)
	end
	m:export("memory", "memory", 0)
	return m:emit()
end

return M
