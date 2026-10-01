/* SPDX-License-Identifier: ISC */
/* Records by value both ways, of every size the registers take and
   some they do not: one past the registers closes them to the rest,
   one aligned past a word starts on a register to match, and one
   aligned to a byte may sit anywhere. */
#include <stdarg.h>

struct C3 { char c[3]; };
struct C7 { char c[7]; };
struct S5 { short s[5]; };
struct I6 { int v[6]; };
struct I7 { int v[7]; };
struct L2 { long long x; int y; };
struct A16 { _Alignas(16) int a; int b; };
struct Big { int v[12]; };

int c3sum(struct C3 a) { return a.c[0] + a.c[1] * 3 + a.c[2] * 5; }

int mix(int a, struct C3 b, struct C7 c, struct S5 d)
{
	return a + c3sum(b) * 7 + (c.c[0] + c.c[6]) * 11 +
	       (d.s[0] + d.s[4]) * 13;
}

int over(int a, int b, struct I6 c, int d)
{
	return a + b * 3 + (c.v[0] + c.v[5]) * 5 + d * 7;
}

int seven(struct I7 a, int b)
{
	return a.v[0] + a.v[6] * 3 + b * 5;
}

int pair(int a, struct L2 b, int c)
{
	return a + (int)b.x * 3 + b.y * 5 + c * 7;
}

int quad(int a, struct A16 b, int c)
{
	return a + b.a * 3 + b.b * 5 + c * 7;
}

int big(int a, int b, int c, int d, int e, int f, struct Big g, int h)
{
	return a + f * 3 + g.v[0] * 5 + g.v[11] * 7 + h * 11;
}

struct C3 retc3(int k) { struct C3 r = {{k, k + 1, k + 2}}; return r; }
struct C7 retc7(int k) { struct C7 r = {{k, 2, 3, 4, 5, 6, k + 6}}; return r; }
struct I6 reti6(int k) { struct I6 r = {{k, 2, 3, 4, 5, k + 5}}; return r; }
struct L2 retl2(int k) { struct L2 r = {(long long)k << 20, k + 1}; return r; }

int vrec(int n, ...)
{
	va_list ap;
	int t = 0;

	va_start(ap, n);
	while (n-- > 0) {
		struct A16 q = va_arg(ap, struct A16);
		struct C3 c = va_arg(ap, struct C3);
		struct L2 l = va_arg(ap, struct L2);

		t = t * 7 + q.a + q.b * 3 + c3sum(c) * 5 + (int)l.x + l.y;
	}
	va_end(ap);
	return t;
}

/* Copies of data aligned to less than a word, which a machine that
   faults on an unaligned load must move in pieces. */
int copies(int k)
{
	short s[5] = {1, 2, 3, 4, k};
	char c[3] = {5, 6, 7};
	struct C3 b[3] = {{{1, 2, 3}}, {{4, 5, 6}}, {{7, 8, k}}};

	b[1] = b[2];
	b[0] = b[1];
	return s[0] + s[4] * 3 + c[2] * 5 + c3sum(b[0]) * 7;
}

/* The other way: gcc's functions called from here. */
int gmix(int, struct C3, struct C7, struct S5);
int gover(int, int, struct I6, int);
int gseven(struct I7, int);
int gpair(int, struct L2, int);
int gquad(int, struct A16, int);
int gbig(int, int, int, int, int, int, struct Big, int);
struct C7 gretc7(int);
struct I6 greti6(int);
int gvrec(int, ...);

static int down(int n)
{
	return n ? down(n - 1) + 1 : 0;
}

int callgcc(int k)
{
	struct C3 b[3] = {{{1, 2, 3}}, {{4, 5, 6}}, {{7, 8, 9}}};
	struct C7 c = {{k, 1, 2, 3, 4, 5, 6}};
	struct S5 d = {{k, 2, 3, 4, 9}};
	struct I6 e = {{k, 2, 3, 4, 5, 6}};
	struct I7 f = {{k, 2, 3, 4, 5, 6, 7}};
	struct L2 g = {(long long)k << 8, 3};
	struct A16 h = {k, 4};
	struct Big m = {{k, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}};
	int t;

	/* b[1] is at an odd address, and deep calls spill the caller. */
	t = down(k + 20);
	t += gmix(1, b[1], c, d);
	t = t * 3 + gover(1, 2, e, 3);
	t = t * 3 + gseven(f, 4);
	t = t * 3 + gpair(1, g, 2);
	t = t * 3 + gquad(1, h, 2);
	t = t * 3 + gbig(1, 2, 3, 4, 5, 6, m, 7);
	t = t * 3 + gretc7(k).c[6] + greti6(k).v[5];
	t = t * 3 + gvrec(2, h, b[2], g, h, b[0], g);
	return t;
}
