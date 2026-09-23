/* SPDX-License-Identifier: ISC */
/* Frame words shared between values that are never live at once.  Each
 * case keeps one value across something that could reuse its word: a
 * loop back edge, a goto backwards, a switch, and inline bodies whose
 * temporaries die before the next call. */
extern int printf(const char *, ...);

static inline long sq(long x) { long t = x * x; return t + 1; }
static inline long pair(long a, long b) { long s = sq(a); long d = sq(b); return s - d; }
static inline int pick(int k) { int r; switch (k & 3) { case 0: r = 5; break; case 1: r = sq(k); break; default: r = -k; } return r; }

static long loopy(int n)
{
	long keep = 7, acc = 0;
	int i;

	for (i = 0; i < n; i++) {
		long t = pair(i, n - i);
		acc += t + keep;
		keep = sq(i) & 0xff;
	}
	return acc + keep;
}

static long backgoto(int n)
{
	long a = 3, b = 0;
again:
	b += pair(a, n) + pick(n);
	if (--n > 0) {
		long c = sq(n);
		a = c - a;
		goto again;
	}
	return a * 31 + b;
}

static long many(long x)
{
	return sq(x) + sq(x + 1) + pair(x, 2) + pair(3, x) + sq(sq(x) & 7) +
		pick((int)x) + pick((int)x + 1) + pick((int)x + 2);
}

long frameshare(void)
{
	long v = 0;
	int k;

	for (k = 0; k < 6; k++)
		v = v * 3 + loopy(k) + backgoto(k) + many(k);
	printf("%ld %ld %ld %ld\n", loopy(9), backgoto(5), many(11), v);
	return 0;
}
