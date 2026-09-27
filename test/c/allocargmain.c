/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int allocarg(int);

int main(void)
{
	printf("%d\n", allocarg(3));
	return 0;
}
