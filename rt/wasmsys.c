/* SPDX-License-Identifier: 0BSD */
/*
 * What a hosted C program expects of its system: the clock, the
 * calendar, the locale, errno and the number parsers.  The clock is
 * the host's; everything else is worked out here.
 */

typedef unsigned long size_t;
typedef long time_t;
typedef long clock_t;

struct tm {
	int tm_sec, tm_min, tm_hour;
	int tm_mday, tm_mon, tm_year;
	int tm_wday, tm_yday, tm_isdst;
	long tm_gmtoff;
	const char *tm_zone;
};

struct lconv {
	char *decimal_point, *thousands_sep, *grouping;
	char *int_curr_symbol, *currency_symbol;
	char *mon_decimal_point, *mon_thousands_sep, *mon_grouping;
	char *positive_sign, *negative_sign;
	char int_frac_digits, frac_digits;
	char p_cs_precedes, p_sep_by_space;
	char n_cs_precedes, n_sep_by_space;
	char p_sign_posn, n_sign_posn;
	char int_p_cs_precedes, int_p_sep_by_space;
	char int_n_cs_precedes, int_n_sep_by_space;
	char int_p_sign_posn, int_n_sign_posn;
};

unsigned long long __wasm_nanos(void);
long __wasm_time(void);
void __exit(long n, long code);
int fflush(void *f);
double pow(double, double);

#include "wasmbig.h"

/* ---- errno ---- */

static int theerrno;

int *__errno_location(void) { return &theerrno; }

/* ---- leaving ---- */

#define NATEXIT 32
static void (*atexits[NATEXIT])(void);
static int natexit;

int atexit(void (*f)(void))
{
	if (natexit >= NATEXIT) return -1;
	atexits[natexit++] = f;
	return 0;
}

void exit(int code)
{
	while (natexit > 0) atexits[--natexit]();
	fflush(0);
	__exit(0, code);
}

void _Exit(int code) { __exit(0, code); }

void abort(void)
{
	fflush(0);
	__exit(0, 134);
}

/* Nothing here delivers a signal, so a handler is kept and never run. */
void (*signal(int sig, void (*f)(int)))(int)
{
	(void)sig;
	(void)f;
	return 0;
}

int raise(int sig) { (void)sig; return 0; }

/* There is no command processor, which a null argument asks about. */
int system(const char *cmd) { return cmd ? -1 : 0; }

/* ---- the clock ---- */

clock_t clock(void)
{
	return (clock_t)(__wasm_nanos() / 1000ULL);
}

time_t time(time_t *t)
{
	time_t now = __wasm_time();

	if (t) *t = now;
	return now;
}

double difftime(time_t a, time_t b) { return (double)(a - b); }

/*
 * Days and civil dates, by Howard Hinnant's method: the year is shifted
 * to start in March so that the leap day falls at its end and no month
 * length depends on it.
 */
static long daysfromcivil(long y, unsigned m, unsigned d)
{
	long era, doy, doe;
	unsigned yoe;

	y -= m <= 2;
	era = (y >= 0 ? y : y - 399) / 400;
	yoe = (unsigned)(y - era * 400);
	doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
	doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}

static void civilfromdays(long z, int *y, int *m, int *d)
{
	long era, doe, yoe, doy, mp;

	z += 719468;
	era = (z >= 0 ? z : z - 146096) / 146097;
	doe = z - era * 146097;
	yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	mp = (5 * doy + 2) / 153;
	*d = (int)(doy - (153 * mp + 2) / 5 + 1);
	*m = (int)(mp + (mp < 10 ? 3 : -9));
	*y = (int)(yoe + era * 400 + (*m <= 2));
}

static struct tm thetm;

/* The host clock is UTC and no zone database is here, so both are the same. */
struct tm *gmtime(const time_t *t)
{
	long secs = *t, days;
	int rem, y, m, d;

	days = secs / 86400;
	rem = (int)(secs - days * 86400);
	if (rem < 0) { rem += 86400; days--; }
	civilfromdays(days, &y, &m, &d);
	thetm.tm_sec = rem % 60;
	thetm.tm_min = (rem / 60) % 60;
	thetm.tm_hour = rem / 3600;
	thetm.tm_mday = d;
	thetm.tm_mon = m - 1;
	thetm.tm_year = y - 1900;
	thetm.tm_wday = (int)((days % 7 + 11) % 7);
	thetm.tm_yday = (int)(days - daysfromcivil(y, 1, 1));
	thetm.tm_isdst = 0;
	thetm.tm_gmtoff = 0;
	thetm.tm_zone = "UTC";
	return &thetm;
}

struct tm *localtime(const time_t *t) { return gmtime(t); }

time_t mktime(struct tm *tm)
{
	long days;
	int y = tm->tm_year + 1900, m = tm->tm_mon, d = tm->tm_mday;
	long secs;

	/* a month outside one to twelve rolls into the year */
	y += m / 12;
	m = m % 12;
	if (m < 0) { m += 12; y--; }
	days = daysfromcivil(y, (unsigned)(m + 1), 1) + (d - 1);
	secs = days * 86400L + tm->tm_hour * 3600L + tm->tm_min * 60L +
	    tm->tm_sec;
	/* write the normalized date back, as mktime must */
	{
		time_t t2 = secs;
		struct tm *g = gmtime(&t2);
		int wday = g->tm_wday, yday = g->tm_yday;

		tm->tm_sec = g->tm_sec;
		tm->tm_min = g->tm_min;
		tm->tm_hour = g->tm_hour;
		tm->tm_mday = g->tm_mday;
		tm->tm_mon = g->tm_mon;
		tm->tm_year = g->tm_year;
		tm->tm_wday = wday;
		tm->tm_yday = yday;
		tm->tm_isdst = 0;
	}
	return secs;
}

static const char *const DAY[7] = { "Sunday", "Monday", "Tuesday",
	"Wednesday", "Thursday", "Friday", "Saturday" };
static const char *const MON[12] = { "January", "February", "March",
	"April", "May", "June", "July", "August", "September", "October",
	"November", "December" };

static size_t puttwo(char *s, size_t n, size_t at, int v, char pad)
{
	if (at < n) s[at] = (v / 10) ? (char)('0' + v / 10) : pad;
	at++;
	if (at < n) s[at] = (char)('0' + v % 10);
	return at + 1;
}

static size_t putstr_(char *s, size_t n, size_t at, const char *p, int max)
{
	int k = 0;

	while (p[k] && (max < 0 || k < max)) {
		if (at < n) s[at] = p[k];
		at++;
		k++;
	}
	return at;
}

static size_t putnum(char *s, size_t n, size_t at, long v, int digits)
{
	char t[24];
	int k = 0;

	if (v < 0) { if (at < n) s[at] = '-'; at++; v = -v; }
	do { t[k++] = (char)('0' + (int)(v % 10)); v /= 10; } while (v);
	while (k < digits) t[k++] = '0';
	while (k > 0) {
		if (at < n) s[at] = t[--k];
		at++;
	}
	return at;
}

size_t strftime(char *s, size_t n, const char *f, const struct tm *tm)
{
	size_t at = 0;

	while (*f) {
		if (*f != '%') {
			if (at < n) s[at] = *f;
			at++;
			f++;
			continue;
		}
		f++;
		switch (*f) {
		case 'a': at = putstr_(s, n, at, DAY[tm->tm_wday & 7], 3); break;
		case 'A': at = putstr_(s, n, at, DAY[tm->tm_wday & 7], -1); break;
		case 'b': case 'h':
			at = putstr_(s, n, at, MON[tm->tm_mon % 12], 3); break;
		case 'B': at = putstr_(s, n, at, MON[tm->tm_mon % 12], -1); break;
		case 'd': at = puttwo(s, n, at, tm->tm_mday, '0'); break;
		case 'e': at = puttwo(s, n, at, tm->tm_mday, ' '); break;
		case 'H': at = puttwo(s, n, at, tm->tm_hour, '0'); break;
		case 'I': at = puttwo(s, n, at,
			tm->tm_hour % 12 ? tm->tm_hour % 12 : 12, '0'); break;
		case 'j': at = putnum(s, n, at, tm->tm_yday + 1, 3); break;
		case 'm': at = puttwo(s, n, at, tm->tm_mon + 1, '0'); break;
		case 'M': at = puttwo(s, n, at, tm->tm_min, '0'); break;
		case 'p': at = putstr_(s, n, at,
			tm->tm_hour < 12 ? "AM" : "PM", -1); break;
		case 'S': at = puttwo(s, n, at, tm->tm_sec, '0'); break;
		case 'y': at = puttwo(s, n, at, (tm->tm_year + 1900) % 100, '0');
			break;
		case 'Y': at = putnum(s, n, at, tm->tm_year + 1900L, 1); break;
		case 'w': at = putnum(s, n, at, tm->tm_wday, 1); break;
		case 'n': if (at < n) s[at] = '\n'; at++; break;
		case 't': if (at < n) s[at] = '\t'; at++; break;
		case 'Z': at = putstr_(s, n, at, "UTC", -1); break;
		case 'z': at = putstr_(s, n, at, "+0000", -1); break;
		case 'D':
			at = puttwo(s, n, at, tm->tm_mon + 1, '0');
			if (at < n) s[at] = '/';
			at++;
			at = puttwo(s, n, at, tm->tm_mday, '0');
			if (at < n) s[at] = '/';
			at++;
			at = puttwo(s, n, at, (tm->tm_year + 1900) % 100, '0');
			break;
		case 'F':
			at = putnum(s, n, at, tm->tm_year + 1900L, 4);
			if (at < n) s[at] = '-';
			at++;
			at = puttwo(s, n, at, tm->tm_mon + 1, '0');
			if (at < n) s[at] = '-';
			at++;
			at = puttwo(s, n, at, tm->tm_mday, '0');
			break;
		case 'R': case 'T': case 'X':
			at = puttwo(s, n, at, tm->tm_hour, '0');
			if (at < n) s[at] = ':';
			at++;
			at = puttwo(s, n, at, tm->tm_min, '0');
			if (*f == 'R') break;
			if (at < n) s[at] = ':';
			at++;
			at = puttwo(s, n, at, tm->tm_sec, '0');
			break;
		case 'x':
			at = puttwo(s, n, at, tm->tm_mon + 1, '0');
			if (at < n) s[at] = '/';
			at++;
			at = puttwo(s, n, at, tm->tm_mday, '0');
			if (at < n) s[at] = '/';
			at++;
			at = puttwo(s, n, at, (tm->tm_year + 1900) % 100, '0');
			break;
		case 'c':
			at = putstr_(s, n, at, DAY[tm->tm_wday & 7], 3);
			if (at < n) s[at] = ' ';
			at++;
			at = putstr_(s, n, at, MON[tm->tm_mon % 12], 3);
			if (at < n) s[at] = ' ';
			at++;
			at = puttwo(s, n, at, tm->tm_mday, ' ');
			if (at < n) s[at] = ' ';
			at++;
			at = puttwo(s, n, at, tm->tm_hour, '0');
			if (at < n) s[at] = ':';
			at++;
			at = puttwo(s, n, at, tm->tm_min, '0');
			if (at < n) s[at] = ':';
			at++;
			at = puttwo(s, n, at, tm->tm_sec, '0');
			if (at < n) s[at] = ' ';
			at++;
			at = putnum(s, n, at, tm->tm_year + 1900L, 4);
			break;
		case '%': if (at < n) s[at] = '%'; at++; break;
		default:
			if (at < n) s[at] = '%';
			at++;
			if (at < n) s[at] = *f;
			at++;
			break;
		}
		if (*f) f++;
	}
	if (at < n) { s[at] = 0; return at; }
	if (n > 0) s[n - 1] = 0;
	return 0;
}

char *asctime(const struct tm *tm)
{
	static char buf[32];

	strftime(buf, sizeof buf, "%c\n", tm);
	return buf;
}

char *ctime(const time_t *t) { return asctime(gmtime(t)); }

/* ---- the locale, which is only ever "C" ---- */

static struct lconv theconv;
static int convready;

char *setlocale(int category, const char *locale)
{
	(void)category;
	if (locale && locale[0] && !(locale[0] == 'C' && locale[1] == 0))
		return 0;
	return "C";
}

struct lconv *localeconv(void)
{
	if (!convready) {
		char *none = "";

		theconv.decimal_point = ".";
		theconv.thousands_sep = none;
		theconv.grouping = none;
		theconv.int_curr_symbol = none;
		theconv.currency_symbol = none;
		theconv.mon_decimal_point = none;
		theconv.mon_thousands_sep = none;
		theconv.mon_grouping = none;
		theconv.positive_sign = none;
		theconv.negative_sign = none;
		theconv.int_frac_digits = (char)255;
		theconv.frac_digits = (char)255;
		theconv.p_cs_precedes = (char)255;
		theconv.p_sep_by_space = (char)255;
		theconv.n_cs_precedes = (char)255;
		theconv.n_sep_by_space = (char)255;
		theconv.p_sign_posn = (char)255;
		theconv.n_sign_posn = (char)255;
		theconv.int_p_cs_precedes = (char)255;
		theconv.int_p_sep_by_space = (char)255;
		theconv.int_n_cs_precedes = (char)255;
		theconv.int_n_sep_by_space = (char)255;
		theconv.int_p_sign_posn = (char)255;
		theconv.int_n_sign_posn = (char)255;
		convready = 1;
	}
	return &theconv;
}

/* ---- errors by name ---- */

char *strerror(int e)
{
	switch (e) {
	case 0: return "Success";
	case 1: return "Operation not permitted";
	case 2: return "No such file or directory";
	case 5: return "Input/output error";
	case 9: return "Bad file descriptor";
	case 12: return "Cannot allocate memory";
	case 13: return "Permission denied";
	case 17: return "File exists";
	case 21: return "Is a directory";
	case 22: return "Invalid argument";
	case 28: return "No space left on device";
	case 38: return "Function not implemented";
	}
	return "Unknown error";
}

/* ---- numbers out of text ---- */

static int isspace_(int c)
{
	return c == ' ' || (c >= '\t' && c <= '\r');
}

static int digitof(int c, int base)
{
	int v;

	if (c >= '0' && c <= '9') v = c - '0';
	else if (c >= 'a' && c <= 'z') v = c - 'a' + 10;
	else if (c >= 'A' && c <= 'Z') v = c - 'A' + 10;
	else return -1;
	return v < base ? v : -1;
}

unsigned long long strtoull(const char *s, char **end, int base)
{
	const char *p = s;
	unsigned long long v = 0;
	int neg = 0, any = 0, d;

	while (isspace_((unsigned char)*p)) p++;
	if (*p == '+' || *p == '-') neg = (*p++ == '-');
	if ((base == 0 || base == 16) && p[0] == '0' &&
	    (p[1] == 'x' || p[1] == 'X') && digitof(p[2], 16) >= 0) {
		p += 2;
		base = 16;
	} else if (base == 0) {
		base = (p[0] == '0') ? 8 : 10;
	}
	while ((d = digitof((unsigned char)*p, base)) >= 0) {
		v = v * (unsigned)base + (unsigned)d;
		any = 1;
		p++;
	}
	if (end) *end = (char *)(any ? p : s);
	return neg ? 0ULL - v : v;
}

long long strtoll(const char *s, char **end, int base)
{
	return (long long)strtoull(s, end, base);
}

unsigned long strtoul(const char *s, char **end, int base)
{
	return (unsigned long)strtoull(s, end, base);
}

long strtol(const char *s, char **end, int base)
{
	return (long)strtoull(s, end, base);
}

/*
 * A decimal string as a double.  The digits are gathered into an
 * integer and scaled once, so only the last place can differ from an
 * exactly rounded conversion.
 */
double strtod(const char *s, char **end)
{
	const char *p = s;
	Big b;
	int neg = 0, any = 0, e = 0, sticky = 0;
	unsigned acc = 0;
	int nacc = 0, full = 0;

	while (isspace_((unsigned char)*p)) p++;
	if (*p == '+' || *p == '-') neg = (*p++ == '-');
	if ((p[0] == 'i' || p[0] == 'I') && (p[1] == 'n' || p[1] == 'N') &&
	    (p[2] == 'f' || p[2] == 'F')) {
		if (end) *end = (char *)(p + 3);
		return neg ? -1.0 / 0.0 : 1.0 / 0.0;
	}
	if ((p[0] == 'n' || p[0] == 'N') && (p[1] == 'a' || p[1] == 'A') &&
	    (p[2] == 'n' || p[2] == 'N')) {
		if (end) *end = (char *)(p + 3);
		return 0.0 / 0.0;
	}
	/* hexadecimal, which C99 asks for and Lua's %q writes */
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X') &&
	    (digitof(p[2], 16) >= 0 ||
	     (p[2] == '.' && digitof(p[3], 16) >= 0))) {
		unsigned long long m = 0;
		int e2 = 0, d;
		double v;

		p += 2;
		while ((d = digitof((unsigned char)*p, 16)) >= 0) {
			if (m < (1ULL << 59)) m = m * 16 + d;
			else { e2 += 4; if (d) sticky = 1; }
			any = 1;
			p++;
		}
		if (*p == '.') {
			p++;
			while ((d = digitof((unsigned char)*p, 16)) >= 0) {
				if (m < (1ULL << 59)) {
					m = m * 16 + d;
					e2 -= 4;
				} else if (d) {
					sticky = 1;
				}
				any = 1;
				p++;
			}
		}
		if (!any) { if (end) *end = (char *)s; return 0.0; }
		if (*p == 'p' || *p == 'P') {
			const char *q = p + 1;
			int sg = 1, x = 0, got = 0;

			if (*q == '+' || *q == '-')
				sg = (*q++ == '-') ? -1 : 1;
			while (*q >= '0' && *q <= '9') {
				x = x * 10 + (*q++ - '0');
				if (x > 100000) x = 100000;
				got = 1;
			}
			if (got) { e2 += sg * x; p = q; }
		}
		if (end) *end = (char *)p;
		bigset(&b, (unsigned)(m & 0xffffffffULL));
		if (m >> 32) {
			b.d[1] = (unsigned)(m >> 32);
			b.n = 2;
		}
		v = bigdouble(&b, e2, sticky);
		return neg ? -v : v;
	}

	bigset(&b, 0);
	while (*p >= '0' && *p <= '9') {
		if (full) {
			e++;
			if (*p != '0') sticky = 1;
		} else {
			acc = acc * 10 + (unsigned)(*p - '0');
			if (++nacc == 9) {
				bigmuladd(&b, 1000000000u, acc);
				acc = 0;
				nacc = 0;
				if (b.n > 88) full = 1;
			}
		}
		any = 1;
		p++;
	}
	if (*p == '.') {
		p++;
		while (*p >= '0' && *p <= '9') {
			if (full) {
				if (*p != '0') sticky = 1;
			} else {
				acc = acc * 10 + (unsigned)(*p - '0');
				e--;
				if (++nacc == 9) {
					bigmuladd(&b, 1000000000u, acc);
					acc = 0;
					nacc = 0;
					if (b.n > 88) full = 1;
				}
			}
			any = 1;
			p++;
		}
	}
	if (!any) { if (end) *end = (char *)s; return 0.0; }
	while (nacc > 0) {			/* the last short group */
		bigmuladd(&b, 10, acc / TENS[nacc - 1] % 10);
		nacc--;
	}
	if (*p == 'e' || *p == 'E') {
		const char *q = p + 1;
		int sg = 1, x = 0, got = 0;

		if (*q == '+' || *q == '-') sg = (*q++ == '-') ? -1 : 1;
		while (*q >= '0' && *q <= '9') {
			x = x * 10 + (*q++ - '0');
			if (x > 100000) x = 100000;
			got = 1;
		}
		if (got) { e += sg * x; p = q; }
	}
	if (end) *end = (char *)p;
	if (b.n == 0) return neg ? -0.0 : 0.0;
	{
		double v;
		int e2 = 0;

		if (e > 0) {
			int k = e;

			while (k >= 9) {
				if (!bigmuladd(&b, 1000000000u, 0))
					return neg ? -1.0 / 0.0 : 1.0 / 0.0;
				k -= 9;
			}
			if (k > 0 && !bigmuladd(&b, TENS[k], 0))
				return neg ? -1.0 / 0.0 : 1.0 / 0.0;
		} else if (e < 0) {
			int m = -e;
			/* room for the quotient to keep enough bits:
			   five to the m is under two to the 2.33m */
			int sh = (m * 24) / 10 + 66;
			int k = m;

			if (!bigshl(&b, sh)) return neg ? -0.0 : 0.0;
			e2 = -(sh + m);
			while (k >= 13) {
				if (bigdiv(&b, 1220703125u)) sticky = 1;
				k -= 13;
			}
			if (k > 0 && bigdiv(&b, FIVES[k])) sticky = 1;
		}
		v = bigdouble(&b, e2, sticky);
		return neg ? -v : v;
	}
}

double atof(const char *s) { return strtod(s, 0); }
int atoi(const char *s) { return (int)strtoll(s, 0, 10); }
long atol(const char *s) { return (long)strtoll(s, 0, 10); }
long long atoll(const char *s) { return strtoll(s, 0, 10); }
