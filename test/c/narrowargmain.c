/* SPDX-License-Identifier: ISC */
#include <stdio.h>

long callgcc(long);

/* Built to use the registers as they come. */
__attribute__((noinline, optimize("O2")))
long gwide(signed char c, short s, unsigned char uc, unsigned short us)
{
	return (long)c * 1000000000 + (long)s * 100000 + (long)uc * 1000 +
	       (long)us;
}

int main(void)
{
	long k;

	for (k = 1; k < 4; k++)
		printf("callgcc %ld %ld\n", k, callgcc(k));
	return 0;
}
