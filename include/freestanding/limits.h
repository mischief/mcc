/* SPDX-License-Identifier: ISC */
#ifndef _LIMITS_H
#define _LIMITS_H

/* The limits a freestanding program is owed.  Every value comes from what
 * the compiler already says about the machine. */

#define CHAR_BIT   __CHAR_BIT__
#define SCHAR_MAX  __SCHAR_MAX__
#define SCHAR_MIN  (-__SCHAR_MAX__ - 1)
#define UCHAR_MAX  (__SCHAR_MAX__ * 2 + 1)

#ifdef __CHAR_UNSIGNED__
#define CHAR_MIN   0
#define CHAR_MAX   UCHAR_MAX
#else
#define CHAR_MIN   SCHAR_MIN
#define CHAR_MAX   SCHAR_MAX
#endif

#define SHRT_MAX   __SHRT_MAX__
#define SHRT_MIN   (-__SHRT_MAX__ - 1)
#define USHRT_MAX  (__SHRT_MAX__ * 2 + 1)

#define INT_MAX    __INT_MAX__
#define INT_MIN    (-__INT_MAX__ - 1)
#define UINT_MAX   (__INT_MAX__ * 2U + 1U)

#define LONG_MAX   __LONG_MAX__
#define LONG_MIN   (-__LONG_MAX__ - 1L)
#define ULONG_MAX  (__LONG_MAX__ * 2UL + 1UL)

#define LLONG_MAX  __LONG_LONG_MAX__
#define LLONG_MIN  (-__LONG_LONG_MAX__ - 1LL)
#define ULLONG_MAX (__LONG_LONG_MAX__ * 2ULL + 1ULL)

#define MB_LEN_MAX 16

#endif
