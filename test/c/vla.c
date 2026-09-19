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
