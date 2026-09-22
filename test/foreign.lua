-- SPDX-License-Identifier: ISC
-- Objects from another compiler, through this linker.  Reading ELF is
-- what makes that possible; the two halves of the program agree on
-- nothing but the ABI and the object format.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-foreign"
tap.scratch(dir)

local CC = os.getenv("CC") or "gcc"
local lua = os.getenv("LUA") or "lua5.4"
local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	local ok = p:close()
	return ok and true or false, out
end

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

write(dir .. "/theirs.c", [[
struct pt { int x, y; };
int triple(int v) { return v * 3; }
long widen(int v) { return (long)v + 1; }
struct pt swap(struct pt p) { struct pt q; q.x = p.y; q.y = p.x; return q; }
int theirdata = 11;
]])
write(dir .. "/mine.c", [[
extern int printf(const char *, ...);
struct pt { int x, y; };
int triple(int);
long widen(int);
struct pt swap(struct pt);
extern int theirdata;
int mine(int v) { return v + 1; }
int main(void)
{
	struct pt p, q;

	p.x = 3;
	p.y = 8;
	q = swap(p);
	printf("%d %ld %d %d %d %d\n", triple(14), widen(41), theirdata,
		q.x, q.y, mine(1));
	return 0;
}
]])

local ok, out = shell(("%s -c -fno-pic %s/theirs.c -o %s/theirs.o")
	:format(CC, dir, dir))
if not ok then tap.skipall("no reference compiler: " .. out) end

local drive = here .. "/../drive.lua"

ok, out = shell(("%s %s -t amd64 %s -c %s/mine.c -o %s/mine.o")
	:format(lua, drive, inc, dir, dir))
tap.ok(ok, "mine.o builds")
if not ok then tap.diag(out) end

ok, out = shell(("%s %s -t amd64 %s/theirs.o %s/mine.o -o %s/prog")
	:format(lua, drive, dir, dir, dir))
tap.ok(ok, "this linker takes the other compiler's object")
if not ok then tap.diag(out) end

local got
ok, got = shell(dir .. "/prog")
tap.ok(ok and got == "42 42 11 8 3 2\n", "and the program is right")
if got ~= "42 42 11 8 3 2\n" then tap.diag("got: " .. tostring(got)) end
tap.done()
