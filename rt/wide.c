/* SPDX-License-Identifier: 0BSD */
/*
 * w_A scalar twice the register width, on a machine that cannot hold one.
 *
 * w_A value twice the register width cannot sit in a register, and this
 * compiler gives every tree node one register.  So on a 32-bit target an
 * eight-byte scalar lives in memory and every operation on one is a call
 * through here, with the operands named by address.  That is the same trade
 * the floating point runtime already makes, one step further along.  The
 * same file answers for a sixteen-byte scalar on a 64-bit machine, with
 * WIDE_HALF 8.
 *
 * Nothing here needs the wide type itself: everything is done on the two
 * halves.  The halves are in memory order, so this is little endian.
 */

#ifndef WIDE_HALF
#define WIDE_HALF 4
#endif

#if WIDE_HALF == 8
typedef unsigned long long w_u;
typedef long long w_i;
#define w_HB 64
#define w_QB 32
#else
typedef unsigned int w_u;
typedef int w_i;
#define w_HB 32
#define w_QB 16
#endif

typedef struct {
	w_u lo, hi;
} w_W;

/* The same file is built as the runtime this compiler links, and put
   inside one object as names of its own where there is no runtime to
   link.  WFN says which. */
#ifndef WFN
#define WFN
#endif

#define w_A (*(const w_W *)a)
#define w_B (*(const w_W *)b)
#define w_D (*(w_W *)d)

WFN void __w_add(void *d, const void *a, const void *b)
{
	w_u lo = w_A.lo + w_B.lo;
	w_D.hi = w_A.hi + w_B.hi + (lo < w_A.lo);
	w_D.lo = lo;
}

WFN void __w_sub(void *d, const void *a, const void *b)
{
	w_u lo = w_A.lo - w_B.lo;
	w_D.hi = w_A.hi - w_B.hi - (w_A.lo < w_B.lo);
	w_D.lo = lo;
}

WFN void __w_and(void *d, const void *a, const void *b)
{
	w_D.lo = w_A.lo & w_B.lo;
	w_D.hi = w_A.hi & w_B.hi;
}

WFN void __w_or(void *d, const void *a, const void *b)
{
	w_D.lo = w_A.lo | w_B.lo;
	w_D.hi = w_A.hi | w_B.hi;
}

WFN void __w_xor(void *d, const void *a, const void *b)
{
	w_D.lo = w_A.lo ^ w_B.lo;
	w_D.hi = w_A.hi ^ w_B.hi;
}

WFN void __w_neg(void *d, const void *a)
{
	w_u lo = -w_A.lo;
	w_D.hi = ~w_A.hi + (lo == 0);
	w_D.lo = lo;
}

WFN void __w_not(void *d, const void *a)
{
	w_D.lo = ~w_A.lo;
	w_D.hi = ~w_A.hi;
}

/* One half times another, in two halves: the widest product a machine
   can work out in one instruction is half by half. */
static void w_mulhalf(w_W *r, w_u x, w_u y)
{
	w_u mask = ((w_u)1 << w_QB) - 1;
	w_u xl = x & mask, xh = x >> w_QB;
	w_u yl = y & mask, yh = y >> w_QB;
	w_u ll = xl * yl, lh = xl * yh, hl = xh * yl, hh = xh * yh;
	w_u mid = lh + hl;
	w_u carry = (mid < lh) ? ((w_u)1 << w_QB) : 0;
	w_u lo = ll + (mid << w_QB);

	r->lo = lo;
	r->hi = hh + (mid >> w_QB) + carry + (lo < ll);
}

WFN void __w_mul(void *d, const void *a, const void *b)
{
	w_W r;

	w_mulhalf(&r, w_A.lo, w_B.lo);
	r.hi += w_A.lo * w_B.hi + w_A.hi * w_B.lo;
	w_D = r;
}

/* Restoring division on the two halves: one bit at a time, which is slow
 * and short.  Nothing here is on a path that matters yet.
 *
 * Everything below names its operands by address rather than passing them
 * by value, because a compiler for a small machine need not support passing
 * a structure in registers, and this one does not.
 */
static void w_divmod(w_W *q, w_W *r, const w_W *np, const w_W *mp)
{
	w_W n = *np, m = *mp;
	int i;

	q->lo = q->hi = 0;
	r->lo = r->hi = 0;
	if (m.lo == 0 && m.hi == 0)
		return;
	for (i = 2 * w_HB - 1; i >= 0; i--) {
		w_u bit = (i >= w_HB) ? (n.hi >> (i - w_HB)) : (n.lo >> i);

		r->hi = (r->hi << 1) | (r->lo >> (w_HB - 1));
		r->lo = (r->lo << 1) | (bit & 1);
		if (r->hi > m.hi || (r->hi == m.hi && r->lo >= m.lo)) {
			w_u lo = r->lo - m.lo;

			r->hi = r->hi - m.hi - (r->lo < m.lo);
			r->lo = lo;
			if (i >= w_HB)
				q->hi |= (w_u)1 << (i - w_HB);
			else
				q->lo |= (w_u)1 << i;
		}
	}
}

static int neg(const w_W *v)
{
	return (v->hi >> (w_HB - 1)) != 0;
}

static void negate(w_W *v)
{
	w_u lo = -v->lo;

	v->hi = ~v->hi + (lo == 0);
	v->lo = lo;
}

WFN void __w_divu(void *d, const void *a, const void *b)
{
	w_W q, r;

	w_divmod(&q, &r, (const w_W *)a, (const w_W *)b);
	w_D = q;
}

WFN void __w_modu(void *d, const void *a, const void *b)
{
	w_W q, r;

	w_divmod(&q, &r, (const w_W *)a, (const w_W *)b);
	w_D = r;
}

WFN void __w_divs(void *d, const void *a, const void *b)
{
	w_W x = w_A, y = w_B, q, r;
	int s = neg(&x) ^ neg(&y);

	if (neg(&x)) negate(&x);
	if (neg(&y)) negate(&y);
	w_divmod(&q, &r, &x, &y);
	if (s) negate(&q);
	w_D = q;
}

WFN void __w_mods(void *d, const void *a, const void *b)
{
	w_W x = w_A, y = w_B, q, r;
	int s = neg(&x);

	if (neg(&x)) negate(&x);
	if (neg(&y)) negate(&y);
	w_divmod(&q, &r, &x, &y);
	if (s) negate(&r);
	w_D = r;
}

WFN void __w_shl(void *d, const void *a, int n)
{
	w_W v = w_A;

	n &= 2 * w_HB - 1;
	if (n == 0) { w_D = v; return; }
	if (n >= w_HB) {
		w_D.hi = v.lo << (n - w_HB);
		w_D.lo = 0;
	} else {
		w_D.hi = (v.hi << n) | (v.lo >> (w_HB - n));
		w_D.lo = v.lo << n;
	}
}

WFN void __w_shru(void *d, const void *a, int n)
{
	w_W v = w_A;

	n &= 2 * w_HB - 1;
	if (n == 0) { w_D = v; return; }
	if (n >= w_HB) {
		w_D.lo = v.hi >> (n - w_HB);
		w_D.hi = 0;
	} else {
		w_D.lo = (v.lo >> n) | (v.hi << (w_HB - n));
		w_D.hi = v.hi >> n;
	}
}

WFN void __w_shrs(void *d, const void *a, int n)
{
	w_W v = w_A;
	w_u sign = (w_u)((w_i)v.hi >> (w_HB - 1));

	n &= 2 * w_HB - 1;
	if (n == 0) { w_D = v; return; }
	if (n >= w_HB) {
		w_D.lo = (w_u)((w_i)v.hi >> (n - w_HB));
		w_D.hi = sign;
	} else {
		w_D.lo = (v.lo >> n) | (v.hi << (w_HB - n));
		w_D.hi = (w_u)((w_i)v.hi >> n);
	}
}

WFN int __w_cmpu(const void *a, const void *b)
{
	if (w_A.hi != w_B.hi)
		return w_A.hi < w_B.hi ? -1 : 1;
	if (w_A.lo != w_B.lo)
		return w_A.lo < w_B.lo ? -1 : 1;
	return 0;
}

WFN int __w_cmps(const void *a, const void *b)
{
	if (w_A.hi != w_B.hi)
		return (w_i)w_A.hi < (w_i)w_B.hi ? -1 : 1;
	if (w_A.lo != w_B.lo)
		return w_A.lo < w_B.lo ? -1 : 1;
	return 0;
}

/* widening and narrowing across the register width */
WFN void __w_exts(void *d, w_i v)
{
	w_D.lo = (w_u)v;
	w_D.hi = (w_u)(v >> (w_HB - 1));
}

WFN void __w_extu(void *d, w_u v)
{
	w_D.lo = v;
	w_D.hi = 0;
}

WFN w_u __w_lo(const void *a)
{
	return w_A.lo;
}

#if WIDE_HALF == 8
/*
 * Conversions between the sixteen-byte integer and the float types.  A
 * float arrives and leaves as its bit pattern, as the rest of the float
 * runtime does; the extended type goes by address.
 */

static void w_negate(w_W *v)
{
	v->lo = ~v->lo + 1;
	v->hi = ~v->hi + (v->lo == 0);
}

static int w_bit(const w_W *v, int k)
{
	return (int)((k >= 64 ? v->hi >> (k - 64) : v->lo >> k) & 1);
}

/* The magnitude rounded to nearest even at p bits: m * 2^*e, m < 2^p. */
static w_u w_round(const w_W *v, int p, int *e)
{
	int n = 128, s;
	w_u m, low;

	while (n > 0 && !w_bit(v, n - 1))
		n--;
	*e = 0;
	if (n <= p)
		return v->lo;
	s = n - p;
	m = s >= 64 ? v->hi >> (s - 64) : (v->lo >> s) | (v->hi << (64 - s));
	if (p < 64)
		m &= ((w_u)1 << p) - 1;
	/* the bits below the rounding bit */
	if (s - 1 >= 64)
		low = v->lo | (v->hi & (((w_u)1 << (s - 1 - 64)) - 1));
	else
		low = v->lo & (((w_u)1 << (s - 1)) - 1);
	if (w_bit(v, s - 1) && (low != 0 || (m & 1))) {
		m++;
		if (p < 64 ? m == (w_u)1 << p : m == 0) {
			m = (w_u)1 << (p - 1);
			s++;
		}
	}
	*e = s;
	return m;
}

#define W_TOFLT(name, T, P, S) \
static T name(const void *a, int sign) \
{ \
	w_W v = w_A; \
	int neg = sign && (w_i)v.hi < 0, e; \
	T r; \
	if (neg) \
		w_negate(&v); \
	r = (T)w_round(&v, P, &e); \
	for (; e >= 32; e -= 32) \
		r *= (T)4294967296.0; \
	r *= (T)((w_u)1 << e); \
	return neg ? -r : r; \
} \
WFN w_u __w_##S##flt(const void *a) \
{ \
	union { T f; w_u u; } c; \
	c.u = 0; \
	c.f = name(a, 1); \
	return c.u; \
} \
WFN w_u __w_##S##fltu(const void *a) \
{ \
	union { T f; w_u u; } c; \
	c.u = 0; \
	c.f = name(a, 0); \
	return c.u; \
}

W_TOFLT(w_toflt, float, 24, f)
W_TOFLT(w_todbl, double, 53, d)

/* A value in range, truncated: the upper half first, then the rest. */
#define W_FIX(name, T, S) \
static void name(void *d, T x, int sign) \
{ \
	int neg = sign && x < 0; \
	T h; \
	if (neg) \
		x = -x; \
	if (x < (T)18446744073709551616.0) { \
		w_D.hi = 0; \
		w_D.lo = (w_u)x; \
	} else { \
		h = x / (T)18446744073709551616.0; \
		w_D.hi = (w_u)h; \
		w_D.lo = (w_u)(x - (T)w_D.hi * (T)18446744073709551616.0); \
	} \
	if (neg) \
		w_negate((w_W *)d); \
} \
WFN void __w_fix##S(void *d, w_u bits) \
{ \
	union { T f; w_u u; } c; \
	c.u = bits; \
	name(d, c.f, 1); \
} \
WFN void __w_fixu##S(void *d, w_u bits) \
{ \
	union { T f; w_u u; } c; \
	c.u = bits; \
	name(d, c.f, 0); \
}

W_FIX(w_fixf, float, f)
W_FIX(w_fixd, double, d)

#if defined(__x86_64__)
static long double w_tox(const void *a, int sign)
{
	w_W v = w_A;
	int neg = sign && (w_i)v.hi < 0, e;
	long double r;

	if (neg)
		w_negate(&v);
	r = (long double)w_round(&v, 64, &e);
	for (; e >= 32; e -= 32)
		r *= 4294967296.0L;
	r *= (long double)((w_u)1 << e);
	return neg ? -r : r;
}

WFN void __w_xflt(void *d, const void *a)
{
	*(long double *)d = w_tox(a, 1);
}

WFN void __w_xfltu(void *d, const void *a)
{
	*(long double *)d = w_tox(a, 0);
}

static void w_fixx(void *d, long double x, int sign)
{
	int neg = sign && x < 0;
	long double h;

	if (neg)
		x = -x;
	if (x < 18446744073709551616.0L) {
		w_D.hi = 0;
		w_D.lo = (w_u)x;
	} else {
		h = x / 18446744073709551616.0L;
		w_D.hi = (w_u)h;
		w_D.lo = (w_u)(x - (long double)w_D.hi *
			18446744073709551616.0L);
	}
	if (neg)
		w_negate((w_W *)d);
}

WFN void __w_fixx(void *d, const void *a)
{
	w_fixx(d, *(const long double *)a, 1);
}

WFN void __w_fixux(void *d, const void *a)
{
	w_fixx(d, *(const long double *)a, 0);
}
#endif
#endif
