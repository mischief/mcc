-- SPDX-License-Identifier: ISC
-- mstrip against the system strip: which sections are left, which
-- symbols, and whether what comes out still links and runs.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-strip"
tap.scratch(dir)

local function shell(cmd)
	local p = io.popen(("cd %s && %s 2>&1"):format(dir, cmd))
	local out = p:read("a")

	return p:close(), out
end

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))

	f:write(text)
	f:close()
end

local pwd = io.popen("pwd"):read("l")
local root = here:sub(1, 1) == "/" and here or pwd .. "/" .. here
local lua = os.getenv("LUA") or "lua5.4"
local mstrip = ("%s %s/../strip.lua"):format(lua, root)

local need = {"gcc", "strip", "readelf", "nm"}
for _, t in ipairs(need) do
	if not shell("command -v " .. t .. " >/dev/null") then
		tap.skip("mstrip", "no system " .. t)
		tap.done()
	end
end

write("p.c", [[
#include <stdio.h>
static int helper(int x) { return x * 3; }
int vis(int y) { return helper(y) + 1; }
int main(void) { printf("%d\n", vis(4)); return 0; }
]])

-- The sections, by name and type, and what nm says.
local function sections(f)
	local _, t = shell("readelf -SW " .. f .. " | awk '/\\]/{print $2, $3}'")
	local names = {}

	for l in t:gmatch("[^\n]+") do names[#names + 1] = l end
	table.sort(names)
	return table.concat(names, "\n")
end
local function same(what, mine, theirs, alsosyms)
	local ok = sections(mine) == sections(theirs)

	if alsosyms then
		local _, a = shell("nm " .. mine)
		local _, b = shell("nm " .. theirs)

		ok = ok and a == b
	end
	if not tap.ok(ok, what) then
		tap.diag("mine:\n" .. sections(mine))
		tap.diag("theirs:\n" .. sections(theirs))
	end
end

shell("gcc -g -O1 -ffunction-sections -c p.c -o p.o")
shell(mstrip .. " -g -o pm.o p.o")
shell("strip -g -o pg.o p.o")
same("-g on an object leaves what strip -g leaves", "pm.o", "pg.o", true)
local ok = shell("gcc -o pm pm.o")
local _, said = shell("./pm")
tap.ok(ok and said == "13\n", "and it still links and runs")

shell("gcc -g -o pe p.c")
shell(mstrip .. " -s -o pes pe")
shell("strip -s -o pgs pe")
same("-s on a program leaves what strip -s leaves", "pes", "pgs")
_, said = shell("./pes")
tap.ok(said == "13\n", "and the program runs")

shell("gcc -g -fpic -shared -o libq.so p.c")
shell(mstrip .. " --strip-unneeded -R .comment -R .note -o libqm.so libq.so")
shell("strip --strip-unneeded -R .comment -R .note -o libqg.so libq.so")
same("--strip-unneeded -R on a library leaves what strip does",
	"libqm.so", "libqg.so")

ok = shell("strip -g -o /dev/null pes") and
	shell("strip -g -o /dev/null libqm.so")
tap.ok(ok, "what mstrip writes, strip reads without complaint")
tap.done()
