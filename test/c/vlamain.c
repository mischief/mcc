/* SPDX-License-Identifier: ISC */
#include <stdio.h>

long simple(long), bytes(long), rows(long), records(long);
long loops(long), nested(long), chooser(void *);
long grid(long, long), mixed(long, long), rowptr(long, long);
long cube(long, long, long), twogrids(long, long);

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
		printf("grid %ld %ld\n", i, grid(i, i + 1));
		printf("mixed %ld %ld\n", i, mixed(i, i + 2));
		printf("rowptr %ld %ld\n", i, rowptr(i, i + 1));
		printf("cube %ld %ld\n", i, cube(i, i + 1, i + 2));
		printf("twogrids %ld %ld\n", i, twogrids(i, i + 1));
	}
	return 0;
}
