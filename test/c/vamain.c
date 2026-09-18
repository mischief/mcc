#include <stdio.h>
long vsum(long, ...);
long vmixed(const char *, ...);
long vrelay(const char *, ...);
#ifdef __amd64__
long vsys(char *, long, const char *, ...);
#endif
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
#ifdef __amd64__
	{
		char b[128];
		long r = vsys(b, (long)sizeof b,
			"%d %s %.2f %lld %d %d %d %d %g %g %g %g %g %g %g %g",
			1, "x", 2.5, 3LL, 4, 5, 6, 7,
			1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5);

		printf("vsys %ld %s\n", r, b);
	}
#endif
	return 0;
}
