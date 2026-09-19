/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct pair { int a, b; };
struct three { int a, b, c; };
struct odd { char a; short b; char c; };
struct big { int v[9]; };
struct twod { double x, y; };
struct mix { int i; double d; };
struct nest { struct pair p; struct pair q; };

int pairsum(struct pair);
int threesum(struct three);
int oddsum(struct odd);
int bigsum(struct big);
double twodsum(struct twod);
double mixsum(struct mix);
int nestsum(struct nest);
int manysum(int, struct pair, long, struct big, struct twod, struct three,
	    int);
struct pair mkpair(int, int);
struct big mkbig(int);
struct twod mktwod(double);
struct mix mkmix(int, double);
struct odd mkodd(int);
struct pair thru(struct pair (*)(int, int), int, int);
struct pair passon(struct pair);
int vpair(int, ...);

int main(void)
{
	struct pair p;
	struct three t;
	struct odd o;
	struct big b;
	struct twod d;
	struct mix m;
	struct nest n;
	int i;

	p.a = 1; p.b = 2;
	t.a = 1; t.b = 2; t.c = 3;
	o.a = 4; o.b = 5; o.c = 6;
	for (i = 0; i < 9; i++)
		b.v[i] = i + 1;
	d.x = 1.5; d.y = 2.5;
	m.i = 3; m.d = 0.25;
	n.p = p; n.q.a = 3; n.q.b = 4;

	printf("pair %d\n", pairsum(p));
	printf("three %d\n", threesum(t));
	printf("odd %d\n", oddsum(o));
	printf("big %d\n", bigsum(b));
	printf("twod %f\n", twodsum(d));
	printf("mix %f\n", mixsum(m));
	printf("nest %d\n", nestsum(n));
	printf("many %d\n", manysum(1, p, 2, b, d, t, 3));

	printf("mkpair %d %d\n", mkpair(7, 8).a, mkpair(7, 8).b);
	printf("mkbig %d %d\n", mkbig(5).v[0], mkbig(5).v[8]);
	printf("mktwod %f %f\n", mktwod(2.5).x, mktwod(2.5).y);
	printf("mkmix %d %f\n", mkmix(9, 1.25).i, mkmix(9, 1.25).d);
	printf("mkodd %d %d %d\n", mkodd(2).a, mkodd(2).b, mkodd(2).c);

	{
		struct pair z = mkpair(4, 5);
		struct big w = mkbig(1);
		struct twod q = mktwod(1.0);
		struct mix y = mkmix(2, 0.5);

		printf("store %d %d %d %d %f %f\n", z.a, z.b, w.v[3],
		       bigsum(w), q.y, y.d);
	}

	printf("thru %d %d\n", thru(mkpair, 6, 7).a, thru(mkpair, 6, 7).b);
	printf("passon %d %d\n", passon(p).a, passon(p).b);

	{
		struct pair u = p;

		u = passon(u);
		printf("assign %d %d\n", u.a, u.b);
	}

	printf("cond %d\n", pairsum(1 ? p : mkpair(9, 9)));
	printf("vpair %d\n", vpair(3, p, t.a ? p : p, mkpair(5, 6)));
	return 0;
}
