-- SPDX-License-Identifier: ISC
-- The archiver and the linker's use of it: a program that names one
-- member of an archive gets that one and not the rest.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local ar = require "mcc.ar"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-ar"
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

write("a.c", "int add(int a, int b) { return a + b; }\n")
write("b.c", "int never_used_here(void) { return 99; }\n")
write("c.c", "int mul(int a, int b) { return a * b; }\n")
write("m.c", [[
#include <stdio.h>
int add(int, int);
int mul(int, int);
int main(void) { printf("%d %d\n", add(2, 3), mul(4, 5)); return 0; }
]])

local lua = os.getenv("LUA") or "lua5.4"
local mcc = ("%s %s/../drive.lua"):format(lua, here)
local mar = ("%s %s/../archive.lua"):format(lua, here)
local ok, out = true, ""

for _, b in ipairs{"a", "b", "c"} do
	local o
	o, out = shell(("%s -w -c %s/%s.c -o %s/%s.o"):format(mcc, dir, b, dir, b))
	ok = ok and o
end
if not tap.ok(ok, "the objects compile") then tap.diag(out) end

ok, out = shell(("%s csrD %s/libx.a %s/a.o %s/b.o %s/c.o")
	:format(mar, dir, dir, dir, dir))
if not tap.ok(ok, "the archive is written") then tap.diag(out) end

local names = {}
for _, m in ipairs(ar.members(dir .. "/libx.a") or {}) do
	names[#names + 1] = m.name
end
tap.ok(table.concat(names, " ") == "a.o b.o c.o",
	"it holds the three members in order")

ok, out = shell(("%s -w %s/m.c %s/libx.a -o %s/prog")
	:format(mcc, dir, dir, dir))
if not tap.ok(ok, "a program links against it") then tap.diag(out) end

local _, said = shell(dir .. "/prog")
tap.ok(said == "5 20\n", "and runs")

-- A build adds to an archive a few objects at a time, takes one out,
-- and runs ranlib over what the system ar wrote.
local function members(path)
	local t = {}

	for _, m in ipairs(ar.members(path) or {}) do t[#t + 1] = m.name end
	return table.concat(t, " ")
end
shell(("rm -f %s/liby.a"):format(dir))
ok = shell(("%s cq %s/liby.a %s/a.o"):format(mar, dir, dir))
ok = ok and shell(("%s r %s/liby.a %s/b.o %s/a.o"):format(mar, dir, dir, dir))
tap.ok(ok and members(dir .. "/liby.a") == "a.o b.o",
	"r replaces a member and adds the rest")
-- Two files of one name in one command are two members.
shell(("rm -f %s/libdup.a; mkdir -p %s/d1 %s/d2; cp %s/a.o %s/d1/p.o; " ..
       "cp %s/b.o %s/d2/p.o"):format(dir, dir, dir, dir, dir, dir, dir))
ok = shell(("%s rcs %s/libdup.a %s/d1/p.o %s/d2/p.o")
	:format(mar, dir, dir, dir))
tap.ok(ok and members(dir .. "/libdup.a") == "p.o p.o",
	"two files of one name both go in")
ok = shell(("%s d %s/liby.a %s"):format(mar, dir, "a.o"))
tap.ok(ok and members(dir .. "/liby.a") == "b.o", "d removes one")
ok = shell(("%s q %s/liby.a %s/c.o %s/a.o"):format(mar, dir, dir, dir))
tap.ok(ok and members(dir .. "/liby.a") == "b.o c.o a.o", "q adds at the end")
local sysar = shell("command -v ar >/dev/null")

if sysar then
	shell(("rm -f %s/libz.a && ar cqS %s/libz.a %s/a.o %s/b.o %s/c.o")
		:format(dir, dir, dir, dir, dir))
	ok, out = shell(("MCC_PROG=mranlib %s %s/libz.a"):format(mar, dir))
	local _, idx = shell(("nm -s %s/libz.a"):format(dir))
	tap.ok(ok and idx:find("Archive index", 1, true) ~= nil,
		"mranlib gives an archive its index")
	ok, out = shell(("%s -w %s/m.c %s/libz.a -o %s/prog2")
		:format(mcc, dir, dir, dir))
	tap.ok(ok, "and a program links against it")
else
	tap.skip("mranlib gives an archive its index", "no system ar")
	tap.skip("and a program links against it", "no system ar")
end

-- kbuild builds built-in.a and vmlinux.a thin, with `ar cDPrST`: only
-- the headers, every name a path from the archive's directory, and a
-- thin archive given to another flattened into its members.  What mar
-- writes is compared with GNU ar byte for byte.
if sysar then
	-- The commands run from the scratch directory, so mar is named
	-- from the root.
	local pwd = io.popen("pwd"):read("l")
	local absmar = mar:gsub("(%S+/%.%./archive%.lua)", function(p)
		return p:sub(1, 1) == "/" and p or pwd .. "/" .. p
	end)

	shell(("mkdir -p %s/sub && cp %s/a.o %s/c.o %s/sub/ && " ..
		"rm -f %s/sub/g.a %s/sub/m.a %s/g.a %s/m.a %s/gd.a %s/md.a")
		:format(dir, dir, dir, dir, dir, dir, dir, dir, dir, dir))
	shell(("cd %s && ar cDPrST sub/g.a sub/a.o && " ..
		"ar cDPrST g.a sub/g.a sub/c.o && ar rcD gd.a a.o b.o c.o")
		:format(dir))
	shell(("cd %s && %s cDPrST sub/m.a sub/a.o && " ..
		"%s cDPrST m.a sub/m.a sub/c.o && %s rcD md.a a.o b.o c.o")
		:format(dir, absmar, absmar, absmar))
	local function same(a, b)
		local f, g = io.open(a, "rb"), io.open(b, "rb")
		local x, y = f and f:read("a"), g and g:read("a")

		if f then f:close() end
		if g then g:close() end
		return x ~= nil and x == y
	end
	tap.ok(same(dir .. "/sub/g.a", dir .. "/sub/m.a") and
		same(dir .. "/g.a", dir .. "/m.a"),
		"a thin archive, nested, is GNU ar's byte for byte")
	tap.ok(same(dir .. "/gd.a", dir .. "/md.a"),
		"and a plain deterministic one")
	tap.ok(members(dir .. "/m.a") == "sub/a.o sub/c.o",
		"a thin member is named by its path")
	ok, out = shell(("%s -w %s/m.c %s/m.a -o %s/prog3")
		:format(mcc, dir, dir, dir))
	tap.ok(ok, "and a program links against it")
else
	for _, t in ipairs{"a thin archive, nested, is GNU ar's byte for byte",
			   "and a plain deterministic one",
			   "a thin member is named by its path",
			   "and a program links against it"} do
		tap.skip(t, "no system ar")
	end
end

-- The member nothing asked for is not in the program.
local f = io.open(dir .. "/prog", "rb")
local image = f and f:read("a") or ""
if f then f:close() end
tap.ok(not image:find("never_used_here", 1, true),
	"the member nothing needs is left out")

-- nm and objdump read an archive a member at a time, and what they
-- print is compared against the system tools rather than against a
-- shape written down here.
local mnm = ("%s %s/../nm.lua"):format(lua, here)
local mobj = ("%s %s/../objdump.lua"):format(lua, here)

-- The shapes compared are GNU binutils'; OpenBSD's nm prints another.
local function same(what, mine, theirs)
	local tool = theirs:match("^%S+")
	local gnu = shell(tool .. " --version 2>&1 | grep -q GNU")
	local _, a = shell(mine)
	local good, b = shell(theirs)

	if not good or not gnu then
		tap.skip(what, "no GNU " .. tool .. " to compare against")
		return
	end
	if not tap.ok(a == b, what) then
		tap.diag("mine:\n" .. a)
		tap.diag("theirs:\n" .. b)
	end
end

same("nm reads an archive as nm does",
	("%s %s/libx.a"):format(mnm, dir),
	("nm %s/libx.a"):format(dir))
same("nm -A names the archive and the member",
	("%s -A %s/libx.a"):format(mnm, dir),
	("nm -A %s/libx.a"):format(dir))
same("objdump reads an archive as objdump does",
	("%s -h %s/libx.a"):format(mobj, dir),
	("objdump -h %s/libx.a"):format(dir))
tap.done()
