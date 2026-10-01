/* SPDX-License-Identifier: ISC */
/* Bit-field initializers.  An unnamed bit-field is not a member, so it
 * takes no initializer.  In a packed record two bit-fields can share a
 * byte from different units, and both must keep their bits.  A member
 * below a bit-field in the same unit keeps its own bytes. */
#pragma pack(1)
struct straddle { unsigned a : 19; unsigned b : 22; };
struct hole { unsigned a : 9; unsigned : 2; unsigned b : 5; };
#pragma pack()
struct lead { signed : 5; unsigned f; };
struct gap { int x; unsigned : 3; unsigned : 0; int y; };
struct below { short f0; signed f1 : 12; };

struct straddle s1 = {-2301, 31555656636995};
struct hole h1 = {-1, 5};
struct lead l1 = {1};
struct gap g1 = {7, 8};
struct gap g2 = {.x = 3, 4};
struct below b1 = {0xBC00L, 0xBC00L};

static unsigned
sum(const void *p, unsigned n)
{
	const unsigned char *b = p;
	unsigned s = 0;

	while (n--)
		s = s * 31 + *b++;
	return s;
}

unsigned
bfinit(int v)
{
	struct straddle s2 = {v, v * 3};
	struct hole h2 = {v, v + 1};
	struct lead l2 = {v};
	struct below b2 = {v, v - 1};
	unsigned r = 0;

	r = r * 7 + sum(&s1, sizeof s1) + s1.a + s1.b;
	r = r * 7 + sum(&h1, sizeof h1) + h1.a + h1.b;
	r = r * 7 + l1.f + (unsigned)g1.x + (unsigned)g1.y;
	r = r * 7 + (unsigned)g2.x + (unsigned)g2.y;
	r = r * 7 + (unsigned)b1.f0 + (unsigned)b1.f1;
	r = r * 7 + s2.a + s2.b + h2.a + h2.b + l2.f;
	r = r * 7 + (unsigned)b2.f0 + (unsigned)b2.f1;
	return r;
}
