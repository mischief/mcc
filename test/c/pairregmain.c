/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct Q { _Alignas(16) long x; long y; };
struct P { long a, b; };
struct D { double a, b; };

long q(int, struct Q, long);
long p(long, long, long, long, long, long, long, struct P, long);
double d(double, double, double, double, double, double, double,
	 struct D, double);
#ifdef __SIZEOF_INT128__
long w(int, __int128, long);
long w7(long, long, long, long, long, long, long, __int128, long);
#endif
long callgcc(long);

long gq(int a, struct Q b, long c)
{
	return a + b.x * 10 + b.y * 100 + c * 1000;
}

long gp(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
	struct P b, long c)
{
	return a0 + a6 * 3 + b.a * 10 + b.b * 100 + c * 1000;
}

double gd(double a0, double a1, double a2, double a3, double a4,
	  double a5, double a6, struct D b, double c)
{
	return a0 + a6 * 3 + b.a * 10 + b.b * 100 + c * 1000;
}

int main(void)
{
	long k;

	for (k = 1; k < 3; k++) {
		struct Q b = {k, k + 1};
		struct P e = {k + 2, k + 3};
		struct D f = {k + 4, k + 5};

		printf("q %ld\n", q(1, b, 2));
		printf("p %ld\n", p(1, 2, 3, 4, 5, 6, 7, e, 8));
		printf("d %.1f\n", d(1, 2, 3, 4, 5, 6, 7, f, 8));
#ifdef __SIZEOF_INT128__
		printf("w %ld\n", w(1, ((__int128)k << 64) | 5, 2));
		printf("w7 %ld\n", w7(1, 2, 3, 4, 5, 6, 7,
				      ((__int128)k << 64) | 5, 2));
#endif
		printf("callgcc %ld\n", callgcc(k));
	}
	return 0;
}
