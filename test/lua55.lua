-- SPDX-License-Identifier: ISC
-- The control variable of a for loop may not be assigned to.
--
-- Lua 5.5 made that an error at load time.  5.4 does not, but it does
-- enforce <const>, so binding every control variable to a const copy
-- and loading the result makes 5.4 refuse exactly what 5.5 would.
-- This compiler runs on whatever Lua a distribution ships, and one
-- that will not load is worse than one that compiles something wrong.
--
--   lua5.4 test/lua55.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local ROOT = here .. "/.."
local DIRS = {"", "as/", "target/", "test/"}

-- `for a, b in e do rest` becomes
-- `for a__ctl, b__ctl in e do local a <const>, b <const> = ... rest`
local function rewrite(src)
	local out = {}

	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		local ind, names, rest =
			line:match("^(%s*)for%s+([%a_][%w_]*[%w_,%s]*)%s+in%s+(.*)$")
		local eq = nil

		if not names then
			ind, names, rest =
				line:match("^(%s*)for%s+([%a_][%w_]*)%s*=%s*(.*)$")
			eq = names ~= nil
		end
		local head = rest and rest:match("^(.*)%f[%w]do%f[%W]")

		if not head then
			out[#out + 1] = line
			goto next
		end
		do
			local tail = rest:sub(#head + 3)
			local ns, all = {}, true

			for n in names:gmatch("[%w_]+") do
				ns[#ns + 1] = n
				if n ~= "_" then all = false end
			end
			if all then
				out[#out + 1] = line
				goto next
			end
			local ctl, bind = {}, {}

			for i, n in ipairs(ns) do
				ctl[i] = n .. "__ctl"
				bind[i] = n .. " <const>"
			end
			out[#out + 1] = ("%sfor %s%s%s do local %s = %s%s")
				:format(ind, table.concat(ctl, ", "),
					eq and " = " or " in ", head,
					table.concat(bind, ", "),
					table.concat(ctl, ", "), tail)
		end
		::next::
	end
	return table.concat(out, "\n")
end

local function slurp(path)
	local f = io.open(path)

	if not f then return nil end
	local s = f:read("a")

	f:close()
	return s
end

local names = {}

for _, d in ipairs(DIRS) do
	local p = io.popen(("ls %s/%s*.lua 2>/dev/null"):format(ROOT, d))

	for line in p:lines() do names[#names + 1] = line end
	p:close()
end

local bad = 0

for _, path in ipairs(names) do
	local src = slurp(path)

	if src then
		local ok, err = load(rewrite(src), "@" .. path)

		if not ok and err:find("const") then
			tap.diag(err)
			bad = bad + 1
		end
	end
end
tap.ok(bad == 0, ("no for loop in %d files assigns to its own variable")
	:format(#names))
tap.done()
