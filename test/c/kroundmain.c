/* SPDX-License-Identifier: ISC */
#include <stdio.h>

float kf1(void), kf2(void), kf3(void), kf4(void), kf5(void);
double kd1(void), kd2(void), kd3(void);
#if defined(__x86_64__)
long double kx1(void), kx2(void);
#else
double kx1(void), kx2(void);
#endif

int main(void)
{
	printf("%a %a %a %a %a\n", kf1(), kf2(), kf3(), kf4(), kf5());
	printf("%a %a %a\n", kd1(), kd2(), kd3());
	printf("%La %La\n", (long double)kx1(), (long double)kx2());
	return 0;
}
