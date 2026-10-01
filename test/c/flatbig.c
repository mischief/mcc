/* SPDX-License-Identifier: ISC */
/* RISC-V: gcc flattens a char and a float into a0 and fa0 even when
   alignment pads the record past two words.  With the float registers
   used up, or as a variadic argument, the record goes by reference. */
#include <stdarg.h>

struct P { char c; float f __attribute__((aligned(16))); };

long gbig(struct P, int);
long gfull(float, float, float, float, float, float, float, float,
	   struct P, int);
struct P gret(int);

long big(struct P a, int b)
{
	return a.c * 100 + (long)a.f * 10 + b;
}

long full(float f0, float f1, float f2, float f3, float f4, float f5,
	  float f6, float f7, struct P a, int b)
{
	a.c++;
	return (long)(f0 + f1 + f2 + f3 + f4 + f5 + f6 + f7) * 1000 +
	       a.c * 100 + (long)a.f * 10 + b;
}

long vbig(int n, ...)
{
	va_list ap;
	long t = 0;

	va_start(ap, n);
	while (n-- > 0) {
		struct P p = va_arg(ap, struct P);

		t = t * 100 + p.c * 10 + (long)p.f;
	}
	va_end(ap);
	return t;
}

struct P ret(int k)
{
	struct P p = {(char)k, 2.0f * k};

	return p;
}

long callgcc(long k)
{
	struct P a = {(char)k, 3};
	struct P r = gret((int)k);
	long t;

	t = gbig(a, 4) + gfull(1, 1, 1, 1, 1, 1, 1, 1, a, 5) * 1000;
	return t * 100 + a.c * 10 + r.c + (long)r.f;
}
