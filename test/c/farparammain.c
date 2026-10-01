/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct Big { long w[40]; };

long far(struct Big, long, long, long, long, long, long, long, long, long);

int main(void)
{
	struct Big b = {{0}};
	long k;

	for (k = 1; k < 4; k++) {
		b.w[0] = k;
		b.w[39] = k * 2;
		printf("far %ld %ld\n", k, far(b, 2, 3, 4, 5, 6, 7, 8, k, k + 1));
	}
	return 0;
}
