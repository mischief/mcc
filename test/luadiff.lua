-- SPDX-License-Identifier: ISC
-- Two Lua interpreters, one built by this compiler and one by the system
-- compiler, over the same script.  What comes out has to be the same.
--
--   lua5.4 test/luadiff.lua <mine> <ref> [runner]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local function absolute(path)
	if not path or path:sub(1, 1) == "/" then return path end
	local p = io.popen("pwd")
	local cwd = p:read("l")
	p:close()
	return cwd .. "/" .. path
end

local mine, ref, run = absolute(arg[1]), absolute(arg[2]), arg[3] or ""

local function output(bin)
	local p = io.popen(("%s%s %s/stress.lua 2>&1"):format(run, bin, here))
	local s = p:read("a")
	p:close()
	-- a table prints its own address, which is not a property of the
	-- compiler
	return (s:gsub("0x%x+", "ADDR"))
end

local a, b = output(mine), output(ref)
local n = select(2, a:gsub("\n", ""))

if not tap.ok(a == b,
    ("Lua built by this compiler answers as gcc's does (%d lines)")
    :format(n)) then
	local x, y = {}, {}
	for l in a:gmatch("[^\n]*") do x[#x + 1] = l end
	for l in b:gmatch("[^\n]*") do y[#y + 1] = l end
	for i = 1, math.max(#x, #y) do
		if x[i] ~= y[i] then
			tap.diag(("line %d\n  mine %s\n  gcc  %s")
				:format(i, tostring(x[i]), tostring(y[i])))
		end
	end
end
tap.done()
