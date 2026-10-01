/* SPDX-License-Identifier: ISC */
/* An empty record, a GNU extension, takes no argument register and
   no stack, and coming back it needs no hidden pointer. */

struct E { };
struct Z { int z[0]; };

struct E gempty(int, struct E, int, struct Z, int);
long gsum(struct E, int, struct E, int);

struct E empty(int a, struct E e, int b)
{
	extern long seen;

	seen = seen * 10 + a - b;
	return e;
}

long sum(struct E a, long x, struct Z z, struct E b, long y)
{
	return x * 100 + y;
}

long callgcc(int k)
{
	struct E e;
	struct Z z;

	gempty(k, e, k + 1, z, k + 2);
	return gsum(e, k, e, 3);
}
