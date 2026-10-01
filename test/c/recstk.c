/* SPDX-License-Identifier: ISC */
/* A record small enough for registers, met once they are all taken,
   is copied onto the stack. */

struct P { long a, b; };
struct F { double x, y; };

long gp(long, long, long, long, long, long, long, long, struct P,
	struct F, struct P);

long p(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
       long a7, struct P x, struct F f, struct P y)
{
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 * 3 + x.a * 5 +
	       x.b * 7 + (long)f.x * 11 + (long)f.y * 13 + y.a * 17 +
	       y.b * 19;
}

long callgcc(long k)
{
	struct P x = {k, k + 1}, y = {k + 2, k + 3};
	struct F f = {k + 4, k + 5};

	return gp(1, 2, 3, 4, 5, 6, 7, k, x, f, y);
}
