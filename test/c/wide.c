/* SPDX-License-Identifier: ISC */
/* eight-byte scalars, which on a 32-bit target do not fit a register */
extern int printf(const char *, ...);

typedef long long i64;
typedef unsigned long long u64;

struct rec { i64 a; double d; int n; };

static struct rec R = {123456789012345LL, 2.5, 7};
static i64 arr[4] = {1LL, -2LL, 1LL << 40, 0};
static double darr[3] = {1.5, -2.5, 0.125};
static double gd = 2.5;
static i64 gl = -5000000000LL;

static i64 mixfn(i64 x, double y, int z)
{
	return x + (i64)y + z;
}

static i64 many(int a, int b, int c, int d, int e, i64 f, i64 g)
{
	return a + b + c + d + e + f * 2 + g;
}

static double dret(double x)
{
	return x * 3.0 + 1.0;
}

static void integers(void)
{
	i64 a = 123456789012345LL, b = -987654321LL;
	printf("i %lld %lld %lld\n", a + b, a - b, a * b);
	printf("i %lld %lld\n", a / b, a % b);
	printf("i %lld %lld %lld\n", a & b, a | b, a ^ b);
	printf("i %lld %lld\n", -a, ~a);
	printf("i %lld %lld %lld\n", a << 5, a >> 5, (i64)(((u64)a) >> 5));
	/* A shift whose count is worked out rather than written, which
	   is the shape a descriptor table is built with.  It has to
	   fold, or an initializer cannot use it. */
	{
		static const u64 tab[] = {
			[0] = ((0xff000000ULL) << (56 - 24)) |
			      ((0x8000ULL) << 40),
			[1] = (0xffULL) << (2 * 3),
		};
		printf("i %llu %llu\n", tab[0], tab[1]);
	}
	printf("i %d %d %d %d\n", a < b, a > b, a == b, a != 0);
	printf("i %d %d\n", (u64)a < (u64)b, (u64)a > (u64)b);
}

static void doubles(void)
{
	double x = 1.5, y = -0.25;
	float f = 2.5f;
	int i = -9;
	unsigned u = 4000000000u;
	i64 a = 7;
	printf("d %.6f %.6f %.6f %.6f\n", x + y, x - y, x * y, x / y);
	printf("d %.6f %.6f\n", -x, gd * 2.0);
	printf("d %d %d %d %d %d\n", x < y, x > y, x == y, x <= y, x != y);
	printf("d %.6f %.6f %.6f\n", (double)i, (double)u, (double)f);
	printf("d %.6f %.6f\n", (double)a, (double)gl);
	printf("d %d %u %lld\n", (int)x, (unsigned)gd, (i64)(x * 1e10));
	printf("d %.6f\n", (double)(float)(x / 3.0));
	printf("d %lld %lld %lld\n", (i64)i, (i64)u, (i64)(char)200);
	printf("d %d %u\n", (int)gl, (unsigned)(u64)gl);
	printf("d %lld %.6f\n", a + i, a + x);
	printf("d %.6f\n", dret(2.0));
}

static void steps(void)
{
	i64 v = 10;
	double d = 1.0;
	v += 5;  printf("s %lld\n", v);
	v -= 3;  printf("s %lld\n", v);
	v *= 1000000; printf("s %lld\n", v);
	v /= 7;  printf("s %lld\n", v);
	v <<= 3; printf("s %lld\n", v);
	v >>= 2; printf("s %lld\n", v);
	v &= 0xffffffLL; printf("s %lld\n", v);
	v |= 0xf000000LL; printf("s %lld\n", v);
	v ^= 0x0f0f0fLL; printf("s %lld\n", v);
	v++;     printf("s %lld\n", v);
	++v;     printf("s %lld\n", v);
	v--;     printf("s %lld\n", v);
	--v;     printf("s %lld\n", v);
	d += 0.5; d *= 3.0; printf("s %.6f\n", d);
	printf("s %lld\n", v > 0 ? v : -v);
	printf("s %d\n", v ? 1 : 0);
}

static void aggregates(void)
{
	i64 *p = arr;
	int i;
	for (i = 0; i < 4; i++) printf("a %lld\n", arr[i]);
	for (i = 0; i < 3; i++) printf("a %.6f\n", darr[i]);
	printf("a %lld %.6f %d\n", R.a, R.d, R.n);
	R.a += 1;
	R.d /= 2.0;
	printf("a %lld %.6f\n", R.a, R.d);
	printf("a %lld %lld\n", *p, p[2]);
	printf("a %lld\n", mixfn(100LL, 2.75, 3));
	printf("a %lld\n", many(1, 2, 3, 4, 5, 6LL, 7LL));
	{
		i64 s = 0;
		int k;
		for (k = 0; k < 10; k++) s += k * 1000000000LL;
		printf("a %lld\n", s);
	}
}

/* A pointer is already as wide as the value on a machine where the
 * value only lives in memory because this compiler was told to keep it
 * there.  Aligning one up is how a variadic argument area is walked. */
static void pointers(void)
{
	char buf[64];
	char *q = buf + 3;
	unsigned long long v = (unsigned long long)q;
	char *r = (char *)((v + 15) & ~15ULL);
	long long d = (long long)(unsigned long long)(void *)q -
		(long long)(unsigned long long)(void *)buf;

	printf("p %d %d %d\n", (int)(r >= q && r - q < 16),
	    (int)(((unsigned long long)(void *)r & 15ULL) == 0), (int)d);
	printf("p %d %d\n", (int)((unsigned long long)(void *)0 == 0ULL),
	    (int)(((unsigned long long)q & ~0xfULL) <= v));
}

void widetest(void)
{
	integers();
	doubles();
	steps();
	aggregates();
	pointers();
}
