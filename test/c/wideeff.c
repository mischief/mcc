/* SPDX-License-Identifier: ISC */
/* An eight-byte element read for its effect only, through an index of
 * eight bytes.  On a 32-bit machine no instruction loads it, and the
 * address is still worked out.  Found by csmith. */
static unsigned long long g[4] = {1, 2, 3, 4};
static long long i = 1;
static int n;

static long long *
p(void)
{
	n++;
	return &i;
}

int
wideeff(int v)
{
	g[i + 1];
	g[*p() + 1];
	(void)g[*p() - 1];
	return n * 10 + v + (int)g[i + 2];
}
