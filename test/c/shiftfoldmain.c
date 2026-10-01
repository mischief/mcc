/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
long long shiftfold(int);

int main(void)
{
	printf("%lld %lld\n", shiftfold(0), shiftfold(5));
	return 0;
}
