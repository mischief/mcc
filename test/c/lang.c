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

void lang(void)
{
	narrow();
	escapes();
	commas();
	bitcommas();
	typeofs();
	ternaries();
	compound();
	arrays();
	chunkid("abc");
	stepping();
}
