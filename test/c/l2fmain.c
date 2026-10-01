/* SPDX-License-Identifier: ISC */
#include <stdio.h>

float sl2f(long long), ul2f(unsigned long long);

static const unsigned long long v[] = {
	0x4000004000000001ULL, 0x4000004000000000ULL, 0x400000bfffffffffULL,
	0x8000008000000001ULL, 0xffffff7fffffffffULL, 0xffffff8000000000ULL,
	0x20000020000001ULL, 1, 0, 0x7fffffffffffffffULL,
};

int main(void)
{
	unsigned i;

	for (i = 0; i < sizeof v / sizeof v[0]; i++)
		printf("%a %a\n", sl2f((long long)v[i]), ul2f(v[i]));
	return 0;
}
