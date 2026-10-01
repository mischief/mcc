/* SPDX-License-Identifier: ISC */
/* Brace elision: an array or record element written without braces of
 * its own takes as many values from the list as it needs, and a record
 * takes a whole value of its own type.  Found by csmith. */
struct pt { int x, y; };
struct box { struct pt a; short n[3]; char tag[4]; };
union u { int i; char c[4]; };
struct holder { union u v; int after; };
struct empty {};
struct withempty { unsigned char f0; struct empty f1; int f2; };

int a2[2][3] = {1, 2, 3, 4};
short a3[2][2][2] = {1, 2, 3, 4, 5, 6, 7};
struct pt pts[3] = {1, 2, 3, 4, 5};
struct box bx = {7, 8, 9, 10, 11, "ab", };
struct box bxs[2] = {1, 2, 3, 4, 5, "xy", 6, 7};
struct pt pt0 = {5, 6};
struct box bcopy[2] = {{{0}}, {.a = {1, 2}, 3, 4}};
struct holder hd[2] = {1, 2, 3, 4};
struct withempty we = {85, 713, 3343};
int mix[3][2] = {{1}, 2, 3, [2] = {4}};

static unsigned
sum(const void *p, unsigned n)
{
	const unsigned char *b = p;
	unsigned s = 0;

	while (n--)
		s = s * 31 + *b++;
	return s;
}

unsigned
elide(int v)
{
	int l2[2][3] = {v, v + 1, v + 2, v + 3};
	struct pt lp[2] = {v, 2, pt0};
	struct box lb = {v, v, v + 1, v + 2, v + 3, "q"};
	unsigned r = 0;

	r = r * 7 + sum(a2, sizeof a2) + sum(a3, sizeof a3);
	r = r * 7 + sum(pts, sizeof pts) + sum(&bx, sizeof bx);
	r = r * 7 + sum(bxs, sizeof bxs) + sum(bcopy, sizeof bcopy);
	r = r * 7 + sum(hd, sizeof hd) + (unsigned)we.f0 + (unsigned)we.f2;
	r = r * 7 + sum(mix, sizeof mix);
	r = r * 7 + sum(l2, sizeof l2) + sum(lp, sizeof lp);
	/* not the whole of lb: the padding of a local is not set */
	r = r * 7 + sum(&lb.a, sizeof lb.a) + sum(lb.n, sizeof lb.n) +
	    sum(lb.tag, sizeof lb.tag);
	return r;
}
