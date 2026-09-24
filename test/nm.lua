-- SPDX-License-Identifier: ISC
-- mnm against GNU nm, option by option, in the C locale a kernel build
-- sorts in.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-nm"
tap.scratch(dir)

local function shell(cmd)
	local p = io.popen(("cd %s && (%s) 2>&1"):format(dir, cmd))
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
local mnm = ("MCC_PROG=nm %s %s/../nm.lua"):format(lua, root)

if not tap.gnu("nm", 2, 30) or not shell("command -v gcc >/dev/null") then
	tap.skipall("no GNU nm and gcc to compare against")
end

write("a.c", "int x = 5; char big[70000]; int f(void) { return x; }\n")
write("b.c", "int z[3]; static int q(void) { return 1; }\n" ..
	"int r(void) { return q(); }\n")
write("p.c", [[
#include <stdio.h>
#include <stdlib.h>
static int local_count = 3;
__attribute__((weak)) int maybe(void) { return 7; }
int main(void)
{
	printf("%d %d\n", local_count, maybe());
	return 0;
}
]])
local ok = shell("gcc -c a.c && gcc -c b.c && ar rcs l.a a.o b.o && " ..
	"gcc -o p p.c && gcc -g -static -o s p.c && cp p ps && strip ps")
tap.ok(ok, "the objects build")

for _, how in ipairs{"a.o", "a.o b.o", "l.a", "a.o l.a b.o", "-n p",
		     "-n s", "-v p", "-p a.o", "-r a.o", "-nr p", "-g p",
		     "-u p", "-D p", "-S s", "-n -S s", "--defined-only p",
		     "-A l.a", "-o a.o b.o", "-P a.o", "-P p", "-P l.a",
		     "-P -A l.a", "-P a.o l.a", "-P -S s", "-t d a.o",
		     "-t o -S s", "--radix=x b.o", "-B a.o", "ps"} do
	local _, mine = shell("LC_ALL=C " .. mnm .. " " .. how)
	local _, theirs = shell("LC_ALL=C nm " .. how)

	if not tap.ok(mine == theirs, "mnm " .. how .. " matches nm") then
		tap.diag("mine:\n" .. mine:sub(1, 600))
		tap.diag("theirs:\n" .. theirs:sub(1, 600))
	end
end
tap.done()
