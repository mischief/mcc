/* SPDX-License-Identifier: ISC */
#include <stdio.h>
#include <string.h>

int nlit(void);
long double lit(int);

int main(void)
{
	int i;

	for (i = -1; i < nlit(); i++) {
		long double v = lit(i);
		unsigned long long lo;
		unsigned short se;

		memcpy(&lo, &v, 8);
		memcpy(&se, (char *)&v + 8, 2);
		printf("%d %016llx %04x\n", i, lo, se);
	}
	return 0;
}
