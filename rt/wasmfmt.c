/* SPDX-License-Identifier: 0BSD */
/*
 * printf and its family, over a sink so the same formatter serves a
 * stream and a buffer.
 *
 * The float conversions carry about seventeen digits, which is what a
 * double holds, rather than the shortest string that reads back.
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

/* The digits of a double, to `prec` places after the point. */
static int fixed(char *out, double v, int prec)
{
	char *p = out;
	double ip, fp;
	int i;

	if (v != v) { out[0] = 'n'; out[1] = 'a'; out[2] = 'n'; return 3; }
	if (v > 1.7976931348623157e308) {
		out[0] = 'i'; out[1] = 'n'; out[2] = 'f'; return 3;
	}
	if (v < -1.7976931348623157e308) {
		out[0] = '-'; out[1] = 'i'; out[2] = 'n'; out[3] = 'f';
		return 4;
	}
	/* a negative zero compares equal to zero, so the sign is read
	   off a division instead */
	if (v < 0.0 || (v == 0.0 && 1.0 / v < 0.0)) { *p++ = '-'; v = -v; }

	/*
	 * Scale to an integer and round there.  The multiply carries its
	 * own rounding error, so a value that lands on an exact half here
	 * need not be one: past about fifteen significant digits the last
	 * one can differ from what an exact conversion gives.
	 *
	 * Round half to even, as a C library does, and take the digits
	 * off the rounded integer so no second rounding creeps in.
	 */
	{
		double scale = 1.0;

		for (i = 0; i < prec; i++) scale *= 10.0;
		if (v * scale < 9007199254740992.0) {
			double s = v * scale;
			double fl = floor(s), fr = s - fl;
			char tmp[400];
			int n = 0;

			if (fr > 0.5 || (fr == 0.5 &&
			    fl - 2.0 * floor(fl / 2.0) != 0.0))
				fl += 1.0;
			while (fl >= 1.0) {
				double q = floor(fl / 10.0);

				tmp[n++] = (char)('0' +
				    (int)(fl - q * 10.0));
				fl = q;
			}
			while (n <= prec) tmp[n++] = '0';
			while (n > 0) {
				*p++ = tmp[--n];
				if (n == prec && prec > 0) *p++ = '.';
			}
			return (int)(p - out);
		}
	}

	/*
	 * Too big to scale.  Dividing a double this large by ten no
	 * longer lands on a whole number, so the digits come from the
	 * bits: the mantissa, doubled once per binary exponent in a
	 * decimal array.
	 */
	ip = floor(v);
	fp = v - ip;

	{
		union { double d; unsigned long long u; } bits;
		unsigned long long m;
		unsigned char dig[352];
		int e, nd = 0, j;

		bits.d = ip;
		e = (int)((bits.u >> 52) & 0x7ff);
		m = bits.u & 0xfffffffffffffULL;
		if (e == 0) {
			e = -1074;
		} else {
			m |= 1ULL << 52;
			e -= 1075;
		}
		if (e < 0) {
			m = (e > -64) ? (m >> -e) : 0;
			e = 0;
		}
		while (m) { dig[nd++] = (unsigned char)(m % 10); m /= 10; }
		if (nd == 0) dig[nd++] = 0;
		while (e-- > 0) {
			int carry = 0;

			for (j = 0; j < nd; j++) {
				int t = dig[j] * 2 + carry;

				dig[j] = (unsigned char)(t % 10);
				carry = t / 10;
			}
			while (carry) {
				dig[nd++] = (unsigned char)(carry % 10);
				carry /= 10;
			}
		}
		while (nd > 1 && dig[nd - 1] == 0) nd--;
		while (nd > 0) *p++ = (char)('0' + dig[--nd]);
	}
	if (prec > 0) {
		*p++ = '.';
		for (i = 0; i < prec; i++) {
			int d;

			fp *= 10.0;
			d = (int)fp;
			if (d < 0) d = 0;
			if (d > 9) d = 9;
			*p++ = (char)('0' + d);
			fp -= (double)d;
		}
	}
	return (int)(p - out);
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
static int sci(char *out, double v, int prec, int upper)
{
	char *p = out;
	int e = 0, n;

	if (v != v || fabs(v) > 1.7976931348623157e308)
		return fixed(out, v, 0);
	if (v < 0.0 || (v == 0.0 && 1.0 / v < 0.0)) { *p++ = '-'; v = -v; }
	if (v != 0.0) {
		while (v >= 10.0) { v /= 10.0; e++; }
		while (v < 1.0) { v *= 10.0; e--; }
	}
	n = fixed(p, v, prec);
	/* rounding can carry 9.99 up to 10, which is one digit too many */
	if (n > 0 && p[1] != '.' && p[1] != 0 && prec > 0) {
		e++;
		n = fixed(p, v / 10.0, prec);
	} else if (n > 1 && prec == 0 && p[1] != 0) {
		e++;
		n = fixed(p, v / 10.0, prec);
	}
	p += n;
	*p++ = upper ? 'E' : 'e';
	*p++ = e < 0 ? '-' : '+';
	if (e < 0) e = -e;
	if (e < 10) *p++ = '0';
	p += unum(p, (unsigned long long)e, 10, 0);
	return (int)(p - out);
}

static int gfmt(char *out, double v, int prec, int upper)
{
	int e = 0, n, i;
	double a = fabs(v);

	if (prec == 0) prec = 1;
	if (a != 0.0 && a == a && a < 1.7976931348623157e308) {
		double t = a;

		while (t >= 10.0) { t /= 10.0; e++; }
		while (t < 1.0) { t *= 10.0; e--; }
	}
	if (e < -4 || e >= prec) n = sci(out, v, prec - 1, upper);
	else n = fixed(out, v, prec - 1 - e);

	/* %g drops the zeros it does not need, and a bare point with them */
	for (i = 0; i < n; i++) if (out[i] == '.') break;
	if (i < n) {
		int stop = n, j;

		for (j = i; j < n; j++) if (out[j] == 'e' || out[j] == 'E') {
			stop = j; break;
		}
		j = stop - 1;
		while (j > i && out[j] == '0') j--;
		if (out[j] == '.') j--;
		if (stop < n) {
			int k, m = j + 1;

			for (k = stop; k < n; k++) out[m++] = out[k];
			n = m;
		} else {
			n = j + 1;
		}
	}
	return n;
}

/*
 * A float conversion writes its own minus and nothing else, so it is
 * written one byte in and the slot is either filled or closed up.
 */
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
