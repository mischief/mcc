/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
long long c17enum(int);

int main(void)
{
	int i;

	for (i = 0; i < 10; i++)
		printf("%lld\n", c17enum(i));
	return 0;
}
