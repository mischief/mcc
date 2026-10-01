/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
unsigned elide(int);

int main(void)
{
	printf("%u %u\n", elide(0), elide(100));
	return 0;
}
