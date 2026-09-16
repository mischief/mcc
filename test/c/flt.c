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
