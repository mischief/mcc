/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int wideeff(int);

int main(void)
{
	printf("%d\n", wideeff(3));
	return 0;
}
