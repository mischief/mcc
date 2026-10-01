-- SPDX-License-Identifier: ISC
-- An xtensa program built by this compiler alone, under the simulator.
-- Deep calls spill frames through the window handlers, and a call with
-- more stack arguments than the frame holds moves the stack pointer
-- with MOVSP, which the runtime answers when the caller was spilled.
--
--   lua5.4 test/xtwin.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-xtwin"

tap.scratch(dir)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	local _, _, code = p:close()
	return code, out
end

local f = assert(io.open(dir .. "/deep.c", "w"))
f:write([[
struct B { int v[12]; };
int take(int a, int b, int c, int d, int e, int f, struct B s, int g)
{
	return s.v[0] + s.v[11] * 3 + g * 5 + a;
}
int down(int n) { return n ? down(n - 1) + 1 : 0; }
int deep(int n)
{
	struct B s = {{n, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, n + 7}};
	int k = down(20);
	return take(1, 2, 3, 4, 5, 6, s, k);
}
int main(void) { return deep(4) - 100; }
]])
f:close()

local code, out = shell("lua5.4 " .. here .. "/../drive.lua --target=xtensa " ..
	dir .. "/deep.c -o " .. dir .. "/deep")
tap.is(code, 0, "builds")
if code ~= 0 then tap.diag(out) end
code, out = shell("timeout 60 qemu-system-xtensa -M sim -cpu dc233c " ..
	"-nographic -monitor none -semihosting -kernel " .. dir .. "/deep")
tap.is(code, 38, "runs to the end")
tap.done()
