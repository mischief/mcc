/* SPDX-License-Identifier: ISC */
/* Hex literals of the x87 extended type keep all sixty-four bits. */

static long double lits[] = {
	-0x1f68acf12ffe5653p-38L, 0x8000000000000001p0L, 0x1.8p1L,
	0x1ffffffffffffffffp0L, 0x18000000000000001p0L,
	0x18000000000000003p0L, 0x1.fffffffffffffffffp16383L,
	0x1p-16445L, 0x3p-16446L, 0x1.ffffffffffffffffp-16383L,
	0x00012345.6789abcdef0123p-3L,
};

int nlit(void)
{
	return sizeof lits / sizeof lits[0];
}

/* The value read at run time, not folded into a table. */
long double lit(int i)
{
	long double v = 0x8000000000000001p0L;

	return i < 0 ? v : lits[i];
}
