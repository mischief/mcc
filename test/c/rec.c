/* whole structs across a foreign ABI: arguments, returns, varargs */
#include <stdarg.h>

struct pair {
	int a, b;
};

struct three {
	int a, b, c;
};

struct odd {
	char a;
	short b;
	char c;
};

struct big {
	int v[9];
};

struct twod {
	double x, y;
};

struct mix {
	int i;
	double d;
};

struct nest {
	struct pair p;
	struct pair q;
};

int pairsum(struct pair s)
{
	return s.a * 10 + s.b;
}

int threesum(struct three s)
{
	return s.a * 100 + s.b * 10 + s.c;
}

int oddsum(struct odd s)
{
	return s.a * 100 + s.b * 10 + s.c;
}

int bigsum(struct big s)
{
	int i, t;

	t = 0;
	for (i = 0; i < 9; i++)
		t = t + s.v[i] * (i + 1);
	return t;
}

double twodsum(struct twod s)
{
	return s.x * 2.0 + s.y;
}

double mixsum(struct mix s)
{
	return (double)s.i + s.d;
}

int nestsum(struct nest s)
{
	return s.p.a + s.p.b * 10 + s.q.a * 100 + s.q.b * 1000;
}

/* records mixed with scalars, and enough of them to spill */
int manysum(int a, struct pair b, long c, struct big d, struct twod e,
	    struct three f, int g)
{
	return a + b.a + b.b + (int)c + d.v[0] + d.v[8] + (int)e.x +
	       f.a + f.b + f.c + g;
}

struct pair mkpair(int a, int b)
{
	struct pair s;

	s.a = a;
	s.b = b;
	return s;
}

struct big mkbig(int k)
{
	struct big s;
	int i;

	for (i = 0; i < 9; i++)
		s.v[i] = k + i;
	return s;
}

struct twod mktwod(double x)
{
	struct twod s;

	s.x = x;
	s.y = x * 3.0;
	return s;
}

struct mix mkmix(int i, double d)
{
	struct mix s;

	s.i = i;
	s.d = d;
	return s;
}

struct odd mkodd(int k)
{
	struct odd s;

	s.a = (char)k;
	s.b = (short)(k * 2);
	s.c = (char)(k * 3);
	return s;
}

/* a record through a pointer to a function, and one straight through */
struct pair thru(struct pair (*f)(int, int), int a, int b)
{
	return f(a, b);
}

struct pair passon(struct pair s)
{
	return mkpair(s.b, s.a);
}

int vpair(int n, ...)
{
	va_list ap;
	int i, t;

	va_start(ap, n);
	t = 0;
	for (i = 0; i < n; i++) {
		struct pair s = va_arg(ap, struct pair);

		t = t + s.a * 10 + s.b;
	}
	va_end(ap);
	return t;
}
