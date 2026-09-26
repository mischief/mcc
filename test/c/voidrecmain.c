/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int voidrec(void);

int main(void)
{
	printf("%d\n", voidrec());
	return 0;
}
