/* SPDX-License-Identifier: ISC */
extern int printf(const char *, ...);
unsigned bigcopy(int);
struct three { long a, b, c; };

struct three mk3(int k)
{
	struct three r = {k, 2 * k, 3 * k};

	return r;
}

long take3(long p, long q, long r, long s, long t, long u, long v, long w,
    struct three x, struct three y)
{
	return p + q * 2 + r + s + t + u + v + w * 3 + x.a + x.b * 5 + y.c * 7;
}

int main(void)
{
	printf("%u %u\n", bigcopy(3), bigcopy(100));
	return 0;
}
