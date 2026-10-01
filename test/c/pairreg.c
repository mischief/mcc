/* SPDX-License-Identifier: ISC */
/* Arguments that want a register pair, or more registers than are
   left: on arm64 a record aligned to sixteen starts on an even x
   register, and one that does not fit closes its file to the rest. */

struct Q { _Alignas(16) long x; long y; };
struct P { long a, b; };
struct D { double a, b; };

long q(int a, struct Q b, long c)
{
	return a + b.x * 10 + b.y * 100 + c * 1000;
}

long p(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
       struct P b, long c)
{
	return a0 + a6 * 3 + b.a * 10 + b.b * 100 + c * 1000;
}

double d(double a0, double a1, double a2, double a3, double a4,
	 double a5, double a6, struct D b, double c)
{
	return a0 + a6 * 3 + b.a * 10 + b.b * 100 + c * 1000;
}

#ifdef __SIZEOF_INT128__
long w(int a, __int128 b, long c)
{
	return a + (long)b * 10 + (long)(b >> 64) * 100 + c * 1000;
}

long w7(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
	__int128 b, long c)
{
	return a0 + a6 * 3 + (long)b * 10 + (long)(b >> 64) * 100 + c * 1000;
}
#endif

long gq(int, struct Q, long);
long gp(long, long, long, long, long, long, long, struct P, long);
double gd(double, double, double, double, double, double, double,
	  struct D, double);

long callgcc(long k)
{
	struct Q b = {k, k + 1};
	struct P e = {k + 2, k + 3};
	struct D f = {k + 4, k + 5};

	return gq(1, b, 2) + gp(1, 2, 3, 4, 5, 6, 7, e, 8) * 7 +
	       (long)gd(1, 2, 3, 4, 5, 6, 7, f, 8) * 11;
}
