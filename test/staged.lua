-- SPDX-License-Identifier: ISC
-- A staged compile, MCC_STAGED, writes what the single process writes:
-- the same assembly, objects, dependency lists and complaints, whether
-- each pass runs as a process of its own or in the driver's process.
--
--   lua5.4 test/staged.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-staged",
	true)
local root = here .. "/.."

local function slurp(path)
	local f = io.open(path, "rb")

	if not f then return nil end
	local s = f:read("a")

	f:close()
	return s
end

local function write(path, text)
	local f = assert(io.open(path, "w"))

	f:write(text)
	f:close()
end

-- What the preprocessor's text has to carry across to the parser: the
-- pragmas it keeps for itself, tokens that would join without a space
-- between them, and literals whose spelling says their type.
local edge = dir .. "/edge.c"
write(edge, [[
#define N -1
#define PLUS +
#pragma pack(push, 1)
struct s { char c; int i; };
#pragma pack(pop)
#pragma pack(2)
struct t { char c; int i; };
#pragma pack()
#pragma GCC visibility push(hidden)
int hid(void) { return 1; }
#pragma GCC visibility pop
int neg(int x) { return -N - x PLUS+1; }
int w = L'\x20ac';
unsigned short u16 = u'x';
const char *str = "a\tb\"c\\" "d";
int sz(void) { return sizeof(struct s) * 10 + sizeof(struct t); }

int
main(void)
{
	return neg(1) + sz() - 57 - hid();
}
]])

-- One run in a directory of its own, so that the paths in the outputs
-- are the same for each way of running it.
local function run(env, args, out)
	local d = dir .. "/run"

	os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
	local cmd = ("cd %s && %s TMPDIR=%s %s drive.lua %s -o %s/%s " ..
		">%s/stdout 2>%s/stderr"):format(root, env, dir, lua,
		args:gsub("@", d), d, out, d, d)
	local ok = os.execute(cmd)
	local got = {ok = ok and true or false,
		     out = slurp(d .. "/" .. out),
		     dep = slurp(d .. "/dep.d"),
		     stdout = slurp(d .. "/stdout"),
		     stderr = slurp(d .. "/stderr")}

	return got
end

local function same(name, args, out)
	local want = run("", args, out)

	for _, env in ipairs{"MCC_STAGED=1", "MCC_STAGED=here"} do
		local got = run(env, args, out)
		local good = got.ok == want.ok and got.stderr == want.stderr and
			got.stdout == want.stdout and got.dep == want.dep and
			(not want.ok or got.out == want.out)

		if not tap.ok(good, ("%s, %s"):format(name, env)) then
			tap.diag(("single: %s %s"):format(want.ok,
				want.stderr or ""))
			tap.diag(("staged: %s %s"):format(got.ok,
				got.stderr or ""))
		end
	end
end

for _, t in ipairs{"amd64", "xtensa", "i386"} do
	same("edge.c -c " .. t, "--target=" .. t .. " -c " .. edge, "edge.o")
	same("edge.c -S -g " .. t, "--target=" .. t .. " -S -g " .. edge,
		"edge.s")
end
same("edge.c -MD -include", "-c -MD -MF @/dep.d -MP -include " ..
	root .. "/test/c/pack.c " .. edge, "edge.o")
same("edge.c -Wp,-MD", "-c -Wp,-MD,@/dep.d -DN2=3 " .. edge, "edge.o")
same("edge.c -g -ffile-prefix-map", "-c -g -ffile-prefix-map=" .. dir ..
	"=/src " .. edge, "edge.o")
same("standard input", "-c -g -x c - <" .. edge, "stdin.o")
same("edge.c linked", "--target=amd64 -nostdlib -e main " .. edge,
	"a.out")
same("assembler with cpp", "-m16 -c test/c/realmode-entry.S", "r.o")
same("assembler", "--target=xtensa -c rt/sim-xtensa.s", "sim.o")
same("wasm", "--target=wasm -c test/c/abi.c", "abi.o")

-- The corpus, where a unit that fails has to fail the same way.
local p = io.popen("ls " .. root .. "/test/c/*.c")

for f in p:lines() do
	local name = f:match("([^/]*)%.c$")

	same(name .. ".c", "--target=xtensa -c " .. f, name .. ".o")
end
p:close()

tap.done()
