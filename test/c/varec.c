/* SPDX-License-Identifier: ISC */
/* va_arg of a record that holds floating point: on x86-64 its pieces
   come from both register files, and from the stack once either is
   full. */
#include <stdarg.h>

struct DL { double d; long l; };
struct FFI { float a, b; int c; };
struct DD { double x, y; };
struct LD { long l; double d; };

long walk(int n, ...)
{
	va_list ap;
	long t = 0;
	int i;

	va_start(ap, n);
	for (i = 0; i < n; i++) {
		struct DL dl = va_arg(ap, struct DL);
		struct FFI f = va_arg(ap, struct FFI);
		struct DD dd = va_arg(ap, struct DD);
		struct LD ld = va_arg(ap, struct LD);
		double _Complex z = va_arg(ap, double _Complex);
		float _Complex w = va_arg(ap, float _Complex);

		t = t * 3 + (long)dl.d * 2 + dl.l + (long)(f.a * 4) +
		    (long)f.b + f.c + (long)dd.x * 5 + (long)dd.y +
		    ld.l * 7 + (long)ld.d + (long)((double *)&z)[0] +
		    (long)((double *)&z)[1] * 11 +
		    (long)((float *)&w)[0] * 13 + (long)((float *)&w)[1];
	}
	va_end(ap);
	return t;
}
