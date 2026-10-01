/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int c17sizes(int);
long long c17chr(int);

int main(void)
{
	int i;

	for (i = 0; i < 4; i++)
		printf("%d ", c17sizes(i));
	printf("\n");
	for (i = 0; i < 11; i++)
		printf("%lld\n", c17chr(i));
	return 0;
}
