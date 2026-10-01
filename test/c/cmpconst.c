/* SPDX-License-Identifier: ISC */
/* A narrow local whose value the compiler knows, compared with a
 * constant.  i386 has no compare of two immediates.  Found by csmith. */
int
cmpconst(int a)
{
	short l = 1;
	signed char c = -2;
	int r = 0;

	0 < l && 0;
	if (l > 0)
		r += 1;
	if (c < 0)
		r += 2;
	r += (l == 1) * 4 + (c != -2) * 8;
	return r + a;
}
