/*
 * The floating point runtime for a machine whose registers are four bytes.
 *
 * Same shim as rt/softfp.c, but a double is named by its address rather than
 * carried in a register, because it does not fit in one.  A float still
 * rides in a register: it is one word wide.
 */

typedef unsigned int u32;
typedef int i32;

static double ld(const void *p)
{
	double d;
	const char *s = (const char *)p;
	char *t = (char *)&d;
	int i;

	for (i = 0; i < 8; i++) t[i] = s[i];
	return d;
}

static void st(void *p, double d)
{
	char *t = (char *)p;
	const char *s = (const char *)&d;
	int i;

	for (i = 0; i < 8; i++) t[i] = s[i];
}

union fbits { u32 i; float f; };

static float f_of(u32 b) { union fbits u; u.i = b; return u.f; }
static u32 f_to(float v) { union fbits u; u.f = v; return u.i; }

void __w_dadd(void *d, const void *a, const void *b) { st(d, ld(a) + ld(b)); }
void __w_dsub(void *d, const void *a, const void *b) { st(d, ld(a) - ld(b)); }
void __w_dmul(void *d, const void *a, const void *b) { st(d, ld(a) * ld(b)); }
void __w_ddiv(void *d, const void *a, const void *b) { st(d, ld(a) / ld(b)); }
void __w_dneg(void *d, const void *a)                { st(d, -ld(a)); }

/* -1, 0, 1, or 2 when the two are unordered */
i32 __w_dcmp(const void *a, const void *b)
{
	double x = ld(a), y = ld(b);

	if (x < y) return -1;
	if (x == y) return 0;
	if (x > y) return 1;
	return 2;
}

/* conversions across the register width */
void __w_i2d(void *d, i32 v)  { st(d, (double)v); }
void __w_u2d(void *d, u32 v)  { st(d, (double)v); }
void __w_f2d(void *d, u32 v)  { st(d, (double)f_of(v)); }

i32 __w_d2i(const void *a)    { return (i32)ld(a); }
u32 __w_d2u(const void *a)    { return (u32)ld(a); }
u32 __w_d2f(const void *a)    { return f_to((float)ld(a)); }

/* and between a double and a wide integer, both in memory */
void __w_l2d(void *d, const void *a)
{
	long long v;
	char *t = (char *)&v;
	const char *s = (const char *)a;
	int i;

	for (i = 0; i < 8; i++) t[i] = s[i];
	st(d, (double)v);
}

void __w_ul2d(void *d, const void *a)
{
	unsigned long long v;
	char *t = (char *)&v;
	const char *s = (const char *)a;
	int i;

	for (i = 0; i < 8; i++) t[i] = s[i];
	st(d, (double)v);
}

void __w_d2l(void *d, const void *a)
{
	long long v = (long long)ld(a);
	char *t = (char *)d;
	const char *s = (const char *)&v;
	int i;

	for (i = 0; i < 8; i++) t[i] = s[i];
}

void __w_d2ul(void *d, const void *a)
{
	unsigned long long v = (unsigned long long)ld(a);
	char *t = (char *)d;
	const char *s = (const char *)&v;
	int i;

	for (i = 0; i < 8; i++) t[i] = s[i];
}
