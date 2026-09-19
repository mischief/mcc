/* SPDX-License-Identifier: 0BSD */
/*
 * Just enough output for a program built by this compiler alone: no libc,
 * one write per line.  %d %ld %lld %u %lu %llu %x %s %c and %% only.
 */
#include <stdarg.h>

long __syscall(long n, long a, long b, long c);

static char obuf[512];
static int olen;

static void flush(void)
{
	if (olen > 0) __syscall(64, 1, (long)obuf, olen);
	olen = 0;
}

static void put(int c)
{
	obuf[olen++] = (char)c;
	if (olen == (int)sizeof obuf || c == '\n') flush();
}

static void putstr(const char *s)
{
	while (*s) put(*s++);
}

static void putnum(unsigned long long v, int base, int neg)
{
	char t[24];
	int n = 0;

	do {
		int d = (int)(v % (unsigned long long)base);
		t[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
		v /= (unsigned long long)base;
	} while (v != 0);
	if (neg) put('-');
	while (n > 0) put(t[--n]);
}

int printf(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	while (*fmt) {
		int longs = 0;
		if (*fmt != '%') {
			put(*fmt++);
			continue;
		}
		fmt++;
		while (*fmt == 'l') { longs++; fmt++; }
		if (*fmt == 'd' || *fmt == 'i') {
			/* one l is a long, which on a 32-bit machine is
			 * a word narrower than a long long */
			long long v = longs > 1 ? va_arg(ap, long long)
				: longs == 1 ? (long long)va_arg(ap, long)
				: (long long)va_arg(ap, int);
			putnum(v < 0 ? (unsigned long long)-v
				     : (unsigned long long)v, 10, v < 0);
		} else if (*fmt == 'u') {
			unsigned long long v = longs > 1
				? va_arg(ap, unsigned long long)
				: longs == 1
				? (unsigned long long)va_arg(ap, unsigned long)
				: (unsigned long long)va_arg(ap, unsigned);
			putnum(v, 10, 0);
		} else if (*fmt == 'x') {
			unsigned long long v = longs > 1
				? va_arg(ap, unsigned long long)
				: longs == 1
				? (unsigned long long)va_arg(ap, unsigned long)
				: (unsigned long long)va_arg(ap, unsigned);
			putnum(v, 16, 0);
		} else if (*fmt == 's') {
			putstr(va_arg(ap, char *));
		} else if (*fmt == 'c') {
			put(va_arg(ap, int));
		} else {
			put(*fmt);
		}
		fmt++;
	}
	va_end(ap);
	flush();
	return 0;
}
