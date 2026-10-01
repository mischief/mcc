/* SPDX-License-Identifier: ISC */
/* A two-register result stored to a frame slot past the reach of a
   12-bit offset: each half needs its own address. */

#ifdef __SIZEOF_INT128__
typedef unsigned __int128 W;
#else
typedef unsigned long long W;
#endif

W gwide(int);

long callgcc(int k)
{
	volatile char pad[4096];
	W r;

	pad[0] = (char)k;
	r = gwide(pad[0]);
	return (long)(r % 1000003) + pad[0];
}
