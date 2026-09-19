#include <stdio.h>

long sizes(void), kinds(void), member(void), chain(void), unions(void);
long pick(long), jumps(long), tern(long, long), casts(void), steps(void);
long indirect(long, long);
long callmany(long);
long rows(long);
long enums(long);

int main(void)
{
	long i, j;

	printf("sizes %ld\n", sizes());
	printf("kinds %ld\n", kinds());
	printf("member %ld\n", member());
	printf("chain %ld\n", chain());
	printf("unions %ld\n", unions());
	for (i = -1; i <= 11; i++)
		printf("pick %ld %ld\n", i, pick(i));
	for (i = 0; i <= 6; i++)
		printf("jumps %ld %ld\n", i, jumps(i));
	for (i = -2; i <= 2; i++)
		for (j = -2; j <= 2; j++)
			printf("tern %ld %ld %ld\n", i, j, tern(i, j));
	printf("casts %ld\n", casts());
	printf("steps %ld\n", steps());
	for (i = -2; i <= 3; i++)
		printf("indirect %ld %ld\n", i, indirect(i, i + 2));
	for (i = 0; i <= 3; i++)
		printf("callmany %ld %ld\n", i, callmany(i));
	for (i = -2; i <= 3; i++)
		printf("rows %ld %ld\n", i, rows(i));
	for (i = -2; i <= 2; i++)
		printf("enums %ld %ld\n", i, enums(i));
	return 0;
}
