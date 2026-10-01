/* SPDX-License-Identifier: ISC */
/* A shift by a constant count out of range is undefined, and it often
 * sits behind a guard that keeps it from running.  Folding one must not
 * stop the compile.  Found by csmith. */
static int
lsh(int a, unsigned b)
{
	return b < 32 ? a << b : a;
}

static int
rsh(int a, int b)
{
	return (b >= 0 && b < 32) ? a >> b : a;
}

/* csmith's guard: the right shift is folded while the count is known
 * to be negative, before the || that skips it is decided. */
static short
safe_lsh16(short left, unsigned right)
{
	return (left < 0 || (int)right < 0 || (int)right >= 32 ||
	    left > (32767 >> (int)right)) ? left : left << (int)right;
}

long long
shiftfold(int v)
{
	int x = v < -1000 ? 5 >> -1 : 7;
	long long y = v < -1000 ? 1LL << 70 : 9;

	return lsh(3, 2727571074u) + rsh(-64, -5) * 3 + lsh(1, 4) * 5 +
	    rsh(-64, 3) * 7 + x * 11 + y * 13 + lsh(v, 2) +
	    safe_lsh16(0, 2727571074u) * 17 + safe_lsh16(3, 2) * 19;
}
