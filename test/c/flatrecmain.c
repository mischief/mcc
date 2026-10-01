/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct FP { float f; void *p; };
struct FL { float f; long l; };
union UD { double d; };
union UI { int i; double d; };
struct DF { double d; float f; };

long flat(struct FP, struct FL, union UD, union UI, struct DF, double);
long callgcc(long);

long gflat(struct FP a, struct FL b, union UD c, union UI d, struct DF e,
	   double x)
{
	return (long)a.f + (long)a.p * 10 + (long)b.f * 100 + b.l * 1000 +
	       (long)c.d * 10000 + d.i * 100000L + (long)e.d * 1000000L +
	       (long)e.f * 10000000L + (long)x * 100000000L;
}

int main(void)
{
	struct FP a = {1, (void *)2};
	struct FL b = {3, 4};
	union UD c = {5};
	union UI d = {6};
	struct DF e = {7, 8};
	long k;

	for (k = 1; k < 3; k++) {
		a.f = k;
		printf("flat %ld\n", flat(a, b, c, d, e, 9));
		printf("callgcc %ld\n", callgcc(k));
	}
	return 0;
}
