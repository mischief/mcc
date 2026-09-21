/* SPDX-License-Identifier: ISC */
#include <stdio.h>
long loads(void), adds(void), swaps(void), signed_adds(void);
long narrow(void), compares(void), flags(void), bits(void), parens(void);
long syncs(void), syncs2(void);
long syncwidths(void), syncwidths2(void);
long syncptrs(void), synconce(void);
long atomics1(void), atomics2(void), atomics3(void);

int main(void)
{
	printf("loads %ld\n", loads());
	printf("adds %ld\n", adds());
	printf("swaps %ld\n", swaps());
	printf("signed %ld\n", signed_adds());
	printf("narrow %ld\n", narrow());
	printf("compares %ld\n", compares());
	printf("flags %ld\n", flags());
	printf("bits %ld\n", bits());
	printf("parens %ld\n", parens());
	printf("syncs %ld %ld\n", syncs(), syncs2());
	printf("syncw %ld\n", syncwidths());
	printf("syncw2 %ld\n", syncwidths2());
	printf("syncp %ld\n", syncptrs());
	printf("synco %ld\n", synconce());
	printf("atom1 %ld\n", atomics1());
	printf("atom2 %ld\n", atomics2());
	printf("atom3 %ld\n", atomics3());
	return 0;
}
