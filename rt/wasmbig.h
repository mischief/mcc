/* SPDX-License-Identifier: 0BSD */
/*
 * A big integer, only as much of one as turning a double into decimal
 * and back needs: enough limbs for five to the power of 1074.
 */
#ifndef WASMBIG_H
#define WASMBIG_H

#define NL 160				/* 32 bit limbs */

typedef struct {
	int n;
	unsigned d[NL];
} Big;

extern const unsigned TENS[10];
extern const unsigned FIVES[13];

void bigset(Big *b, unsigned v);
int bigmuladd(Big *b, unsigned m, unsigned a);
unsigned bigdiv(Big *b, unsigned m);
int bigshl(Big *b, int k);
void bigshr(Big *b, int k, int *lost);
int bigbits(const Big *b);
double bigdouble(Big *b, int e2, int sticky);
int bigdigits(Big *b, char *out);
void bigmulpow5(Big *b, int k);

#endif
