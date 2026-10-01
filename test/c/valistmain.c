/* SPDX-License-Identifier: ISC */
#include <stdio.h>
#include <stdarg.h>

long wrap(int, ...);
long msum(int, va_list);
int fmt(char *, unsigned long, const char *, ...);

long gsum(int n, va_list ap)
{
	long t = 0;

	while (n-- > 0) {
		t = t * 10 + va_arg(ap, int);
		t += (long)va_arg(ap, double);
	}
	return t;
}

static long gwrap(int n, ...)
{
	va_list ap;
	long r;

	va_start(ap, n);
	r = msum(n, ap);
	va_end(ap);
	return r;
}

int main(void)
{
	char buf[64];
	int r;

	printf("wrap %ld\n", wrap(3, 1, 0.5, 2, 10.0, 3, 20.25));
	printf("gwrap %ld\n", gwrap(3, 1, 0.5, 2, 10.0, 3, 20.25));
	r = fmt(buf, sizeof buf, "%d %s %.2f %c", 42, "x", 2.5, 'q');
	printf("fmt %d %s\n", r, buf);
	return 0;
}
