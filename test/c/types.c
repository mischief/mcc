/* SPDX-License-Identifier: ISC */
/* structs, unions, typedefs, enums, sizeof, casts, switch, goto, ?: */

typedef unsigned char byte;
typedef struct Point Point;

struct Point {
	int x;
	int y;
};

union Value {
	long i;
	void *p;
	byte b[8];
};

struct Node {
	struct Node *next;
	Point at;
	union Value v;
	char tag;
};

enum Kind { K_NIL, K_INT = 10, K_STR, K_LAST };

struct Node nodes[4];
Point origin;

long sizes(void)
{
	return sizeof(Point) * 1000000 + sizeof(union Value) * 10000
	     + sizeof(struct Node) * 100 + sizeof(byte) * 10 + sizeof(long);
}

long kinds(void)
{
	return K_NIL * 100 + K_INT * 10 + K_STR + K_LAST * 1000;
}

long dot(Point *p)
{
	return p->x * p->x + p->y * p->y;
}

long member(void)
{
	Point a;
	Point b;

	a.x = 3;
	a.y = 4;
	b = a;				/* whole struct assignment */
	b.x = b.x + 10;
	return dot(&a) * 1000 + dot(&b);
}

long chain(void)
{
	long i;
	long s;

	for (i = 0; i < 4; i++) {
		nodes[i].at.x = (int)i;
		nodes[i].at.y = (int)(i * i);
		nodes[i].v.i = i + 100;
		nodes[i].tag = (char)('a' + i);
		nodes[i].next = (i + 1 < 4) ? &nodes[i + 1] : (struct Node *)0;
	}
	s = 0;
	{
		struct Node *n;
		for (n = &nodes[0]; n; n = n->next)
			s = s * 10 + n->at.x + n->at.y + (n->v.i - 100)
			  + (n->tag - 'a');
	}
	return s;
}

long unions(void)
{
	union Value v;

	v.i = 0;
	v.b[0] = 1;
	v.b[1] = 2;
	v.b[7] = 8;
	return v.i;
}

long pick(long n)
{
	switch (n) {
	case 0:
		return 100;
	case 1:
	case 2:
		return 200;
	case 10:
		n = n * 3;
		break;
	default:
		return -1;
	}
	return n;
}

long jumps(long n)
{
	long s;

	s = 0;
top:
	if (n <= 0)
		goto done;
	s = s + n;
	n = n - 1;
	goto top;
done:
	return s;
}

long tern(long a, long b)
{
	return (a > b ? a : b) * 10 + (a < b ? 1 : 0);
}

long casts(void)
{
	long l;
	int i;
	byte c;

	l = 300;
	c = (byte)l;
	i = (int)l * 1000;
	return (long)c + i + (long)(int)(l * 100000000);
}

long steps(void)
{
	long a[4];
	long *p;
	struct Node *n;
	long i;
	long s;

	for (i = 0; i < 4; i++)
		a[i] = i;
	p = a;
	s = 0;
	s = s * 10 + *p++;
	s = s * 10 + *p++;
	p--;
	s = s * 10 + *p;
	n = &nodes[0];
	n->at.x = 5;
	s = s * 100 + n->at.x++;
	s = s * 100 + n->at.x;
	n->tag = 'a';
	s = s * 10 + (n->tag++ - 'a');
	s = s * 10 + (n->tag - 'a');
	return s;
}

typedef long (*Fn)(long, long);

struct Ops {
	Fn add;
	Fn mul;
	char *name;
};

static long o_add(long a, long b) { return a + b; }
static long o_mul(long a, long b) { return a * b; }

struct Ops ops;

long indirect(long a, long b)
{
	Fn f;
	long (*g)(long, long);
	long s;

	ops.add = o_add;
	ops.mul = o_mul;
	f = ops.add;
	g = &o_mul;
	s = f(a, b);
	s = s * 1000 + (*g)(a, b);
	s = s * 1000 + ops.mul(a, b);
	s = s * 1000 + (*ops.add)(a, b);
	return s;
}

long many(long a, long b, long c, long d, long e, long f, long g, long h,
	  long i, long j)
{
	return a * 1000000000 + b * 100000000 + c * 10000000 + d * 1000000
	     + e * 100000 + f * 10000 + g * 1000 + h * 100 + i * 10 + j;
}

long callmany(long n)
{
	return many(n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7,
		    n + 8, n + 9)
	     + many(1, 2, 3, 4, 5, 6, 7, 8, 9, 0);
}

/* A pointer to an array is not an array: only the outermost array of a
   parameter decays, so the bound inside the parentheses is kept. */
struct cell { int a; long b; };

long rowsize(long (*rows)[4], struct cell (*cells)[8], long n)
{
	long flat[4];
	long s;

	s = (long)sizeof(*rows) * 100 + (long)sizeof(**rows) * 10
	  + (long)sizeof(*cells) + (long)sizeof(**cells)
	  + (long)sizeof(rows) + (long)sizeof(flat);
	(*rows)[0] = n;
	(*rows)[3] = n * 2;
	(*cells)[0].a = (int)n;
	(*cells)[7].b = n * 3;
	return s + (*rows)[0] + (*rows)[3] + (*cells)[0].a + (*cells)[7].b;
}

long rows(long n)
{
	long r[4];
	struct cell c[8];

	return rowsize(&r, &c, n);
}

/* A packed enumeration takes the narrowest type that holds its
   values, which a kernel counts on when it lays a structure out. */
enum small { S1 = 1, S2, S3 } __attribute__((packed));
enum mid { M1 = 300, M2 } __attribute__((packed));
enum signd { N1 = -1, N2 = 5 } __attribute__((packed));
enum wide { W1 = 70000 } __attribute__((packed));
enum plain { P1 = 1, P2 };

struct packedin { char c; enum small a; char d; enum mid b; };

long enums(long v)
{
	struct packedin s;

	s.c = (char)v;
	s.a = S2;
	s.d = (char)(v + 1);
	s.b = M2;
	return (long)sizeof(enum small) * 100000
	     + (long)sizeof(enum mid) * 10000
	     + (long)sizeof(enum signd) * 1000
	     + (long)sizeof(enum wide) * 100
	     + (long)sizeof(enum plain) * 10
	     + (long)sizeof(struct packedin)
	     + s.c + s.d + (long)s.a + (long)s.b + (long)N1 + (long)W1;
}

/* How big the object behind a pointer is.  This compiler does not
 * track it, and the builtin has an answer for exactly that case: all
 * ones where it is asked for the most there could be, zero for the
 * least.  A kernel guards a call to a name nothing defines with it,
 * so the answer has to be the one that says "no idea" rather than a
 * size that would make the guard fire. */
static char osbuf[10];

long objsizes(long v)
{
    char *p = osbuf + (v & 1);
    unsigned long a = __builtin_object_size(p, 0);
    unsigned long b = __builtin_object_size(p, 1);
    unsigned long c = __builtin_object_size(p, 2);
    unsigned long d = __builtin_object_size(p, 3);

    return (long)(a == (unsigned long)-1) * 1000 +
           (long)(b == (unsigned long)-1) * 100 +
           (long)(c == 0) * 10 + (long)(d == 0);
}

/* The overflow builtins: the wrapped value goes through the pointer and
 * the answer says whether the true one fit.  Every pair of widths and
 * signs, worked out where the operands and the answer do not share a
 * type. */
long overflows(long v)
{
	signed char c = 0;
	unsigned char uc = 0;
	short sh = 0;
	unsigned short us = 0;
	int i = 0;
	unsigned u = 0;
	long l = 0;
	unsigned long ul = 0;
	long n = 0;
	int a = (int)v, b = (int)(v * 1000003);
	unsigned ua = (unsigned)v;
	long la = v * 1000000007L;

	n = n * 2 + __builtin_add_overflow(a, b, &i) + i;
	n = n * 2 + __builtin_sub_overflow(a, b, &i) + i;
	n = n * 2 + __builtin_mul_overflow(a, b, &i) + i;
	n = n * 2 + __builtin_add_overflow(ua, ua, &u) + (long)u;
	n = n * 2 + __builtin_sub_overflow(ua, ua + 1, &u) + (long)u;
	n = n * 2 + __builtin_mul_overflow(ua, ua, &u) + (long)u;
	n = n * 2 + __builtin_add_overflow(la, la, &l) + l;
	n = n * 2 + __builtin_mul_overflow(la, la, &l) + l;
	n = n * 2 + __builtin_mul_overflow(la, la, &ul) + (long)ul;
	n = n * 2 + __builtin_add_overflow(a, b, &c) + c;
	n = n * 2 + __builtin_add_overflow(a, b, &uc) + uc;
	n = n * 2 + __builtin_mul_overflow(a, b, &sh) + sh;
	n = n * 2 + __builtin_add_overflow(a, b, &us) + us;
	n = n * 2 + __builtin_sub_overflow(ua, la, &i) + i;
	n = n * 2 + __builtin_sub_overflow(ua, la, &l) + l;
	n = n * 2 + __builtin_mul_overflow(ua, la, &ul) + (long)ul;
	return n;
}
