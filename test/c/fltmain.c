#include <stdio.h>

long arith(long, long), divide(long, long), cmps(long, long);
long convs(long), consts(void), negs(long), stored(long);

int main(void)
{
	long i, j;

	for (i = -3; i <= 3; i++)
		for (j = -3; j <= 3; j++) {
			printf("arith %ld %ld %ld\n", i, j, arith(i, j));
			printf("divide %ld %ld %ld\n", i, j, divide(i, j));
			printf("cmps %ld %ld %ld\n", i, j, cmps(i, j));
		}
	for (i = -20; i <= 20; i += 7)
		printf("convs %ld %ld\n", i, convs(i));
	printf("consts %ld\n", consts());
	for (i = -5; i <= 5; i++)
		printf("negs %ld %ld\n", i, negs(i));
	for (i = 0; i <= 4; i++)
		printf("stored %ld %ld\n", i, stored(i));
	return 0;
}
