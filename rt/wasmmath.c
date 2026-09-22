/* SPDX-License-Identifier: 0BSD */
/*
 * The mathematics a C program asks for, on a machine that has the four
 * operations and a square root and nothing else. Everything here is a
 * series or an iteration over those.
 *
 * Accuracy is a few ulp, not the half an ulp a real libm promises.
 */

#define PI	3.14159265358979323846
#define LN2	0.69314718055994530942

int abs(int v) { return v < 0 ? -v : v; }
long labs(long v) { return v < 0 ? -v : v; }

double fabs(double x) { return __builtin_fabs(x); }
double sqrt(double x) { return __builtin_sqrt(x); }

/* The exponent and the mantissa, which every one of these needs. */
/*
 * Building the scale as one number would overflow or underflow before
 * it ever reached x, so it goes in steps the exponent can hold.  The
 * small step is 2**-969, which keeps a value that ends up subnormal
 * normal on the way and out of a second rounding.
 */
static double scale2(double x, int n)
{
	union { double d; unsigned long long u; } s;

	if (n > 1023) {
		x *= 8.98846567431158e307;	/* 2**1023 */
		n -= 1023;
		if (n > 1023) {
			x *= 8.98846567431158e307;
			n -= 1023;
			if (n > 1023) n = 1023;
		}
	} else if (n < -1022) {
		x *= 2.004168360008973e-292;	/* 2**-969 */
		n += 969;
		if (n < -1022) {
			x *= 2.004168360008973e-292;
			n += 969;
			if (n < -1022) n = -1022;
		}
	}
	s.u = (unsigned long long)(n + 1023) << 52;
	return x * s.d;
}

double ldexp(double x, int n) { return scale2(x, n); }
double scalbn(double x, int n) { return scale2(x, n); }

double frexp(double x, int *e)
{
	int n = 0;

	*e = 0;
	if (x == 0.0 || x != x || x - x != 0.0) return x;
	if (x < 0.0) return -frexp(-x, e);
	while (x >= 1.0) { x *= 0.5; n++; }
	while (x < 0.5) { x *= 2.0; n--; }
	*e = n;
	return x;
}

/* Past this a double holds no fraction, and the conversion below would
   trap instead of rounding.  A NaN fails the test and comes back whole. */
#define WHOLE 9007199254740992.0

double floor(double x)
{
	double t;

	if (!(fabs(x) < WHOLE)) return x;
	t = (double)(long long)x;
	if (t > x) t -= 1.0;
	return t;
}

double ceil(double x)
{
	double t;

	if (!(fabs(x) < WHOLE)) return x;
	t = (double)(long long)x;
	if (t < x) t += 1.0;
	return t;
}

double fmod(double a, double b)
{
	double q;

	if (b == 0.0) return 0.0 / 0.0;
	q = a / b;
	q = (q < 0.0) ? ceil(q) : floor(q);
	return a - q * b;
}

/* e^x, by halving into the range where the series converges fast */
double exp(double x)
{
	int n = 0;
	double t, s;
	int i;

	if (x != x) return x;
	/* halve until the series converges fast, then square back that
	   many times -- the count is of halvings, not of sign */
	while (x > 0.5 || x < -0.5) { x *= 0.5; n++; }
	s = 1.0; t = 1.0;
	for (i = 1; i < 18; i++) { t *= x / (double)i; s += t; }
	while (n-- > 0) s *= s;
	return s;
}

/* the natural log, by the exponent plus atanh on the mantissa */
double log(double x)
{
	int e;
	double m, z, z2, s, t;
	int i;

	if (x != x || x < 0.0) return 0.0 / 0.0;
	if (x == 0.0) return -1.0 / 0.0;
	m = frexp(x, &e);
	while (m < 0.70710678118654752440) { m *= 2.0; e--; }
	z = (m - 1.0) / (m + 1.0);
	z2 = z * z;
	s = 0.0; t = z;
	for (i = 1; i < 40; i += 2) { s += t / (double)i; t *= z2; }
	return 2.0 * s + (double)e * LN2;
}

double log10(double x) { return log(x) * 0.43429448190325182765; }
double log2(double x) { return log(x) * 1.44269504088896340736; }

double pow(double a, double b)
{
	long long n;
	int odd;
	double r;

	if (b == 0.0 || a == 1.0) return 1.0;
	if (a != a || b != b) return a + b;
	/* a negative base has a real power only when the exponent is
	   whole, and then the sign is the parity's */
	if (a < 0.0 || (a == 0.0 && 1.0 / a < 0.0)) {
		if (floor(b) != b) return 0.0 / 0.0;
		odd = fabs(b) < 9007199254740992.0 && fmod(b, 2.0) != 0.0;
		r = pow(-a, b);
		return odd ? -r : r;
	}
	if (a == 0.0) return b > 0.0 ? 0.0 : 1.0 / 0.0;
	/* an integer power costs no logarithm */
	n = (fabs(b) < 1024.0) ? (long long)b : 0;
	if (n != 0 && (double)n == b) {
		double base = a;
		long long k = n < 0 ? -n : n;

		r = 1.0;
		while (k) {
			if (k & 1) r *= base;
			base *= base;
			k >>= 1;
		}
		return n < 0 ? 1.0 / r : r;
	}
	return exp(b * log(a));
}

/* sine on the reduced argument, by its series */
static double sinr(double x)
{
	double t = x, s = x, x2 = x * x;
	int i;

	for (i = 3; i < 20; i += 2) {
		t *= -x2 / (double)((i - 1) * i);
		s += t;
	}
	return s;
}

double sin(double x)
{
	double q = x / (2.0 * PI);

	x -= (q < 0.0 ? ceil(q) : floor(q)) * (2.0 * PI);
	if (x > PI) x -= 2.0 * PI;
	if (x < -PI) x += 2.0 * PI;
	if (x > PI / 2.0) x = PI - x;
	if (x < -PI / 2.0) x = -PI - x;
	return sinr(x);
}

double cos(double x) { return sin(x + PI / 2.0); }
double tan(double x) { return sin(x) / cos(x); }

double atan(double x)
{
	int flip = 0, neg = 0;
	double s, t, x2;
	int i;

	int half = 0;

	if (x < 0.0) { x = -x; neg = 1; }
	if (x > 1.0) { x = 1.0 / x; flip = 1; }
	/* The series crawls near one. atan(x) = 2 atan(x / (1 + sqrt(1 +
	   x^2))) halves the argument, and twice puts it under a third.  */
	while (x > 0.3) {
		x = x / (1.0 + sqrt(1.0 + x * x));
		half++;
	}
	x2 = x * x;
	s = 0.0; t = x;
	for (i = 1; i < 60; i += 2) {
		s += ((i / 2) & 1 ? -t : t) / (double)i;
		t *= x2;
	}
	while (half-- > 0) s *= 2.0;
	if (flip) s = PI / 2.0 - s;
	return neg ? -s : s;
}

double atan2(double y, double x)
{
	if (x > 0.0) return atan(y / x);
	if (x < 0.0) return y >= 0.0 ? atan(y / x) + PI : atan(y / x) - PI;
	if (y > 0.0) return PI / 2.0;
	if (y < 0.0) return -PI / 2.0;
	return 0.0;
}

double asin(double x)
{
	if (x >= 1.0) return PI / 2.0;
	if (x <= -1.0) return -PI / 2.0;
	return atan(x / sqrt(1.0 - x * x));
}

double acos(double x) { return PI / 2.0 - asin(x); }
