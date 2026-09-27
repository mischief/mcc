/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int readonce(int);

int main(void)
{
	printf("%d %d\n", readonce(0), readonce(7));
	return 0;
}
