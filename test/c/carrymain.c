/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
unsigned long carry(unsigned long);

int main(void)
{
	printf("%lx %lx %lx\n", carry(16), carry(8), carry(1));
	return 0;
}
