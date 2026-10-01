/* SPDX-License-Identifier: ISC */
/* A parameter the caller left on the stack, copied into a frame slot
   too far from the frame pointer for one instruction to reach: the
   record ahead of it takes the room. */

struct Big { long w[40]; };

long far(struct Big b, long a1, long a2, long a3, long a4, long a5,
	 long a6, long a7, long a8, long a9)
{
	return b.w[0] + b.w[39] * 10 + a1 + a2 + a3 + a4 + a5 + a6 + a7 +
	       a8 * 100 + a9 * 1000;
}
