/* SPDX-License-Identifier: ISC */
#ifndef _TIME_H
#define _TIME_H

#include <stddef.h>

typedef long time_t;
typedef long clock_t;

#define CLOCKS_PER_SEC ((clock_t)1000000)

/*
 * The last two fields are glibc's, not the standard's, and they are here
 * because mktime and localtime write them.  A structure with only the nine
 * standard members would be written past its end.
 */
struct tm {
	int tm_sec;
	int tm_min;
	int tm_hour;
	int tm_mday;
	int tm_mon;
	int tm_year;
	int tm_wday;
	int tm_yday;
	int tm_isdst;
	long tm_gmtoff;
	const char *tm_zone;
};

time_t time(time_t *t);
clock_t clock(void);
double difftime(time_t a, time_t b);
time_t mktime(struct tm *tm);
struct tm *localtime(const time_t *t);
struct tm *gmtime(const time_t *t);
char *asctime(const struct tm *tm);
char *ctime(const time_t *t);
size_t strftime(char *s, size_t n, const char *fmt, const struct tm *tm);

#endif
