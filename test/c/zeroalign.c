/* SPDX-License-Identifier: ISC */
/* RISC-V: a record of size zero takes no register and no stack, but
   gcc still aligns the next stack slot to the record's alignment. */

struct Z { _Alignas(16) char m[0]; };

long gza(int, int, int, int, int, int, int, int, int, struct Z, int);

long za(int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7,
	int a8, struct Z z, int a9)
{
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 * 10 + a9 * 100;
}

long callgcc(long k)
{
	struct Z z;

	return gza(1, 1, 1, 1, 1, 1, 1, 1, (int)k, z, 3);
}
