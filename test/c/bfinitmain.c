/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
unsigned bfinit(int);

int main(void)
{
	printf("%u %u %u\n", bfinit(0), bfinit(1), bfinit(-2301));
	return 0;
}
