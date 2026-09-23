/* SPDX-License-Identifier: ISC */
/* GNU C's `~` on a complex value is its conjugate, which is how BSD libm
 * writes conj().  A real argument to a complex parameter, or a real
 * value returned from a complex function, becomes the complex number
 * with a zero imaginary part; the callee used to read a stale register
 * for that half. */
extern int printf(const char *, ...);

static double _Complex conj(double _Complex z) { return ~z; }
static float _Complex conjf(float _Complex z) { return ~z; }
static double _Complex id(double _Complex z) { return z; }
static double _Complex two(void) { return 2.5; }

static int negzero(double d)
{
	union { double d; unsigned long long u; } x = { d };
	return (int)(x.u >> 63);
}

long cconj(void)
{
	double _Complex a = conj(1.0 + 2.0i), b = conj(3.0);
	float _Complex c = conjf(1.0f - 4.0fi);
	double _Complex d = id(4.0), e = two(), n = -id(0.0);

	printf("%g %g %g %d %g %g\n", __real__ a, __imag__ a, __real__ b,
	       negzero(__imag__ b), (double)__real__ c, (double)__imag__ c);
	printf("%g %g %g %g %d %d\n", __real__ d, __imag__ d, __real__ e,
	       __imag__ e, negzero(__real__ n), negzero(__imag__ n));
	return 0;
}
