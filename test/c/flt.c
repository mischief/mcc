/* floating point, lowered to calls */

static double half(double x)
{
	return x / 2.0;
}

long arith(long a, long b)
{
	double x;
	double y;

	x = (double)a;
	y = (double)b;
	return (long)((x + y) * 1000.0) + (long)((x - y) * 100.0)
	     + (long)(x * y) + (long)(half(x) * 10.0);
}

long divide(long a, long b)
{
	if (b == 0)
		return -1;
	return (long)((double)a / (double)b * 10000.0);
}

long cmps(long a, long b)
{
	double x;
	double y;
	long m;

	x = (double)a;
	y = (double)b;
	m = 0;
	if (x == y) m = m + 1;
	if (x != y) m = m + 2;
	if (x < y)  m = m + 4;
	if (x <= y) m = m + 8;
	if (x > y)  m = m + 16;
	if (x >= y) m = m + 32;
	if (x)      m = m + 64;
	if (!y)     m = m + 128;
	return m;
}

long convs(long v)
{
	float f;
	double d;
	unsigned long u;
	int i;

	d = (double)v / 3.0;
	f = (float)d;
	i = (int)d;
	u = (unsigned long)(d < 0.0 ? -d : d);
	return (long)(d * 1000.0) + (long)(f * 100.0) * 7 + i * 13
	     + (long)u * 3 + (long)(double)(float)0.5;
}

long consts(void)
{
	double a;
	float b;

	a = 1.5;
	b = 0.25;
	return (long)(a * 1000.0) + (long)((double)b * 10000.0)
	     + (long)(1e3 + 0.5) + (long)(-2.75 * 4.0);
}

long negs(long v)
{
	double d;

	d = (double)v;
	return (long)(-d * 10.0) + (long)(-(-d));
}

double table[4];

long stored(long n)
{
	long i;
	double s;

	for (i = 0; i < 4; i++)
		table[i] = (double)(i * n) + 0.5;
	s = 0.0;
	for (i = 0; i < 4; i++)
		s = s + table[i];
	return (long)(s * 100.0);
}

/* a float steps through the runtime, so the old value has to be kept */
long steps(long i)
{
	double d = (double)i;
	float f = (float)i + 0.5f;
	double a, b;
	double arr[2];
	double *p = arr;

	arr[0] = (double)i;
	arr[1] = (double)i + 1.0;
	a = d++;
	b = d--;
	a = a * 1000.0 + b * 100.0 + d;
	f++;
	--f;
	a = a + (double)f * 10.0;
	a = a + (*p++)++;
	return (long)(a * 100.0) + (long)(arr[0] * 10.0) + (p - arr);
}

/* A NaN answers no to every ordered question and yes to inequality,
   which is the one thing a hardware compare gets wrong on its own. */
long nans(long a)
{
	double z = 0.0;
	double n = z / z;
	double inf = 1.0 / (a == 0 ? z : 0.0);
	double x = (double)a;
	long m = 0;

	if (n == x)  m = m + 1;
	if (n != x)  m = m + 2;
	if (n < x)   m = m + 4;
	if (n <= x)  m = m + 8;
	if (n > x)   m = m + 16;
	if (n >= x)  m = m + 32;
	if (n == n)  m = m + 64;
	if (n != n)  m = m + 128;
	if (n)       m = m + 256;
	if (!n)      m = m + 512;
	if (inf > x) m = m + 1024;
	if (-inf < x) m = m + 2048;
	if (inf == inf) m = m + 4096;
	return m;
}

/* The two conversions no single instruction does: a word with its top bit
   set, and a double too big for a signed word.  Every value here stays
   inside the range the standard defines, so gcc and mcc must agree. */
long uconv(long a)
{
	unsigned long u = (unsigned long)a * 0x0123456789abcdefUL;
	double e = (double)u;
	double d = (double)(u >> 1);
	unsigned long back = (unsigned long)d;
	float f = (float)(e / 1e20);

	return (long)(back >> 20) + (long)(unsigned long)(e / 65536.0)
	     + (long)((double)f * 1000000.0);
}

static double ten(double a, double b, double c, double d, double e,
		  double f, double g, double h, double i, double j)
{
	return a + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0
	     + g * 7.0 + h * 8.0 + i * 9.0 + j * 10.0;
}

/* More floats than the file has registers, so some go to the stack, and
   a call inside a call leaves a live value to be saved across it. */
long many(long v)
{
	double x = (double)v;
	double y = x + 0.5;

	return (long)(ten(x, y, x, y, x, y, x, y, x, y) * 10.0)
	     + (long)(ten(y, x, ten(x, y, x, y, x, y, x, y, x, y),
			  y, x, y, x, y, x, y) * 2.0);
}

struct pair { double x, y; };

static struct pair mkpair(double a, double b)
{
	struct pair p;

	p.x = a;
	p.y = b;
	return p;
}

static double dot(struct pair p, struct pair q)
{
	return p.x * q.x + p.y * q.y;
}

long pairs(long v)
{
	struct pair p = mkpair((double)v, (double)v + 0.5);
	struct pair q = mkpair(0.25, 0.75);

	return (long)(dot(p, q) * 1000.0) + (long)(dot(q, p) * 10.0)
	     + (long)(p.x * 3.0) + (long)(q.y * 4.0);
}

/* The two the machine has an instruction for, where it has one. */
long roots(long a)
{
	double d = (double)a;
	double m = d < 0.0 ? -d : d;
	float f = (float)m;

	return (long)(__builtin_sqrt(m) * 1000.0)
	     + (long)(__builtin_fabs(d) * 100.0)
	     + (long)(__builtin_sqrtf(f) * 10.0)
	     + (long)(__builtin_fabsf(-f) * 7.0)
	     + (long)(__builtin_sqrt(__builtin_fabs(d) + 1.0) * 3.0);
}

/* Rounding to an integral value, and the values a header names. */
long rounds(long a)
{
	double d = (double)a / 4.0;
	float f = (float)d;
	long m = 0;

	m = (long)(__builtin_floor(d) * 100.0);
	m = m * 7 + (long)(__builtin_ceil(d) * 100.0);
	m = m * 3 + (long)(__builtin_trunc(d) * 100.0);
	m = m * 5 + (long)(__builtin_rint(d) * 100.0);
	m = m * 11 + (long)(__builtin_nearbyint(d) * 100.0);
	m = m * 13 + (long)((double)__builtin_floorf(f) * 10.0);
	m = m * 17 + (long)((double)__builtin_ceilf(f) * 10.0);
	m = m * 19 + (long)((double)__builtin_truncf(f) * 10.0);
	m = m * 23 + (long)((double)__builtin_rintf(f) * 10.0);
	return m;
}

long named(long a)
{
	double i = __builtin_inf();
	float fi = __builtin_inff();
	double h = __builtin_huge_val();
	double n = __builtin_nan("");
	float fn = __builtin_nanf("");
	double x = (double)a;
	long m = 0;

	if (i > x) m = m + 1;
	if (-i < x) m = m + 2;
	if ((double)fi > x) m = m + 4;
	if (h == i) m = m + 8;
	if (n != n) m = m + 16;
	if ((double)fn != (double)fn) m = m + 32;
	if (n < x) m = m + 64;
	if (__builtin_huge_valf() == fi) m = m + 128;
	return m;
}
