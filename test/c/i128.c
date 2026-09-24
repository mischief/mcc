/* SPDX-License-Identifier: ISC */
/* GNU __int128: a scalar twice the register width on a 64-bit machine,
   which takes the same road a 64-bit one takes on a 32-bit machine. */
extern int printf(const char *, ...);

#ifdef __SIZEOF_INT128__
typedef unsigned __int128 u128;
typedef __int128 s128;
typedef unsigned long long u64;

union halves {
	u128 full;
	struct { u64 low, high; };
};

static u64 lo(u128 v) { return (u64)v; }
static u64 hi(u128 v) { return (u64)(v >> 64); }

static u128 add(u128 a, u128 b) { return a + b; }
static u128 sub(u128 a, u128 b) { return a - b; }
static u128 mul(u128 a, u128 b) { return a * b; }
static u128 divide(u128 a, u128 b) { return a / b; }
static u128 rem(u128 a, u128 b) { return a % b; }
static s128 sdiv(s128 a, s128 b) { return a / b; }

static void show(const char *what, u128 v)
{
	printf("%s %llx %llx\n", what, hi(v), lo(v));
}

/* A shift by a count the compiler cannot know takes a different road
   from one it can: the count decides between three shapes. */
static void counted(u128 a, s128 s)
{
	volatile int n;
	int k;

	for (k = 0; k < 130; k += 7) {
		n = k;
		printf("count %d %llx %llx %llx %llx %llx %llx\n", k,
		    hi(a << n), lo(a << n), hi(a >> n), lo(a >> n),
		    hi((u128)(s >> n)), lo((u128)(s >> n)));
	}
}

/* Constants the compiler works out itself: an enum, a static
   initializer, and the value a wide function returns. */
enum {
	SIGNED = ((s128)-1) < 0, UNSIGNED = ((u128)-1) < 0,
	BIG = ((u128)1 << 100) > ((u128)1 << 99),
	TOP = ((u128)-1 >> 127) == 1
};
static u128 ones = (u128)-1;
static s128 negbig = -((s128)1 << 70);
static s128 table[3] = {(s128)1 << 70, -2, [2] = 7};
typedef int ti __attribute__((mode(TI)));

static s128 pick(int c)
{
	if (c)
		return 0;
	return c ? (s128)1 : (s128)-1 << 80;
}

static void constants(void)
{
	printf("enum %d %d %d %d\n", SIGNED, UNSIGNED, BIG, TOP);
	show("ones", ones);
	show("negbig", (u128)negbig);
	show("table", (u128)table[0]);
	show("table1", (u128)table[1]);
	show("fold", ~(u128)0 ^ ((u128)1 << 64));
	show("pick", (u128)pick(1));
	show("pick0", (u128)pick(0));
	printf("mode %d\n", (int)sizeof(ti));
}

void i128test(void)
{
	u128 a = 1, b = 3;
	union halves h;
	s128 s;
	int i;

	a <<= 64;
	a |= 7;
	show("a", a);
	show("b", b);
	show("add", add(a, b));
	show("sub", sub(a, b));
	show("mul", mul(a, b));
	show("div", divide(a, b));
	show("rem", rem(a, b));
	show("and", a & 0xffff);
	show("or", b | a);
	show("xor", a ^ a);
	show("not", ~b);
	show("neg", -b);
	show("shr", a >> 60);
	show("shl", b << 100);
	printf("cmp %d %d %d %d\n", a > b, a < b, a == b, b >= b);

	s = -5;
	show("sneg", (u128)s);
	show("sdiv", (u128)sdiv(s, 2));
	show("sshr", (u128)(s >> 1));

	h.full = 0;
	h.low = 0x1122334455667788ULL;
	h.high = 0x99aabbccddeeff00ULL;
	show("halves", h.full);
	printf("size %d align %d\n", (int)sizeof(u128), (int)_Alignof(u128));

	for (i = 0; i < 3; i++)
		show("loop", add(a, (u128)i));
	counted(a, s);
	constants();
}
#else
void i128test(void) { }
#endif
