/* SPDX-License-Identifier: ISC */
/* The two-byte floats.  A value moves as two bytes and travels in an
   xmm register; arithmetic on one is done in a float, and crossing
   widths calls the runtime gcc calls. */
extern int printf(const char *, ...);
extern void *memcpy(void *, const void *, unsigned long);

typedef _Float16 h;
typedef __bf16 b;

static unsigned hb(h x) { unsigned short u; memcpy(&u, &x, 2); return u; }
static unsigned bb(b x) { unsigned short u; memcpy(&u, &x, 2); return u; }

static h gh = 1.5;
static b gb = -3.25;
static h tbl[5] = {0.1, 65504.0, 1e-7, -0.0, 1e6};
struct pair { char x; h y; char z; };

h hadd(h x, h y) { return x + y; }
b bmul(b x, float y) { return x * y; }
float hup(h x) { return x; }
double bup(b x) { return x; }
h fromd(double d) { return d; }
/* OpenBSD's compiler_rt has no __truncxfbf2, so the long double
   narrows to binary16 here. */
h fromld(long double d) { return d; }
struct pair mkpair(h y) { struct pair p = {1, y, 2}; return p; }

void halftest(void)
{
	h a = 2.0, c, n, *q;
	b d;
	struct pair p;
	int i;

	c = hadd(a, gh);
	d = bmul(gb, 3.0f);
	printf("calls %04x %04x %d %d\n", hb(c), bb(d), (int)(hup(c) * 100),
	    (int)(bup(d) * 100));
	for (i = 0; i < 5; i++)
		printf("tbl %04x\n", hb(tbl[i]));
	printf("round %04x %04x %04x\n", hb(fromd(1.0009765625)),
	    hb(fromd(1.00146484375)), hb(fromd(-70000.0)));
	printf("ldround %04x %04x %04x\n", hb(fromld(1.00048828125L)),
	    hb(fromld(3.0e38L)), bb(bmul(1.00390625, 1.0f)));
	n = -c;
	printf("neg %04x %d %d\n", hb(n), n < a, !n);
	c += 1;
	c++;
	printf("inc %04x %d\n", hb(c), (int)c);
	p = mkpair(3.0);
	printf("pair %d %04x %d %d\n", p.x, hb(p.y), p.z, (int)sizeof p);
	q = &tbl[0];
	*q = -*q;
	printf("store %04x %d\n", hb(tbl[0]), a > 1.5 ? 1 : 0);
	printf("sizes %d %d\n", (int)sizeof(h), (int)_Alignof(b));
}
