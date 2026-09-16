#include <stdio.h>
long sums(void), strs(void), recs(void), ptrs(void), floats(void);
long statics(long), locals(void);
int main(void)
{
	long i;
	printf("sums %ld\n", sums());
	printf("strs %ld\n", strs());
	printf("recs %ld\n", recs());
	printf("ptrs %ld\n", ptrs());
	printf("floats %ld\n", floats());
	for (i = 0; i < 8; i++)
		printf("statics %ld %ld\n", i, statics(i));
	printf("locals %ld\n", locals());
	printf("locals %ld\n", locals());
	return 0;
}
