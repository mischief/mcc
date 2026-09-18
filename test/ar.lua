-- The archiver and the linker's use of it: a program that names one
-- member of an archive gets that one and not the rest.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local ar = require "ar"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-ar"
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

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

-- The member nothing asked for is not in the program.
local f = io.open(dir .. "/prog", "rb")
local image = f and f:read("a") or ""
if f then f:close() end
tap.ok(not image:find("never_used_here", 1, true),
	"the member nothing needs is left out")
tap.done()
