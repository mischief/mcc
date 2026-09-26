/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
unsigned long long carry(unsigned long);

int main(void)
{
	printf("%llx %llx %llx\n", carry(16), carry(8), carry(1));
	return 0;
}
