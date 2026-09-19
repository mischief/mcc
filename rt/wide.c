/* SPDX-License-Identifier: 0BSD */
/*
 * A scalar twice the register width, on a machine that cannot hold one.
 *
 * A value twice the register width cannot sit in a register, and this
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
typedef unsigned long long u32;
typedef long long i32;
#define HB 64
#define QB 32
#else
typedef unsigned int u32;
typedef int i32;
#define HB 32
#define QB 16
#endif

typedef struct {
	u32 lo, hi;
} W;

#define A (*(const W *)a)
#define B (*(const W *)b)
#define D (*(W *)d)

void __w_add(void *d, const void *a, const void *b)
{
	u32 lo = A.lo + B.lo;
	D.hi = A.hi + B.hi + (lo < A.lo);
	D.lo = lo;
}

void __w_sub(void *d, const void *a, const void *b)
{
	u32 lo = A.lo - B.lo;
	D.hi = A.hi - B.hi - (A.lo < B.lo);
	D.lo = lo;
}

void __w_and(void *d, const void *a, const void *b)
{
	D.lo = A.lo & B.lo;
	D.hi = A.hi & B.hi;
}

void __w_or(void *d, const void *a, const void *b)
{
	D.lo = A.lo | B.lo;
	D.hi = A.hi | B.hi;
}

void __w_xor(void *d, const void *a, const void *b)
{
	D.lo = A.lo ^ B.lo;
	D.hi = A.hi ^ B.hi;
}

void __w_neg(void *d, const void *a)
{
	u32 lo = -A.lo;
	D.hi = ~A.hi + (lo == 0);
	D.lo = lo;
}

void __w_not(void *d, const void *a)
{
	D.lo = ~A.lo;
	D.hi = ~A.hi;
}

/* One half times another, in two halves: the widest product a machine
   can work out in one instruction is half by half. */
static void mulhalf(W *r, u32 x, u32 y)
{
	u32 mask = ((u32)1 << QB) - 1;
	u32 xl = x & mask, xh = x >> QB;
	u32 yl = y & mask, yh = y >> QB;
	u32 ll = xl * yl, lh = xl * yh, hl = xh * yl, hh = xh * yh;
	u32 mid = lh + hl;
	u32 carry = (mid < lh) ? ((u32)1 << QB) : 0;
	u32 lo = ll + (mid << QB);

	r->lo = lo;
	r->hi = hh + (mid >> QB) + carry + (lo < ll);
}

void __w_mul(void *d, const void *a, const void *b)
{
	W r;

	mulhalf(&r, A.lo, B.lo);
	r.hi += A.lo * B.hi + A.hi * B.lo;
	D = r;
}

/* Restoring division on the two halves: one bit at a time, which is slow
 * and short.  Nothing here is on a path that matters yet.
 *
 * Everything below names its operands by address rather than passing them
 * by value, because a compiler for a small machine need not support passing
 * a structure in registers, and this one does not.
 */
static void divmod(W *q, W *r, const W *np, const W *mp)
{
	W n = *np, m = *mp;
	int i;

	q->lo = q->hi = 0;
	r->lo = r->hi = 0;
	if (m.lo == 0 && m.hi == 0)
		return;
	for (i = 2 * HB - 1; i >= 0; i--) {
		u32 bit = (i >= HB) ? (n.hi >> (i - HB)) : (n.lo >> i);

		r->hi = (r->hi << 1) | (r->lo >> (HB - 1));
		r->lo = (r->lo << 1) | (bit & 1);
		if (r->hi > m.hi || (r->hi == m.hi && r->lo >= m.lo)) {
			u32 lo = r->lo - m.lo;

			r->hi = r->hi - m.hi - (r->lo < m.lo);
			r->lo = lo;
			if (i >= HB)
				q->hi |= (u32)1 << (i - HB);
			else
				q->lo |= (u32)1 << i;
		}
	}
}

static int neg(const W *v)
{
	return (v->hi >> (HB - 1)) != 0;
}

static void negate(W *v)
{
	u32 lo = -v->lo;

	v->hi = ~v->hi + (lo == 0);
	v->lo = lo;
}

void __w_divu(void *d, const void *a, const void *b)
{
	W q, r;

	divmod(&q, &r, (const W *)a, (const W *)b);
	D = q;
}

void __w_modu(void *d, const void *a, const void *b)
{
	W q, r;

	divmod(&q, &r, (const W *)a, (const W *)b);
	D = r;
}

void __w_divs(void *d, const void *a, const void *b)
{
	W x = A, y = B, q, r;
	int s = neg(&x) ^ neg(&y);

	if (neg(&x)) negate(&x);
	if (neg(&y)) negate(&y);
	divmod(&q, &r, &x, &y);
	if (s) negate(&q);
	D = q;
}

void __w_mods(void *d, const void *a, const void *b)
{
	W x = A, y = B, q, r;
	int s = neg(&x);

	if (neg(&x)) negate(&x);
	if (neg(&y)) negate(&y);
	divmod(&q, &r, &x, &y);
	if (s) negate(&r);
	D = r;
}

void __w_shl(void *d, const void *a, int n)
{
	W v = A;

	n &= 2 * HB - 1;
	if (n == 0) { D = v; return; }
	if (n >= HB) {
		D.hi = v.lo << (n - HB);
		D.lo = 0;
	} else {
		D.hi = (v.hi << n) | (v.lo >> (HB - n));
		D.lo = v.lo << n;
	}
}

void __w_shru(void *d, const void *a, int n)
{
	W v = A;

	n &= 2 * HB - 1;
	if (n == 0) { D = v; return; }
	if (n >= HB) {
		D.lo = v.hi >> (n - HB);
		D.hi = 0;
	} else {
		D.lo = (v.lo >> n) | (v.hi << (HB - n));
		D.hi = v.hi >> n;
	}
}

void __w_shrs(void *d, const void *a, int n)
{
	W v = A;
	u32 sign = (u32)((i32)v.hi >> (HB - 1));

	n &= 2 * HB - 1;
	if (n == 0) { D = v; return; }
	if (n >= HB) {
		D.lo = (u32)((i32)v.hi >> (n - HB));
		D.hi = sign;
	} else {
		D.lo = (v.lo >> n) | (v.hi << (HB - n));
		D.hi = (u32)((i32)v.hi >> n);
	}
}

int __w_cmpu(const void *a, const void *b)
{
	if (A.hi != B.hi)
		return A.hi < B.hi ? -1 : 1;
	if (A.lo != B.lo)
		return A.lo < B.lo ? -1 : 1;
	return 0;
}

int __w_cmps(const void *a, const void *b)
{
	if (A.hi != B.hi)
		return (i32)A.hi < (i32)B.hi ? -1 : 1;
	if (A.lo != B.lo)
		return A.lo < B.lo ? -1 : 1;
	return 0;
}

/* widening and narrowing across the register width */
void __w_exts(void *d, i32 v)
{
	D.lo = (u32)v;
	D.hi = (u32)(v >> (HB - 1));
}

void __w_extu(void *d, u32 v)
{
	D.lo = v;
	D.hi = 0;
}

u32 __w_lo(const void *a)
{
	return A.lo;
}
