-- Position independent code reaching an object another unit owns.
--
-- Under -fpic a reference to a global this unit does not own goes
-- through a GOT node.  Every target has to be able to put that address
-- in a register, and the answer has to be the right one, so this
-- builds both halves, links them and runs.
--
--   lua5.4 test/pic.lua [amd64|riscv64|arm64]

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
local which = arg[1] or "amd64"
local RUN = {amd64 = "", riscv64 = "qemu-riscv64 ", arm64 = "qemu-aarch64 "}
local run = RUN[which]

if not run then tap.skipall("no way to run " .. which) end
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-pic-" .. which

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))

	f:write(text)
	f:close()
end

-- Every shape that has to reach a global: read, write, step, address,
-- an element, a load through one, and a call.
write("use.c", [[
extern int c;
extern int arr[4];
extern char *p;
extern int fn(int);
static int s;
int rd(void) { return c; }
void wr(int v) { c = v; }
int rmw(void) { return ++c; }
int *ad(void) { return &c; }
int el(int i) { return arr[i]; }
char ld(void) { return *p; }
int call(int x) { return fn(x); }
int st(void) { return ++s; }
]])
write("def.c", [[
int c = 41;
int arr[4] = {10, 20, 30, 40};
static char buf[8] = "xy";
char *p = buf;
int fn(int x) { return x * 2; }
int rd(void); void wr(int); int rmw(void); int *ad(void);
int el(int); char ld(void); int call(int); int st(void);
int main(void)
{
	int bad = 0;

	if (rd() != 41) bad += 1;
	wr(7); if (rd() != 7) bad += 2;
	if (rmw() != 8) bad += 4;
	if (ad() != &c) bad += 8;
	if (el(2) != 30) bad += 16;
	if (ld() != 'x') bad += 32;
	if (call(21) != 42) bad += 64;
	if (st() != 1 || st() != 2) bad += 128;
	return bad;
}
]])

local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"

local function shell(cmd)
	local p = io.popen(("cd %s && %s 2>&1"):format(dir, cmd))
	local out = p:read("a")

	return p:close(), out
end

local function cc(args)
	return shell(("%s %s -t %s %s"):format(lua, drive, which, args))
end

local ok, out = cc("-fpic -c -o use.o use.c")

if not tap.ok(ok and true or false, which .. "/pic compiles a use") then
	tap.diag(out)
	tap.done()
	return
end
ok, out = cc("-fpic -c -o def.o def.c")
if not tap.ok(ok and true or false, which .. "/pic compiles a definition")
then
	tap.diag(out)
	tap.done()
	return
end
ok, out = cc("-static -o pic use.o def.o")
if not tap.ok(ok and true or false, which .. "/pic links") then
	tap.diag(out)
	tap.done()
	return
end
local _, said = shell(run .. "./pic; echo rc=$?")

if not tap.ok((said or ""):find("rc=0", 1, true) ~= nil,
    which .. "/pic answers as it should") then
	tap.diag(tostring(said))
end
tap.done()
