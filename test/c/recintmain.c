/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct pair { int a, b; };
struct three { int a, b, c; };
struct odd { char a; short b; char c; };
struct big { int v[9]; };
struct nest { struct pair p; struct pair q; };

int pairsum(struct pair);
int threesum(struct three);
int oddsum(struct odd);
int bigsum(struct big);
int nestsum(struct nest);
int manysum(int, struct pair, long, struct big, struct three, int);
struct pair mkpair(int, int);
struct big mkbig(int);
struct odd mkodd(int);
struct pair thru(struct pair (*)(int, int), int, int);
struct pair passon(struct pair);

int main(void)
{
	struct pair p;
	struct three t;
	struct odd o;
	struct big b;
	struct nest n;
	int i;

	p.a = 1; p.b = 2;
	t.a = 1; t.b = 2; t.c = 3;
	o.a = 4; o.b = 5; o.c = 6;
	for (i = 0; i < 9; i++)
		b.v[i] = i + 1;
	n.p = p; n.q.a = 3; n.q.b = 4;

	printf("pair %d\n", pairsum(p));
	printf("three %d\n", threesum(t));
	printf("odd %d\n", oddsum(o));
	printf("big %d\n", bigsum(b));
	printf("nest %d\n", nestsum(n));
	printf("many %d\n", manysum(1, p, 2, b, t, 3));

	printf("mkpair %d %d\n", mkpair(7, 8).a, mkpair(7, 8).b);
	printf("mkbig %d %d\n", mkbig(5).v[0], mkbig(5).v[8]);
	printf("mkodd %d %d %d\n", mkodd(2).a, mkodd(2).b, mkodd(2).c);

	{
		struct pair z = mkpair(4, 5);
		struct big w = mkbig(1);

		printf("store %d %d %d %d\n", z.a, z.b, w.v[3], bigsum(w));
	}

	printf("thru %d %d\n", thru(mkpair, 6, 7).a, thru(mkpair, 6, 7).b);
	printf("passon %d %d\n", passon(p).a, passon(p).b);

	{
		struct pair u = p;

		u = passon(u);
		printf("assign %d %d\n", u.a, u.b);
	}

	printf("cond %d\n", pairsum(1 ? p : mkpair(9, 9)));
	return 0;
}
