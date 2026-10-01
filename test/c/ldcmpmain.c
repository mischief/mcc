/* SPDX-License-Identifier: ISC */
#include <stdio.h>

double lq1(void), lq2(void);
int lq3(void), lq4(void), lq5(void), lq6(void), lq7(void);

int main(void)
{
	printf("%g %g %d %d %d %d %d\n", lq1(), lq2(), lq3(), lq4(), lq5(),
	       lq6(), lq7());
	return 0;
}
