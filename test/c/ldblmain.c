#include <stdio.h>
#include <stdarg.h>

long arith(long), cmps(long), nans(long), convs(long), range(long);
long stored(long), many(long), roots(long), asmst(long);

static long double vsum(int n, ...)
{
	va_list ap;
	long double t = 0.0L;
	int i;

	va_start(ap, n);
	for (i = 0; i < n; i++)
		t += va_arg(ap, long double);
	va_end(ap);
	return t;
}

int main(void)
{
	long i;

	for (i = -3; i <= 3; i++) {
		printf("arith %ld %ld\n", i, arith(i));
		printf("cmps %ld %ld\n", i, cmps(i));
		printf("nans %ld %ld\n", i, nans(i));
		printf("convs %ld %ld\n", i, convs(i));
		printf("range %ld %ld\n", i, range(i));
		printf("many %ld %ld\n", i, many(i));
		printf("roots %ld %ld\n", i, roots(i));
		printf("asmst %ld %ld\n", i, asmst(i));
	}
	for (i = 0; i <= 4; i++)
		printf("stored %ld %ld\n", i, stored(i));
	printf("vsum %ld\n",
	       (long)(vsum(4, 1.0L, 2.5L, 3.25L, 4.125L) * 1000.0L));
	printf("sizes %zu %zu %d\n", sizeof(long double),
	       _Alignof(long double), __LDBL_MANT_DIG__);
	return 0;
}
