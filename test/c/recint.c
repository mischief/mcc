/* SPDX-License-Identifier: ISC */
/* whole structs across a foreign ABI, with no floating point in them */

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

int nestsum(struct nest s)
{
	return s.p.a + s.p.b * 10 + s.q.a * 100 + s.q.b * 1000;
}

/* records mixed with scalars, and enough of them to spill */
int manysum(int a, struct pair b, long c, struct big d, struct three e,
	    int f)
{
	return a + b.a + b.b + (int)c + d.v[0] + d.v[8] +
	       e.a + e.b + e.c + f;
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

struct odd mkodd(int k)
{
	struct odd s;

	s.a = (char)k;
	s.b = (short)(k * 2);
	s.c = (char)(k * 3);
	return s;
}

struct pair thru(struct pair (*f)(int, int), int a, int b)
{
	return f(a, b);
}

struct pair passon(struct pair s)
{
	return mkpair(s.b, s.a);
}
