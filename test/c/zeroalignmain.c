/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct Z { _Alignas(16) char m[0]; };

long za(int, int, int, int, int, int, int, int, int, struct Z, int);
long callgcc(long);

long gza(int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7,
	 int a8, struct Z z, int a9)
{
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 * 10 + a9 * 100;
}

int main(void)
{
	struct Z z;
	long k;

	for (k = 1; k < 3; k++) {
		printf("za %ld\n", za(1, 1, 1, 1, 1, 1, 1, 1, (int)k, z, 4));
		printf("callgcc %ld\n", callgcc(k));
	}
	return 0;
}
