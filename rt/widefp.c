/*
 * The floating point runtime for a machine whose registers are four bytes.
 *
 * Same arithmetic as rt/softfp.c -- this is only the shape of the call.  A
 * double does not fit a register there, so it is named by its address; a
 * float is one word and still rides in one.
 */

typedef unsigned int u32;
typedef int i32;
typedef unsigned long long u64;
typedef long long i64;

i64 __dadd(i64, i64);
i64 __dsub(i64, i64);
i64 __dmul(i64, i64);
i64 __ddiv(i64, i64);
i64 __dneg(i64);
i64 __dcmp(i64, i64);
i64 __i2d(i64);
i64 __u2d(i64);
i64 __d2i(i64);
i64 __d2u(i64);
i64 __f2d(i64);
i64 __d2f(i64);

static u64 ld(const void *p)
{
	const unsigned char *s = (const unsigned char *)p;
	u64 v = 0;
	int i;

	for (i = 7; i >= 0; i--) v = (v << 8) | (u64)s[i];
	return v;
}

static void st(void *p, u64 v)
{
	unsigned char *t = (unsigned char *)p;
	int i;

	for (i = 0; i < 8; i++) {
		t[i] = (unsigned char)(v & 0xff);
		v >>= 8;
	}
}

void __w_dadd(void *d, const void *a, const void *b)
{
	st(d, (u64)__dadd((i64)ld(a), (i64)ld(b)));
}

void __w_dsub(void *d, const void *a, const void *b)
{
	st(d, (u64)__dsub((i64)ld(a), (i64)ld(b)));
}

void __w_dmul(void *d, const void *a, const void *b)
{
	st(d, (u64)__dmul((i64)ld(a), (i64)ld(b)));
}

void __w_ddiv(void *d, const void *a, const void *b)
{
	st(d, (u64)__ddiv((i64)ld(a), (i64)ld(b)));
}

i64 __dfloor(i64);
i64 __dceil(i64);
i64 __dtrunc(i64);
i64 __drint(i64);

void __w_dfloor(void *d, const void *a) { st(d, (u64)__dfloor((i64)ld(a))); }
void __w_dceil(void *d, const void *a)  { st(d, (u64)__dceil((i64)ld(a))); }
void __w_dtrunc(void *d, const void *a) { st(d, (u64)__dtrunc((i64)ld(a))); }
void __w_drint(void *d, const void *a)  { st(d, (u64)__drint((i64)ld(a))); }

void __w_dneg(void *d, const void *a)
{
	st(d, (u64)__dneg((i64)ld(a)));
}

i32 __w_dcmp(const void *a, const void *b)
{
	return (i32)__dcmp((i64)ld(a), (i64)ld(b));
}

void __w_i2d(void *d, i32 v)  { st(d, (u64)__i2d((i64)v)); }
void __w_u2d(void *d, u32 v)  { st(d, (u64)__u2d((i64)(u64)v)); }
void __w_f2d(void *d, u32 v)  { st(d, (u64)__f2d((i64)(u64)v)); }

i32 __w_d2i(const void *a)    { return (i32)__d2i((i64)ld(a)); }
u32 __w_d2u(const void *a)    { return (u32)__d2u((i64)ld(a)); }
u32 __w_d2f(const void *a)    { return (u32)__d2f((i64)ld(a)); }

void __w_l2d(void *d, const void *a)  { st(d, (u64)__i2d((i64)ld(a))); }
void __w_ul2d(void *d, const void *a) { st(d, (u64)__u2d((i64)ld(a))); }
void __w_d2l(void *d, const void *a)  { st(d, (u64)__d2i((i64)ld(a))); }
void __w_d2ul(void *d, const void *a) { st(d, (u64)__d2u((i64)ld(a))); }
