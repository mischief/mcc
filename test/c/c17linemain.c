/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
extern int c17ln0, c17ln1, c17ln2, c17ln3, c17ln4;
extern const char *c17fn1, *c17fn2;

int main(void)
{
	printf("%d %d %d %d %d\n", c17ln0, c17ln1, c17ln2, c17ln3, c17ln4);
	printf("%s %s\n", c17fn1, c17fn2);
	return 0;
}
