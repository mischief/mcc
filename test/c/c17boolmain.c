/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int c17bool(int);

int main(void)
{
	int i;

	for (i = 0; i < 16; i++)
		printf("%d %d\n", i, c17bool(i));
	return 0;
}
