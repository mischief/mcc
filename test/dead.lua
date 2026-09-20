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
int gone(void);
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
	-- The test of a statement nothing reaches is not a label: what
	-- it would compile to goes as well.
	{"a test nothing reaches", [[
void f(int v, int *p)
{
	if (sizeof(int) == 2) {
		if (gone())
			v = 1;
		else if (gone())
			v = 2;
		while (gone())
			v = 3;
		do { v = 4; } while (gone());
		for (gone(); gone(); gone())
			v = 5;
		switch (gone()) {
		case 1: v = 6; break;
		default: v = 7; break;
		}
		*p = v;
	}
}
]]},
	{"the right of a settled && or ||", [[
void f(int v)
{
	do { } while (0 && (gone(), 1));
	do { } while (1 || (gone(), 1));
	if (0 && (gone(), 1))
		v = 1;
	if (1 || (gone(), 1))
		v = 2;
}
]]},
	{"a body that answers the same every time", [[
static inline __attribute__((always_inline)) int off(void) { return 0; }
static inline __attribute__((always_inline)) int on(void) { return 1; }
int other(void);
void f(int v)
{
	if (off() && gone())
		v = 1;
	if (on() || gone())
		v = 2;
	if (off() && other())
		v = 3;
	if (off())
		gone();
	else if (off())
		gone();
}
]]},
	{"a record handed over by value", [[
typedef struct { unsigned long v; } pmd_t;
static inline int is_swap(pmd_t p) { return 0; }
static inline int is_huge(pmd_t p) { return 0; }
void f(pmd_t *p)
{
	if (is_swap(*p) || is_huge(*p))
		gone();
}
]]},
	{"an operand that decides on its own", [[
int side(void);
void f(void)
{
	if (side() && 0)
		gone();
	if (side() || 1)
		;
	else
		gone();
	if (!(side() && 0))
		;
	else
		gone();
}
]]},
	{"a slot that holds one number", [[
int enabled(void);
void f(void)
{
	int on = 0 && enabled();
	int off = 0;

	if (on && gone())
		off = 1;
	if (on)
		gone();
	if (off != 0)
		gone();
	switch (off) {
	case 1: gone(); break;
	default: break;
	}
}
]]},
	{"a pointer that settles to nothing", [[
struct s { int a; };
void f(int *out)
{
	struct s *p = 0;

	if (p)
		gone();
	if (p != 0)
		gone();
	if (p && p->a)
		gone();
	if (!p)
		*out = 1;
}
]]},
	-- The kernel writes WARN_ON_ONCE(!IS_ENABLED(...)) and returns,
	-- which leaves everything after it out of reach.
	{"a statement expression that settles", [[
void *f(int n)
{
	if (({ int w = !!(!0); __builtin_expect(!!(w), 0); }))
		return 0;
	gone();
	return 0;
}
]]},
	-- A value behind a mask cannot hold a bit the mask clears.  The
	-- kernel reads a three-bit zone number and compares it with a
	-- zone the configuration left out of the list.
	{"a value behind a mask", [[
static inline int zonenum(unsigned long f) { return (f >> 26) & 3u; }
void f(unsigned long fl, int *out)
{
	if (zonenum(fl) == 4)
		gone();
	if ((fl & 7) == 8)
		gone();
	if (zonenum(fl) == 2)
		*out = 1;
}
]]},
	-- A name of this unit's own that nothing reaches is not built,
	-- so what it would have called is never named either.
	{"a static nothing reaches", [[
static void chain(void) { gone(); }
static void caller(void) { chain(); }
static int kept(void) __attribute__((used));
static int kept(void) { return 1; }
static int used_by_table(int x) { return x; }
static int (*fp)(int) = used_by_table;
int f(int x) { return fp(x); }
]]},
	-- A call in an operand the other one rules out is not a use, so
	-- a body deferred for want of a caller stays deferred.
	{"a call an operand rules out", [[
static int inner(void) { gone(); return 1; }
int f(int c)
{
	int off = 0;

	if (off && inner())
		return 1;
	return off ? inner() : 0;
}
]]},
	-- A label inside a body built where it was called is reached
	-- only from inside it: the kernel's static_cpu_has is an
	-- `asm goto` with two of them, and it stands in a test.
	{"a label inside a body built where it was called", [[
static inline __attribute__((always_inline)) int has(void)
{
	goto yes;
yes:
	return 0;
no:
	return 1;
}
void f(void)
{
	if (!0)
		return;
	if (has())
		gone();
	gone();
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
