/* SPDX-License-Identifier: ISC */
/* An unsigned int added to an unsigned long is added at 64 bits, and
 * what the assignment answers is the 32 bits it stored.  The widening
 * back is a `movl %eax,%eax`, which is no move to itself.  perl's
 * Digest::SHA counts its length this way and lost the carry. */
struct len { unsigned int hi, lo; };

static void count(struct len *s, unsigned long bits)
{
	if ((s->lo += bits) < bits)
		s->hi++;
}

unsigned long long carry(unsigned long bits)
{
	struct len n;
	unsigned int u = 4294967290u;
	unsigned long wide;

	n.hi = 0;
	n.lo = 4294967280u;
	count(&n, bits);
	wide = (u += bits);
	return (unsigned long long)n.hi << 40 |
	    (unsigned long long)n.lo << 8 | wide;
}
