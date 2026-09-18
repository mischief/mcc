-- The driver, in the shape a build system expects one.
--
-- The point is that `CC=mcc` works: the flags a makefile passes to
-- everything are taken or ignored, the stages stop where -c, -S and -E say
-- they stop, and what comes out runs.  Nothing but this compiler is
-- involved -- its own assembler and its own linker make the file.
--
--   lua5.4 test/drive.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local function full(p)
	if p:sub(1, 1) == "/" then return p end
	local h = io.popen("pwd")
	local cwd = h:read("l")
	h:close()
	return cwd .. "/" .. p
end

here = full(here)
local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-drive"

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))
	f:write(text)
	f:close()
end

local function shell(cmd)
	local p = io.popen(("cd %s && %s 2>&1"):format(dir, cmd))
	local out = p:read("a")
	return p:close(), out
end

local function cc(args)
	return shell(("%s %s %s"):format(lua, drive, args))
end

write("add.c", [[
int add(int a, int b) { return a + b; }
]])
write("main.c", [[
#include <stdio.h>
int add(int a, int b);
int main(int argc, char **argv)
{
	printf("sum %d %s %d\n", add(20, 22), "ok", argc);
	return 0;
}
]])

-- the flags a makefile passes to everything, none of which mean anything
-- here and none of which may be mistaken for a file
local noise = "-O2 -Wall -Wextra -g -std=gnu11 -pipe -fno-common -MMD"

local ok, out = cc(noise .. " -c add.c main.c")
if not tap.ok(ok and true or false, "-c compiles each file on its own") then
	tap.diag(out)
	tap.done()
end
tap.ok(io.open(dir .. "/add.o") ~= nil and
	io.open(dir .. "/main.o") ~= nil,
	"each object takes its source's name")

ok, out = cc("-o prog add.o main.o")
if not tap.ok(ok and true or false, "objects link into a program") then
	tap.diag(out)
	tap.done()
end

local _, said = shell("./prog one two")
tap.is(said, "sum 42 ok 3\n", "the program runs and gets its arguments")

ok, out = cc(noise .. " -o prog2 add.c main.c")
tap.ok(ok and true or false, "sources compile and link in one step")
local _, s2 = shell("./prog2 one two")
tap.is(s2, "sum 42 ok 3\n", "and answer the same")

ok = cc("-S add.c")
tap.ok(ok and io.open(dir .. "/add.s") ~= nil, "-S stops at assembly")

ok, out = cc("-E add.c")
tap.ok(ok and out:find("int", 1, true) ~= nil, "-E stops at tokens")

-- an unknown flag is a flag, not a file
ok, out = cc("-fno-semantic-interposition -Wno-unused -o prog3 add.c main.c")
tap.ok(ok and true or false, "an unknown flag is not taken for a file")

-- the stack protector needs the value and the handler from somewhere
ok, out = cc("-fstack-protector-all -o prog4 add.c main.c " ..
	here .. "/../rt/ssp.c")
tap.ok(ok and true or false, "-fstack-protector links against its runtime")

tap.done()
