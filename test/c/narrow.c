/* SPDX-License-Identifier: ISC */
/* A conversion between two integer types of one narrow width still
 * extends by the new type's signedness.  OpenBSD's regcomp tests
 * `cs->ptr[(uch)c]` with c a char parameter, and the index came out
 * sign-extended, so every byte above 127 read far off the table. */
typedef unsigned char uch;
typedef struct { uch *ptr; uch mask; } cset;

static uch tab[256];

static inline int chin(const cset *cs, char c)
{
	return (cs->ptr[(uch)c] & cs->mask) != 0;
}

int narrow(int i, int which)
{
	cset cs = {tab, 1};

	tab[200] = 1;
	switch (which) {
	case 0: return (unsigned char)(char)i;
	case 1: return (signed char)(unsigned char)i;
	case 2: return (unsigned short)(short)i;
	case 3: return (short)(unsigned short)i;
	default: return chin(&cs, i);
	}
}
