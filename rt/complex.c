/* SPDX-License-Identifier: 0BSD */
/* The complex multiply and divide, under the names every compiler on
 * this platform gives them.  The compiler builds addition, subtraction
 * and negation out of the two halves where they stand; these two are
 * here because the divide needs a test to keep its range and neither
 * is short enough to be worth repeating at every site.
 *
 * The multiply is the school formula with the fixup C99 Annex G asks
 * for: a product of an infinity and a zero comes out NaN in both
 * halves, and the recovery turns each infinity into a signed one and
 * each NaN operand into a zero of the right sign, so that infinity
 * times a finite number is infinity rather than NaN.
 *
 * The divide is Smith's: scaling by the larger of the two denominator
 * halves keeps the intermediate products inside the range, where the
 * school formula would overflow for a denominator near the top of it.
 */

struct dc { double re, im; };
struct fc { float re, im; };

static int disinf(double v) { return v > 1.7976931348623157e308 ||
			      v < -1.7976931348623157e308; }
static int disnan(double v) { return v != v; }
static double dcopysign(double v, double s)
{
	union { double d; unsigned long long u; } a, b;

	a.d = v;
	b.d = s;
	a.u = (a.u & 0x7fffffffffffffffULL) | (b.u & 0x8000000000000000ULL);
	return a.d;
}

struct dc __muldc3(double a, double b, double c, double d)
{
	struct dc z;
	double ac = a * c, bd = b * d, ad = a * d, bc = b * c;
	int recalc = 0;

	z.re = ac - bd;
	z.im = ad + bc;
	if (!disnan(z.re) || !disnan(z.im)) return z;
	if (disinf(a) || disinf(b)) {
		a = dcopysign(disinf(a) ? 1.0 : 0.0, a);
		b = dcopysign(disinf(b) ? 1.0 : 0.0, b);
		if (disnan(c)) c = dcopysign(0.0, c);
		if (disnan(d)) d = dcopysign(0.0, d);
		recalc = 1;
	}
	if (disinf(c) || disinf(d)) {
		c = dcopysign(disinf(c) ? 1.0 : 0.0, c);
		d = dcopysign(disinf(d) ? 1.0 : 0.0, d);
		if (disnan(a)) a = dcopysign(0.0, a);
		if (disnan(b)) b = dcopysign(0.0, b);
		recalc = 1;
	}
	if (!recalc && (disinf(ac) || disinf(bd) || disinf(ad) ||
			disinf(bc))) {
		if (disnan(a)) a = dcopysign(0.0, a);
		if (disnan(b)) b = dcopysign(0.0, b);
		if (disnan(c)) c = dcopysign(0.0, c);
		if (disnan(d)) d = dcopysign(0.0, d);
		recalc = 1;
	}
	if (recalc) {
		double inf = 1.0e308 * 10.0;

		z.re = inf * (a * c - b * d);
		z.im = inf * (a * d + b * c);
	}
	return z;
}

struct dc __divdc3(double a, double b, double c, double d)
{
	struct dc z;
	double ac = c < 0.0 ? -c : c;
	double ad = d < 0.0 ? -d : d;

	if (ac >= ad) {
		double r = d / c, den = c + d * r;

		z.re = (a + b * r) / den;
		z.im = (b - a * r) / den;
	} else {
		double r = c / d, den = c * r + d;

		z.re = (a * r + b) / den;
		z.im = (b * r - a) / den;
	}
	return z;
}

struct fc __mulsc3(float a, float b, float c, float d)
{
	struct dc w = __muldc3(a, b, c, d);
	struct fc z;

	z.re = (float)w.re;
	z.im = (float)w.im;
	return z;
}

struct fc __divsc3(float a, float b, float c, float d)
{
	struct dc w = __divdc3(a, b, c, d);
	struct fc z;

	z.re = (float)w.re;
	z.im = (float)w.im;
	return z;
}

/* The extended type, where it exists.  The pair goes in memory and
 * comes back on the x87 stack, as the ABI says.
 */
#if defined(__x86_64__)

struct xc { long double re, im; };

static int xisinf(long double v)
{
	return v > 1.18973149535723176502e4932L ||
	       v < -1.18973149535723176502e4932L;
}
static int xisnan(long double v) { return v != v; }

long double _Complex __mulxc3(long double a, long double b, long double c,
		   long double d);
long double _Complex __divxc3(long double a, long double b, long double c,
		   long double d);

static long double _Complex
xcmake(struct xc z)
{
	long double _Complex r;

	__real__ r = z.re;
	__imag__ r = z.im;
	return r;
}

long double _Complex
__mulxc3(long double a, long double b, long double c, long double d)
{
	struct xc z;

	z.re = a * c - b * d;
	z.im = a * d + b * c;
	if (!xisnan(z.re) || !xisnan(z.im)) return xcmake(z);
	if (xisinf(a) || xisinf(b) || xisinf(c) || xisinf(d)) {
		long double inf = 1.0e4932L * 10.0L;

		z.re = inf * (a * c - b * d);
		z.im = inf * (a * d + b * c);
	}
	return xcmake(z);
}

long double _Complex
__divxc3(long double a, long double b, long double c, long double d)
{
	struct xc z;
	long double ac = c < 0.0L ? -c : c;
	long double ad = d < 0.0L ? -d : d;

	if (ac >= ad) {
		long double r = d / c, den = c + d * r;

		z.re = (a + b * r) / den;
		z.im = (b - a * r) / den;
	} else {
		long double r = c / d, den = c * r + d;

		z.re = (a * r + b) / den;
		z.im = (b * r - a) / den;
	}
	return xcmake(z);
}

#endif
