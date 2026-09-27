/* SPDX-License-Identifier: ISC */
/* READ_ONCE as OpenBSD writes it: a statement expression whose local
 * shares a frame slot with the variable it is assigned to.  Each copy
 * used to store the same register to that slot again. */
#define READ_ONCE(x) ({ __typeof(x) __tmp = *(volatile __typeof(x) *)&(x); __tmp; })

struct buf { long pad[21]; int *q; };

static int seen;

static void
wait(int *q)
{
	seen += *q;
}

int
readonce(int n)
{
	struct buf b;
	int v = n, *q;

	b.q = n ? &v : 0;
	q = READ_ONCE(b.q);
	if (q != 0)
		wait(q);
	return seen;
}
