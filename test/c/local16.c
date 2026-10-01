/* SPDX-License-Identifier: ISC */
/* A local aligned to sixteen bytes starts on sixteen bytes, since code
   another compiler built may store to it with an aligned move.  The
   result slot of a call is such a local too. */

struct A { _Alignas(16) long a; long b; };
struct B { struct A x; long c[3]; };

struct E { };

void seen(const char *, const void *);
struct B mkb(long);
struct B mke(float _Complex, float _Complex, struct E, struct E, struct E);

long locals(long k)
{
	char c = (char)k;
	struct A a = {k, k + 1};
	long l = k * 3;
	struct A arr[3];
	int i = (int)k;
	struct B b = mkb(k);

	arr[1].a = k;
	seen("a", &a);
	seen("arr", arr);
	seen("b", &b);
	return c + a.a + a.b + l + arr[1].a + i + b.x.a + b.c[2];
}

/* Words before it in other numbers, used and unused. */
long one(long k)
{
	long x = k;
	struct A a = {k, k};

	seen("one", &a);
	return x + a.b;
}

long two(long k)
{
	long x = k, y = k * 2, z;
	struct A a = {x, y};

	seen("two", &a);
	return a.a + a.b;
}

long three(long k)
{
	long x = k, y = k * 2, z = k * 3;
	struct B b = mkb(x + y + z);

	seen("three", &b);
	return b.c[2];
}

/* Words nothing names, which the frame may drop. */
long four(long k)
{
	long u, v = k;
	struct B b = mkb(v);

	seen("four", &b);
	return b.c[2];
}

long five(long k)
{
	long u, w, v = k;
	struct B b = mkb(v);

	seen("five", &b);
	return b.c[2];
}

/* Blocks that give their words back. */
long six(long k)
{
	long t = 0;

	{
		long h = k;

		t += h;
	}
	{
		int a0 = k, a1 = k + 1, a2 = k + 2, a3 = k + 3, a4 = k + 4;
		struct B r;
		long h = 5;

		r = mkb(a0 + a1 + a2 + a3 + a4);
		seen("six", &r);
		t += r.c[2] + h;
	}
	return t;
}

/* An odd number of words whose address escapes. */
long seven(long k)
{
	char c1 = 1, c2 = 2, c3 = 3;
	struct B r;

	r = mkb(k);
	seen("seven", &r);
	return r.c[2] + *(volatile char *)&c1 + *(volatile char *)&c2 +
	       *(volatile char *)&c3;
}

/* Empty records, each a word of the frame. */
long eight(long k)
{
	float _Complex z, y;
	struct E e1, e2, e3;
	struct B r;

	((float *)&z)[0] = k;
	((float *)&z)[1] = 1;
	y = z;
	r = mke(z, y, e1, e2, e3);
	seen("eight", &r);
	return r.c[2];
}
