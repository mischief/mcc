/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
int narrow(int, int);

int main(void)
{
	printf("%d %d %d %d %d\n", narrow(200, 0), narrow(200, 1),
	    narrow(40000, 2), narrow(40000, 3), narrow(200, 4));
	return 0;
}
