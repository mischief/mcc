/* _Complex parses and lays out as a pair.  Arithmetic on one is
   refused, so all this can do is carry one about, which is what a
   header wants. */
#include <stddef.h>

typedef double _Complex dc;
typedef float _Complex fc;

struct both { dc a; fc b; char c; };

dc keep(dc x) { return x; }
fc keepf(fc x) { return x; }

long sizes(void)
{
	return (long)sizeof(double _Complex) * 1000
	     + (long)sizeof(float _Complex) * 100
	     + (long)sizeof(struct both)
	     + (long)_Alignof(double _Complex);
}

static dc g;

long carry(long v)
{
	struct both b;
	dc a;
	double *p = (double *)&a;

	p[0] = (double)v;
	p[1] = (double)v + 0.5;
	g = a;
	b.a = keep(g);
	b.c = (char)v;
	a = b.a;
	p = (double *)&a;
	return (long)(p[0] * 100.0) + (long)(p[1] * 10.0) + b.c;
}
