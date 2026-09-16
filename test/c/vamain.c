#include <stdio.h>
long vsum(long, ...);
long vmixed(const char *, ...);
long vrelay(const char *, ...);
int main(void)
{
	printf("vsum0 %ld\n", vsum(0));
	printf("vsum1 %ld\n", vsum(1, 7L));
	printf("vsum3 %ld\n", vsum(3, 1L, 2L, 3L));
	printf("vsum8 %ld\n", vsum(8, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L));
	printf("vsum12 %ld\n", vsum(12, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L,
		1L, 2L, 3L));
	printf("vmixed %ld\n", vmixed("ilp", 11, 22L, "3"));
	printf("vmixed2 %ld\n", vmixed("iiiiiiii", 1, 2, 3, 4, 5, 6, 7, 8));
	printf("vrelay %ld\n", vrelay("xxx", 4L, 5L, 6L));
	return 0;
}
