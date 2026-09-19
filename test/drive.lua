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

-- An expansion stands on the line where the macro's name stood, even
-- when its arguments were spread over several.  Preprocessed assembly
-- rests on it: one line there is one statement.
do
	local f = assert(io.open(dir .. "/split.c", "w"))

	f:write([[
#define TWO(a, b) one a, b, three
TWO(x,
    y)
mark
]])
	f:close()
	ok, out = cc("-E split.c")
	local said = nil

	for l in (out or ""):gmatch("[^\n]+") do
		if l:find("one", 1, true) then said = l end
	end
	if not tap.ok(said == "one x, y, three",
	    "an expansion stays on one line") then
		tap.diag(tostring(said))
	end
end

-- `#` puts a backslash in front of a quote or a backslash that came
-- out of a string literal, and leaves a stray one alone.  Assembly
-- handed to the kernel's __stringify rests on the second half.
do
	local f = assert(io.open(dir .. "/hash.c", "w"))

	f:write([[
#define S(x) #x
S(mov $(\nr/2))
S("a\\b")
]])
	f:close()
	ok, out = cc("-E hash.c")
	local said = {}

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) == '"' then said[#said + 1] = l end
	end
	if not tap.ok(said[1] == [==["mov $(\nr/2)"]==] and
	    said[2] == [==["\"a\\\\b\""]==],
	    "# escapes only what it must") then
		tap.diag(tostring(said[1]) .. " / " .. tostring(said[2]))
	end
end

-- A backslash and a newline splice two lines into one.  Preprocessed
-- assembly has to come out as one line, because one line there is one
-- statement; C keeps the break, and so does gcc.
do
	local f = assert(io.open(dir .. "/cont.S", "w"))

	f:write("a b \\\n c, \\\n d\nmark\n")
	f:close()
	os.execute(("cp %s/cont.S %s/cont.c"):format(dir, dir))
	ok, out = cc("-E cont.S")
	local said = {}

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) ~= "#" and l:match("%S") then
			said[#said + 1] = l:match("^%s*(.-)%s*$")
		end
	end
	if not tap.ok(said[1] == "a b c, d",
	    "a spliced line of assembly comes out as one") then
		tap.diag(table.concat(said, " | "))
	end
	ok, out = cc("-E cont.c")
	local n = 0

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) ~= "#" and l:match("%S") then n = n + 1 end
	end
	if not tap.ok(n == 4, "a spliced line of C keeps its breaks") then
		tap.diag("lines " .. n)
	end
end

-- A macro that stands for nothing still separates what came before it
-- from what comes after, which is how the kernel writes a per-cpu
-- operand: `movq PER_CPU_VAR(x)` must not become `movq(x)`.
do
	local f = assert(io.open(dir .. "/empty.S", "w"))

	f:write([[
#define NOTHING
#define REL (%rip)
#define VAR(v) NOTHING(v)REL
	movq	VAR(top), %rsp
]])
	f:close()
	ok, out = cc("-E empty.S")
	local said = nil

	for l in (out or ""):gmatch("[^\n]+") do
		if l:find("movq", 1, true) then said = l end
	end
	if not tap.ok(said ~= nil and
	    said:find("movq (top)(%rip), %rsp", 1, true) ~= nil,
	    "a macro that expands to nothing leaves its space") then
		tap.diag(tostring(said))
	end
end

-- A body built where it is called.  The "i" constraint takes a
-- constant and nothing else, so only the caller has one: the parameter
-- still holds what was handed over when the input is read, and the
-- output writes it afterwards.  This is what linux's rip_rel_ptr needs,
-- and gcc only manages it with the optimizer on, so it is checked by
-- running rather than by comparing.
if (os.getenv("MCC_TARGET") or "amd64") == "amd64" then
	local f = assert(io.open(dir .. "/ripr.c", "w"))

	f:write([[
#include <stdio.h>
static __inline__ __attribute__((always_inline)) void *rip(void *p)
{
	__asm__("leaq %c1(%%rip), %0" : "=r"(p) : "i"(p));
	return p;
}
int v = 7;
int main(void)
{
	printf("%d %d
", *(int *)rip(&v), rip(&v) == (void *)&v);
	return 0;
}
]])
	f:close()
	ok, out = cc("-o ripr ripr.c")
	if not tap.ok(ok and true or false,
	    "a body with an immediate constraint builds where it is called")
	then
		tap.diag(out)
	else
		local _, said = shell("./ripr")

		if not tap.ok((said or ""):match("7 1") ~= nil,
		    "and the caller's address reaches the template") then
			tap.diag(tostring(said))
		end
	end
end

-- A macro given on the command line may take arguments, and the name
-- it answers to is the one before the parentheses.
do
	local f = assert(io.open(dir .. "/dmac.c", "w"))

	f:write([[
int printf(const char *, ...);
int main(void)
{
	printf("%d %d %d %s\n", FOO(3), ADD(2, 5), PLAIN, STR(hi));
	return 0;
}
]])
	f:close()
	-- every one quoted: parentheses are the shell's too
	local args = "'-DFOO(x)=42' '-DADD(a,b)=((a)+(b))' -DPLAIN=7 " ..
		"'-DSTR(s)=#s'"

	ok, out = cc(args .. " -o dmac dmac.c")
	if not tap.ok(ok and true or false, "-D defines a macro with " ..
	    "arguments") then
		tap.diag(out)
	else
		local _, said = shell("./dmac")

		tap.is(said, "42 7 7 hi\n", "and it expands")
	end
end

-- an unknown flag is a flag, not a file
ok, out = cc("-fno-semantic-interposition -Wno-unused -o prog3 add.c main.c")
tap.ok(ok and true or false, "an unknown flag is not taken for a file")

-- the stack protector needs the value and the handler from somewhere
ok, out = cc("-fstack-protector-all -o prog4 add.c main.c " ..
	here .. "/../rt/ssp.c")
tap.ok(ok and true or false, "-fstack-protector links against its runtime")

tap.done()
