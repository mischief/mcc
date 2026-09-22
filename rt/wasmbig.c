/* SPDX-License-Identifier: 0BSD */
/*
 * The big integer that turns a double into decimal and back.  A double
 * is a whole number times a power of two, so both directions are exact
 * arithmetic on integers and nothing has to be guessed at.
 */

#include "wasmbig.h"

const unsigned TENS[10] = {
	1, 10, 100, 1000, 10000, 100000, 1000000, 10000000,
	100000000, 1000000000
};

const unsigned FIVES[13] = {
	1, 5, 25, 125, 625, 3125, 15625, 78125, 390625, 1953125,
	9765625, 48828125, 244140625
};

/*
 * A decimal numeral is an integer times a power of ten, so the digits
 * go into a big integer and the power is applied to it exactly.  What
 * comes out is the nearest double, which printf and back has to be.
 */

double ldexp(double x, int n);

void bigset(Big *b, unsigned v)
{
	b->n = v ? 1 : 0;
	b->d[0] = v;
}

/* b = b * m + a, or 0 if there is no room */
int bigmuladd(Big *b, unsigned m, unsigned a)
{
	unsigned long long c = a;
	int i;

	for (i = 0; i < b->n; i++) {
		c += (unsigned long long)b->d[i] * m;
		b->d[i] = (unsigned)c;
		c >>= 32;
	}
	while (c) {
		if (b->n >= NL) return 0;
		b->d[b->n++] = (unsigned)c;
		c >>= 32;
	}
	return 1;
}

/* b = b / m, and the remainder */
unsigned bigdiv(Big *b, unsigned m)
{
	unsigned long long r = 0;
	int i;

	for (i = b->n - 1; i >= 0; i--) {
		r = (r << 32) | b->d[i];
		b->d[i] = (unsigned)(r / m);
		r = r % m;
	}
	while (b->n > 0 && b->d[b->n - 1] == 0) b->n--;
	return (unsigned)r;
}

int bigshl(Big *b, int k)
{
	int words = k / 32, bits = k % 32, i;

	if (b->n == 0) return 1;
	if (b->n + words + 1 > NL) return 0;
	if (bits) {
		unsigned carry = 0;

		for (i = 0; i < b->n; i++) {
			unsigned v = b->d[i];

			b->d[i] = (v << bits) | carry;
			carry = v >> (32 - bits);
		}
		if (carry) b->d[b->n++] = carry;
	}
	if (words) {
		for (i = b->n - 1; i >= 0; i--) b->d[i + words] = b->d[i];
		for (i = 0; i < words; i++) b->d[i] = 0;
		b->n += words;
	}
	return 1;
}

/* right shift, noting in `lost` whether a set bit went away */
void bigshr(Big *b, int k, int *lost)
{
	int words = k / 32, bits = k % 32, i;

	if (words >= b->n) {
		for (i = 0; i < b->n; i++) if (b->d[i]) *lost = 1;
		b->n = 0;
		return;
	}
	for (i = 0; i < words; i++) if (b->d[i]) *lost = 1;
	if (words) {
		for (i = 0; i + words < b->n; i++) b->d[i] = b->d[i + words];
		b->n -= words;
	}
	if (bits) {
		if (b->d[0] & ((1u << bits) - 1)) *lost = 1;
		for (i = 0; i < b->n; i++) {
			unsigned hi = (i + 1 < b->n) ? b->d[i + 1] : 0;

			b->d[i] = (b->d[i] >> bits) | (hi << (32 - bits));
		}
		while (b->n > 0 && b->d[b->n - 1] == 0) b->n--;
	}
}

int bigbits(const Big *b)
{
	unsigned v;
	int k = 0;

	if (b->n == 0) return 0;
	v = b->d[b->n - 1];
	while (v) { v >>= 1; k++; }
	return (b->n - 1) * 32 + k;
}

/* b * 2**e2 as a double, rounded to nearest with ties to even */
double bigdouble(Big *b, int e2, int sticky)
{
	unsigned long long m;
	int bits = bigbits(b), d, round;

	if (bits == 0) return 0.0;
	/* exactly 54 bits: the 53 kept and the one they round on */
	if (bits > 54) {
		d = bits - 54;
		bigshr(b, d, &sticky);
		e2 += d;
	} else if (bits < 54) {
		d = 54 - bits;
		if (!bigshl(b, d)) return 0.0;
		e2 -= d;
	}
	m = b->d[0];
	if (b->n > 1) m |= (unsigned long long)b->d[1] << 32;
	/* a result below the smallest normal keeps fewer bits */
	if (e2 + 1 < -1074) {
		d = -1074 - (e2 + 1);
		if (d >= 54) return 0.0;
		if (m & ((1ULL << d) - 1)) sticky = 1;
		m >>= d;
		e2 += d;
	}
	round = (int)(m & 1);
	m >>= 1;
	e2++;
	if (round && (sticky || (m & 1))) {
		m++;
		if (m == (1ULL << 53)) { m >>= 1; e2++; }
	}
	if (e2 > 971) return 1.0 / 0.0;
	return ldexp((double)m, e2);
}


/* b = b * 5**k */
void bigmulpow5(Big *b, int k)
{
	while (k >= 13) {
		bigmuladd(b, 1220703125u, 0);
		k -= 13;
	}
	if (k > 0) bigmuladd(b, FIVES[k], 0);
}

/* The decimal digits of b, most significant first.  Returns how many. */
int bigdigits(Big *b, char *out)
{
	char tmp[1200];
	int n = 0, i, j;

	if (b->n == 0) { out[0] = '0'; return 1; }
	while (b->n > 0) {
		unsigned r = bigdiv(b, 1000000000u);

		for (i = 0; i < 9; i++) {
			tmp[n++] = (char)('0' + r % 10);
			r /= 10;
		}
	}
	while (n > 1 && tmp[n - 1] == '0') n--;
	for (j = 0; j < n; j++) out[j] = tmp[n - 1 - j];
	return n;
}
