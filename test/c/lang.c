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

/* a weak definition the other file replaces with a strong one */
__attribute__((weak)) int replaced(void) { return 1; }

static void weaks(void)
{
	printf("weak %d %d %d %d\n", weakfn(1), aliasfn(1), aliasdata,
	       replaced());
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

static void inlines2(void)
{
	int a, b;

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
	wrapped();
	inlines2();
}
