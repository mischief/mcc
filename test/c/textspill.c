/* SPDX-License-Identifier: ISC */
/* A body built where it was called, inside the arguments of a call:
   its code is written before the place it goes, and must not take
   the spill slots that hold what the call has worked out so far. */

int add3(int a, int b, int c)
{
	return a * 100 + b * 10 + c;
}

static int div0(int a, int b)
{
	return b == 0 ? a : a / b;
}

static long long mod0(long long a, long long b)
{
	return b == 0 ? a : a % b;
}

int nest(int x, int y, int z)
{
	return add3(x * 2, div0(add3(1, y * 3, 2), 5), z * 7) +
	       x * div0(add3(y, z, x), 3);
}

long long wnest(signed char c)
{
	return mod0(3, div0((int)mod0(0, c), 5)) + mod0(100, mod0(c, 7) + 9);
}
