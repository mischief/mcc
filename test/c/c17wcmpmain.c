/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int c17wcmp(int);

int main(void)
{
	int i;

	for (i = 0; i < 7; i++)
		printf("%d\n", c17wcmp(i));
	return 0;
}
