/* SPDX-License-Identifier: 0BSD */
/*
 * printf and its family, over a sink so the same formatter serves a
 * stream and a buffer.
 *
 * A float conversion goes through the exact decimal of the double, so
 * the last digit comes out the same as a C library gives.
 */

typedef unsigned long size_t;
typedef char *va_list_ptr;

#include <stdarg.h>

typedef struct {
	char *buf;		/* where a string sink writes */
	size_t cap, n;		/* its room, and how much was wanted */
	void *file;		/* or a stream */
} sink;

int fputc(int c, void *f);
double fabs(double);
double floor(double);
double pow(double, double);
double log10(double);

#include "wasmbig.h"

static void put(sink *s, int c)
{
	if (s->file) fputc(c, s->file);
	else if (s->n + 1 < s->cap) s->buf[s->n] = (char)c;
	s->n++;
}

static void putstr(sink *s, const char *p, int len, int width, int left,
    int zero)
{
	int pad = width - len;

	/* a zero pad goes after a sign or a base prefix, not before */
	if (zero && !left) {
		if (len > 0 && (*p == '-' || *p == '+' || *p == ' ')) {
			put(s, *p++);
			len--;
		}
		if (len > 1 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
			put(s, p[0]);
			put(s, p[1]);
			p += 2;
			len -= 2;
		}
	}
	if (!left) while (pad-- > 0) put(s, zero ? '0' : ' ');
	while (len-- > 0) put(s, *p++);
	while (pad-- > 0) put(s, ' ');
}

static int unum(char *out, unsigned long long v, int base, int upper)
{
	const char *d = upper ? "0123456789ABCDEF" : "0123456789abcdef";
	char tmp[32];
	int n = 0, i;

	do { tmp[n++] = d[v % (unsigned)base]; v /= (unsigned)base; }
	while (v);
	for (i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
	return n;
}

/*
 * Every double is a whole number times a power of two, so it has an
 * exact decimal.  It is written out in full and then rounded where the
 * format asks, which is the only way the last digit comes out the same
 * as a C library gives.
 */

#define NDIG 1200

/*
 * The digits of `v`, most significant first, with `point` set so that
 * the value is 0.<digits> times ten to the point.  Returns how many
 * digits there are; a zero gives one of them.
 */
static int decimalof(double v, char *dig, int *point)
{
	union { double d; unsigned long long u; } b;
	Big big;
	unsigned long long m;
	char frac[NDIG];
	int e, f, n = 0, nf = 0, i, lead;

	b.d = v;
	e = (int)((b.u >> 52) & 0x7ff);
	m = b.u & 0xfffffffffffffULL;
	if (e == 0) {
		e = -1074;
	} else {
		m |= 1ULL << 52;
		e -= 1075;
	}
	if (m == 0) { dig[0] = '0'; *point = 1; return 1; }
	if (e >= 0) {
		bigset(&big, (unsigned)(m & 0xffffffffULL));
		if (m >> 32) { big.d[1] = (unsigned)(m >> 32); big.n = 2; }
		bigshl(&big, e);
		n = bigdigits(&big, dig);
		*point = n;
		return n;
	}
	f = -e;
	/* the whole part, and then the fraction as m times five to the f */
	if (f < 64 && (m >> f) != 0) {
		unsigned long long w = m >> f;

		bigset(&big, (unsigned)(w & 0xffffffffULL));
		if (w >> 32) { big.d[1] = (unsigned)(w >> 32); big.n = 2; }
		n = bigdigits(&big, dig);
	}
	{
		unsigned long long lo = (f < 64) ?
		    (m & ((1ULL << f) - 1)) : m;

		bigset(&big, (unsigned)(lo & 0xffffffffULL));
		if (lo >> 32) { big.d[1] = (unsigned)(lo >> 32); big.n = 2; }
		bigmulpow5(&big, f);
		nf = bigdigits(&big, frac);
	}
	/* the fraction has exactly f places, so it is padded on the left */
	for (i = 0; i < f - nf; i++) dig[n + i] = '0';
	for (i = 0; i < nf; i++) dig[n + (f - nf) + i] = frac[i];
	*point = n;
	n += f;
	/* a leading zero is not a digit of the value */
	lead = 0;
	while (lead < n - 1 && dig[lead] == '0') lead++;
	if (lead) {
		for (i = 0; i + lead < n; i++) dig[i] = dig[i + lead];
		n -= lead;
		*point -= lead;
	}
	while (n > 1 && dig[n - 1] == '0') n--;
	return n;
}

/*
 * Round `dig` to `keep` digits, half to even.  Returns the new count,
 * and moves the point when the carry makes a digit.
 */
static int roundat(char *dig, int n, int keep, int *point)
{
	int up = 0, i;

	if (keep >= n) return n;
	if (keep < 0) { *point += 0; return 0; }
	if (dig[keep] > '5') {
		up = 1;
	} else if (dig[keep] == '5') {
		for (i = keep + 1; i < n; i++)
			if (dig[i] != '0') { up = 1; break; }
		if (!up && keep > 0 && ((dig[keep - 1] - '0') & 1)) up = 1;
		if (!up && keep == 0) up = 0;
	}
	n = keep;
	if (up) {
		for (i = n - 1; i >= 0; i--) {
			if (dig[i] != '9') { dig[i]++; break; }
			dig[i] = '0';
		}
		if (i < 0) {
			for (i = n; i > 0; i--) dig[i] = dig[i - 1];
			dig[0] = '1';
			n++;
			(*point)++;
		}
	}
	while (n > 1 && dig[n - 1] == '0') n--;
	if (n == 0) { dig[0] = '0'; n = 1; }
	return n;
}

/* whether the value is anything but a finite number, written out */
static int notfinite(char *out, double v)
{
	if (v != v) { out[0] = 'n'; out[1] = 'a'; out[2] = 'n'; return 3; }
	if (v > 1.7976931348623157e308) {
		out[0] = 'i'; out[1] = 'n'; out[2] = 'f'; return 3;
	}
	if (v < -1.7976931348623157e308) {
		out[0] = '-'; out[1] = 'i'; out[2] = 'n'; out[3] = 'f';
		return 4;
	}
	return 0;
}

static int negative(double v)
{
	return v < 0.0 || (v == 0.0 && 1.0 / v < 0.0);
}

/* The digits of a double, to `prec` places after the point. */
static int fixed(char *out, double v, int prec)
{
	char dig[NDIG];
	char *p = out;
	int point, n, i, k;

	k = notfinite(out, v);
	if (k) return k;
	if (negative(v)) { *p++ = '-'; v = -v; }
	n = decimalof(v, dig, &point);
	n = roundat(dig, n, point + prec, &point);
	if (n == 0 || dig[0] == '0') { n = 0; point = 0; }
	/* the whole part */
	if (point <= 0) {
		*p++ = '0';
	} else {
		for (i = 0; i < point; i++)
			*p++ = (i < n) ? dig[i] : '0';
	}
	if (prec > 0) {
		*p++ = '.';
		for (i = 0; i < prec; i++) {
			int at = point + i;

			*p++ = (at >= 0 && at < n) ? dig[at] : '0';
		}
	}
	return (int)(p - out);
}

/* %e, and the exponent %g needs to choose with */
static int sci(char *out, double v, int prec, int upper)
{
	char dig[NDIG];
	char *p = out;
	int point, n, i, e, k;

	k = notfinite(out, v);
	if (k) return k;
	if (negative(v)) { *p++ = '-'; v = -v; }
	n = decimalof(v, dig, &point);
	if (n == 1 && dig[0] == '0') {
		e = 0;
	} else {
		n = roundat(dig, n, prec + 1, &point);
		e = point - 1;
	}
	*p++ = dig[0];
	if (prec > 0) {
		*p++ = '.';
		for (i = 1; i <= prec; i++)
			*p++ = (i < n) ? dig[i] : '0';
	}
	*p++ = upper ? 'E' : 'e';
	*p++ = e < 0 ? '-' : '+';
	if (e < 0) e = -e;
	if (e < 10) *p++ = '0';
	p += unum(p, (unsigned long long)e, 10, 0);
	return (int)(p - out);
}

static int gfmt(char *out, double v, int prec, int upper)
{
	char dig[NDIG];
	int point, n, e, k;

	k = notfinite(out, v);
	if (k) return k;
	if (prec == 0) prec = 1;
	{
		double a = v < 0.0 ? -v : v;

		if (a == 0.0) {
			e = 0;
		} else {
			n = decimalof(a, dig, &point);
			roundat(dig, n, prec, &point);
			e = point - 1;
		}
	}
	if (e < -4 || e >= prec) {
		n = sci(out, v, prec - 1, upper);
	} else {
		n = fixed(out, v, prec - 1 - e);
	}
	/* %g drops the zeros the precision asked for but the value does
	   not have, and the point with them */
	{
		int i, dot = -1, stop = n;

		for (i = 0; i < n; i++) {
			if (out[i] == '.') dot = i;
			if (out[i] == 'e' || out[i] == 'E') { stop = i; break; }
		}
		if (dot >= 0) {
			int last = stop - 1;

			while (last > dot && out[last] == '0') last--;
			if (last == dot) last--;
			if (last + 1 < stop) {
				for (i = 0; i + stop < n; i++)
					out[last + 1 + i] = out[stop + i];
				n -= stop - (last + 1);
			}
		}
		return n;
	}
}

/* %a: the bits as they are, which is what a round trip wants */
static int hexf(char *out, double v, int prec, int upper)
{
	union { double d; unsigned long long u; } b;
	const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
	char *p = out;
	unsigned long long m;
	int e, i, lead, n;

	if (v != v || fabs(v) > 1.7976931348623157e308)
		return fixed(out, v, 0);
	b.d = v;
	if (b.u >> 63) *p++ = '-';
	e = (int)((b.u >> 52) & 0x7ff);
	m = b.u & 0xfffffffffffffULL;
	*p++ = '0';
	*p++ = upper ? 'X' : 'x';
	if (e == 0) {
		lead = 0;
		e = m ? -1022 : 0;
	} else {
		lead = 1;
		e -= 1023;
	}
	*p++ = (char)('0' + lead);
	n = 13;
	while (n > 0 && ((m >> (52 - 4 * n)) & 0xf) == 0) n--;
	if (prec >= 0) n = prec;
	if (n > 0) {
		*p++ = '.';
		for (i = 0; i < n; i++)
			*p++ = dig[(m >> (48 - 4 * i)) & 0xf];
	}
	*p++ = upper ? 'P' : 'p';
	*p++ = e < 0 ? '-' : '+';
	p += unum(p, (unsigned long long)(e < 0 ? -e : e), 10, 0);
	return (int)(p - out);
}

/* %e, and the exponent %g needs to choose with */
static int addsign(char *tmp, int n, int plus, int space)
{
	int k;

	if (tmp[1] == '-' || !(plus || space)) {
		for (k = 0; k < n; k++) tmp[k] = tmp[k + 1];
		return n;
	}
	tmp[0] = plus ? '+' : ' ';
	return n + 1;
}

static int format(sink *s, const char *f, va_list ap)
{
	char tmp[520];

	while (*f) {
		int left = 0, zero = 0, width = 0, prec = -1, longs = 0;
		int plus = 0, space = 0, alt = 0;
		int n;

		if (*f != '%') { put(s, *f++); continue; }
		f++;
		if (*f == '%') { put(s, '%'); f++; continue; }
		for (;;) {
			if (*f == '-') left = 1;
			else if (*f == '0') zero = 1;
			else if (*f == '+') plus = 1;
			else if (*f == ' ') space = 1;
			else if (*f == '#') alt = 1;
			else break;
			f++;
		}
		if (*f == '*') { width = va_arg(ap, int); f++; }
		else while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
		if (*f == '.') {
			f++;
			prec = 0;
			if (*f == '*') { prec = va_arg(ap, int); f++; }
			else while (*f >= '0' && *f <= '9')
				prec = prec * 10 + (*f++ - '0');
		}
		while (*f == 'l' || *f == 'z' || *f == 'j' || *f == 'h') {
			if (*f == 'l' || *f == 'z' || *f == 'j') longs++;
			f++;
		}

		switch (*f) {
		case 'd': case 'i': {
			long long v = longs > 1 ? va_arg(ap, long long)
			    : longs == 1 ? (long long)va_arg(ap, long)
			    : (long long)va_arg(ap, int);
			int neg = v < 0;
			unsigned long long u = neg ? (unsigned long long)-v
			    : (unsigned long long)v;

			n = 0;
			if (neg) tmp[n++] = '-';
			else if (plus) tmp[n++] = '+';
			else if (space) tmp[n++] = ' ';
			n += unum(tmp + n, u, 10, 0);
			putstr(s, tmp, n, width, left, zero);
			break;
		}
		case 'u': case 'x': case 'X': case 'o': {
			unsigned long long v = longs > 1
			    ? va_arg(ap, unsigned long long)
			    : longs == 1 ? (unsigned long long)va_arg(ap, unsigned long)
			    : (unsigned long long)va_arg(ap, unsigned);
			int base = (*f == 'u') ? 10 : (*f == 'o') ? 8 : 16;

			n = 0;
			if (alt && v != 0) {
				if (*f == 'o') {
					tmp[n++] = '0';
				} else if (*f != 'u') {
					tmp[n++] = '0';
					tmp[n++] = *f;
				}
			}
			n += unum(tmp + n, v, base, *f == 'X');
			putstr(s, tmp, n, width, left, zero);
			break;
		}
		case 'p': {
			unsigned long v = (unsigned long)va_arg(ap, void *);

			tmp[0] = '0'; tmp[1] = 'x';
			n = 2 + unum(tmp + 2, v, 16, 0);
			putstr(s, tmp, n, width, left, 0);
			break;
		}
		case 'c': {
			tmp[0] = (char)va_arg(ap, int);
			putstr(s, tmp, 1, width, left, 0);
			break;
		}
		case 's': {
			const char *p = va_arg(ap, const char *);
			int len = 0;

			if (!p) p = "(null)";
			while (p[len] && (prec < 0 || len < prec)) len++;
			putstr(s, p, len, width, left, 0);
			break;
		}
		case 'f': case 'F':
			n = fixed(tmp + 1, va_arg(ap, double),
			    prec < 0 ? 6 : prec);
			n = addsign(tmp, n, plus, space);
			putstr(s, tmp, n, width, left, zero);
			break;
		case 'e': case 'E':
			n = sci(tmp + 1, va_arg(ap, double),
			    prec < 0 ? 6 : prec, *f == 'E');
			n = addsign(tmp, n, plus, space);
			putstr(s, tmp, n, width, left, zero);
			break;
		case 'a': case 'A':
			n = hexf(tmp + 1, va_arg(ap, double), prec,
			    *f == 'A');
			n = addsign(tmp, n, plus, space);
			putstr(s, tmp, n, width, left, zero);
			break;
		case 'g': case 'G':
			n = gfmt(tmp + 1, va_arg(ap, double),
			    prec < 0 ? 6 : prec, *f == 'G');
			n = addsign(tmp, n, plus, space);
			putstr(s, tmp, n, width, left, zero);
			break;
		default:
			put(s, '%');
			put(s, *f);
		}
		if (*f) f++;
	}
	return (int)s->n;
}

int vfprintf(void *f, const char *fmt, va_list ap)
{
	sink s;

	s.buf = 0; s.cap = 0; s.n = 0; s.file = f;
	return format(&s, fmt, ap);
}

int fprintf(void *f, const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vfprintf(f, fmt, ap);
	va_end(ap);
	return n;
}

int vsnprintf(char *b, size_t cap, const char *fmt, va_list ap)
{
	sink s;

	s.buf = b; s.cap = cap; s.n = 0; s.file = 0;
	format(&s, fmt, ap);
	if (cap > 0) b[s.n < cap - 1 ? s.n : cap - 1] = 0;
	return (int)s.n;
}

int snprintf(char *b, size_t cap, const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(b, cap, fmt, ap);
	va_end(ap);
	return n;
}

int sprintf(char *b, const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(b, (size_t)-1, fmt, ap);
	va_end(ap);
	return n;
}

/* stdout, which is the third of the streams rt/wasmio.c keeps */
extern void *stdout;

int vprintf(const char *fmt, va_list ap)
{
	return vfprintf(stdout, fmt, ap);
}

int printf(const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vfprintf(stdout, fmt, ap);
	va_end(ap);
	return n;
}

int vsprintf(char *b, const char *fmt, va_list ap)
{
	return vsnprintf(b, (size_t)-1, fmt, ap);
}
