/* variadic functions */
#include <stdarg.h>

long vsum(long n, ...)
{
	va_list ap;
	long s;
	long i;

	va_start(ap, n);
	s = 0;
	for (i = 0; i < n; i++)
		s = s * 10 + va_arg(ap, long);
	va_end(ap);
	return s;
}

long vmixed(const char *fmt, ...)
{
	va_list ap;
	long s;
	const char *p;

	va_start(ap, fmt);
	s = 0;
	for (p = fmt; *p; p++) {
		if (*p == 'i')
			s = s * 100 + va_arg(ap, int);
		else if (*p == 'l')
			s = s * 100 + va_arg(ap, long);
		else if (*p == 'p')
			s = s * 100 + *va_arg(ap, char *);
		else if (*p == 'd')
			s = s * 100 + (long)va_arg(ap, double);
	}
	va_end(ap);
	return s;
}

static long relay(const char *fmt, va_list ap)
{
	long s;
	const char *p;

	s = 0;
	for (p = fmt; *p; p++)
		s = s * 10 + va_arg(ap, long);
	return s;
}

long vrelay(const char *fmt, ...)
{
	va_list ap;
	long s;

	va_start(ap, fmt);
	s = relay(fmt, ap);
	va_end(ap);
	return s;
}
