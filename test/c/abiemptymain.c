/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct E { };
struct Z { int z[0]; };

struct E empty(int, struct E, int);
long sum(struct E, long, struct Z, struct E, long);
long callgcc(int);
long seen;

struct E gempty(int a, struct E e, int b, struct Z z, int c)
{
	seen = seen * 7 + a * 3 + b * 2 + c;
	return e;
}

long gsum(struct E a, int x, struct E b, int y)
{
	return x * 1000 + y;
}

int main(void)
{
	struct E e;
	struct Z z;
	int k;

	for (k = 1; k < 4; k++) {
		empty(k, e, 9);
		printf("empty %d %ld\n", k, seen);
		printf("sum %d %ld\n", k, sum(e, k, z, e, 5));
		printf("callgcc %d %ld %ld\n", k, callgcc(k), seen);
	}
	return 0;
}
