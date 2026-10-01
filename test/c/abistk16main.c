/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct Q { _Alignas(16) long a; long b; };
struct R { _Alignas(16) long a; long b; char c[20]; };

long q(long, long, long, long, long, long, long, long, long,
       struct Q, struct R, long);
long callgcc(long);

long gq(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
	long a7, long a8, struct Q x, struct R y, long z)
{
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 * 3 +
	       x.a * 5 + x.b * 7 + y.a * 11 + y.b * 13 + y.c[19] * 17 +
	       z * 19;
}

int main(void)
{
	long k;

	for (k = 1; k < 4; k++) {
		struct Q x = {k * 10, k * 20};
		struct R y = {k * 30, k * 40};

		y.c[19] = 2;
		printf("q %ld %ld\n", k, q(1, 2, 3, 4, 5, 6, 7, 8, k, x, y, 9));
		printf("callgcc %ld %ld\n", k, callgcc(k));
	}
	return 0;
}
