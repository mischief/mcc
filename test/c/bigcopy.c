/* SPDX-License-Identifier: ISC */
/* Records bigger than the offset field of a load or store: copied,
 * zeroed, passed and returned by value, and assigned in a chain, which
 * uses the pointers the copy was handed.  Records of three words cross
 * to and from functions the system compiler built.  Found by csmith. */
struct big { long head; char mid[40001]; long tail; };
struct three { long a, b, c; };
struct three mk3(int k);
long take3(long p, long q, long r, long s, long t, long u, long v, long w,
    struct three x, struct three y);
struct pair { unsigned long f0; signed char f1; };

static struct big a, b, c;

static unsigned
sum(const void *p, unsigned n)
{
	const unsigned char *s = p;
	unsigned r = 0;

	while (n--)
		r = r * 31 + *s++;
	return r;
}

static struct big
make(int v)
{
	struct big r;
	unsigned i;

	for (i = 0; i < sizeof r.mid; i++)
		r.mid[i] = (char)(i * 7 + v);
	r.head = v;
	r.tail = -v;
	return r;
}

static long
take(struct big x, int k)
{
	return x.head + x.tail * 3 + x.mid[k] + x.mid[sizeof x.mid - 1];
}

unsigned
bigcopy(int v)
{
	struct pair z[4][10][6] = {};
	unsigned r;

	a = make(v);
	c = b = a;
	/* not the whole of c: make leaves the padding unset */
	r = sum(c.mid, sizeof c.mid) + (unsigned)c.head + (unsigned)c.tail;
	r = r * 7 + (unsigned)take(b, v & 1023);
	z[3][9][5].f1 = (signed char)v;
	r = r * 7 + sum(z, sizeof z);
	{
		struct three t = mk3(v);

		r = r * 7 + (unsigned)(t.a + t.b * 3 + t.c * 5);
		r = r * 7 + (unsigned)take3(1, 2, 3, 4, 5, 6, 7, 8, t, mk3(-v));
	}
	return r;
}
