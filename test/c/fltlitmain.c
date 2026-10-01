/* SPDX-License-Identifier: ISC */
#include <stdio.h>

float lf1(void), lf2(void), lf3(void), lf4(void), lf5(void), lf6(void);
float lf7(void), lf8(void), lf9(void);

#if defined(__x86_64__)
typedef long double ld;
#else
typedef double ld;
#endif
ld ll1(void), ll2(void), ll3(void), ll4(void), ll5(void), ll6(void);
ld ll7(void), ll8(void), ll9(void);

int main(void)
{
	float (*f[])(void) = {lf1, lf2, lf3, lf4, lf5, lf6, lf7, lf8, lf9};
	ld (*l[])(void) = {ll1, ll2, ll3, ll4, ll5, ll6, ll7, ll8, ll9};
	unsigned i;

	for (i = 0; i < sizeof f / sizeof f[0]; i++)
		printf("lf%u %a\n", i + 1, f[i]());
	for (i = 0; i < sizeof l / sizeof l[0]; i++)
		printf("ll%u %La\n", i + 1, (long double)l[i]());
	return 0;
}
