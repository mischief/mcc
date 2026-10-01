/* SPDX-License-Identifier: ISC */
#include <stdio.h>

unsigned short lc1(void);
long lc2(void), lc11(void);
int lc3(void), lc12(void);
unsigned lc4(void);
double lc5(void), lc7(void), lc8(void), lc9(void);
float lc6(void);
unsigned long lc10(void);

int main(void)
{
	printf("%u %ld %d %u\n", lc1(), lc2(), lc3(), lc4());
	printf("%a %a %a %a %a\n", lc5(), lc6(), lc7(), lc8(), lc9());
	printf("%lu %ld %d\n", lc10(), lc11(), lc12());
	return 0;
}
