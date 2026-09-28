-- SPDX-License-Identifier: ISC
-- Each driver mode loads only the modules it needs, and a later stage
-- starts without the modules of the stage before it.
--
--   lua5.4 test/drivemods.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-drivemods",
	true)

local function write(path, text)
	local f = assert(io.open(path, "w"))

	f:write(text)
	f:close()
end

local c = dir .. "/plain.c"
write(c, "int add(int a, int b) { return a + b; }\n" ..
	"int main(void) { return add(1, 2) - 3; }\n")

-- The probe prints every module the driver asks for, and what else
-- was loaded at the moment it asked.
local probe = dir .. "/probe.lua"
write(probe, [[
local rq = require
local seen = {}
function require(n)
	if not package.loaded[n] then
		local with = {}

		for k in pairs(package.loaded) do
			if k:match("^mcc%.") then with[#with + 1] = k end
		end
		seen[#seen + 1] = n .. "<" .. table.concat(with, ",") .. ">"
	end
	return rq(n)
end
local drive = os.getenv("DRIVE")
local exit = os.exit
local function report()
	io.stdout:write("loaded:", table.concat(seen, " "), "\n")
end
os.exit = function(c)
	report()
	exit(c)
end
arg = {[-1] = arg[-1], [0] = drive, table.unpack(arg, 1)}
dofile(drive)
report()
]])

local function run(args, env)
	local cmd = ("cd %s/.. && %s TMPDIR=%s DRIVE=%s/../drive.lua %s %s " ..
		"%s 2>&1"):format(here, env or "", dir, here, lua, probe, args)
	local p = io.popen(cmd)
	local out = p:read("a")

	p:close()
	local loaded = out:match("loaded:([^\n]*)")
	local mods = {}

	for m, with in (loaded or ""):gmatch("(%S+)<([^>]*)>") do
		local w = {}

		for k in with:gmatch("[^,]+") do w[k] = true end
		mods[m] = w
	end
	return loaded and mods, out
end

-- What a mode must not load, and what must be gone when a module of
-- the next stage loads.
local cases = {
	{"-E", "--target=xtensa -E -o " .. dir .. "/plain.i " .. c,
	 never = {"mcc.parse", "mcc.gen", "mcc.widert", "mcc.as", "mcc.elf",
		  "mcc.ld", "mcc.drive.link"},
	 want = {"mcc.cpp"},
	 gone = {["mcc.cpp"] = {"mcc.target.xtensa", "mcc.md", "mcc.tree"}}},
	{"-S", "--target=xtensa -S -o " .. dir .. "/plain.s " .. c,
	 never = {"mcc.as", "mcc.elf", "mcc.ld", "mcc.drive.link"},
	 want = {"mcc.parse"}},
	{"-c", "--target=xtensa -c -o " .. dir .. "/plain.o " .. c,
	 never = {"mcc.ld", "mcc.so", "mcc.drive.link"},
	 want = {"mcc.parse", "mcc.as"},
	 gone = {["mcc.as"] = {"mcc.parse", "mcc.cpp", "mcc.gen"}}},
	{"-c amd64", "--target=amd64 -c -o " .. dir .. "/a.o " .. c,
	 never = {"mcc.ld"}, want = {"mcc.as"}},
	{"-r", "--target=amd64 -r -o " .. dir .. "/r.o " .. dir .. "/a.o",
	 never = {"mcc.cpp", "mcc.parse", "mcc.drive.cc", "mcc.target.amd64",
		  "mcc.as"},
	 want = {"mcc.ld"}},
	{"link", "--target=amd64 -nostdlib -e main -o " .. dir ..
	 "/a.out " .. dir .. "/a.o",
	 never = {"mcc.cpp", "mcc.parse", "mcc.drive.cc", "mcc.target.amd64"},
	 want = {"mcc.ld"}},
	{"compile and link", "--target=amd64 -nostdlib -e main -o " .. dir ..
	 "/b.out " .. c,
	 want = {"mcc.parse", "mcc.ld"},
	 gone = {["mcc.ld"] = {"mcc.parse", "mcc.cpp", "mcc.as", "mcc.gen",
			       "mcc.target.amd64"}}},
	{"staged parent", "--target=amd64 -c -o " .. dir .. "/s.o " .. c,
	 env = "MCC_STAGED=1",
	 never = {"mcc.cpp", "mcc.parse", "mcc.as", "mcc.target.amd64"}},
}

-- A link builds the runtime once and keeps it in TMPDIR; the link case
-- is about the link, so the runtime is built first.
run("--target=amd64 -c -o " .. dir .. "/a.o " .. c)
run("--target=amd64 -nostdlib -e main -o " .. dir .. "/warm.out " ..
	dir .. "/a.o")

for _, k in ipairs(cases) do
	local name, args = k[1], k[2]

	local mods, out = run(args, k.env)

	if not tap.ok(mods, name .. ": the driver ran") then
		tap.diag(out)
		goto next
	end
	for _, m in ipairs(k.never or {}) do
		tap.ok(not mods[m], ("%s: %s is not loaded"):format(name, m))
	end
	for _, m in ipairs(k.want or {}) do
		tap.ok(mods[m], ("%s: %s is loaded"):format(name, m))
	end
	for at, list in pairs(k.gone or {}) do
		for _, m in ipairs(list) do
			tap.ok(mods[at] and not mods[at][m],
				("%s: %s is let go before %s loads"):format(
				name, m, at))
		end
	end
	::next::
end

tap.done()
