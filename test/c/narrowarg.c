/* SPDX-License-Identifier: ISC */
/* A narrow argument read from a local is extended to the register,
   which RISC-V asks of the caller and a callee built by gcc trusts. */

long gwide(signed char, short, unsigned char, unsigned short);

long callgcc(long k)
{
	signed char c = (signed char)(-k - 100);
	short s = (short)(-k * 1000);
	unsigned char uc = (unsigned char)(k + 200);
	unsigned short us = (unsigned short)(k + 60000);

	return gwide(c, s, uc, us);
}
