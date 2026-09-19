/* SPDX-License-Identifier: ISC */
#include <stdio.h>

long simple(long), bytes(long), rows(long), records(long);
long loops(long), nested(long), chooser(void *);

int main(void)
{
	long i;
	char c;

	printf("chooser %ld %ld\n", chooser(0), chooser(&c));
	for (i = 1; i <= 6; i++) {
		printf("simple %ld %ld\n", i, simple(i));
		printf("bytes %ld %ld\n", i, bytes(i));
		printf("rows %ld %ld\n", i, rows(i));
		printf("records %ld %ld\n", i, records(i));
		printf("loops %ld %ld\n", i, loops(i));
		printf("nested %ld %ld\n", i, nested(i));
	}
	return 0;
}
