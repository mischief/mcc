/* SPDX-License-Identifier: ISC */
long implicits(void);

/* Leaves rubbish above the int it answers with, which is what makes
 * the width of an implicit call visible.
 */
long dirty(void)
{
	return 0x5555555500000003L;
}

int main(void)
{
	implicits();
	return 0;
}
