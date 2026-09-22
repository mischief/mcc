/* SPDX-License-Identifier: ISC */
/* Arrays whose bound is worked out where they stand.  The room comes
   off the stack, the name is the pointer to it, and sizeof answers
   with what it turned out to be. */
#include <stddef.h>

static long take(int *p, int n)
{
	long t = 0;
	int i;

	for (i = 0; i < n; i++) t += p[i];
	return t;
}

long simple(long n)
{
	int a[n];
	int i;
	long t = 0;

	for (i = 0; i < n; i++) a[i] = i * i;
	for (i = 0; i < n; i++) t += a[i];
	return t + (long)sizeof(a) + take(a, (int)n);
}

long bytes(long n)
{
	char b[n + 1];
	long i, t = 0;

	for (i = 0; i < n; i++) b[i] = (char)('a' + i);
	b[n] = 0;
	for (i = 0; b[i]; i++) t += b[i];
	return t + (long)sizeof(b);
}

/* Only the outermost bound varies, which is the shape a library uses
   for a table of small fixed rows. */
long rows(long n)
{
	unsigned char m[n][2];
	long i, t = 0;

	for (i = 0; i < n; i++) {
		m[i][0] = (unsigned char)i;
		m[i][1] = (unsigned char)(i * 3);
	}
	for (i = 0; i < n; i++) t += m[i][0] * 10 + m[i][1];
	return t + (long)sizeof(m) + (long)sizeof(m[0]);
}

struct cell { int a; char b; };

long records(long n)
{
	struct cell v[n];
	long i, t = 0;

	for (i = 0; i < n; i++) {
		v[i].a = (int)i;
		v[i].b = (char)(i + 1);
	}
	for (i = 0; i < n; i++) t += v[i].a * 10 + v[i].b;
	return t + (long)sizeof(v);
}

/* One in a block inside a loop, and a bound that is a whole
   expression rather than a name. */
long loops(long n)
{
	long i, t = 0;

	for (i = 0; i < n; i++) {
		char b[i + 2];
		long j;

		for (j = 0; j < i + 1; j++) b[j] = 'x';
		b[i + 1] = 0;
		t += (long)sizeof(b);
		if (i == 2) continue;
		t += 1;
	}
	return t;
}

long nested(long n)
{
	long t = 0;
	int a[n];

	a[0] = 7;
	{
		int b[n + 1];

		b[n] = 9;
		t = a[0] + b[n] + (long)sizeof(b);
	}
	return t + (long)sizeof(a);
}

long chooser(void *p)
{
	char tmp[p ? 1 : 64];

	return (long)sizeof(tmp);
}

/* Every bound worked out where it stands, not only the outermost.  The
   size of a row is a run-time value too, so stepping a row is a
   multiply by what a slot holds and not by a number.
 */
long grid(long h, long w)
{
	char g[h][w];
	long i, j, t = 0;

	for (i = 0; i < h; i++)
		for (j = 0; j < w; j++) g[i][j] = (char)(i * w + j);
	for (i = 0; i < h; i++)
		for (j = 0; j < w; j++) t += g[i][j];
	t = t * 1000 + (long)sizeof(g);
	t = t * 100 + (long)sizeof(g[0]);
	return t * 10 + (long)sizeof(g[0][0]);
}

/* A bound that is a number on the outside and one that is not on the
   inside, and the other way round.  Either makes the whole array one
   whose size is only known here.
 */
long mixed(long h, long w)
{
	char inner[3][w];
	char outer[h][4];
	long i, j, t = 0;

	for (i = 0; i < 3; i++)
		for (j = 0; j < w; j++) inner[i][j] = (char)(i + j);
	for (i = 0; i < h; i++)
		for (j = 0; j < 4; j++) outer[i][j] = (char)(i * j);
	for (i = 0; i < 3; i++)
		for (j = 0; j < w; j++) t += inner[i][j];
	for (i = 0; i < h; i++)
		for (j = 0; j < 4; j++) t += outer[i][j];
	t = t * 1000 + (long)sizeof(inner);
	t = t * 1000 + (long)sizeof(outer);
	t = t * 100 + (long)sizeof(inner[0]);
	return t * 10 + (long)sizeof(outer[0]);
}

/* A pointer to a row whose width is a run-time value.  The pointer is
   an ordinary one; what it steps by is not.
 */
long rowptr(long h, long w)
{
	char g[h][w];
	char (*p)[w] = g;
	long i, j, t = 0;

	for (i = 0; i < h; i++)
		for (j = 0; j < w; j++) g[i][j] = (char)(i * 2 + j);
	for (i = 0; i < h; i++)
		for (j = 0; j < w; j++) t += p[i][j];
	t = t * 100 + (long)sizeof(*p);
	return t * 10 + (long)(p[1] - p[0] == w);
}

/* Three deep, and the difference between two rows says how wide one is. */
long cube(long d, long h, long w)
{
	char c[d][h][w];
	long i, j, k, t = 0;

	for (i = 0; i < d; i++)
		for (j = 0; j < h; j++)
			for (k = 0; k < w; k++) c[i][j][k] = (char)(i + j + k);
	for (i = 0; i < d; i++)
		for (j = 0; j < h; j++)
			for (k = 0; k < w; k++) t += c[i][j][k];
	t = t * 1000 + (long)sizeof(c);
	t = t * 100 + (long)sizeof(c[0]);
	t = t * 10 + (long)sizeof(c[0][0]);
	return t * 100 + (long)(&c[1][0][0] - &c[0][0][0]);
}

/* Two of them in one function must not share their room. */
long twogrids(long h, long w)
{
	char a[h][w];
	char b[h][w];

	a[0][0] = 1;
	b[0][0] = 2;
	return a[0][0] * 10 + b[0][0];
}
