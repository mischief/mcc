-- SPDX-License-Identifier: ISC
-- What of C this compiler takes, one small program at a time.
--
-- A whole project is a slow way to learn that a designated initialiser is
-- not supported: it reads a thousand headers first and stops at the first
-- line it cannot parse.  Each case here is a few lines, is compiled and
-- run, and its output is compared with what the system compiler makes
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

tap.scratch(dir)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

-- The system compiler, which assembles what this one writes and builds
-- the answer to compare against.  It is the only oracle here.
local CC = os.getenv("CC") or "cc"

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
]]},

{"typeof", [[
#define swap(a, b) do { typeof(a) t_ = (a); (a) = (b); (b) = t_; } while (0)
int main(void) { int x = 1, y = 2; __typeof__(x) z = 7;
	typeof(int *) p = &x; swap(x, y);
	printf("%d %d %d %d\n", x, y, z, *p); return 0; }
]]},

{"array parameter with a variable size", [[
int f(int n, int a[n]) { return a[n - 1]; }
int g(int n, int b[n][3]) { return b[1][2]; }
int main(void) { int v[5] = {1,2,3,4,5}; int w[2][3] = {{1,2,3},{4,5,6}};
	printf("%d %d\n", f(5, v), g(2, w)); return 0; }
]]},

{"type macros the headers ask for", [[
__SIZE_TYPE__ a = 1; __PTRDIFF_TYPE__ b = 2; __INTPTR_TYPE__ c = 3;
__UINT64_TYPE__ d = 4; __WCHAR_TYPE__ e = 5;
int main(void) { printf("%d %d %d %d %d %d\n", (int)a, (int)b, (int)c,
	(int)d, (int)e, __INT_MAX__ == 2147483647); return 0; }
]]},

{"case ranges", [[
int f(int c) { switch (c) { case '0'...'9': return 1;
	case 'a' ... 'f': return 2; case 20: return 3; default: return 0; } }
int main(void) { printf("%d %d %d %d\n", f('5'), f('c'), f(20), f('z'));
	return 0; }
]]},

{"pragma once", [[
#include "compat-once.h"
#include "compat-once.h"
int main(void) { printf("%d\n", ONCE_OK); return 0; }
]], extra = {["compat-once.h"] = "#pragma once\nenum { ONCE_OK = 7 };\n"}},

{"named variadic macro parameter", [[
#define pr(fmt, args...) printf(fmt, ##args)
int main(void) { pr("%d %d\n", 1, 2); pr("done\n"); return 0; }
]]},

{"float constants fold", [[
static const float s = 1.0f/255.0f;
static const double d = 1.0/3.0 + 1.0;
static const float t = (float)3;
static const int n = (int)2.9;
int main(void) { printf("%f %f %f %d\n", s, d, t, n); return 0; }
]]},

{"C23 attributes", [==[
[[maybe_unused]] static int spare = 1;
int f(int x) { switch (x) { case 1: [[fallthrough]];
	case 2: return 2; default: return 0; } }
int main(void) { [[maybe_unused]] int q = 1;
	printf("%d %d %d\n", f(1), f(2), f(3)); return 0; }
]==]},

{"statement expressions", [[
#define max(a, b) ({ __typeof__(a) _a = (a), _b = (b); _a > _b ? _a : _b; })
struct p { int x, y; };
int main(void) {
	int a = 3, b = 7;
	struct p s = {1, 2};
	struct p r = ({ struct p t = s; t.x = 9; t; });

	printf("%d %d %d %d %d\n", max(a, b), max(b, a),
		({ int i, t = 0; for (i = 0; i < 4; i++) t += i; t; }),
		r.x, r.y);
	return 0;
}
]]},

{"include_next", [[
#include "compat-next.h"
int main(void) { printf("%d %d\n", NEXT_A, NEXT_B); return 0; }
]], extra = {["compat-next.h"] =
	"#define NEXT_A 1\n#include_next <compat-next.h>\n",
	["sub/compat-next.h"] = "#define NEXT_B 2\n"},
	incs = {"", "sub"}},

{"byte swap", [[
int main(void) { unsigned int v = 0x11223344;
	unsigned long w = 0x1122334455667788UL;
	printf("%x %lx\n", __builtin_bswap32(v), __builtin_bswap64(w));
	return 0; }
]]},

{"_Generic", [[
#define tn(x) _Generic((x), int: "int", long: "long", double: "double", \
	char *: "charp", default: "other")
int main(void) { int i = 1; long l = 2; double d = 3; char *p = "x";
	short s = 4;
	printf("%s %s %s %s %s\n", tn(i), tn(l), tn(d), tn(p), tn(s));
	return 0; }
]]},

{"computed goto", [[
int run(int n) {
	static const void *tab[] = {&&a, &&b, &&c};
	int t = 0;
	goto *tab[n];
a:	t += 1; goto done;
b:	t += 2; goto done;
c:	t += 4; goto done;
done:	return t;
}
int main(void) { printf("%d %d %d\n", run(0), run(1), run(2)); return 0; }
]]},

{"statement expressions in short circuits", [[
#define max(a, b) ({ __typeof__(a) _a = (a), _b = (b); _a > _b ? _a : _b; })
static int side = 0;
static int bump(int v) { side++; return v; }
int main(void) {
	int a = 3, b = 7, c;

	c = a > 1 ? max(a, b) : max(b, a);
	printf("%d %d\n", c, side);
	c = 0 && max(bump(1), 2);
	printf("%d %d\n", c, side);
	c = 0 ? max(bump(5), 9) : 4;
	printf("%d %d\n", c, side);
	c = 1 ? max(bump(5), 9) : 4;
	printf("%d %d %d\n", c, side, max(a, b) + max(b, a) * 2);
	return 0;
}
]]},

{"read-write asm operand", [[
int main(void) { int x = 1;
	__asm__("addl $1, %0" : "+r"(x));
	__asm__ volatile("" ::: "memory");
	printf("%d\n", x); return 0; }
]]},

{"a file scope asm is passed through", [[
__asm__(".pushsection .note.t, \"a\", %note\n.balign 4\n.popsection\n");
int main(void) { printf("ok\n"); return 0; }
]]},

{"a compound literal at file scope", [[
struct pair { int a, b; };
struct obj { const char *n; const struct pair *p; };
static int spare(void) { return 1; }
static const struct obj o = { "x", (const struct pair[]) { {1,2}, {3,4} } };
int main(void) { printf("%s %d %d %d\n", o.n, o.p[0].a, o.p[1].b, spare());
	return 0; }
]]},

{"literal prefixes", [[
int main(void) { const char *a = u8"hi", *b = u8"a" "b"; int c = L'x';
	printf("%s %s %d\n", a, b, c); return 0; }
]]},

{"a null pointer in a conditional", [[
struct s { int a; };
static struct s one = {7};
#define VT(n) ((n) != 0 ? &one : NULL)
int main(void) { printf("%d\n", VT(1)->a); return 0; }
]]},

{"packed and aligned", [[
struct p { char a; int b; short c; } __attribute__((packed));
struct n { char a; int b; short c; };
struct pb { unsigned a : 3; unsigned b : 30; } __attribute__((packed));
struct al { char a; } __attribute__((aligned(16)));
struct __attribute__((packed)) q { char a; long b; };
__attribute__((aligned(64))) static int wide = 7;
int main(void) {
	struct p x = {1, 2, 3};

	printf("%d %d %d %d %d\n", (int)sizeof(struct p),
		(int)sizeof(struct n), (int)sizeof(struct pb),
		(int)sizeof(struct al), (int)sizeof(struct q));
	printf("%d %d %d %d %d\n", x.a, x.b, x.c,
		(int)((unsigned long)&(((struct p *)0)->b)),
		(int)(((unsigned long)&wide) % 64 == 0));
	return 0;
}
]]},

{"a section by name", [[
__attribute__((section(".mydata"))) int placed = 42;
__attribute__((section(".init.text"))) int early(void) { return 7; }
int main(void) { printf("%d %d\n", placed, early()); return 0; }
]]},

{"flexible array member", [[
struct s { int n; char b[]; };
int main(void) { printf("%d\n", (int)sizeof(struct s)); return 0; }
]]},

{"bitfields", [[
struct s { unsigned a : 3, b : 5; int c; };
struct t { int x : 4; unsigned y : 20; char z; };
struct u { unsigned char p : 2, q : 6, r : 3; };
struct v { int a : 5; int : 0; int b : 5; };
static struct s g = {5, 9, 7};
static struct t h = {-3, 1000, 'A'};
static struct s d = {.b = 9, .a = 5};
int main(void) {
	struct s x; struct t w; struct u y; struct v z;
	int k = 2;
	struct s l = {k, k + 4, k + 1};

	x.a = 5; x.b = 9; x.c = 7;
	w.x = -3; w.y = 1000; w.z = 'A';
	y.p = 3; y.q = 40; y.r = 5;
	z.a = -1; z.b = 2;
	printf("%d %d %d %d\n", x.a, x.b, x.c, (int)sizeof(struct s));
	printf("%d %u %c %d\n", w.x, w.y, w.z, (int)sizeof(struct t));
	printf("%d %d %d %d\n", y.p, y.q, y.r, (int)sizeof(struct u));
	printf("%d %d %d\n", z.a, z.b, (int)sizeof(struct v));
	x.a = 9; x.b++; --w.x; y.q += 3;
	printf("%d %d %d %d\n", x.a, x.b, w.x, y.q);
	printf("%d %d %d %d %d %d\n", g.a, g.b, g.c, h.x, d.a, d.b);
	printf("%u %d %d\n", h.y, l.a, l.b);
	return 0;
}
]]},

{"_Static_assert", [[
_Static_assert(sizeof(int) == 4, "int is four bytes");
int main(void) { printf("ok\n"); return 0; }
]]},

{"variable length array", [[
int main(void) { int n = 3; char b[n + 1];
	b[0] = 'o'; b[1] = 'k'; b[2] = 0;
	printf("%s %d\n", b, (int)sizeof b); return 0; }
]]},

{"struct by value", [[
struct p { int x, y; };
static int sum(struct p p) { return p.x + p.y; }
int main(void) { struct p a = { 3, 4 }; printf("%d\n", sum(a)); return 0; }
]]},

{"struct return", [[
struct p { int x, y; };
static struct p make(int v) { struct p p; p.x = v; p.y = v + 1; return p; }
int main(void) { struct p a = make(3); printf("%d %d\n", a.x, a.y);
	return 0; }
]]},

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
		local more = ""
		for nm, text in pairs(c.extra or {}) do
			local d = nm:match("^(.*)/[^/]*$")

			if d then os.execute("mkdir -p " .. dir .. "/" .. d) end
			local h = assert(io.open(dir .. "/" .. nm, "w"))

			h:write(text)
			h:close()
		end
		for _, d in ipairs(c.incs or {}) do
			more = more .. " -I" .. dir ..
				(d == "" and "" or "/" .. d)
		end

		local ok, out = shell(("%s %s/../cc.lua -t amd64 -I%s%s " ..
			"-I%s/../include -I%s/../include/hosted %s -o %s/t.s")
			:format(lua, here, dir, more, here, here, src, dir))
		local said, want

		if ok then
			ok, out = shell((CC .. " -w -o %s/mine %s/t.s " ..
				"%s/../rt/softfp.c %s/../rt/varargs.c")
				:format(dir, dir, here, here))
		end
		if ok then
			local _r

			_r, said = shell(dir .. "/mine")
			shell((CC .. " -w -I%s%s -o %s/ref %s")
				:format(dir, more, dir, src))
			_r, want = shell(dir .. "/ref")
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
