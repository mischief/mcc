/* SPDX-License-Identifier: ISC */
#include <stdio.h>

#if defined(__x86_64__)
typedef long double ld;
#else
typedef double ld;
#endif
ld lk1(void), lk2(void), lk3(void), lk4(void), lk5(void), lk6(void);
ld lk7(void), lk8(void), lk9(void), lk10(void);

int main(void)
{
	ld (*k[])(void) = {lk1, lk2, lk3, lk4, lk5, lk6, lk7, lk8, lk9, lk10};
	unsigned i;

	for (i = 0; i < sizeof k / sizeof k[0]; i++)
		printf("lk%u %La\n", i + 1, (long double)k[i]());
	return 0;
}
