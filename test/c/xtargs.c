/* SPDX-License-Identifier: ISC */
/* Argument shapes the Xtensa convention has a rule of its own for: the
   halves of a complex go as two arguments, an empty record aligned past
   a word still aligns the stack once the registers are gone, and a call
   with many arguments on the stack.  No floating point arithmetic: the
   values only travel, and come back as bits. */
#include <stdarg.h>

struct E { double _Complex z[0]; };
struct R { int v[9]; };
struct Q { int v[7] __attribute__((aligned(16))); };
struct H { int v[300]; };

static unsigned bits(const void *p, int n)
{
	const unsigned char *c = p;
	unsigned h = 0;

	while (n-- > 0)
		h = h * 31 + *c++;
	return h;
}

unsigned cplx(int a, unsigned long long b, double _Complex c, int d)
{
	return a + (unsigned)b * 3 + bits(&c, sizeof c) * 5 + d * 7;
}

unsigned fcplx(int a, float _Complex b, int c)
{
	return a + bits(&b, sizeof b) * 3 + c * 5;
}

unsigned empty(struct Q a, int b, struct E c, int d)
{
	return bits(&a, sizeof a.v) + b * 3 + d * 5;
}

unsigned vcplx(int n, ...)
{
	va_list ap;
	unsigned t = 0;

	va_start(ap, n);
	while (n-- > 0) {
		double d = va_arg(ap, double);
		double _Complex z = va_arg(ap, double _Complex);

		t = t * 7 + bits(&d, sizeof d) + bits(&z, sizeof z) * 3;
	}
	va_end(ap);
	return t;
}

/* A big frame: the parameters are copied in from far away. */
unsigned far(struct H z, int a, int b, int c, int d, int e, int f,
	     struct R g, int h)
{
	return a + f * 3 + bits(&g, sizeof g) * 5 + h * 7 + z.v[299];
}

unsigned vfar(int n, ...)
{
	char pad[1200];
	va_list ap;
	unsigned t = 0;

	__builtin_memset(pad, n, sizeof pad);
	va_start(ap, n);
	while (n-- > 0)
		t = t * 3 + va_arg(ap, int);
	va_end(ap);
	return t + pad[1000];
}

unsigned many(long long a, long long b, long long c, long long d,
	      long long e, long long f, long long g, long long h,
	      long long i, long long j, long long k, long long l,
	      long long m, long long n)
{
	return (unsigned)(a + b * 3 + c * 5 + d * 7 + e + f * 3 + g * 5 +
			  h * 7 + i + j * 3 + k * 5 + l * 7 + m + n * 3);
}

/* gcc's functions called from here. */
unsigned gcplx(int, unsigned long long, double _Complex, int);
unsigned gempty(struct Q, int, struct E, int);
unsigned gvcplx(int, ...);
unsigned gmany(long long, long long, long long, long long, long long,
	       long long, long long, long long, long long, long long,
	       long long, long long, long long, long long);

unsigned callgcc(int k)
{
	double _Complex z, y;
	struct R r = {{k, 2, 3, 4, 5, 6, 7, 8, 9}};
	struct E e;
	struct Q qq = {{k, 2, 3, 4, 5, 6, 7}};
	unsigned long long w = 0x3ff0000000000000ULL + k;
	long long q[14];
	int i;

	__builtin_memcpy(&z, &w, 8);
	__builtin_memcpy((char *)&z + 8, &r, 8);
	y = z;
	for (i = 0; i < 14; i++)
		q[i] = (long long)k << i;
	return gcplx(1, 2, z, 3) + gempty(qq, 4, e, 5) * 3 +
	       gvcplx(2, 1.0, z, 2.0, y) * 5 +
	       gmany(q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8],
		     q[9], q[10], q[11], q[12], q[13]) * 7;
}
