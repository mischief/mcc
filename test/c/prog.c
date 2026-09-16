/* Exercises the front end: control flow, pointers, arrays, calls, globals. */

long counter = 0;
long table[8];

long sum(long n)
{
	long i, s;

	s = 0;
	for (i = 1; i <= n; i++)
		s += i;
	return s;
}

long fact(long n)
{
	if (n <= 1)
		return 1;
	return n * fact(n - 1);
}

long slen(char *s)
{
	char *p;

	p = s;
	while (*p)
		p++;
	return p - s;
}

long copy(char *d, char *s)
{
	long n;

	n = 0;
	while (*s) {
		*d = *s;
		d++;
		s++;
		n++;
	}
	*d = 0;
	return n;
}

long classify(long x)
{
	if (x < 0 && x > -10)
		return 1;
	if (x == 0 || x == 100)
		return 2;
	return 0;
}

long bits(long a, long b)
{
	return (a & b) | (a ^ b) | (a << 2) | (a >> 1);
}

long divmod(long a, long b)
{
	return a / b * 1000 + a % b;
}

long fill(long n)
{
	long i, s;

	for (i = 0; i < n; i++)
		table[i] = i * i;
	s = 0;
	for (i = 0; i < n; i++)
		s += table[i];
	return s;
}

long buffered(void)
{
	char buf[16];
	long n;

	n = copy(buf, "abcdef");
	return n * 1000 + slen(buf) * 10 + buf[3];
}

long bump(long by)
{
	counter += by;
	return counter;
}

long ternlike(long x)
{
	long r;

	r = 0;
	while (x > 0) {
		if (x % 2)
			r++;
		x /= 2;
	}
	return r;
}
