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

/*
 * Handing a va_list to the system library, which only works where the
 * compiler uses the system's own shape for one.  The harness that links
 * against our own tiny runtime instead does not ask for this.
 */
#if defined(__amd64__) && defined(VA_SYS)
int vsnprintf(char *, unsigned long, const char *, va_list);

long vsys(char *out, long n, const char *fmt, ...)
{
	va_list ap;
	long r;

	va_start(ap, fmt);
	r = vsnprintf(out, (unsigned long)n, fmt, ap);
	va_end(ap);
	return r;
}
#endif

/*
 * A copy taken from a va_list that arrived as a parameter.  By then it
 * has decayed to a pointer, so what has to be copied is what it points
 * at; copying the pointer variable reads the caller's frame as if it
 * were the state.  Every vfprintf in a library opens this way.
 */
static long counted(const char *fmt, va_list ap)
{
	va_list c1, c2;
	long t = 0;
	const char *p;

	__builtin_va_copy(c1, ap);
	__builtin_va_copy(c2, ap);
	for (p = fmt; *p; p++) {
		if (*p == 'd') t = t * 10 + va_arg(c1, int);
		else if (*p == 'l') t = t * 10 + (long)va_arg(c1, long long);
		else if (*p == 'f') t = t * 10 + (long)va_arg(c1, double);
	}
	/* the second copy walks it again from the start */
	for (p = fmt; *p; p++) {
		if (*p == 'd') t = t * 3 + va_arg(c2, int);
		else if (*p == 'l') t = t * 3 + (long)va_arg(c2, long long);
		else if (*p == 'f') t = t * 3 + (long)va_arg(c2, double);
	}
	va_end(c1);
	va_end(c2);
	return t;
}

static long feed(const char *fmt, ...)
{
	va_list ap;
	long r;

	va_start(ap, fmt);
	r = counted(fmt, ap);
	va_end(ap);
	return r;
}

long copies(long v)
{
	return feed("dlfd", (int)v, (long long)(v + 1), (double)(v + 2),
		    (int)(v + 3));
}
