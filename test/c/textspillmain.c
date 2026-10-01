/* SPDX-License-Identifier: ISC */
#include <stdio.h>

int nest(int, int, int);
long long wnest(signed char);

int main(void)
{
	printf("nest %d %d\n", nest(1, 2, 3), nest(-4, 5, 6));
	printf("wnest %d %d\n", (int)wnest(9), (int)wnest(-3));
	return 0;
}
