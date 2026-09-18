/*
 * The floating point runtime, in integers.
 *
 * The compiler never puts a float in a float register: every operation is a
 * call to one of these, with the value carried as its bit pattern.  That is
 * what a machine without an FPU needs, and it keeps the code tables free of
 * a second register class.
 *
 * Nothing here uses a C float or double, for two reasons.  The obvious one
 * is that a compiler reading this file would lower `a * b` into a call to
 * __dmul, which is this function.  The other is that lua-os links no libgcc,
 * so the only arithmetic available is the integer kind.
 *
 * Every product is built from 16x16 pieces.  A 32-bit machine does 32x32->64
 * in two instructions and a 64x64 in several, and the one Xtensa core this
 * is tested on has no high-word multiply at all, so the pieces are the
 * portable size rather than the fast one.
 *
 * Rounding is to nearest, ties to even, which is what a C program expects.
 * Only the default rounding direction is implemented, and no exception
 * flags are kept.
 *
 * float add, subtract, multiply and divide are done in double and rounded
 * once.  A double carries more than twice the precision of a float plus two
 * bits, which is the condition for that single rounding to give the same
 * answer as working in float throughout.
 */

typedef unsigned int u32;
typedef int i32;
typedef unsigned long long u64;
typedef long long i64;

#define DBIAS	1023
#define DMANT	52
#define FBIAS	127
#define FMANT	23

/* 32x32 -> 64, from four 16x16 products */
static u64 mulu32(u32 a, u32 b)
{
	u32 al = a & 0xffff, ah = a >> 16;
	u32 bl = b & 0xffff, bh = b >> 16;
	u32 ll = al * bl, lh = al * bh, hl = ah * bl, hh = ah * bh;
	u64 mid = (u64)lh + (u64)hl;

	return ((u64)hh << 32) + (mid << 16) + (u64)ll;
}

/* 64x64 -> 128 */
static void mulu64(u64 a, u64 b, u64 *hi, u64 *lo)
{
	u32 a0 = (u32)a, a1 = (u32)(a >> 32);
	u32 b0 = (u32)b, b1 = (u32)(b >> 32);
	u64 p00 = mulu32(a0, b0);
	u64 p01 = mulu32(a0, b1);
	u64 p10 = mulu32(a1, b0);
	u64 p11 = mulu32(a1, b1);
	u64 mid = (p00 >> 32) + (p01 & 0xffffffffu) + (p10 & 0xffffffffu);

	*lo = (mid << 32) | (p00 & 0xffffffffu);
	*hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
}

/* A number taken apart: sign, unbiased exponent, and a significand with the
 * hidden bit in place.  cls is 0 for a finite number, 1 for a zero, 2 for an
 * infinity and 3 for a NaN. */
typedef struct {
	int sign;
	int exp;
	u64 sig;
	int cls;
} Num;

static void unpackd(u64 b, Num *n)
{
	int e = (int)((b >> DMANT) & 0x7ff);
	u64 m = b & (((u64)1 << DMANT) - 1);

	n->sign = (int)(b >> 63) & 1;
	if (e == 0x7ff) {
		n->cls = m ? 3 : 2;
		n->exp = 0;
		n->sig = m;
		return;
	}
	if (e == 0) {
		if (m == 0) {
			n->cls = 1;
			n->exp = 0;
			n->sig = 0;
			return;
		}
		/* subnormal: normalise it and lower the exponent to match */
		n->cls = 0;
		n->exp = 1 - DBIAS;
		n->sig = m;
		while ((n->sig & ((u64)1 << DMANT)) == 0) {
			n->sig <<= 1;
			n->exp--;
		}
		return;
	}
	n->cls = 0;
	n->exp = e - DBIAS;
	n->sig = m | ((u64)1 << DMANT);
}

static u64 packd(int sign, int exp, u64 sig)
{
	return ((u64)(sign & 1) << 63) | ((u64)(exp & 0x7ff) << DMANT) |
	       (sig & (((u64)1 << DMANT) - 1));
}

static u64 dinf(int sign)  { return packd(sign, 0x7ff, 0); }
static u64 dzero(int sign) { return packd(sign, 0, 0); }
static u64 dnan(void)      { return packd(0, 0x7ff, (u64)1 << (DMANT - 1)); }

/*
 * Round a value whose significand is `sig` with `guard` bits of extra
 * precision below it, and whose exponent is that of bit (DMANT + guard) of
 * sig.  Ties go to even.
 */
static u64 rounded(int sign, int exp, u64 sig, int guard)
{
	u64 half, low, rest;

	if (sig == 0) return dzero(sign);
	/* bring the top set bit to position DMANT + guard */
	while (sig >> (DMANT + guard + 1)) {
		u64 sticky = sig & 1;
		sig = (sig >> 1) | sticky;
		exp++;
	}
	while ((sig >> (DMANT + guard)) == 0) {
		sig <<= 1;
		exp--;
	}
	/* a number too small to normalise loses bits instead */
	if (exp < 1 - DBIAS) {
		int shift = (1 - DBIAS) - exp;

		if (shift > 63) return dzero(sign);
		while (shift-- > 0) {
			u64 sticky = sig & 1;
			sig = (sig >> 1) | sticky;
		}
		exp = 1 - DBIAS;
		half = (u64)1 << (guard - 1);
		low = sig & (((u64)1 << guard) - 1);
		rest = sig >> guard;
		if (low > half || (low == half && (rest & 1)))
			rest++;
		if (rest >> DMANT)
			return packd(sign, 1, rest);
		return packd(sign, 0, rest);
	}
	half = (u64)1 << (guard - 1);
	low = sig & (((u64)1 << guard) - 1);
	rest = sig >> guard;
	if (low > half || (low == half && (rest & 1))) {
		rest++;
		if (rest >> (DMANT + 1)) {
			rest >>= 1;
			exp++;
		}
	}
	if (exp > DBIAS) return dinf(sign);
	return packd(sign, exp + DBIAS, rest);
}

/* shift right, keeping a sticky bit at the bottom */
static u64 shiftsticky(u64 v, int n)
{
	u64 sticky = 0;

	if (n >= 64) return v ? 1 : 0;
	if (n <= 0) return v;
	sticky = (v & (((u64)1 << n) - 1)) ? 1 : 0;
	return (v >> n) | sticky;
}

#define G 3			/* guard bits carried below the significand */

static u64 addmag(int sign, int ea, u64 sa, int eb, u64 sb)
{
	if (ea < eb) {
		int te = ea; u64 ts = sa;
		ea = eb; sa = sb; eb = te; sb = ts;
	}
	sa <<= G;
	sb = shiftsticky(sb << G, ea - eb);
	return rounded(sign, ea, sa + sb, G);
}

static u64 submag(int sign, int ea, u64 sa, int eb, u64 sb)
{
	u64 a, b;

	if (ea < eb || (ea == eb && sa < sb)) {
		int te = ea; u64 ts = sa;
		ea = eb; sa = sb; eb = te; sb = ts;
		sign ^= 1;
	}
	a = sa << G;
	b = shiftsticky(sb << G, ea - eb);
	if (a == b) return dzero(0);
	return rounded(sign, ea, a - b, G);
}

static u64 dadd(u64 x, u64 y, int flip)
{
	Num a, b;

	unpackd(x, &a);
	unpackd(y, &b);
	b.sign ^= flip;
	if (a.cls == 3 || b.cls == 3) return dnan();
	if (a.cls == 2 || b.cls == 2) {
		if (a.cls == 2 && b.cls == 2 && a.sign != b.sign)
			return dnan();
		return dinf(a.cls == 2 ? a.sign : b.sign);
	}
	if (a.cls == 1 && b.cls == 1) return dzero(a.sign & b.sign);
	if (a.cls == 1) return packd(b.sign, 0, 0) | (y ^ ((u64)flip << 63));
	if (b.cls == 1) return x;
	if (a.sign == b.sign)
		return addmag(a.sign, a.exp, a.sig, b.exp, b.sig);
	return submag(a.sign, a.exp, a.sig, b.exp, b.sig);
}

i64 __dadd(i64 x, i64 y) { return (i64)dadd((u64)x, (u64)y, 0); }
i64 __dsub(i64 x, i64 y) { return (i64)dadd((u64)x, (u64)y, 1); }
i64 __dneg(i64 x)        { return (i64)((u64)x ^ ((u64)1 << 63)); }

i64 __dmul(i64 x, i64 y)
{
	Num a, b;
	u64 hi, lo, sig;
	int sign, exp;

	unpackd((u64)x, &a);
	unpackd((u64)y, &b);
	sign = a.sign ^ b.sign;
	if (a.cls == 3 || b.cls == 3) return (i64)dnan();
	if (a.cls == 2 || b.cls == 2) {
		if (a.cls == 1 || b.cls == 1) return (i64)dnan();
		return (i64)dinf(sign);
	}
	if (a.cls == 1 || b.cls == 1) return (i64)dzero(sign);

	/* 53 x 53 -> 106 bits, of which the top 56 are kept */
	mulu64(a.sig, b.sig, &hi, &lo);
	exp = a.exp + b.exp;
	/* the product has its point after bit 2*DMANT; move it to
	 * DMANT + G, keeping everything below as a sticky bit */
	{
		int drop = 2 * DMANT - (DMANT + G);	/* 49 */
		u64 keep = (hi << (64 - drop)) | (lo >> drop);
		u64 sticky = (lo & (((u64)1 << drop) - 1)) ? 1 : 0;

		sig = keep | sticky;
	}
	return (i64)rounded(sign, exp, sig, G);
}

i64 __ddiv(i64 x, i64 y)
{
	Num a, b;
	u64 q = 0, r;
	int sign, exp, i;

	unpackd((u64)x, &a);
	unpackd((u64)y, &b);
	sign = a.sign ^ b.sign;
	if (a.cls == 3 || b.cls == 3) return (i64)dnan();
	if (a.cls == 2) {
		if (b.cls == 2) return (i64)dnan();
		return (i64)dinf(sign);
	}
	if (b.cls == 2) return (i64)dzero(sign);
	if (b.cls == 1) {
		if (a.cls == 1) return (i64)dnan();
		return (i64)dinf(sign);
	}
	if (a.cls == 1) return (i64)dzero(sign);

	/* one bit at a time: DMANT + G + 1 of them, then a sticky */
	exp = a.exp - b.exp;
	r = a.sig;
	for (i = 0; i <= DMANT + G; i++) {
		q <<= 1;
		if (r >= b.sig) {
			r -= b.sig;
			q |= 1;
		}
		r <<= 1;
	}
	if (r) q |= 1;
	/* q now holds the quotient with its point after bit DMANT + G */
	return (i64)rounded(sign, exp, q, G);
}

/* -1, 0, 1, or 2 when the two are unordered */
i64 __dcmp(i64 x, i64 y)
{
	Num a, b;

	unpackd((u64)x, &a);
	unpackd((u64)y, &b);
	if (a.cls == 3 || b.cls == 3) return 2;
	if (a.cls == 1 && b.cls == 1) return 0;
	if (a.sign != b.sign) return a.sign ? -1 : 1;
	if (a.cls == 2 && b.cls == 2) return 0;
	if (a.cls == 2) return a.sign ? -1 : 1;
	if (b.cls == 2) return b.sign ? 1 : -1;
	if (a.cls == 1) return a.sign ? 1 : -1;
	if (b.cls == 1) return b.sign ? -1 : 1;
	if (a.exp != b.exp) {
		int less = a.exp < b.exp;
		return (less != (a.sign != 0)) ? -1 : 1;
	}
	if (a.sig != b.sig) {
		int less = a.sig < b.sig;
		return (less != (a.sign != 0)) ? -1 : 1;
	}
	return 0;
}

/* conversions ---------------------------------------------------------- */

/* An integer, with its point at bit zero, as a double. */
static u64 fromu64(int sign, u64 m)
{
	int extra = 0;

	if (m == 0) return dzero(sign);
	/* make room for the guard bits below it */
	while (m >> (64 - G)) {
		u64 sticky = m & 1;

		m = (m >> 1) | sticky;
		extra++;
	}
	return rounded(sign, DMANT + extra, m << G, G);
}

i64 __i2d(i64 v)
{
	if (v < 0) return (i64)fromu64(1, (u64)0 - (u64)v);
	return (i64)fromu64(0, (u64)v);
}

i64 __u2d(i64 v)
{
	return (i64)fromu64(0, (u64)v);
}

i64 __d2u(i64 x)
{
	Num a;
	u64 m;
	int shift;

	unpackd((u64)x, &a);
	if (a.cls != 0) return 0;
	shift = a.exp - DMANT;
	if (a.exp < 0) return 0;
	if (a.exp > 63) return 0;
	m = a.sig;
	if (shift >= 0) {
		if (shift > 63) return 0;
		m <<= shift;
	} else {
		m = shift < -63 ? 0 : (m >> -shift);
	}
	return (i64)(a.sign ? (u64)0 - m : m);
}

i64 __d2i(i64 x)
{
	return __d2u(x);
}

/* float, through double ------------------------------------------------ */

static u64 f2d(u32 b)
{
	int e = (int)((b >> FMANT) & 0xff);
	u32 m = b & ((1u << FMANT) - 1);
	int sign = (int)(b >> 31) & 1;

	if (e == 0xff) {
		if (m) return dnan();
		return dinf(sign);
	}
	if (e == 0) {
		int exp;

		if (m == 0) return dzero(sign);
		exp = 1 - FBIAS;
		while ((m & (1u << FMANT)) == 0) {
			m <<= 1;
			exp--;
		}
		return rounded(sign, exp, (u64)m << (DMANT - FMANT + G), G);
	}
	return packd(sign, e - FBIAS + DBIAS,
		     (u64)m << (DMANT - FMANT));
}

static u32 d2f(u64 b)
{
	Num a;
	u64 sig;
	int exp;

	unpackd(b, &a);
	if (a.cls == 3) return 0x7fc00000u;
	if (a.cls == 2) return ((u32)a.sign << 31) | 0x7f800000u;
	if (a.cls == 1) return (u32)a.sign << 31;
	/* round the 53-bit significand down to 24, ties to even */
	exp = a.exp;
	sig = a.sig;
	{
		int drop = DMANT - FMANT;	/* 29 */
		u64 half = (u64)1 << (drop - 1);
		u64 low = sig & (((u64)1 << drop) - 1);
		u64 rest = sig >> drop;

		if (exp < 1 - FBIAS) {
			int shift = (1 - FBIAS) - exp;
			u64 s;

			if (shift > 31) return (u32)a.sign << 31;
			s = shiftsticky(sig, shift);
			low = s & (((u64)1 << drop) - 1);
			rest = s >> drop;
			if (low > half || (low == half && (rest & 1))) rest++;
			return ((u32)a.sign << 31) | (u32)rest;
		}
		if (low > half || (low == half && (rest & 1))) {
			rest++;
			if (rest >> (FMANT + 1)) {
				rest >>= 1;
				exp++;
			}
		}
		if (exp > FBIAS) return ((u32)a.sign << 31) | 0x7f800000u;
		return ((u32)a.sign << 31) |
		       ((u32)(exp + FBIAS) << FMANT) |
		       ((u32)rest & ((1u << FMANT) - 1));
	}
}

i64 __f2d(i64 x) { return (i64)f2d((u32)x); }
i64 __d2f(i64 x) { return (i64)(u64)d2f((u64)x); }

i64 __fadd(i64 x, i64 y)
{
	return __d2f(__dadd(__f2d(x), __f2d(y)));
}

i64 __fsub(i64 x, i64 y)
{
	return __d2f(__dsub(__f2d(x), __f2d(y)));
}

i64 __fmul(i64 x, i64 y)
{
	return __d2f(__dmul(__f2d(x), __f2d(y)));
}

i64 __fdiv(i64 x, i64 y)
{
	return __d2f(__ddiv(__f2d(x), __f2d(y)));
}

i64 __fneg(i64 x)  { return (i64)(u64)((u32)x ^ 0x80000000u); }
i64 __fcmp(i64 x, i64 y) { return __dcmp(__f2d(x), __f2d(y)); }

i64 __i2f(i64 v) { return __d2f(__i2d(v)); }
i64 __u2f(i64 v) { return __d2f(__u2d(v)); }
i64 __f2i(i64 x) { return __d2i(__f2d(x)); }
i64 __f2u(i64 x) { return __d2u(__f2d(x)); }

/*
 * Classification.  The argument is a bit pattern, like everything else
 * here.  Shifting the sign bit out leaves an unsigned value that orders
 * the same way the exponent and mantissa do, so one comparison answers
 * each question.
 */
#define DINF	0xffe0000000000000ULL
#define FINF	0xff000000U

i32 __disnan(i64 x) { return ((u64)x << 1) > DINF; }
i32 __disinf(i64 x) { return ((u64)x << 1) == DINF; }
i32 __disfin(i64 x) { return ((u64)x << 1) < DINF; }
i32 __disneg(i64 x) { return x < 0; }

i32 __disinfs(i64 x)
{
	if (!__disinf(x)) return 0;
	return x < 0 ? -1 : 1;
}

i32 __disnorm(i64 x)
{
	u64 e = ((u64)x >> DMANT) & 0x7ff;

	return e != 0 && e != 0x7ff;
}

i32 __fisnan(i64 x) { return ((u32)x << 1) > FINF; }
i32 __fisinf(i64 x) { return ((u32)x << 1) == FINF; }
i32 __fisfin(i64 x) { return ((u32)x << 1) < FINF; }
i32 __fisneg(i64 x) { return ((u32)x >> 31) != 0; }

i32 __fisinfs(i64 x)
{
	if (!__fisinf(x)) return 0;
	return ((u32)x >> 31) ? -1 : 1;
}

i32 __fisnorm(i64 x)
{
	u32 e = ((u32)x >> FMANT) & 0xff;

	return e != 0 && e != 0xff;
}
