-- SPDX-License-Identifier: ISC
-- The parser's optional parts load only when a program uses them.
-- A method missing from parse.lua's lazy list is nil until something
-- else loads its module, so the list is checked against the modules.
--
--   lua5.4 test/lazy.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-lazy"

tap.scratch(dir)

local P = require "mcc.parse.base"
require "mcc.parse"
local LAZY = rawget(P, "LAZY")

tap.ok(LAZY, "parse.lua keeps its list of lazy methods")

local mods = {}
for name, mod in pairs(LAZY) do
	mods[mod] = mods[mod] or {}
	mods[mod][name] = true
end

for mod, listed in pairs(mods) do
	local path = here .. "/../" .. mod:gsub("%.", "/") .. ".lua"
	local f = assert(io.open(path))
	local src = f:read("a")
	f:close()
	local defined = {}

	for name in src:gmatch("\nfunction P[.:]([%w_]+)") do
		defined[name] = true
	end
	for name in src:gmatch("\nP%.([%w_]+)%s*=") do
		defined[name] = true
	end
	for name in pairs(defined) do
		tap.ok(listed[name], ("%s: %s is in the lazy list"):format(mod, name))
	end
	for name in pairs(listed) do
		tap.ok(defined[name], ("%s: %s is defined there"):format(mod, name))
	end
end

-- The parser looks a name up in the builtins only when it has one of
-- these prefixes.
local B = require("mcc.parse.builtin").BUILTIN
local PREFIX = {"__builtin_", "__sync_", "__atomic_", "__c11_atomic_"}

local bad = {}

for name in pairs(B) do
	local ok = false

	for _, p in ipairs(PREFIX) do
		if name:sub(1, #p) == p then ok = true end
	end
	if not ok then bad[#bad + 1] = name end
end
table.sort(bad)
tap.is(table.concat(bad, " "), "", "every builtin has a builtin's prefix")

-- Compiles that need none of the optional parts, with and without the
-- headers.  errno names __errno_location, which is not a builtin.  A
-- native compile may read the system's headers, which are GNU C, so the
-- headers are checked on a cross target, which reads this tree's own.
local progs = {
	{name = "plain", want = "", targets = {"amd64", "xtensa"},
	 text = "int add(int a, int b) { return a + b; }\n" ..
		"int main(void) { return add(1, 2) - 3; }\n"},
	{name = "hdr", want = "", targets = {"xtensa"},
	 text = "#include <stdio.h>\n#include <stdlib.h>\n" ..
		"#include <string.h>\n#include <errno.h>\n" ..
		"int main(void) { char b[8]; strcpy(b, \"x\"); " ..
		"printf(\"%s\\n\", b); return atoi(b) + errno; }\n"},
}
local f

local probe = dir .. "/probe.lua"
f = assert(io.open(probe, "w"))
f:write([[
local watch = {}
for m in os.getenv("WATCH"):gmatch("%S+") do watch[m] = true end
local rq = require
local seen = {}
function require(n)
	if watch[n] then seen[#seen + 1] = n end
	return rq(n)
end
local drive = os.getenv("DRIVE")
local exit = os.exit
os.exit = function(c)
	io.stdout:write("loaded:", table.concat(seen, " "), "\n")
	exit(c)
end
arg = {[0] = drive, table.unpack(arg, 1)}
dofile(drive)
]])
f:close()

-- mcc.ir serves only the recorded register choice.
local names = {"mcc.ir"}
for mod in pairs(mods) do names[#names + 1] = mod end
table.sort(names)

for _, prog in ipairs(progs) do
	local c = ("%s/%s.c"):format(dir, prog.name)

	f = assert(io.open(c, "w"))
	f:write(prog.text)
	f:close()
	for _, target in ipairs(prog.targets) do
		local cmd = ("cd %s/.. && WATCH=%q DRIVE=%s/../drive.lua " ..
			"%s %s --target=%s -c -o %s/%s.o %s 2>&1"):format(here,
			table.concat(names, " "), here, lua, probe, target,
			dir, prog.name, c)
		local p = io.popen(cmd)
		local out = p:read("a")
		p:close()
		local loaded = out:match("loaded:([^\n]*)")
		local what = target .. " " .. prog.name

		tap.ok(loaded, what .. ": the compile ran")
		if not loaded then tap.diag(out) end
		tap.is(loaded, prog.want, what .. ": only what it needs loaded")
	end
end

tap.done()
