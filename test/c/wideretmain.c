/* SPDX-License-Identifier: ISC */
#include <stdio.h>

#ifdef __SIZEOF_INT128__
typedef unsigned __int128 W;
#else
typedef unsigned long long W;
#endif

long callgcc(int);

W gwide(int k)
{
	W w = 0x714fe392c20b557eULL;

	return (w << (sizeof(W) * 4)) + 0xeeb4131185c4cbcbULL + k;
}

int main(void)
{
	int k;

	for (k = 1; k < 3; k++)
		printf("callgcc %ld\n", callgcc(k));
	return 0;
}
