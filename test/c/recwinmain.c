/* SPDX-License-Identifier: ISC */
#include <stdarg.h>
#include <stdio.h>

struct C3 { char c[3]; };
struct C7 { char c[7]; };
struct S5 { short s[5]; };
struct I6 { int v[6]; };
struct I7 { int v[7]; };
struct L2 { long long x; int y; };
struct A16 { _Alignas(16) int a; int b; };
struct Big { int v[12]; };

int c3sum(struct C3);
int mix(int, struct C3, struct C7, struct S5);
int over(int, int, struct I6, int);
int seven(struct I7, int);
int pair(int, struct L2, int);
int quad(int, struct A16, int);
int big(int, int, int, int, int, int, struct Big, int);
struct C3 retc3(int);
struct C7 retc7(int);
struct I6 reti6(int);
struct L2 retl2(int);
int vrec(int, ...);
int callgcc(int);
int copies(int);

static int gc3sum(struct C3 a) { return a.c[0] + a.c[1] * 3 + a.c[2] * 5; }

int gmix(int a, struct C3 b, struct C7 c, struct S5 d)
{
	return a + gc3sum(b) * 7 + (c.c[0] + c.c[6]) * 11 +
	       (d.s[0] + d.s[4]) * 13;
}

int gover(int a, int b, struct I6 c, int d)
{
	return a + b * 3 + (c.v[0] + c.v[5]) * 5 + d * 7;
}

int gseven(struct I7 a, int b)
{
	return a.v[0] + a.v[6] * 3 + b * 5;
}

int gpair(int a, struct L2 b, int c)
{
	return a + (int)b.x * 3 + b.y * 5 + c * 7;
}

int gquad(int a, struct A16 b, int c)
{
	return a + b.a * 3 + b.b * 5 + c * 7;
}

int gbig(int a, int b, int c, int d, int e, int f, struct Big g, int h)
{
	return a + f * 3 + g.v[0] * 5 + g.v[11] * 7 + h * 11;
}

struct C7 gretc7(int k) { struct C7 r = {{k, 2, 3, 4, 5, 6, k + 6}}; return r; }
struct I6 greti6(int k) { struct I6 r = {{k, 2, 3, 4, 5, k + 5}}; return r; }

int gvrec(int n, ...)
{
	va_list ap;
	int t = 0;

	va_start(ap, n);
	while (n-- > 0) {
		struct A16 q = va_arg(ap, struct A16);
		struct C3 c = va_arg(ap, struct C3);
		struct L2 l = va_arg(ap, struct L2);

		t = t * 7 + q.a + q.b * 3 + gc3sum(c) * 5 + (int)l.x + l.y;
	}
	va_end(ap);
	return t;
}

int main(void)
{
	struct C3 b[3] = {{{1, 2, 3}}, {{4, 5, 6}}, {{7, 8, 9}}};
	struct C7 c = {{9, 1, 2, 3, 4, 5, 6}};
	struct S5 d = {{8, 2, 3, 4, 9}};
	struct I6 e = {{7, 2, 3, 4, 5, 6}};
	struct I7 f = {{6, 2, 3, 4, 5, 6, 7}};
	struct L2 g = {500, 3};
	struct A16 h = {5, 4};
	struct Big m = {{4, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}};
	struct C3 r3 = retc3(10);
	struct C7 r7 = retc7(20);
	struct I6 r6 = reti6(30);
	struct L2 rl = retl2(40);

	printf("mix %d\n", mix(1, b[1], c, d));
	printf("over %d\n", over(1, 2, e, 3));
	printf("seven %d\n", seven(f, 4));
	printf("pair %d\n", pair(1, g, 2));
	printf("quad %d\n", quad(1, h, 2));
	printf("big %d\n", big(1, 2, 3, 4, 5, 6, m, 7));
	printf("ret %d %d %d %d %d %d %d\n", r3.c[0], r3.c[2], r7.c[0],
	       r7.c[6], r6.v[0], r6.v[5], (int)rl.x + rl.y);
	printf("vrec %d\n", vrec(2, h, b[2], g, h, b[0], g));
	printf("callgcc %d\n", callgcc(3));
	printf("copies %d\n", copies(9));
	return 0;
}
