/* SPDX-License-Identifier: ISC */
#ifndef _INTTYPES_H
#define _INTTYPES_H

#include <stdint.h>

/* The printf and scanf spellings.  Only the widths a program is likely to
 * ask for by name.  A 64-bit value is a long where a long is 64 bits and a
 * long long where it is not, as stdint.h says; a pointer is a long. */
#if !defined(__SIZEOF_LONG__) || __SIZEOF_LONG__ == 8
#define __PRI64 "l"
#else
#define __PRI64 "ll"
#endif
#define PRId8   "d"
#define PRId16  "d"
#define PRId32  "d"
#define PRId64  __PRI64 "d"
#define PRIi8   "i"
#define PRIi16  "i"
#define PRIi32  "i"
#define PRIi64  __PRI64 "i"
#define PRIu8   "u"
#define PRIu16  "u"
#define PRIu32  "u"
#define PRIu64  __PRI64 "u"
#define PRIx8   "x"
#define PRIx16  "x"
#define PRIx32  "x"
#define PRIx64  __PRI64 "x"
#define PRIX8   "X"
#define PRIX16  "X"
#define PRIX32  "X"
#define PRIX64  __PRI64 "X"
#define PRIo8   "o"
#define PRIo16  "o"
#define PRIo32  "o"
#define PRIo64  __PRI64 "o"
#define PRIdPTR "ld"
#define PRIuPTR "lu"
#define PRIxPTR "lx"
#define PRIdMAX __PRI64 "d"
#define PRIuMAX __PRI64 "u"
#define PRIxMAX __PRI64 "x"

#define SCNd8   "hhd"
#define SCNd16  "hd"
#define SCNd32  "d"
#define SCNd64  __PRI64 "d"
#define SCNu8   "hhu"
#define SCNu16  "hu"
#define SCNu32  "u"
#define SCNu64  __PRI64 "u"
#define SCNx8   "hhx"
#define SCNx16  "hx"
#define SCNx32  "x"
#define SCNx64  __PRI64 "x"

typedef struct { intmax_t quot, rem; } imaxdiv_t;

intmax_t imaxabs(intmax_t v);
imaxdiv_t imaxdiv(intmax_t a, intmax_t b);
intmax_t strtoimax(const char *s, char **end, int base);
uintmax_t strtoumax(const char *s, char **end, int base);

#endif
