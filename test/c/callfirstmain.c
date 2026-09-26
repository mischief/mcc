/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int callfirst(int);
int callafter(void);
int callix(void);

int main(void)
{
	callfirst(54);
	printf("%d %d\n", callix(), callafter());
	return 0;
}
