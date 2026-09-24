-- SPDX-License-Identifier: ISC
-- msize: the text, data and bss of an object, compared against the
-- system size on the objects, a linked program and an archive.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local ar = require "ar"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-size"
tap.scratch(dir)

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))

	f:write(text)
	f:close()
end

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")

	return p:close(), out
end

write("data.c", [[
static char g_data[16] = "hello data!!";
static int  g_count = 42;
int get(void) { return g_count; }
]])
write("bss.c", [[
static int  g_bss[64];
static char g_buf[128];
int f(void) { return g_bss[0]; }
]])
write("main.c", [[
#include <stdio.h>
int get(void);
int main(void) { printf("%d\n", get()); return 0; }
]])

local lua = os.getenv("LUA") or "lua5.4"
local mcc = ("%s %s/../drive.lua"):format(lua, here)
local msize = ("%s %s/../size.lua"):format(lua, here)
local ok, out = true, ""

for _, b in ipairs{"data", "bss", "main"} do
	local o
	o, out = shell(("%s -w -c %s/%s.c -o %s/%s.o"):format(mcc, dir, b, dir, b))
	ok = ok and o
end
if not tap.ok(ok, "the objects compile") then tap.diag(out) end

ok, out = shell(("%s -w %s/main.o %s/data.o %s/bss.o -o %s/prog")
	:format(mcc, dir, dir, dir, dir))
if not tap.ok(ok, "a program links") then tap.diag(out) end

ok, out = shell(("%s -w %s/main.o %s/data.o %s/bss.o -pie -o %s/prog_pie")
	:format(mcc, dir, dir, dir, dir))
if not tap.ok(ok, "a pie program links") then tap.diag(out) end

shell(("%s csrD %s/libx.a %s/data.o %s/bss.o"):format(
	("%s %s/../archive.lua"):format(lua, here), dir, dir, dir))

-- The compared form is GNU size's; OpenBSD's size prints another.
local havesize = shell("size --version 2>&1 | grep -q 'GNU size'")

if not havesize then
	tap.skip("msize matches the system size on objects", "no GNU size")
	tap.skip("msize matches the system size on a program", "no GNU size")
	tap.skip("msize matches the system size on a pie program", "no GNU size")
	tap.skip("msize matches the system size on an archive", "no GNU size")
	tap.done()
end

-- What size prints for one or more files, and what msize prints, are
-- compared rather than written down here.
local function same(what, files)
	local mine, a = shell(msize .. " " .. files)
	local theirs, b = shell("size " .. files)

	if not tap.ok(a == b, what) then
		tap.diag("mine:\n" .. a)
		tap.diag("theirs:\n" .. b)
	end
end

same("msize matches the system size on objects",
	("%s/%s.o %s/%s.o"):format(dir, "data", dir, "bss"))
same("msize matches the system size on a program", dir .. "/prog")
same("msize matches the system size on a pie program", dir .. "/prog_pie")
same("msize matches the system size on an archive", dir .. "/libx.a")

-- The options, each against the same set of files.
local all = ("%s/data.o %s/bss.o %s/libx.a %s/prog"):format(dir, dir, dir, dir)
for _, o in ipairs{"-x", "-o", "-d -t", "-t -x", "--radix=16", "-A",
		   "-A -x", "-A -o", "--format=sysv -t", "-B -o -t"} do
	same("msize " .. o .. " matches size " .. o, o .. " " .. all)
end
do
	-- the message names the program, so msize answers as size here
	local _, a = shell("MCC_PROG=size " .. msize .. " " .. dir .. "/nosuch")
	local _, b = shell("size " .. dir .. "/nosuch")

	tap.is(a, b, "a file that is not there is said so, and nothing else")
end
tap.done()
