/* SPDX-License-Identifier: ISC */
/* A va_list crosses between this compiler's code and gcc's, both
   ways, which works where it has the system's shape. */
#include <stdarg.h>

long gsum(int n, va_list ap);
int vsnprintf(char *, unsigned long, const char *, va_list);

/* A list built here, read by gcc. */
long wrap(int n, ...)
{
	va_list ap, aq;
	long r;

	va_start(ap, n);
	va_copy(aq, ap);
	r = gsum(n, ap) * 1000 + gsum(n, aq);
	va_end(aq);
	va_end(ap);
	return r;
}

/* A list gcc built, read here. */
long msum(int n, va_list ap)
{
	long t = 0;

	while (n-- > 0) {
		t = t * 10 + va_arg(ap, int);
		t += (long)va_arg(ap, double);
	}
	return t;
}

int fmt(char *buf, unsigned long n, const char *f, ...)
{
	va_list ap;
	int r;

	va_start(ap, f);
	r = vsnprintf(buf, n, f, ap);
	va_end(ap);
	return r;
}
