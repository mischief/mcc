/* SPDX-License-Identifier: ISC */
/* The x87 extended type, which only amd64 has here.  Every answer
   crosses to a long before it is printed, so the comparison against
   gcc does not turn on how a library prints one. */

long double add(long double a, long double b) { return a + b; }
long double sub(long double a, long double b) { return a - b; }
long double mul(long double a, long double b) { return a * b; }
long double dvd(long double a, long double b) { return a / b; }

long arith(long v)
{
	long double a = (long double)v;
	long double b = a + 0.5L;

	return (long)(add(a, b) * 1000.0L) + (long)(sub(a, b) * 100.0L)
	     + (long)(mul(a, b) * 10.0L) + (long)(dvd(a, b) * 10000.0L)
	     + (long)(-a * 7.0L);
}

long cmps(long v)
{
	long double a = (long double)v;
	long double b = 1.5L;
	long m = 0;

	if (a == b) m = m + 1;
	if (a != b) m = m + 2;
	if (a < b)  m = m + 4;
	if (a <= b) m = m + 8;
	if (a > b)  m = m + 16;
	if (a >= b) m = m + 32;
	if (a)      m = m + 64;
	if (!b)     m = m + 128;
	return m;
}

/* A NaN answers no to every ordered question and yes to inequality. */
long nans(long v)
{
	long double z = 0.0L;
	long double n = z / z;
	long double inf = 1.0L / (v == 0 ? z : 0.0L);
	long double x = (long double)v;
	long m = 0;

	if (n == x)  m = m + 1;
	if (n != x)  m = m + 2;
	if (n < x)   m = m + 4;
	if (n >= x)  m = m + 8;
	if (n == n)  m = m + 16;
	if (n != n)  m = m + 32;
	if (n)       m = m + 64;
	if (inf > x) m = m + 128;
	if (-inf < x) m = m + 256;
	return m;
}

long convs(long v)
{
	long double d = (long double)v / 3.0L;
	double e = (double)d;
	float f = (float)d;
	unsigned long u = (unsigned long)(d < 0.0L ? -d : d);
	long double back = (long double)e + (long double)(long)v;

	return (long)(d * 1000.0L) + (long)(e * 100.0) * 7
	     + (long)((double)f * 10.0) * 3 + (long)u * 13
	     + (long)(back * 5.0L);
}

/* Past the range of a double in both directions, which is the whole
   reason the type is here. */
long range(long v)
{
	long double big = 1e400L * (long double)v;
	long double small = 1e-400L * (long double)v;

	return (long)(big / 1e390L) + (long)(small * 1e410L)
	     + (long)(big * small * 1e10L);
}

long double table[4];

long stored(long n)
{
	long i;
	long double s;

	for (i = 0; i < 4; i++)
		table[i] = (long double)(i * n) + 0.25L;
	s = 0.0L;
	for (i = 0; i < 4; i++)
		s = s + table[i];
	return (long)(s * 100.0L);
}

static long double ten(long double a, long double b, long double c,
		       long double d, long double e, long double f,
		       long double g, long double h, long double i,
		       long double j)
{
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8
	     + i * 9 + j * 10;
}

/* Every one of them is on the caller's stack, and a call inside a call
   leaves a value of this type live across it. */
long many(long v)
{
	long double x = (long double)v;
	long double y = x + 0.5L;

	return (long)(ten(x, y, x, y, x, y, x, y, x, y) * 10.0L)
	     + (long)(ten(y, x, ten(x, y, x, y, x, y, x, y, x, y),
			  y, x, y, x, y, x, y) * 2.0L);
}

long roots(long v)
{
	long double d = (long double)v;
	long double m = d < 0.0L ? -d : d;

	return (long)(__builtin_sqrtl(m) * 1000.0L)
	     + (long)(__builtin_fabsl(d) * 100.0L)
	     + (long)(__builtin_sqrtl(m + 1.0L) * 3.0L);
}

/* The template takes the value on the x87 stack itself, which is what
   t and u name.  A library's own square root is written this way. */
long asmst(long v)
{
	long double x = (long double)v;
	long double m = x < 0.0L ? -x : x;
	unsigned short fpsr;
	long double q = m;
	long double five = 5.0L;

	__asm__ ("fsqrt" : "+t"(m));
	__asm__ ("frndint" : "+t"(x));
	do __asm__ ("fprem; fnstsw %%ax" : "+t"(q), "=a"(fpsr) : "u"(five));
	while (fpsr & 0x400);
	return (long)(m * 1000.0L) + (long)(x * 10.0L) + (long)(q * 100.0L);
}

/* Classifying one reads its bits; copysign and fabs work on them too. */
long xclass(long v)
{
	long double x = v == 0 ? 0.0L : v == 1 ? -0.0L : v == 2 ?
	    __builtin_infl() : v == 3 ? -__builtin_infl() : v == 4 ?
	    __builtin_nanl("") : (long double)v * 1e-4940L;

	return __builtin_isnan(x) + 2 * __builtin_isinf(x) +
	    4 * __builtin_isfinite(x) + 8 * !!__builtin_signbit(x) +
	    16 * __builtin_isnormal(x) + 32 * (__builtin_isinf_sign(x) + 1) +
	    128 * (long)__builtin_copysignl(3.0L, x) +
	    1024 * (long)__builtin_fabsl(-7.0L);
}

/* A long double _Complex comes back on the x87 stack. */
long double _Complex xcplx(long double a, long double b)
{
	long double _Complex z;

	__real__ z = a;
	__imag__ z = b;
	return z * z / (z + 1.0L);
}

/* Math builtins nothing declared answer in their own type. */
long xmath(long v)
{
	long double m = __builtin_fmaxl((long double)v, 2.5L);

	return (long)(m * 10) + 100 * (long)__builtin_logbl(m * 8) +
	    1000 * (long)__builtin_scalbnl(m, 3);
}
