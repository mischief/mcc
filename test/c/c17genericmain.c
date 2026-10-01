/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int c17generic(int);

int main(void)
{
	int i;

	for (i = 0; i < 10; i++)
		printf("%d\n", c17generic(i));
	return 0;
}
