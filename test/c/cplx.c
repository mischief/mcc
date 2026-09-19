/* SPDX-License-Identifier: ISC */
/* _Complex: the layout, and the arithmetic on it.  The compiler builds
   addition, subtraction and negation out of the two halves where they
   stand, and sends the multiply and the divide to the runtime under
   the names every other compiler gives them. */
#include <stddef.h>

typedef double _Complex dc;
typedef float _Complex fc;

struct both { dc a; fc b; char c; };

dc keep(dc x) { return x; }
fc keepf(fc x) { return x; }

long sizes(void)
{
	return (long)sizeof(double _Complex) * 1000
	     + (long)sizeof(float _Complex) * 100
	     + (long)sizeof(struct both)
	     + (long)_Alignof(double _Complex);
}

static dc g;

long carry(long v)
{
	struct both b;
	dc a;
	double *p = (double *)&a;

	p[0] = (double)v;
	p[1] = (double)v + 0.5;
	g = a;
	b.a = keep(g);
	b.c = (char)v;
	a = b.a;
	p = (double *)&a;
	return (long)(p[0] * 100.0) + (long)(p[1] * 10.0) + b.c;
}

/* The two spellings <complex.h> uses, written out so this needs no
   header: the imaginary unit, and the pair built through a union. */
#define I (0.0f + 1.0fi)
#define CMPLX(x, y, t) \
	((union { _Complex t __z; t __xy[2]; }){.__xy = {(x), (y)}}.__z)
#define CIMAG(x, t) \
	(+(union { _Complex t __z; t __xy[2]; }){(_Complex t)(x)}.__xy[1])

static dc lastdc;
static fc lastfc;

double cplxd(int which, double a, double b, double c, double d)
{
	dc x = CMPLX(a, b, double);
	dc y = CMPLX(c, d, double);
	dc z;

	switch (which) {
	case 0: z = x + y; break;
	case 1: z = x - y; break;
	case 2: z = x * y; break;
	case 3: z = x / y; break;
	case 4: z = -x; break;
	case 5: z = x + c; break;
	case 6: z = x * c; break;
	case 7: z = x / c; break;
	case 8: z = (dc)(a + b * I); break;
	case 9: z = (dc)(fc)x; break;
	default: z = x; break;
	}
	lastdc = z;
	return (double)z * 1000.0 + CIMAG(z, double);
}

double cplxf(int which, double a, double b, double c, double d)
{
	fc x = CMPLX((float)a, (float)b, float);
	fc y = CMPLX((float)c, (float)d, float);
	fc z;

	switch (which) {
	case 0: z = x + y; break;
	case 1: z = x - y; break;
	case 2: z = x * y; break;
	case 3: z = x / y; break;
	case 4: z = -x; break;
	default: z = x; break;
	}
	lastfc = z;
	return (double)(float)z * 1000.0 + (double)CIMAG(z, float);
}

int cplxsame(double a, double b)
{
	dc x = CMPLX(a, b, double);
	dc y = CMPLX(a, b, double);
	dc n = CMPLX(a, -b, double);

	return (x == y) * 10 + (x != y) + (x == n) * 100 +
	       (__real__ x == a) * 1000 + (__imag__ x == b) * 10000;
}

double cplxlast(int im)
{
	if (im) return CIMAG(lastdc, double) + (double)CIMAG(lastfc, float);
	return (double)lastdc + (double)(float)lastfc;
}

/* The extended type, which on x86_64 is a pair of eighty bit values in
   thirty two bytes.  The multiply and the divide are left out on
   purpose: the ABI returns that pair on the x87 stack and this
   compiler hands over a pointer, so its helpers are named apart and
   an object it built cannot be linked against another compiler'"'"'s.
   Everything here is built where it stands and needs no helper. */
typedef long double _Complex lc;

double cplxl(int which, double a, double b, double c, double d)
{
	lc x = CMPLX((long double)a, (long double)b, long double);
	lc y = CMPLX((long double)c, (long double)d, long double);
	lc z;

	switch (which) {
	case 0: z = x + y; break;
	case 1: z = x - y; break;
	case 2: z = -x; break;
	case 3: z = x + c; break;
	case 4: z = (lc)(dc)x; break;
	default: z = x; break;
	}
	return (double)(long double)z * 1000.0 +
	       (double)CIMAG(z, long double);
}
