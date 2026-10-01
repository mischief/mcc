/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int cmpconst(int);

int main(void)
{
	printf("%d\n", cmpconst(10));
	return 0;
}
