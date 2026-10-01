/* SPDX-License-Identifier: ISC */
/* How x86-64 classes an eightbyte: one only padding takes no register,
   and an __int128 member makes both of its eightbytes integer. */
#include <stdarg.h>

struct Pad { _Alignas(16) char c; };
struct Pad2 { _Alignas(16) short s; char t; };

long pad(struct Pad a, int b, struct Pad2 c, long d)
{
	return a.c * 1000 + b * 100 + c.s * 10 + c.t + d;
}

long vpad(int n, ...)
{
	va_list ap;
	long t = 0;

	va_start(ap, n);
	while (n-- > 0) {
		struct Pad p = va_arg(ap, struct Pad);

		t = t * 10 + p.c + va_arg(ap, int);
	}
	va_end(ap);
	return t;
}

#ifdef __SIZEOF_INT128__
union W { __int128 i; double d[2]; };

long wide(union W w, double x)
{
	return (long)(w.i >> 64) * 10 + (long)w.i + (long)x;
}
#endif
