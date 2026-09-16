/*
 * The floating point runtime.
 *
 * The compiler never puts a float in a float register: every operation is a
 * call to one of these, with the value carried as its bit pattern in an
 * ordinary register.  That is what a machine without an FPU needs, and it
 * keeps the code tables free of a second register class.
 *
 * This file is the shim.  Built by a compiler that has doubles, it is a few
 * instructions; built for a machine without them, it bottoms out in that
 * compiler's own soft float.  Replacing it with our own implementation is
 * separate work.
 *
 * Everything is passed and returned as a 64-bit integer, because that is the
 * only register class the compiler knows about.  A 32-bit float rides in the
 * low half.
 */

typedef long long i64;
typedef unsigned long long u64;

union dbits { i64 i; double d; };
union fbits { int i; float f; };

static double d_of(i64 b) { union dbits u; u.i = b; return u.d; }
static i64 d_to(double v) { union dbits u; u.d = v; return u.i; }
static float f_of(i64 b) { union fbits u; u.i = (int)b; return u.f; }
static i64 f_to(float v) { union fbits u; u.f = v; return (i64)u.i; }

i64 __dadd(i64 x, i64 y) { return d_to(d_of(x) + d_of(y)); }
i64 __dsub(i64 x, i64 y) { return d_to(d_of(x) - d_of(y)); }
i64 __dmul(i64 x, i64 y) { return d_to(d_of(x) * d_of(y)); }
i64 __ddiv(i64 x, i64 y) { return d_to(d_of(x) / d_of(y)); }
i64 __dneg(i64 x)        { return d_to(-d_of(x)); }

i64 __fadd(i64 x, i64 y) { return f_to(f_of(x) + f_of(y)); }
i64 __fsub(i64 x, i64 y) { return f_to(f_of(x) - f_of(y)); }
i64 __fmul(i64 x, i64 y) { return f_to(f_of(x) * f_of(y)); }
i64 __fdiv(i64 x, i64 y) { return f_to(f_of(x) / f_of(y)); }
i64 __fneg(i64 x)        { return f_to(-f_of(x)); }

/* -1 less, 0 equal, 1 greater, 2 unordered. */
i64 __dcmp(i64 x, i64 y)
{
	double a = d_of(x), b = d_of(y);
	if (a < b) return -1;
	if (a == b) return 0;
	if (a > b) return 1;
	return 2;
}

i64 __fcmp(i64 x, i64 y)
{
	float a = f_of(x), b = f_of(y);
	if (a < b) return -1;
	if (a == b) return 0;
	if (a > b) return 1;
	return 2;
}

i64 __i2d(i64 v) { return d_to((double)v); }
i64 __u2d(i64 v) { return d_to((double)(u64)v); }
i64 __i2f(i64 v) { return f_to((float)v); }
i64 __u2f(i64 v) { return f_to((float)(u64)v); }

i64 __d2i(i64 x) { return (i64)d_of(x); }
i64 __d2u(i64 x) { return (i64)(u64)d_of(x); }
i64 __f2i(i64 x) { return (i64)f_of(x); }
i64 __f2u(i64 x) { return (i64)(u64)f_of(x); }

i64 __d2f(i64 x) { return f_to((float)d_of(x)); }
i64 __f2d(i64 x) { return d_to((double)f_of(x)); }
