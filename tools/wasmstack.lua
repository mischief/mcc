#!/usr/bin/env lua5.4
-- wasmstack.lua -- walk what target/wasm.lua wrote and say where the
-- value stack goes wrong.
--
-- An engine reports an imbalance by byte offset in a compiled module,
-- which is the wrong end to debug from. This reads the text, so it
-- names the function and the line.

local POP = {
	["local.set"] = 1, ["local.tee"] = 1, ["global.set"] = 1,
	["drop"] = 1, ["return"] = 0, ["br_if"] = 1, ["goto_if"] = 1,
}
local PUSH = {
	["local.get"] = 1, ["local.tee"] = 1, ["global.get"] = 1,
	["memory.size"] = 1,
}

local function effect(op, a, sigs)
	if op:match("%.const$") then return 0, 1 end
	if op:match("%.load") then return 1, 1 end
	if op:match("%.store") then return 2, 0 end
	if op == "call" then
		local s = sigs[(a[1] or ""):gsub("^@", "")]

		if s then return s.n, s.r and 1 or 0 end
		return 0, 0
	end
	if op == "call_indirect" then
		local n, seen, r = 0, false, nil

		for _, w in ipairs(a) do
			if w == "->" then seen = true
			elseif seen then r = w
			else n = n + 1 end
		end
		return n + 1, r and 1 or 0
	end
	if POP[op] or PUSH[op] then return POP[op] or 0, PUSH[op] or 0 end
	-- an operator with a type prefix: two in and one out, unless it
	-- is one of the unary ones
	local rest = op:match("^[if]%d+%.(.+)$")

	if rest then
		local UN = { eqz = true, clz = true, ctz = true,
			popcnt = true, neg = true, abs = true, sqrt = true,
			ceil = true, floor = true, trunc = true,
			nearest = true }

		if UN[rest] or rest:match("^wrap") or rest:match("^extend")
		    or rest:match("^convert") or rest:match("^trunc_")
		    or rest:match("^demote") or rest:match("^promote")
		    or rest:match("^reinterpret") then
			return 1, 1
		end
		return 2, 1
	end
	return 0, 0
end

-- every function's parameter count and whether it answers a value
local function signatures(paths)
	local sigs = {}

	for _, p in ipairs(paths) do
		local f = io.open(p)

		if f then
			local cur
			for line in f:read("a"):gmatch("[^\n]+") do
				local s = line:match("^%s*(.-)%s*$")
				local nm = s:match("^%.func%s+(%S+)")

				if nm then cur = nm sigs[nm] = { n = 0 } end
				local ps = s:match("^%.params%s*(.*)$")

				if ps and cur then
					local n = 0

					for _ in ps:gmatch("%S+") do n = n + 1 end
					sigs[cur].n = n
				end
				local r = s:match("^%.result%s*(.*)$")

				if r and cur then sigs[cur].r = r ~= "" end
				local cs, rest = s:match("^%.callsig%s+(%S+)%s*(.*)$")

				if cs and not sigs[cs] then
					local pp, rr = rest:match("^(.-)%s*%->%s*(.*)$")
					local n = 0

					for _ in (pp or ""):gmatch("%S+") do n = n + 1 end
					sigs[cs] = { n = n, r = rr ~= "" }
				end
			end
			f:close()
		end
	end
	return sigs
end

local sigs = signatures(arg)
local bad = 0

for _, path in ipairs(arg) do
	local f = io.open(path)

	if f then
		local cur, depth, line = nil, 0, 0

		for s in f:read("a"):gmatch("[^\n]+") do
			line = line + 1
			s = s:match("^%s*(.-)%s*$")
			local nm = s:match("^%.func%s+(%S+)")

			if nm then cur = nm depth = 0
			elseif s == ".endfunc" then cur = nil
			elseif cur and not s:match("^%.") and
			    not s:match(":$") then
				local op, rest = s:match("^(%S+)%s*(.*)$")
				local a = {}

				for w in rest:gmatch("%S+") do a[#a + 1] = w end
				local pop, push = effect(op, a, sigs)

				if depth - pop < 0 then
					bad = bad + 1
					print(("%s:%d in %s: %s wants %d, stack has %d")
					    :format(path, line, cur, op, pop, depth))
					depth = 0
				else
					depth = depth - pop + push
				end
				if op == "goto" or op == "return" then depth = 0 end
			end
		end
		f:close()
	end
end
print(bad .. " places the stack ran out")
