/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct P { long a, b; };
struct F { double x, y; };

long p(long, long, long, long, long, long, long, long, struct P,
       struct F, struct P);
long callgcc(long);

long gp(long a0, long a1, long a2, long a3, long a4, long a5, long a6,
	long a7, struct P x, struct F f, struct P y)
{
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 * 3 + x.a * 5 +
	       x.b * 7 + (long)f.x * 11 + (long)f.y * 13 + y.a * 17 +
	       y.b * 19;
}

int main(void)
{
	long k;

	for (k = 1; k < 4; k++) {
		struct P x = {k * 10, k * 20}, y = {k * 30, k * 40};
		struct F f = {k * 50, k * 60};

		printf("p %ld %ld\n", k, p(1, 2, 3, 4, 5, 6, 7, k, x, f, y));
		printf("callgcc %ld %ld\n", k, callgcc(k));
	}
	return 0;
}
