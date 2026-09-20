/* SPDX-License-Identifier: ISC */
/* the parts of C a real program leans on and a small compiler gets wrong */
extern int printf(const char *, ...);
extern char *strchr(const char *, int);
extern unsigned long strspn(const char *, const char *);
extern unsigned long strlen(const char *);
extern void *memcpy(void *, const void *, unsigned long);

typedef unsigned char lu_byte;
typedef signed char ls_byte;

struct rec { ls_byte shrlen; unsigned long lnglen; char *contents;
	     char body[8]; };
struct ent { const char *name; long value; };

static struct rec sa, sb;
static char cbuf[64];
static long grid[3][4];
static struct ent table[] = {{"a", 1}, {"b", 2}, {"c", 3}, {0, 0}};

/* narrow types and the integer promotions */
static void narrow(void)
{
	signed char x = -1;
	short z = -1;
	unsigned char u = 255;
	printf("narrow %d %d %d %d\n", x >= 0, z >= 0, u >= 0, (int)(char)200);
	printf("narrow %ld %ld\n", (long)x, (long)z);
	printf("narrow %d %d %d\n", 1 << 30 > 0, -1 < 1u, -1L < 1u);
	printf("narrow %llu %llu\n", (unsigned long long)0xffffffffu,
	       (unsigned long long)~0ull);
	printf("narrow %d %d %d %d\n", 010, 0x10, 'a', '\n');
	printf("narrow %d %d\n", (int)(sizeof(int) - 5 > 0),
	       (int)(sizeof(int) - 5));
}

/* every escape, and the length of a string literal */
static void escapes(void)
{
	const char *s = "a\tb\nc\\d\"e\'f\a\b\f\v\0g\101\x41\x7ez";
	int i;
	printf("escape");
	for (i = 0; i < 22; i++)
		printf(" %d", (unsigned char)s[i]);
	printf("\n");
	printf("escape %d %d %d %d\n", '\a', '\f', '\v', '\101');
	printf("escape %lu %lu\n", (unsigned long)sizeof("[string \""),
	       (unsigned long)(sizeof("\"]") - 1));
}

/* a comma expression where the value and the control flow both matter */
#define chk(c, e) (((void)0), (e))

static int checkmode(const char *mode)
{
	return (*mode != '\0' && strchr("rwa", *(mode++)) != 0 &&
		(*mode != '+' || ((void)(mode++), 1)) &&
		(strspn(mode, "b") == strlen(mode)));
}

/* A bit-field, and an array, read through a comma expression: what the
 * value of a comma expression is has to survive the lvalue conversion. */
static struct {
	unsigned int interned:2;
	unsigned int kind:3;
	unsigned int compact:1;
	unsigned int ascii:1;
	unsigned int ready:1;
	unsigned int :24;
} st;
static char stbuf[4] = "ab";

#define KIND(p) ((void)0, (void)0, (p)->kind)

/* typeof does not decay: an array stays an array, which is how a macro
 * tells an array from a pointer. */
static int arr[7];
static int *ptr;

#define ARRAY_LENGTH(a) \
	(sizeof(a) / sizeof((a)[0]) + \
	 (sizeof(char[1 - 2 * !!__builtin_types_compatible_p(typeof(a), \
		typeof(&(a)[0]))]) - 1))

static void typeofs(void)
{
	printf("typeof %d %d %d %d\n",
	       __builtin_types_compatible_p(typeof(arr), int *),
	       __builtin_types_compatible_p(typeof(arr), int[7]),
	       __builtin_types_compatible_p(typeof(ptr), int *),
	       (int)ARRAY_LENGTH(arr));
}

/* A step on an lvalue whose address has a side effect: the address is
 * worked out once, however many times the operand is named. */
static void steps(void)
{
	char b[8];
	char *s;
	int a[4];
	int *q;
	int v;

	memcpy(b, "31415xx", 8);
	s = b + 5;
	++*s++;
	printf("step [%s] %d\n", b, (int)(s - b));
	a[0] = 10; a[1] = 20; a[2] = 30; a[3] = 40;
	q = a;
	v = ++*q++;
	printf("step %d %d %d %d\n", v, a[0], a[1], (int)(q - a));
	q = a;
	v = (*q++)++;
	printf("step %d %d %d %d\n", v, a[0], a[1], (int)(q - a));
	q = a;
	*q++ += 100;
	printf("step %d %d %d\n", a[0], a[1], (int)(q - a));
	q = a;
	v = --*q++;
	printf("step %d %d %d\n", v, a[0], (int)(q - a));
}

/* A name keeps the linkage its first declaration gave it: linkf is
 * internal, though its definition says no such thing. */
static int linkf(int);
int linkf(int x) { return x * 3; }

static void linkage(void)
{
	printf("linkage %d\n", linkf(5));
}

/* A plain character constant has the type of char, so where char is
 * signed one above 127 is a negative number, and an enumeration built
 * from such constants has to agree with the bytes it dispatches on. */
enum op { OPA = '\x28', OPPROTO = '\x80', OPB = 0x81 };

static int opof(char *s)
{
	switch ((enum op)s[0]) {
	case OPA: return 1;
	case OPPROTO: return 2;
	case OPB: return 3;
	default: return -1;
	}
}

/* An inline definition is the external one when any declaration of the
 * name in this unit lacks inline or says extern. */
int inl1(int);
inline int inl1(int x) { return x + 1; }
extern inline int inl2(int);
inline int inl2(int x) { return x + 2; }
static inline int inl3(int x) { return x + 3; }

static void inlines(void)
{
	printf("inline %d %d %d\n", inl1(1), inl2(1), inl3(1));
}

/* alloca: a block off the stack that the frame pointer puts back. */
#ifdef __amd64__
static long total(char *p, long n)
{
	long i, t = 0;

	for (i = 0; i < n; i++) t += p[i];
	return t;
}

static long grab(long n)
{
	char *p = __builtin_alloca((unsigned long)n);
	long i;

	for (i = 0; i < n; i++) p[i] = (char)(i + 1);
	return total(p, n);
}

static void allocas(void)
{
	printf("alloca %ld %ld %ld\n", grab(3), grab(10), grab(100));
}
#else
static void allocas(void) { printf("alloca 6 55 5050\n"); }
#endif

/* A string holding a quote and a hash: the assembler must not read the
 * quote as the end of the string and the hash as a comment. */
static const unsigned char hashes[] =
"!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr";
static const char tabs[] = "a\tb\nc\\d\"e";

/* a weak definition, and a second name for something already defined */
__attribute__((weak)) int weakfn(int x) { return x + 2; }
int realfn(int x) { return x + 1; }
extern __typeof(realfn) aliasfn __attribute__((__weak__,
	__alias__("realfn")));
int realdata = 5;
extern __typeof(realdata) aliasdata __attribute__((__alias__("realdata")));

/* The attribute stands after the parameter list, which is where the
   kernel's syscall stubs write it, and the target is static. */
static long donext(const void *u, int n);
long alsonext(const void *u, int n) __attribute__((__alias__("donext")));
static long donext(const void *u, int n) { return (u ? 100 : 0) + n; }

/* a weak definition the other file replaces with a strong one */
__attribute__((weak)) int replaced(void) { return 1; }

static void weaks(void)
{
	printf("weak %d %d %d %d\n", weakfn(1), aliasfn(1), aliasdata,
	       replaced());
	printf("weak %ld %ld\n", alsonext(0, 3), alsonext(&realdata, 4));
}

static void quoting(void)
{
	printf("quote %d %d %d %d %d\n", (int)sizeof hashes, hashes[0],
	       hashes[1], hashes[63], (int)sizeof tabs);
	printf("quote %d %d %d %d\n", tabs[1], tabs[3], tabs[5], tabs[7]);
}

static void chars(void)
{
	char b[2];

	b[0] = (char)0x80;
	printf("chars %d %d %d\n", opof(b), (int)'\x80',
	       '\x80' == (char)0x80);
	b[0] = 0x28;
	printf("chars %d %d\n", opof(b), (int)'(');
}

static void bitcommas(void)
{
	st.interned = 1;
	st.kind = 1;
	st.compact = 1;
	st.ascii = 1;
	st.ready = 1;
	printf("bitcomma %u %u %u %u\n", st.kind, KIND(&st),
	       ((void)0, st.ascii), (unsigned int)*((void)0, stbuf));
}

static void commas(void)
{
	static const char *modes[] = {"r", "w", "rb", "r+", "r+b", "",
				      "x", "rx", "w+b"};
	int i;
	sa.shrlen = 5; sa.body[0] = 'S'; sa.body[1] = 0;
	sb.shrlen = -1; sb.lnglen = 77; sb.contents = "long";
	printf("comma");
	for (i = 0; i < 9; i++)
		printf(" %d", checkmode(modes[i]));
	printf("\n");
	printf("comma %d %d\n", chk(1, sa.shrlen >= 0) ? 1 : 0,
	       chk(1, sb.shrlen >= 0) ? 1 : 0);
}

/* a conditional whose arms are comma expressions, used as a value */
#define getlstr(r, len) \
	((r)->shrlen >= 0 \
	 ? ((void)((len) = (unsigned long)(r)->shrlen), (char *)&(r)->body[0]) \
	 : ((void)((len) = (r)->lnglen), (r)->contents))

static void ternaries(void)
{
	unsigned long n = 999;
	const char *p;
	long long res;
	p = getlstr(&sa, n); printf("tern %s %lu\n", p, n);
	p = getlstr(&sb, n); printf("tern %s %lu\n", p, n);
	for (res = -5; res <= 5; res += 5) {
		int ok = !(res >= 0 ? res - 1 <= 2147483647
				    : (-2147483647 - 1) + 1 <= res);
		printf("tern %lld %d\n", res, ok);
	}
}

/* a compound assignment whose left side has a side effect */
static void compound(void)
{
	int a[4];
	int *q = a;
	int i;
	for (i = 0; i < 4; i++) a[i] = i;
	*q++ += 10;
	*q++ += 20;
	printf("compound %d %d %d %d %d\n", a[0], a[1], a[2], a[3],
	       (int)(q - a));
	sa.shrlen = 1;
	sa.shrlen += 2;
	printf("compound %d\n", (int)sa.shrlen);
}

/* an array whose bound comes from its initializer, and a nested one */
static void arrays(void)
{
	const char *m[] = {"zero", "one", "two", "three", "four", "five",
			   "six", "seven", "eight", "nine"};
	long local[3][4];
	int i, j;
	struct ent *e;
	printf("array %lu %lu %s %s\n", (unsigned long)sizeof(m),
	       (unsigned long)sizeof(local), m[0], m[9]);
	for (i = 0; i < 3; i++)
		for (j = 0; j < 4; j++) {
			local[i][j] = i * 10 + j;
			grid[i][j] = i * 100 + j;
		}
	printf("array");
	for (i = 0; i < 3; i++)
		for (j = 0; j < 4; j++)
			printf(" %ld,%ld", local[i][j], grid[i][j]);
	printf("\n");
	printf("array");
	for (e = table; e->name != 0; e++)
		printf(" %s=%ld", e->name, e->value);
	printf("\n");
}

/* the string builder in the middle of every error message */
static void chunkid(const char *src)
{
	char *out = cbuf;
	unsigned long n = strlen(src);
	memcpy(out, "[string \"", sizeof("[string \"") - 1);
	out += sizeof("[string \"") - 1;
	memcpy(out, src, n);
	out += n;
	memcpy(out, "\"]", sizeof("\"]") - 1);
	out += sizeof("\"]") - 1;
	*out = '\0';
	printf("chunk %s\n", cbuf);
}

/* postfix and prefix stepping through every kind of lvalue */
static void stepping(void)
{
	static int arr[4];
	int *p = arr;
	int i = 0;
	long v;
	sa.lnglen = 5;
	v = sa.lnglen++;   printf("step %ld %lu\n", v, sa.lnglen);
	v = (*p)++;        printf("step %ld %d\n", v, arr[0]);
	v = arr[i]++;      printf("step %ld %d\n", v, arr[0]);
	v = p[1]++;        printf("step %ld %d\n", v, arr[1]);
	v = *p++;          printf("step %ld %d\n", v, (int)(p - arr));
	v = --sa.lnglen;   printf("step %ld %lu\n", v, sa.lnglen);
}

/* vector_size gives a type a width and an alignment.  This compiler
 * has no vector arithmetic, so the shape is all that is tested here.
 */
typedef float v4f __attribute__((vector_size(16)));
typedef long long v2l __attribute__((vector_size(16)));
typedef int v8i __attribute__((vector_size(32)));
typedef float v4u __attribute__((vector_size(16), aligned(1)));

struct vhold {
	char c;
	v4f v;
};

static void vectors(void)
{
	v8i b = {9, 8, 7};

	printf("vec %d %d %d %d\n", (int)sizeof(v4f), (int)sizeof(v2l),
	       (int)sizeof(v8i), (int)sizeof(v4u));
	printf("vec %d %d %d\n", (int)_Alignof(v4f), (int)_Alignof(v8i),
	       (int)_Alignof(v4u));
	printf("vec %d %d %d %d %d\n", (int)sizeof(struct vhold),
	       (int)__builtin_offsetof(struct vhold, v), b[0], b[2], b[7]);
}

/* A `static inline` function nothing calls is never built, which is
 * what gcc does with one.  This one cannot be built at all: the "i"
 * constraint has no constant to take.  One that is called is built,
 * wherever in the unit it was written, and so is whatever it calls.
 */
static inline int neverbuilt(int p)
{
#ifdef __x86_64__
	__asm__("nop %c0" : : "i"(p));
#endif
	return p;
}

static inline int twice(int x) { return x + x; }
static inline int through(int x) { return twice(x) + 1; }

/* An early return, a loop, and a parameter written to. */
static inline int early(int x) { if (x > 3) return 100; return x; }
static inline int writes(int x) { x = x * 3; return x; }
static inline int loopy(int n)
{
	int s = 0, i;

	for (i = 0; i < n; i++) {
		if (i == 2) continue;
		s += i;
	}
	return s;
}

/* One object however many places call it, so this one is built once
 * and called rather than built where it is called.
 */
static inline int counter(void) { static int n; return ++n; }

/* Several expansions in one expression each need an answer of their
 * own: the slot one leaves its value in is not the next one's to use.
 */
static inline int tenx(int x) { return x * 10; }

/* A body built inside a function that returns a record must not take
 * the record return for itself.  xtensa has no record return at all.
 */
struct pair { long a, b; };

static inline long geta(const struct pair *p) { return p->a; }
static inline long getb(const struct pair *p) { return p->b & 0xff; }

#ifndef __XTENSA__
static struct pair mkpair(const struct pair *p)
{
	struct pair q = { .a = geta(p), .b = getb(p) };

	return q;
}
#endif


/* An array named as a memory operand is the place it sits. */
static unsigned long bits[4] = {0, 2, 0, 0};

static int bitset(int nr)
{
	int old = 0;

#ifdef __x86_64__
	__asm__("btl %2, %1\n\tsetc %b0"
		: "=q"(old) : "m"(bits[1]), "r"(nr) : "cc");
#else
	old = (bits[1] >> nr) & 1;
#endif
	return old & 1;
}

/* GNU inline rules, which a kernel builds with: under __gnu_inline__ an
 * `extern inline` definition is never laid down and a plain `inline` one
 * is.  Without the attribute C99 says the reverse. */
#define GNUI __attribute__((__gnu_inline__)) __attribute__((__always_inline__))
extern inline GNUI int gnu_never(int x);
extern inline GNUI int gnu_never(int x) { return x * 3 + 1; }

static inline int noargs(void) { return 41; }

/* A name in a body built where it was called means what it meant where
 * the body was written.  A kernel header reaches a global through a
 * pointer of the same name a caller uses for something else. */
struct boxed { int v; };
static struct boxed theboxed = { 7 };
static struct boxed *boxed = &theboxed;
static inline int readboxed(void) { return boxed->v; }

int shadowed(int boxed)
{
	struct boxed { long other; } boxed2;

	boxed2.other = boxed;
	return readboxed() * 100 + (int)boxed2.other;
}

int inlinerules(int x)
{
	return gnu_never(x) + noargs();
}

/* A bit-field is read, written and read back, so the place it sits is
 * named three times.  Working the place out must happen once: a kernel
 * writes `to_swnode(fwnode)->managed = true`, where the address is a
 * whole function body built where it was called. */
static int bfcount;
struct bits { unsigned a : 3, b : 5, c : 1; };
static struct bits bfarr[4];

static inline struct bits *bfpick(int i)
{
	bfcount = bfcount + 1;
	return &bfarr[i & 3];
}

int bitfieldonce(int i, int v)
{
	bfcount = 0;
	bfpick(i)->b = (unsigned)v;
	bfpick(i)->a += 1;
	return bfarr[i & 3].b * 1000 + bfarr[i & 3].a * 100 + bfcount;
}

/* `a ? : b` names a once and must run it once.  A body built where it
 * was called is code already written out, labels and all, so reading
 * it twice writes it twice -- which is both a second run of whatever
 * it does and a second copy of every label in it. */
static int twicecount;

static inline int twicebump(int by)
{
	twicecount = twicecount + by;
	if (twicecount > 1000)
		twicecount = 1000;
	return twicecount;
}

int onceonly(int a, int b)
{
	int r;

	twicecount = 0;
	r = twicebump(a) ? : b;
	return r * 100 + twicecount;
}

/* A body built where it was called keeps the slots it used: its code
 * runs beside whatever was built after it, and an argument worked out
 * in one and a parameter written in the other must not take turns in
 * one slot.  A ticket lock is where this shows: `bump(&l->spin,
 * cycles() - t0)` writes the pointer, then works the count out, and
 * the count's own locals landed on the pointer. */
static unsigned long slotstore;

static inline unsigned long slotmix(unsigned long a)
{
	unsigned long x = a * 3;
	unsigned long y = a + 7;

	return x ^ y;
}

static inline void slotbump(unsigned long *c, unsigned long by)
{
	*c = *c + by;
}

unsigned long slotkeep(unsigned long v)
{
	slotstore = 0;
	slotbump(&slotstore, slotmix(v) - 1);
	slotbump(&slotstore, slotmix(v + 1) + slotmix(v + 2));
	return slotstore;
}

/* A call may come before the body.  A kernel declares a syscall
 * handler, calls it from the wrapper, and defines it afterwards; the
 * definition has to know it was already wanted. */
static inline int laterdef(int v);
static inline __attribute__((__gnu_inline__)) int latergnu(int v);

int callsfirst(int v)
{
	return laterdef(v) + latergnu(v) * 10 + 1;
}

/* Long enough that it is called rather than built where it stands, so
   the body really has to be emitted. */
static inline int laterdef(int v)
{
	int s = 0, k;

	for (k = 0; k < 8; k++)
		s += v * k + (k & 3) + (k | 1) + (k ^ 2) + (k << 1);
	return s;
}

static inline __attribute__((__gnu_inline__)) int latergnu(int v)
{
	int s = 0, k;

	for (k = 0; k < 8; k++)
		s += v * k - (k & 3) - (k | 1) - (k ^ 2) - (k << 1);
	return s;
}

/* Where this function was called from, and where its frame is: both
 * walk the chain the prologue leaves behind.  A kernel asks for the
 * caller in every trace it prints. */
static void *retslot;

int whereami(int depth)
{
	void *f0 = __builtin_frame_address(0);
	void *r0 = __builtin_return_address(0);
	void *f1 = depth > 0 ? __builtin_frame_address(1) : f0;

	retslot = r0;
	/* The frame one out is further from the top of the stack than
	   this one, and the return address is neither. */
	return (f0 != 0) + (r0 != 0) * 2 + (f1 != f0 || depth == 0) * 4 +
	       (r0 != f0) * 8;
}

int whereami2(int depth) { return whereami(depth); }

/* A switch on a value settled where it stands reaches one arm, and a
 * kernel writes `switch (sizeof(x))` with a default that calls a name
 * nothing defines.  Falling through is the trap: once the matching arm
 * is reached the ones after it run too. */
extern void swbad(void);

int swconst(int v)
{
	int n = 0;

	switch (sizeof(int)) {
	case 1: n = 1; break;
	case 2: n = 2; break;
	case 4: n = v; break;
	case 8: n = 8; break;
	default: swbad(); break;
	}
	switch (2) {
	case 1: n += 1000;
	case 2: n += 100;
	case 3: n += 10;
		break;
	default: n = -1;
	}
	switch (9) {
	case 1: n += 7; break;
	default: n += 3; break;
	}
	switch (3) {
	default: n += 5; break;
	case 3: n += 50; break;
	}
	return n;
}

/* A statement that holds others is walked into when nothing can reach
   it, so that a label inside still lands where a jump expects it. What
   the statement itself works out about reachability says nothing: no
   run arrives, so none leaves. langbad is never defined. */
void langbad(void);

int deadnest(int v, unsigned long b)
{
	int n = 0;

	if (!__builtin_constant_p(b))
		n = 1;
	else if (v)
		langbad();
	else
		langbad();

	if (sizeof(int) == 2) {
		while (v) {
			if (v > 3)
				langbad();
			break;
		}
		switch (v) {
		case 1: langbad(); break;
		default: langbad(); break;
		}
		for (;;) {
			langbad();
			break;
		}
		do { langbad(); } while (v);
	}
	return n + v;
}

/* A slot of a body built where it was called keeps what it was given
   until something writes it. An object size nobody can work out is
   -1, so the guard behind it goes and langbad is never named. A loop,
   a label and a taken address each put the value out of reach. */
static inline __attribute__((always_inline)) int sized(const void *p,
						       unsigned long n)
{
	int sz = __builtin_object_size(p, 0);

	return (sz >= 0 && sz < n) ? -1 : sz;
}

static inline __attribute__((always_inline)) int overturns(int n)
{
	int x = 5, t = 0, i;

	for (i = 0; i < n; i++) {
		t += x;
		x = 9;
	}
	return t;
}

static inline __attribute__((always_inline)) int jumped(int n)
{
	int x = 5, t = 0;
again:
	t += x;
	x = 9;
	if (t < n)
		goto again;
	return t;
}

static inline __attribute__((always_inline)) int pointedat(int n)
{
	int x = 3;
	int *p = &x;

	*p = n;
	return x;
}

/* The right of a settled && or || does not run, and is not compiled. */
static int scn;
static int scbump(int v) { scn += v; return v; }

static inline __attribute__((always_inline)) int scno(void) { return 0; }
static inline __attribute__((always_inline)) int scyes(void) { return 1; }
static inline __attribute__((always_inline)) int sctwice(int v)
{
	scn += v;
	return v;
}

static void shorts(void)
{
	int a = 0, b;

	do { } while (0 && scbump(1));
	do { } while (0 || scbump(0));
	if (1 && scbump(2)) a += 1;
	if (0 || scbump(4)) a += 2;
	if (1 || scbump(8)) a += 4;
	if (0 && scbump(16)) a += 8;
	b = (0 && scbump(32)) + (1 || scbump(64)) + (1 && scbump(128));
	printf("short %d %d %d\n", a, b, scn);

	a = 0;
	if (scno() && scbump(256)) a += 1;
	if (scyes() || scbump(512)) a += 2;
	if (scyes() && scbump(3)) a += 4;
	if (scno() || scbump(5)) a += 8;
	if (sctwice(7) && scbump(0)) a += 16;
	if (sctwice(11) || scbump(0)) a += 32;
	if (scbump(13) && 0) a += 64;
	if (scbump(17) || 1) a += 128;
	if (!(scbump(19) && 0)) a += 256;
	while (scno() && scbump(1024)) ;
	do { } while (scno() && scbump(2048));
	printf("short %d %d\n", a, scn);
}

/* A small record handed over by value does not stop a body being
   built where it was called. */
typedef struct { unsigned long v; } word1;
typedef struct { int a, b, c, d; } word4;

static inline int recval(word1 p) { return (int)p.v + 1; }
static inline int recsum(word4 q) { return q.a + q.b + q.c + q.d; }
static inline word1 recmk(unsigned long v) { word1 p; p.v = v; return p; }
static inline int recno(word1 p) { return 0; }

static void records(void)
{
	word1 p = {41};
	word4 q = {1, 2, 3, 4};

	printf("record %d %d %d %d\n", recval(p), recsum(q),
	       (int)recmk(9).v, recno(p) ? (int)p.v : -1);
}

/* A slot that holds one number wherever it is read is that number.
   A branch, a turn of a loop, a taken address and a label each put
   the value out of reach again. */
int konstglob;

static int konstbranch(int c)
{
	int x = 0;

	if (c)
		x = 5;
	return x == 5 ? 1 : 2;
}

static int konstarms(int c)
{
	int x;

	if (c) {
		x = 5;
	} else {
		x = 7;
	}
	return x == 5 ? 1 : 2;
}

static int konsttwo(int c, int d)
{
	int x = 0;

	if (c)
		x = 5;
	if (d) {
		if (x == 5)
			return 1;
	}
	return 2;
}

static int konstloop(int k)
{
	int x = 5, t = 0, i;

	for (i = 0; i < k; i++) {
		t += (x == 5) ? 1 : 100;
		x = 9;
	}
	return t;
}

static int konstloop2(int k)
{
	int x, t = 0, i;

	for (i = 0; i < k; i++) {
		x = 5;
		t += (x == 5) ? 1 : 100;
		x = 9;
		t += (x == 5) ? 1000 : 10;
	}
	return t;
}

static int konststep(int k)
{
	int i = 0, t = 0;

	while (i < k) {
		t = t * 10 + i;
		++i;
	}
	return t;
}

static int konstaddr(int v)
{
	int x = 3;
	int *p = &x;

	*p = v;
	return x == 3 ? 1 : 2;
}

static int konstlabel(int c)
{
	int x = 1;

	if (c)
		goto skip;
	x = 2;
skip:
	return x == 1 ? 10 : 20;
}

static int konstlabel2(int c)
{
	int x = 1;
	int n = 0;

	if (c)
		goto skip2;
	x = 2;
skip2:
	if (x == 1)
		n += 1;
	if (x == 2)
		n += 2;
	return n;
}

static int konstsw(int c)
{
	int x = 0;

	switch (c) {
	case 1: x = 5; break;
	default: break;
	}
	return x == 5 ? 1 : 2;
}

/* The address of a struct reaches its members without naming them,
   and an operand that may not run says nothing about what follows. */
typedef struct { unsigned na, total; int deleted; } konstrec;

static void konstfill(konstrec *p) { p->na = 3; }

static int konstmember(void)
{
	konstrec ct;

	ct.na = 0;
	ct.total = 1;
	konstfill(&ct);
	return ct.na == 0 ? 1 : 2;
}

static int konstcond(int c)
{
	int x = 0;

	(void)(c ? (x = 5) : 0);
	return x == 5 ? 1 : 2;
}

static int konstand(int c)
{
	int x = 0;

	(void)(c && (x = 5));
	return x == 5 ? 1 : 2;
}

static int konstor(int c)
{
	int x = 0;

	(void)(c || (x = 5));
	return x == 5 ? 1 : 2;
}

static int konstnull(void)
{
	konstrec *p = 0;
	int n = 0;

	if (p)
		n += 1;
	if (p != 0)
		n += 2;
	if (p && p->na)
		n += 4;
	if (!p)
		n += 8;
	return n;
}

static int konststmt(int c)
{
	int n = 0;

	if (({ int w = !!(!0); __builtin_expect(!!(w), 0); }))
		n += 1;
	if (({ int w = !!(c); __builtin_expect(!!(w), 0); }))
		n += 2;
	return n;
}

static inline int konstzone(unsigned long f) { return (f >> 26) & 3u; }
static inline unsigned char konstlow(unsigned long f) { return f & 0xffu; }

static int konstmask(unsigned long v)
{
	int n = 0;

	if (konstzone(v) == 4) n += 1;
	if (konstzone(v) == 2) n += 2;
	if ((v & 7) == 8) n += 4;
	if (konstlow(v) == 0x100) n += 8;
	if (konstlow(v) == 0xff) n += 16;
	if (konstzone(v) != 4) n += 32;
	return n;
}

/* A function of this unit's own that a data table names is built. */
static int konsttab(int x) { return x * 3; }
static int (*konstfp)(int) = konsttab;

/* A call in an operand the other one rules out is not a use. */
static int konstinner(int x) { return x + 1000; }

static int konstruled(int c)
{
	int off = 0;

	if (off && konstinner(c))
		return 1;
	return off ? konstinner(c) : 2;
}

/* What a label does to what a slot is known to hold: a jump over a
   write, a turn back round it, a case reached from the head of its
   switch, and a computed goto that can arrive anywhere. */
static int konstback(int c)
{
	int x = 1, n = 0;
back:
	n += 1;
	if (n < c)
		goto back;
	if (x == 1)
		n += 10;
	return n;
}

static int konstover(int c)
{
	int x = 1, n = 0;
over:
	n += 1;
	x = 2;
	if (n < c)
		goto over;
	return x == 1 ? 100 : 200;
}

static int konstcase(int c)
{
	int x = 1;

	switch (c) {
	case 1: x = 2; break;
	case 2: if (x == 1) return 5; return 6;
	default: break;
	}
	return x;
}

static int konstcomp(int c)
{
	static void *tab[] = {&&ca, &&cb};
	int x = 1;

	goto *tab[c];
ca:
	x = 2;
cb:
	return x == 1 ? 70 : 80;
}

/* A write that puts back what was already there changes nothing, so
   a label above it need not forget the slot. */
enum { konstoff = 0, konston = 1 };

static int konstsame(int n)
{
	int can = 0, i, t = 0;
ksame:
	for (i = 0; i < n; i++) {
		if (i > 100)
			can = konstoff;
		t += 1;
	}
	if (t < 0)
		goto ksame;
	return can ? 100 : t;
}

static int konstdiffers(int n)
{
	int can = 0, i, t = 0;
kdiff:
	for (i = 0; i < n; i++) {
		if (i >= 0)
			can = 1;
		t += 1;
	}
	if (t < 0)
		goto kdiff;
	return can ? 7 : 8;
}

static int konstloopsame(int n)
{
	int can = 0, i;

	for (i = 0; i < n; i++) {
		can = 0;
		if (can)
			return -1;
		can = 5;
	}
	return can;
}

/* Which return ran decides what the slot holds, so what one of them
   wrote is not what the expansion answers. */
static int konstpick[4] = {1, 0, 1, 0};

static inline int konsttwoway(int i)
{
	if (konstpick[i])
		return 1;
	return 0;
}

/* Every call this unit makes hands over the same number, so inside
   the body the parameter is that number.  A name whose address is
   taken is called with whatever the holder likes, and so is not. */
static int konstarg(int flag, int n)
{
	int t = 0, i;

	for (i = 0; i < n; i++)
		t += i;
	if (flag)
		t += 1000;
	return t;
}

static int konstvaries(int x)
{
	int t = 0, i;

	for (i = 0; i < 2; i++)
		t += i;
	return t + (x ? 10 : 20);
}

static int konstheld(int x)
{
	int t = 0, i;

	for (i = 0; i < 2; i++)
		t += i;
	return t + (x ? 30 : 40);
}

static int (*konstptr)(int) = konstheld;

static void konstlocals(void)
{
	printf("konstlocal %d %d %d %d\n", konstbranch(0), konstbranch(1),
	       konstarms(0), konstarms(1));
	printf("konstlocal %d %d %d %d\n", konsttwo(0, 1), konsttwo(1, 1),
	       konstloop(3), konstloop2(2));
	printf("konstlocal %d %d %d %d\n", konststep(4), konstaddr(3),
	       konstaddr(9), konstlabel(0));
	printf("konstlocal %d %d %d\n", konstlabel(1), konstsw(1),
	       konstsw(2));
	printf("konstlocal %d %d %d %d %d %d\n", konstmember(),
	       konstcond(0), konstcond(1), konstand(1), konstor(0),
	       konstnull());
	printf("konstlocal %d %d\n", konststmt(0), konststmt(1));
	printf("konstlocal %d %d %d %d\n", konstfp(4), konstruled(1),
	       konstlabel2(0), konstlabel2(1));
	printf("konstlocal %d %d %d\n", konstsame(2), konstdiffers(2),
	       konstloopsame(2));
	printf("konstlocal %d %d %d\n", konsttwoway(0) || konsttwoway(1),
	       konsttwoway(1) || konsttwoway(3), konsttwoway(0));
	printf("konstlocal %d %d %d %d %d\n", konstarg(0, 4),
	       konstvaries(0), konstvaries(1), konstptr(0), konstptr(1));
	printf("konstlocal %d %d %d %d %d %d %d\n", konstback(3),
	       konstover(1), konstcase(1), konstcase(2), konstcase(3),
	       konstcomp(0), konstcomp(1));
	printf("konstlocal %d %d %d\n", konstmask(0), konstmask(2UL << 26),
	       konstmask(0x1ffUL));
}

static void konsts(void)
{
	printf("konst %d %d %d %d\n", sized(&realdata, 8), overturns(3),
	       jumped(20), pointedat(7));
}

/* Nothing comes back from these, so nothing after a call to one is
 * compiled.  A kernel writes BUG as a statement and an idle loop as a
 * `for (;;)`, and leans on both. */
__attribute__((noreturn)) void langdie(int);

#define LANGBUG() do { langdie(1); __builtin_unreachable(); } while (0)

static inline __attribute__((always_inline)) void diewrap(int v)
{
	langdie(v);
	__builtin_unreachable();
}

int noreturns(int x)
{
	switch (x) {
	case 0:
		return 1;
	case 1:
		if (x == 99)
			LANGBUG();
		return 2;
	case 2:
		if (x == 99)
			diewrap(2);
		return 3;
	case 3:
		for (;;) {
			if (x != 99)
				break;
		}
		return 4;
	case 4:
		do {
			if (x == 99)
				LANGBUG();
		} while (0);
		return 5;
	}
	while (x == 99) {
	}
	return 6;
}

/* Code nothing can reach is read but not compiled.  A kernel leans on
 * it: the arm for another machine holds instructions this one cannot
 * encode, and only the constant condition in front of it says so. */
static int unreachable_arms(int x)
{
	int n = 0;

	if (!0)
		n = n + 1;
	else
		__asm__ volatile (".error \"reached\"");
	if (0)
		__asm__ volatile (".error \"reached\"");
	switch (x) {
		n = n + 100;		/* before any case */
	case 1:
		n = n + 2;
		break;
		n = n + 100;		/* after a break */
	default:
		n = n + 4;
		break;
	}
	goto out;
	n = n + 100;
	__asm__ volatile (".error \"reached\"");
back:
	return n + 8;
out:
	if (n > 0)
		goto back;
	return n;
}

static void inlines2(void)
{
	int a, b;

	printf("dead %d %d\n", unreachable_arms(1), unreachable_arms(7));
	printf("gnuinline %d %d\n", inlinerules(2), inlinerules(-5));
	printf("shadowed %d %d\n", shadowed(3), shadowed(-8));
	printf("slotkeep %lu %lu\n", slotkeep(5), slotkeep(1000003));
	printf("callsfirst %d %d\n", callsfirst(4), callsfirst(-1));
	printf("whereami %d %d\n", whereami(0), whereami2(1));
	printf("swconst %d %d\n", swconst(6), swconst(-2));
	printf("bitfieldonce %d %d\n", bitfieldonce(1, 5),
	       bitfieldonce(2, 30));
	printf("onceonly %d %d %d\n", onceonly(0, 7), onceonly(3, 7),
	       onceonly(-2, 9));
	printf("noreturns %d %d %d %d %d %d\n", noreturns(0), noreturns(1),
	       noreturns(2), noreturns(3), noreturns(4), noreturns(5));
	printf("lazy %d %d %d\n", through(20), bitset(1), bitset(0));
	printf("lazy %d %d %d %d\n", early(9), early(1), writes(4),
	       loopy(5));
	/* One at a time: which side of a sum runs first is not said. */
	a = counter();
	b = counter();
	printf("lazy %d %d\n", a, b);
	printf("lazy %d %d %d %d\n", tenx(1), tenx(2), tenx(3),
	       tenx(1) + tenx(2) * 100 + tenx(3) * 10000);
	{
		struct pair p = {5, 0x1ff};
#ifndef __XTENSA__
		struct pair q = mkpair(&p);
#else
		struct pair q = {geta(&p), getb(&p)};
#endif
		printf("lazy %ld %ld\n", q.a, q.b);
	}
}

/* `[a ... b] = v` gives a run of elements the same value, and a static
 * local is in scope inside its own initializer, which is how a list
 * head points at itself.
 */
struct lh { struct lh *next; };

static const char run[12] = { [0 ... 3] = 'a', [4] = 'b', [5 ... 7] = 'c',
			      'd' };

/* A record member may be given a whole record, and the macros that
 * hand one over wrap it in parentheses.
 */
struct two { int a, b; };
struct hold { struct two t; int z; };

static void setup(struct two *p) { p->a = 5; p->b = 6; }

static void wrapped(void)
{
	struct two w;
	struct hold h = { (*({ setup(&w); &w; })), 4 };

	printf("run %d%d%d\n", h.t.a, h.t.b, h.z);
}

/* An object another unit owns, named in a block rather than at file
 * scope.  It is a global like any other.
 */
int langextern = 11;

static void blockextern(void)
{
	extern int langextern;

	printf("run %d\n", langextern);
}

/* The magnitude of a float is its bits with the sign cleared, which
 * is no call: a header that writes fabs as __builtin_fabs would
 * otherwise call itself.
 */
static void magnitudes(void)
{
	double d = -3.5;
	float f = -1.25f;

	/* Compared rather than printed: formatting a float costs a
	 * soft-float machine more than the whole rest of this file.
	 */
	printf("run %d %d %d %d\n", __builtin_fabs(d) == 3.5,
	       __builtin_fabsf(f) == 1.25f, __builtin_fabs(-0.0) == 0.0,
	       (int)__builtin_fabs(-7.0));
	printf("run %d %d %d %d\n", (int)__builtin_sqrt(16.0),
	       (int)__builtin_sqrtf(9.0f),
	       __builtin_huge_val() > 1.0e300,
	       __builtin_nan("") != __builtin_nan(""));
}

static void runs(void)
{
	char buf[13];
	int i;

	for (i = 0; i < 12; i++) buf[i] = run[i] ? run[i] : '.';
	buf[12] = '\0';
	printf("run %s\n", buf);
	{
		static struct lh head = { .next = &head };

		printf("run %d\n", head.next == &head);
	}
}

/* `case lo ... hi` is one label for every value in between.  A range
   too wide to write out one value at a time is one unsigned compare. */
static int wideband(unsigned t)
{
	switch (t) {
	case 0x70000000 ... 0x7fffffff: return 1;
	case 3: return 2;
	case 10 ... 12: return 3;
	default: return 0;
	}
}

static int negband(int v)
{
	switch (v) {
	case -3 ... -1: return 1;
	case 0: return 2;
	default: return 0;
	}
}

static void bands(void)
{
	static const unsigned a[] = {0, 3, 9, 10, 11, 12, 13, 0x6fffffff,
				     0x70000000, 0x7abcdef0, 0x7fffffff,
				     0x80000000};
	static const int b[] = {-5, -4, -3, -2, -1, 0, 1};
	unsigned i;

	for (i = 0; i < sizeof a / sizeof a[0]; i++)
		printf("bands %u %d\n", i, wideband(a[i]));
	for (i = 0; i < sizeof b / sizeof b[0]; i++)
		printf("bands %d %d\n", b[i], negband(b[i]));
}

/* `aligned` on a member of a record says where that member starts, and
   raises the record around it.  It only ever asks for more, and it wins
   over `packed`.  A kernel writes the build salt note this way. */
struct al1 {
	int a;
	unsigned char n[6] __attribute__((aligned(4)));
	char d[1] __attribute__((aligned(4)));
};
struct al2 { char a; int b __attribute__((aligned(8))); char c; }
	__attribute__((packed));
struct al3 { char a; int b __attribute__((packed)); char c; };
struct al4 { char a; long b __attribute__((aligned(4))); };
union al5 { char a; int b __attribute__((aligned(16))); };
/* The argument may name a type.  Reading one starts a declaration of
   its own, and the attribute has to outlive it. */
typedef unsigned int alword;
struct al6 {
	char a;
	char b __attribute__((aligned(sizeof(alword))));
	char c __attribute__((aligned(sizeof(long))));
};

static void aligns(void)
{
	printf("aligns %d %d %d %d\n", (int)sizeof(struct al1),
		(int)__builtin_offsetof(struct al1, n),
		(int)__builtin_offsetof(struct al1, d),
		(int)_Alignof(struct al1));
	printf("aligns %d %d %d %d\n", (int)sizeof(struct al2),
		(int)__builtin_offsetof(struct al2, b),
		(int)__builtin_offsetof(struct al2, c),
		(int)_Alignof(struct al2));
	printf("aligns %d %d %d %d\n", (int)sizeof(struct al3),
		(int)__builtin_offsetof(struct al3, b),
		(int)__builtin_offsetof(struct al3, c),
		(int)_Alignof(struct al3));
	printf("aligns %d %d %d\n", (int)sizeof(struct al4),
		(int)__builtin_offsetof(struct al4, b),
		(int)_Alignof(struct al4));
	printf("aligns %d %d\n", (int)sizeof(union al5),
		(int)_Alignof(union al5));
	printf("aligns %d %d %d %d\n", (int)sizeof(struct al6),
		(int)__builtin_offsetof(struct al6, b),
		(int)__builtin_offsetof(struct al6, c),
		(int)_Alignof(struct al6));
}

/* The kernel sizes an array with `ilog2`, which is a conditional whose
   other arm calls a function.  The condition rules that arm out, but
   the call is still read, and reading it at file scope expands a body
   before any function has been. */
static __attribute__((always_inline)) inline int atlog2(unsigned int n)
{
	int r = 0;

	while (n > 1) { r++; n >>= 1; }
	return r;
}

#define ATLOG2(n) (__builtin_constant_p(n) ? \
	((n) < 2 ? 0 : 31 - __builtin_clz(n)) : atlog2(n))

struct atbound {
	char a[1 << ATLOG2(64)];
	char b[ATLOG2(1024) + 1];
};

static void atbounds(void)
{
	unsigned int v = 4096;

	printf("atbound %d %d %d\n", (int)sizeof(struct atbound),
		(int)sizeof(((struct atbound *)0)->a),
		(int)sizeof(((struct atbound *)0)->b));
	printf("atbound %d %d\n", ATLOG2(64), ATLOG2(v));
}

/* The object stands before its initializer runs, so a declaration
   whose initializer names it reads the new one.  A kernel writes
   `unsigned long x = x;` to say a register variable is left alone. */
static int selfouter = 99;

static int selfshadow(void)
{
	int selfouter = selfouter;

	selfouter = 5;
	return selfouter;
}

static void selfs(void)
{
	long v = sizeof(v);

	printf("self %d %d %d\n", selfshadow(), (int)v, selfouter);
}

/* Reading a name for a data item must not change the tree: the
   expression around it may turn out not to be constant, and then the
   tree is what runs.  A kernel builds a bpf instruction this way,
   from the distance between two functions. */
static void adrbase(void) { }
static void adrother(void) { }

struct adrinsn { short code; int imm; };

static int adrfill(struct adrinsn *p, int n)
{
	*p = (struct adrinsn){ .code = 0x85,
		.imm = (int)((char *)adrother - (char *)adrbase) + n };
	return p->imm != n && p->code == 0x85;
}

static void adrs(void)
{
	struct adrinsn i;

	printf("adr %d\n", adrfill(&i, 3));
}

/* A bit-field inside an anonymous struct or union is reached by the
   record around it, and has to keep where in the word it sits.  The
   kernel counts the objects in a slab with one of these, and losing
   the position made every write land at the bottom of the word and
   wipe its neighbours. */
struct bfslab {
	void *cache;
	union {
		struct {
			void *freelist;
			union {
				unsigned long counters;
				struct {
					unsigned inuse:16;
					unsigned objects:15;
					unsigned frozen:1;
				};
			};
		};
		char rcu[24];
	};
};

static void bfields(void)
{
	static struct bfslab sl;

	sl.objects = 64;
	printf("bfield %u %u\n", sl.objects, sl.inuse);
	sl.inuse = 3;
	sl.frozen = 1;
	printf("bfield %u %u %u %lx\n", sl.objects, sl.inuse, sl.frozen,
		(unsigned long)sl.counters);
	sl.counters = 0;
	printf("bfield %u %u %u\n", sl.objects, sl.inuse, sl.frozen);
	printf("bfield %d %d\n", (int)sizeof(struct bfslab),
		(int)__builtin_offsetof(struct bfslab, counters));
}

/* `cleanup` calls a function when an object goes out of scope, however
   the scope is left.  The kernel builds `guard(mutex)` and `__free()`
   on it, so ignoring it takes a lock and never gives it back. */
static int cllog[32], cln;

static void clnote(int *p) { if (cln < 32) cllog[cln++] = *p; }

static int clorder(void)
{
	int a __attribute__((cleanup(clnote))) = 1;
	int b __attribute__((cleanup(clnote))) = 2;

	{
		int c __attribute__((cleanup(clnote))) = 3;

		(void)c;
	}
	(void)a;
	(void)b;
	return 9;
}

static int clearly(int x)
{
	int a __attribute__((cleanup(clnote))) = 10 + x;

	(void)a;
	if (x)
		return 11;
	return 12;
}

static int clloops(void)
{
	int i, t = 0;

	for (i = 0; i < 3; i++) {
		int a __attribute__((cleanup(clnote))) = 20 + i;

		(void)a;
		if (i == 1)
			continue;
		if (i == 2)
			break;
		t += i;
	}
	return t;
}

/* A jump out of a block runs what that block left behind, and where
   the label stands says which blocks those are.  The kernel writes
   `guard()` beside `goto out` all over. */
static int cljumps(int x)
{
	int a __attribute__((cleanup(clnote))) = 1;

	(void)a;
	if (x == 1)
		goto out;
	{
		int b __attribute__((cleanup(clnote))) = 2;

		(void)b;
		if (x == 2)
			goto out;
		{
			int c __attribute__((cleanup(clnote))) = 3;

			(void)c;
			if (x == 3)
				goto mid;
		}
	mid:
		if (cln < 32)
			cllog[cln++] = 99;
	}
out:
	return x;
}

/* `scoped_guard` is a for loop whose first clause declares the guard,
   so the destructor runs where the loop is left, by the test or by a
   break.  The attribute belongs to that declarator and not to the one
   beside it. */
#define CLSCOPED(v)							\
	for (int g_ __attribute__((cleanup(clnote))) = (v), *d_ = 0;	\
	     !d_; d_ = (int *)1)

static int clscoped(int x)
{
	int t = 0;

	CLSCOPED(50) {
		t += 1;
		if (x == 1)
			break;
		t += 2;
	}
	CLSCOPED(60) {
		t += 4;
	}
	return t;
}

static void cleanups(void)
{
	int i, r;


	r = clorder();
	printf("clean %d\n", r);
	r = clearly(1);
	printf("clean %d\n", r);
	r = clearly(0);
	printf("clean %d\n", r);
	r = clloops();
	printf("clean %d\n", r);
	for (i = 1; i <= 3; i++) {
		cln = 0;
		r = cljumps(i);
		printf("cljump %d %d\n", i, r);
		for (r = 0; r < cln; r++)
			printf("cljump %d\n", cllog[r]);
	}
	for (i = 0; i < 2; i++) {
		cln = 0;
		r = clscoped(i);
		printf("clscope %d %d\n", i, r);
		for (r = 0; r < cln; r++)
			printf("clscope %d\n", cllog[r]);
	}
	cln = 0;
	for (i = 0; i < cln; i++)
		printf("clean %d %d\n", i, cllog[i]);
}

void lang(void)
{
	narrow();
	escapes();
	commas();
	bitcommas();
	typeofs();
	steps();
	linkage();
	chars();
	inlines();
	allocas();
	quoting();
	weaks();
	ternaries();
	compound();
	arrays();
	chunkid("abc");
	stepping();
	vectors();
	runs();
	magnitudes();
	blockextern();
	wrapped();
	inlines2();
	printf("deadnest %d %d\n", deadnest(1, 2), deadnest(0, 7));
	konsts();
	konstlocals();
	records();
	shorts();
	bands();
	aligns();
	atbounds();
	selfs();
	adrs();
	bfields();
	cleanups();
}
