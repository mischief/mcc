#include <stdio.h>
long loads(void), adds(void), swaps(void), signed_adds(void);
long narrow(void), compares(void), flags(void), bits(void), parens(void);

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
	return 0;
}
