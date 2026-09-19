#include <stdio.h>

long sizes(void), carry(long);

int main(void)
{
	long i;

	printf("sizes %ld\n", sizes());
	for (i = -3; i <= 3; i++)
		printf("carry %ld %ld\n", i, carry(i));
	return 0;
}
