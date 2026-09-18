-- What of C this compiler takes, one small program at a time.
--
-- A whole project is a slow way to learn that a designated initialiser is
-- not supported: it reads a thousand headers first and stops at the first
-- line it cannot parse.  Each case here is a few lines, is compiled and
-- run, and its output is compared with what gcc's build of the same lines
-- says.  The whole file runs in about a second.
--
-- A case marked `todo` is a gap that is known.  TAP counts it as expected,
-- and says so if it starts passing.
--
--   lua5.4 test/compat.lua [name ...]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-compat"

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

local HEAD = [[
#include <stdio.h>
]]

local cases = {

{"line comments", [[
int main(void) { // a comment
	return puts("ok") < 0; }
]]},

{"mixed declarations", [[
int main(void) { int a = 1; printf("%d ", a); int b = a + 1;
	for (int i = 0; i < 2; i++) printf("%d ", i);
	printf("%d\n", b); return 0; }
]]},

{"_Bool", [[
#include <stdbool.h>
struct s { char a; _Bool b; char c; };
int main(void) { bool t = 2; _Bool f = 0; int *p = 0;
	printf("%d %d %d %d %d %d\n", (int)t, (int)f, (int)(_Bool)7,
		(int)(_Bool)p, (int)sizeof(_Bool), (int)sizeof(struct s));
	return 0; }
]]},

{"__func__", [[
void f(void) { printf("%s %s ", __func__, __FUNCTION__); }
int main(void) { f(); printf("%s\n", __func__); return 0; }
]]},

{"designated initialisers", [[
struct p { int x, y, z; };
struct p a = { .z = 3, .x = 1 };
int v[6] = { [4] = 9, [1] = 2 };
int main(void) { printf("%d %d %d %d %d %d\n", a.x, a.y, a.z,
	v[0], v[1], v[4]); return 0; }
]]},

{"nested designators", [[
struct b { int s, w; };
union u { struct b basic; long other; };
struct t { int kind; union u u; int prop; };
struct t a = { .kind = 1, .u.basic.w = 4, .prop = 8 };
struct t c[2] = { [1] = { .u.basic.s = 5 } };
int main(void) { printf("%d %d %d %d\n", a.kind, a.u.basic.w, a.prop,
	c[1].u.basic.s); return 0; }
]]},

{"compound literals", [[
struct p { int x, y; };
static struct p *origin = &(struct p){ .x = 1, .y = 2 };
static int sum(struct p *p) { return p->x + p->y; }
int main(void) { struct p *a = &(struct p){ 10, 20 };
	int *v = (int[]){ 3, 4, 5 };
	printf("%d %d %d %d\n", sum(a), v[2], sum(origin),
		(struct p){ .y = 7 }.y); return 0; }
]]},

{"constant folding", [[
enum { a = (0 < 8 ? (1 << 0) << 8 : 1), b = 1 && 2, c = 0 || 3,
       d = sizeof(int) * 2 };
int main(void) { printf("%d %d %d %d\n", a, b, c, d); return 0; }
]]},

{"anonymous union", [[
struct s { int tag; union { int i; char c[4]; }; };
int main(void) { struct s x; x.tag = 1; x.i = 0x41424344;
	printf("%d %c\n", x.tag, x.c[0]); return 0; }
]], todo = true},

{"flexible array member", [[
struct s { int n; char b[]; };
int main(void) { printf("%d\n", (int)sizeof(struct s)); return 0; }
]]},

{"bitfields", [[
struct s { unsigned a : 3, b : 5; };
int main(void) { struct s x; x.a = 5; x.b = 9;
	printf("%d %d %d\n", x.a, x.b, (int)sizeof(struct s)); return 0; }
]], todo = true},

{"_Static_assert", [[
_Static_assert(sizeof(int) == 4, "int is four bytes");
int main(void) { printf("ok\n"); return 0; }
]]},

{"variable length array", [[
int main(void) { int n = 3; char b[n + 1];
	b[0] = 'o'; b[1] = 'k'; b[2] = 0;
	printf("%s %d\n", b, (int)sizeof b); return 0; }
]], todo = true},

{"struct by value", [[
struct p { int x, y; };
static int sum(struct p p) { return p.x + p.y; }
int main(void) { struct p a = { 3, 4 }; printf("%d\n", sum(a)); return 0; }
]], todo = true},

{"struct return", [[
struct p { int x, y; };
static struct p make(int v) { struct p p; p.x = v; p.y = v + 1; return p; }
int main(void) { struct p a = make(3); printf("%d %d\n", a.x, a.y);
	return 0; }
]], todo = true},

{"static and restrict in a parameter", [[
static int f(int a[static 4], char *restrict s) { return a[3] + (s ? 1 : 0); }
int main(void) { int v[4] = { 0, 0, 0, 7 };
	printf("%d\n", f(v, "x")); return 0; }
]]},

{"long long and shifts", [[
int main(void) { long long v = 1ll << 40; unsigned long long u = ~0ull;
	printf("%lld %llu %lld\n", v, u, v / 3 - 1); return 0; }
]]},

{"string concatenation and escapes", [[
int main(void) { printf("a" "\tb\x41\101" "\n"); return 0; }
]]},

{"goto and switch fallthrough", [[
int main(void) { int n = 0;
	switch (2) { case 1: n += 1; case 2: n += 2; case 3: n += 4; break;
		     default: n = 99; }
	if (n < 10) goto done;
	n = -1;
done:	printf("%d\n", n); return 0; }
]]},

{"function pointers", [[
static int add(int a, int b) { return a + b; }
static int mul(int a, int b) { return a * b; }
int main(void) { int (*t[2])(int, int) = { add, mul };
	printf("%d %d\n", t[0](3, 4), t[1](3, 4)); return 0; }
]]},
}

local pick = {}
for _, a in ipairs(arg) do pick[a] = true end

for _, c in ipairs(cases) do
	local name, body = c[1], c[2]

	if next(pick) == nil or pick[name] then
		local src = dir .. "/t.c"
		local f = assert(io.open(src, "w"))

		f:write(HEAD, body)
		f:close()

		local ok, out = shell(("%s %s/../cc.lua -t amd64 " ..
			"-I%s/../include -I%s/../include/hosted %s -o %s/t.s")
			:format(lua, here, here, here, src, dir))
		local said, want

		if ok then
			ok, out = shell(("gcc -w -o %s/mine %s/t.s " ..
				"%s/../rt/softfp.c %s/../rt/varargs.c")
				:format(dir, dir, here, here))
		end
		if ok then
			_, said = shell(dir .. "/mine")
			shell(("gcc -w -o %s/ref %s"):format(dir, src))
			_, want = shell(dir .. "/ref")
			ok = said == want
		end
		if c.todo then
			tap.todo(ok, name)
		elseif not tap.ok(ok, name) then
			tap.diag(said and ("got  " .. tostring(said) ..
				"want " .. tostring(want)) or out)
		end
	end
end
tap.done()
