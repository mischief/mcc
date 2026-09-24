/* SPDX-License-Identifier: 0BSD */
/* The two-byte floats, under the names gcc and compiler_rt give their
   conversions.  The compiler does arithmetic on one in a float and
   calls these to cross between the widths.  Rounding is to nearest,
   ties to even, straight from the wider value. */

#ifdef __x86_64__

typedef unsigned long long u64;

float __extendhfsf2(_Float16 x);
_Float16 __truncsfhf2(float x);
_Float16 __truncdfhf2(double x);
_Float16 __truncxfhf2(long double x);
__bf16 __truncsfbf2(float x);
__bf16 __truncdfbf2(double x);
__bf16 __truncxfbf2(long double x);

union h { _Float16 f; unsigned short u; };
union b { __bf16 f; unsigned short u; };
union s { float f; unsigned u; };
union d { double f; u64 u; };
union x { long double f; struct { u64 m; unsigned short se; } p; };

/* m holds the value with its leading one at bit 63, worth 2^e.  The
   format has eb bits of exponent and mb of fraction. */
static unsigned short
rnd(unsigned sign, int e, u64 m, int eb, int mb)
{
	int top = (1 << eb) - 1;
	int te = e + (top >> 1);
	int shift = 63 - mb;
	unsigned s = sign << (eb + mb);
	u64 keep, rem, half;

	if (te < 1)
		shift += 1 - te;
	if (shift > 64)
		return s;
	if (shift == 64) {
		/* Below half the smallest step: a tie goes to zero. */
		keep = m > (1ULL << 63);
	} else {
		keep = m >> shift;
		rem = m & ((1ULL << shift) - 1);
		half = 1ULL << (shift - 1);
		if (rem > half || (rem == half && (keep & 1)))
			keep++;
	}
	/* A subnormal carries into the smallest normal on its own. */
	if (te < 1)
		return s | keep;
	if (keep >> (mb + 1)) {
		keep >>= 1;
		te++;
	}
	if (te >= top)
		return s | top << mb;
	return s | te << mb | (keep & ((1U << mb) - 1));
}

/* An infinity, or a NaN made quiet that keeps the top of its payload.
   pay holds the payload with its first bit at bit 63. */
static unsigned short
special(unsigned sign, int nan, u64 pay, int eb, int mb)
{
	unsigned s = sign << (eb + mb);
	unsigned inf = ((1U << eb) - 1) << mb;

	if (!nan)
		return s | inf;
	return s | inf | 1U << (mb - 1) | (unsigned)(pay >> (64 - mb));
}

static unsigned short
fromdf(double v, int eb, int mb)
{
	union d d;
	unsigned sign;
	int e;
	u64 f;

	d.f = v;
	sign = d.u >> 63;
	e = d.u >> 52 & 0x7ff;
	f = d.u & ((1ULL << 52) - 1);
	if (e == 0x7ff)
		return special(sign, f != 0, f << 12, eb, mb);
	/* A double below 2^-1022 is far under either format's range. */
	if (e == 0)
		return sign << (eb + mb);
	return rnd(sign, e - 1023, (f | 1ULL << 52) << 11, eb, mb);
}

static unsigned short
fromxf(long double v, int eb, int mb)
{
	union x x;
	unsigned sign;
	int e;
	u64 m;

	x.f = v;
	sign = x.p.se >> 15;
	e = x.p.se & 0x7fff;
	m = x.p.m;
	if (e == 0x7fff)
		return special(sign, (m << 1) != 0, m << 1, eb, mb);
	if (e == 0 || m == 0)
		return sign << (eb + mb);
	while (!(m >> 63)) {
		m <<= 1;
		e--;
	}
	return rnd(sign, e - 16383, m, eb, mb);
}

float
__extendhfsf2(_Float16 x)
{
	union h h;
	union s r;
	unsigned sign, e, m;

	h.f = x;
	sign = (unsigned)(h.u >> 15) << 31;
	e = h.u >> 10 & 0x1f;
	m = h.u & 0x3ff;
	if (e == 0x1f) {
		r.u = sign | 0x7f800000 | m << 13;
		return r.f;
	}
	if (e == 0) {
		r.f = (float)m * 0x1p-24f;
		r.u |= sign;
		return r.f;
	}
	r.u = sign | (e - 15 + 127) << 23 | m << 13;
	return r.f;
}

_Float16
__truncsfhf2(float x)
{
	union h h;

	h.u = fromdf(x, 5, 10);
	return h.f;
}

_Float16
__truncdfhf2(double x)
{
	union h h;

	h.u = fromdf(x, 5, 10);
	return h.f;
}

_Float16
__truncxfhf2(long double x)
{
	union h h;

	h.u = fromxf(x, 5, 10);
	return h.f;
}

__bf16
__truncsfbf2(float x)
{
	union b b;

	b.u = fromdf(x, 8, 7);
	return b.f;
}

__bf16
__truncdfbf2(double x)
{
	union b b;

	b.u = fromdf(x, 8, 7);
	return b.f;
}

__bf16
__truncxfbf2(long double x)
{
	union b b;

	b.u = fromxf(x, 8, 7);
	return b.f;
}

#endif
