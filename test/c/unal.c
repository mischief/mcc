/* SPDX-License-Identifier: ISC */
/* Members of a packed record off their own alignment, read, written,
   stepped and copied.  A machine that faults on an unaligned load
   moves them in bytes. */
#include <stdint.h>

#pragma pack(1)
struct P { uint8_t a; int64_t b; int32_t c; int16_t d; signed f1 : 10;
	   unsigned f2 : 4; };
struct Q { char x; struct P p; };
#pragma pack()

struct P gp = {1, 0x1122334455667788LL, -7, 300, -100, 9};
struct Q gq = {2, {3, -5, 77, -2, 200, 3}};

/* No 64-bit multiply: the reference build for the Xtensa simulator
   cannot run one. */
int unal(int k)
{
	struct P lp = gp;
	struct Q *q = &gq;
	struct Q lq;

	gp.c += k;
	gp.d++;
	++gp.b;
	lp.f2 = 13;
	lp.f1--;
	q->p.c = q->p.c * 3;
	q->p.b <<= 4;
	lq.p = gp;
	lq.p.d--;
	return (int)gp.b + (int)(gp.b >> 32) * 2 + gp.c * 3 + gp.d * 5 +
	       gp.f1 * 7 + lp.f1 * 11 + lp.f2 * 13 + (int)q->p.b * 17 +
	       (int)(q->p.b >> 32) * 29 + q->p.c * 19 + lq.p.d * 23 +
	       lq.p.f2;
}
