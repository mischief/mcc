-- SPDX-License-Identifier: ISC
-- Code nothing can reach is not compiled.  Each case names a function
-- the arm would call; the name must not appear in the assembly.
--
--   lua5.4 test/dead.lua <target>

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local target = arg[1] or "amd64"

local PRELUDE = [[
typedef unsigned long size_t;
void gone(void);
]]

local CASES = {
	{"an else arm behind a settled test", [[
void f(unsigned long b, int s)
{
	if (!__builtin_constant_p(b))
		;
	else if (s)
		gone();
	else
		gone();
}
]]},
	{"a switch nothing reaches", [[
void f(int v)
{
	if (sizeof(int) == 2) {
		switch (v) {
		case 1: gone(); break;
		default: gone(); break;
		}
	}
}
]]},
	{"a loop nothing reaches", [[
void f(int v)
{
	if (sizeof(int) == 2) {
		while (v)
			gone();
		do { gone(); } while (v);
		for (;;) { gone(); break; }
	}
}
]]},
	{"an object size nobody can work out", [[
static inline __attribute__((always_inline)) void c(const void *p,
						    size_t n, int src)
{
	int sz = __builtin_object_size(p, 0);

	if (sz >= 0 && sz < n) {
		if (src)
			gone();
		else
			gone();
	}
}
char buf[32];
void f(const void *p, size_t n) { c(buf, 8, 0); c(p, n, 1); }
]]},
}

local function compile(src)
	local cf = os.tmpname() .. ".c"
	local sf = os.tmpname() .. ".s"
	local h = assert(io.open(cf, "w"))

	h:write(PRELUDE, src)
	h:close()

	local cmd = ("%s %s/../drive.lua --target=%s -S -o %s %s 2>&1"):
		format(arg[-1] or "lua5.4", here, target, sf, cf)
	local p = io.popen(cmd)
	local err = p:read("a")

	p:close()
	local a = io.open(sf)
	local text = a and a:read("a") or ""

	if a then a:close() end
	os.remove(cf)
	os.remove(sf)
	return text, err
end


for _, c in ipairs(CASES) do
	local text, err = compile(c[2])

	if text == "" then
		tap.ok(false, c[1] .. ": " .. (err or "no output"))
	else
		tap.ok(not text:find("gone", 1, true), c[1])
	end
end
tap.done()
