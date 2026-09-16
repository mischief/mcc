#include <stdio.h>

long sum(long), fact(long), slen(char *), copy(char *, char *);
long classify(long), bits(long, long), divmod(long, long), fill(long);
long buffered(void), bump(long), ternlike(long);
extern long counter;

int main(void)
{
	long i;
	char buf[32];

	for (i = 0; i <= 12; i++)
		printf("sum %ld %ld\n", i, sum(i));
	for (i = 0; i <= 10; i++)
		printf("fact %ld %ld\n", i, fact(i));
	printf("slen %ld %ld %ld\n", slen(""), slen("a"), slen("hello world"));
	printf("copy %ld %s\n", copy(buf, "the quick brown fox"), buf);
	for (i = -12; i <= 101; i += 17)
		printf("classify %ld %ld\n", i, classify(i));
	printf("bits %ld %ld %ld\n", bits(0, 0), bits(12345, 678), bits(-5, 3));
	printf("divmod %ld %ld %ld\n", divmod(100, 7), divmod(-100, 7),
		divmod(100, -7));
	for (i = 0; i <= 8; i++)
		printf("fill %ld %ld\n", i, fill(i));
	printf("buffered %ld\n", buffered());
	for (i = 1; i <= 4; i++)
		printf("bump %ld %ld\n", i, bump(i));
	printf("counter %ld\n", counter);
	for (i = 0; i <= 40; i += 7)
		printf("ternlike %ld %ld\n", i, ternlike(i));
	return 0;
}
