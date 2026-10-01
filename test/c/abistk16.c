/* SPDX-License-Identifier: ISC */
/* A record aligned past the word keeps that alignment where it lands
   on the stack, once the argument registers are full. */

struct Q { _Alignas(16) long a; long b; };
struct R { _Alignas(16) long a; long b; char c[20]; };

long gq(long, long, long, long, long, long, long, long, long,
	struct Q, struct R, long);

long q(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
       long a7, long a8, struct Q x, struct R y, long z)
{
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 * 3 +
	       x.a * 5 + x.b * 7 + y.a * 11 + y.b * 13 + y.c[19] * 17 +
	       z * 19;
}

long callgcc(long k)
{
	struct Q x = {k, k + 1};
	struct R y = {k + 2, k + 3};

	y.c[19] = 4;
	return gq(1, 2, 3, 4, 5, 6, 7, 8, k, x, y, 9);
}
