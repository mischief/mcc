-- SPDX-License-Identifier: ISC
-- What `-g` promises.  mas builds the line table gas builds, byte for
-- byte.  `-g` leaves every mapped section as it was.  A program linked
-- from `-g` objects tells a debugger where it stopped.
--
--   lua5.4 test/dwarf.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local elf = require "elf"

local lua = os.getenv("LUA") or "lua5.4"
local pwd = io.popen("pwd"):read("l")
local drive = (here:sub(1, 1) == "/" and here or pwd .. "/" .. here) ..
	"/../drive.lua"
local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-dwarf")
local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))

	f:write(text)
	f:close()
	return dir .. "/" .. name
end

local function run(cmd)
	return os.execute(cmd .. " 2>/dev/null")
end

-- The sections of an object by name, each with its bytes and its
-- relocations.  A relocation against a section names the section, so
-- two objects that number their sections differently still compare.
local function sections(path, want)
	local u = elf.header(path)
	local byidx, out = {}, {}

	for _, s in ipairs(u.order) do byidx[s.shndx] = s.name end
	for _, s in ipairs(u.debug or {}) do byidx[s.shndx] = s.name end
	local function each(s)
		if not want(s) then return end
		local bytes, relocs = elf.section(u, s, u.symnames)
		local rs = {}

		table.sort(relocs, function(x, y) return x.off < y.off end)
		for i, r in ipairs(relocs) do
			local n = r.sym:match("^%.Lsec(%d+)$")

			rs[i] = ("%x %s %s%+d"):format(r.off, r.kind,
				n and byidx[tonumber(n)] or r.sym, r.addend)
		end
		out[s.name] = (out[s.name] or "") .. bytes .. "\n" ..
			table.concat(rs, "\n") .. "\n"
	end
	for _, s in ipairs(u.order) do each(s) end
	for _, s in ipairs(u.debug or {}) do each(s) end
	return out
end

local function linetable(s)
	return s.name == ".debug_line" or s.name == ".debug_line_str"
end

-- mas against gas -----------------------------------------------------

-- Rows at one address, a line that goes back, a file in another
-- directory, the options, a gap too wide for a special opcode, and a
-- second section.
local CASES = {
	rows = [[
	.file 0 "/w" "t.c"
	.file 1 "t.c"
	.text
f:
	.loc 1 3 1
	nop
	.loc 1 2 5
	.loc 1 40 5 is_stmt 0
	nop
	.file 2 "/usr/include/stdio.h"
	.file 3 "sub/x.h"
	.file 4 "/w" "y.h"
	.loc 2 7 0 prologue_end
	.skip 300
	nop
	.loc 3 1
	.skip 20
	nop
	.loc 4 1 2 discriminator 3
	nop
	.section .text.b,"ax"
	.loc 1 9 9
	ret
	.text
	.loc 1 10 1
	ret
]],
	-- Which directory each name lands in.
	dirs = [[
	.file 0 "/w" "sub/t.c"
	.file 1 "/w" "sub/x.h"
	.file 2 "/q" "r/y.h"
	.file 3 "/w/sub" "z.h"
	.file 4 "/w/" "u.h"
	.file 5 "v/" "a.h"
	.file 6 "/w/sub/b.h"
	.file 7 "/abs/c.h"
	.text
	.loc 1 1
	nop
	.loc 7 1000000
	nop
	.loc 6 1
	nop
]],
}

if not has("as") or not tap.gnu("as", 2, 40) then
	tap.skip("mas against gas", "no GNU as 2.40 or later")
else
	for name, text in pairs(CASES) do
		local s = write(name .. ".s", text)
		local g, m = dir .. "/" .. name .. ".gas.o",
			dir .. "/" .. name .. ".mas.o"

		if not run(("as --nocompress-debug-sections -o %s %s")
			:format(g, s)) then
			tap.skip(name, "gas refused it")
		else
			assert(run(("%s %s -c -o %s %s"):format(lua, drive, m, s)))
			local a, b = sections(g, linetable), sections(m, linetable)

			tap.is(b[".debug_line"], a[".debug_line"],
				name .. ": .debug_line")
			tap.is(b[".debug_line_str"], a[".debug_line_str"],
				name .. ": .debug_line_str")
		end
	end
	-- What gcc writes for a whole program.
	if has("gcc") then
		for _, b in ipairs{"prog", "gotoloop", "rec"} do
			local c = here .. "/c/" .. b .. ".c"
			local s = dir .. "/gcc-" .. b .. ".s"
			local g, m = s .. ".gas.o", s .. ".mas.o"

			if run(("gcc -g -O0 -fno-asynchronous-unwind-tables " ..
				"-S %s -o %s %s"):format(inc, s, c)) and
			   run(("as --nocompress-debug-sections -o %s %s")
				:format(g, s)) and
			   run(("%s %s -c -o %s %s"):format(lua, drive, m, s))
			then
				local x, y = sections(g, linetable),
					sections(m, linetable)

				tap.is(y[".debug_line"], x[".debug_line"],
					"gcc -g " .. b .. ".c: .debug_line")
			else
				tap.skip("gcc -g " .. b .. ".c",
					"one of the tools refused it")
			end
		end
	end
end

-- -g changes no mapped byte ---------------------------------------------

local function mapped(s) return s.perm ~= nil end

local sources = {}
do
	local p = io.popen("ls " .. here .. "/c/*.c")

	for l in p:lines() do sources[#sources + 1] = l end
	p:close()
end

-- The peephole runs at -O2, and it must not see a `.loc`.
for _, t in ipairs{"amd64", "arm64"} do
	local n, bad = 0, {}

	for _, f in ipairs(sources) do
		local b = f:match("([^/]+)%.c$")
		local o = ("%s/%s.%s"):format(dir, b, t)
		local cmd = ("%s %s --target=%s -O2 %s -w -c %s"):format(lua,
			drive, t, inc, f)

		if run(cmd .. " -o " .. o .. ".o") then
			if not run(cmd .. " -g -o " .. o .. ".g.o") then
				bad[#bad + 1] = b .. " (-g fails)"
			else
				local x = sections(o .. ".o", mapped)
				local y = sections(o .. ".g.o", mapped)
				local same = true

				for k, v in pairs(x) do
					if y[k] ~= v then same = false end
				end
				for k in pairs(y) do
					if not x[k] then same = false end
				end
				if not same then bad[#bad + 1] = b end
				n = n + 1
			end
		end
	end
	tap.ok(n > 20 and #bad == 0,
		("%s: -g leaves %d objects as they were"):format(t, n))
	if #bad > 0 then tap.diag("differ: " .. table.concat(bad, " ")) end
end

-- A debugger reads it ---------------------------------------------------

local t = write("t.c", [[
int g = 2;

int f(int x)
{
	int y = x * g;
	return y + 1;
}
]])
local m = write("m.c", [[
#include <stdio.h>

int f(int x);

int main(void)
{
	int r = f(20);

	printf("%d\n", r);
	return 0;
}
]])
local prog = dir .. "/prog"
local linked = run(("cd %s && %s %s -g -o %s t.c m.c"):format(dir, lua,
	drive, prog))

tap.ok(linked, "a program built with -g links")
if linked then
	local p = io.popen(prog)
	local said = p:read("a")

	p:close()
	tap.is(said, "41\n", "and runs")
	if has("gdb") then
		local q = io.popen(("gdb -nx -batch -ex 'break f' -ex run " ..
			"-ex bt -ex next %s 2>&1"):format(prog))
		local s = q:read("a")

		q:close()
		tap.ok(s:find("f %(%) at t%.c:5") ~= nil,
			"gdb stops in f at t.c:5")
		tap.ok(s:find("main %(%) at m%.c:7") ~= nil,
			"gdb says main called f from m.c:7")
		tap.ok(s:find("\n6%s+return y %+ 1;") ~= nil,
			"next goes to line 6")
	else
		tap.skip("gdb", "no gdb")
	end
end

-- A gcc object with compressed debug sections ------------------------

local function gdb(path, ...)
	local q = io.popen(("gdb -nx -batch %s %s 2>&1"):format(
		table.concat({...}, " "), path))
	local said = q:read("a")

	q:close()
	return said
end

write("tv.c", [[
__thread int tv = 3;

int gettv(void)
{
	return tv;
}
]])
write("tm.c", [[
#include <stdio.h>

int gettv(void);

int main(void)
{
	printf("%d\n", gettv());
	return 0;
}
]])
if not has("gcc") or not run(("cd %s && gcc -g -gz=zlib -c tv.c"):format(dir))
then
	tap.skip("gcc -gz", "no gcc that compresses debug sections")
else
	local function link(out, flags)
		return run(("cd %s && %s %s %s -o %s tm.c tv.o"):format(dir,
			lua, drive, flags, out))
	end
	local p = dir .. "/gz"

	tap.ok(link(p, "-g"), "a gcc -gz object links")
	if has("gdb") then
		local s = gdb(p, "-ex 'break gettv'", "-ex run", "-ex 'print tv'")

		tap.ok(s:find("gettv %(%) at tv%.c:5") ~= nil and
			s:find("%$1 = 3") ~= nil,
			"gdb reads the inflated sections")
	end
	-- Without -g the link never reads them, and with -s it drops
	-- them.
	for _, f in ipairs{"", "-g -s"} do
		link(p, f)
		local u = elf.header(p)

		tap.ok(u.debug == nil, ("mcc %s: no debug sections")
			:format(f == "" and "without -g" or f))
	end
	-- A stream that will not inflate costs its unit its debug
	-- sections, and nothing else.
	local o = elf.header(dir .. "/tv.o")
	local f = assert(io.open(dir .. "/tv.o", "r+b"))

	for _, e in ipairs(o.debug) do
		if e.squashed then
			f:seek("set", e.off + 30)
			f:write(("\255"):rep(8))
		end
	end
	f:close()
	local q = io.popen(("cd %s && %s %s -g -o %s tm.c tv.o 2>&1"):format(
		dir, lua, drive, p))
	local said = q:read("a")

	tap.ok(q:close(), "a broken stream still links")
	tap.ok(said:find("warning: .*dropped") ~= nil, "and says so")
	local r = io.popen(p)

	tap.is(r:read("a"), "3\n", "and the program runs")
	r:close()
end

tap.done()
