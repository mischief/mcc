/* SPDX-License-Identifier: ISC */
/* A hosted program takes the C library's own stdint.h: its types are the
 * ones that library's interfaces are written in. */
#if __STDC_HOSTED__ && __has_include_next(<stdint.h>)
#include_next <stdint.h>
#else
#ifndef _STDINT_H
#define _STDINT_H

/* A long is a pointer wide everywhere this compiler goes, and 64 bits
 * only where the pointer is.  The 64-bit types follow that. */
#if __SIZEOF_LONG__ == 8
#define __I64              long
#define __I64C(v)          v ## L
#define __U64C(v)          v ## UL
#define __LONG_MAX         9223372036854775807L
#define __ULONG_MAX        18446744073709551615UL
#else
#define __I64              long long
#define __I64C(v)          v ## LL
#define __U64C(v)          v ## ULL
#define __LONG_MAX         2147483647L
#define __ULONG_MAX        4294967295UL
#endif

typedef signed char        int8_t;
typedef short              int16_t;
typedef int                int32_t;
typedef __I64              int64_t;
typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned __I64     uint64_t;
typedef long               intptr_t;
typedef unsigned long      uintptr_t;
typedef int64_t            intmax_t;
typedef uint64_t           uintmax_t;

#define INT8_MAX    127
#define INT16_MAX   32767
#define INT32_MAX   2147483647
#define INT64_MAX   __I64C(9223372036854775807)
#define INT8_MIN    (-128)
#define INT16_MIN   (-32768)
#define INT32_MIN   (-2147483647 - 1)
#define INT64_MIN   (-__I64C(9223372036854775807) - 1)
#define UINT8_MAX   255
#define UINT16_MAX  65535
#define UINT32_MAX  4294967295U
#define UINT64_MAX  __U64C(18446744073709551615)
#define INTPTR_MAX  __LONG_MAX
#define UINTPTR_MAX __ULONG_MAX
#define INTMAX_MAX  INT64_MAX
#define UINTMAX_MAX UINT64_MAX
#define SIZE_MAX    __ULONG_MAX

/* The least and fast families, which portable code asks for far more often
 * than it asks for an exact width.  The smallest type that will hold the
 * width is the exact one here, and the fast one is a word. */
typedef int8_t             int_least8_t;
typedef int16_t            int_least16_t;
typedef int32_t            int_least32_t;
typedef int64_t            int_least64_t;
typedef uint8_t            uint_least8_t;
typedef uint16_t           uint_least16_t;
typedef uint32_t           uint_least32_t;
typedef uint64_t           uint_least64_t;

typedef int8_t             int_fast8_t;
typedef long               int_fast16_t;
typedef long               int_fast32_t;
typedef int64_t            int_fast64_t;
typedef uint8_t            uint_fast8_t;
typedef unsigned long      uint_fast16_t;
typedef unsigned long      uint_fast32_t;
typedef uint64_t           uint_fast64_t;

#define INT_LEAST8_MAX     INT8_MAX
#define INT_LEAST16_MAX    INT16_MAX
#define INT_LEAST32_MAX    INT32_MAX
#define INT_LEAST64_MAX    INT64_MAX
#define INT_LEAST8_MIN     INT8_MIN
#define INT_LEAST16_MIN    INT16_MIN
#define INT_LEAST32_MIN    INT32_MIN
#define INT_LEAST64_MIN    INT64_MIN
#define UINT_LEAST8_MAX    UINT8_MAX
#define UINT_LEAST16_MAX   UINT16_MAX
#define UINT_LEAST32_MAX   UINT32_MAX
#define UINT_LEAST64_MAX   UINT64_MAX
#define INT_FAST8_MAX      INT8_MAX
#define INT_FAST16_MAX     __LONG_MAX
#define INT_FAST32_MAX     __LONG_MAX
#define INT_FAST64_MAX     INT64_MAX
#define INT_FAST8_MIN      INT8_MIN
#define INT_FAST16_MIN     (-__LONG_MAX - 1)
#define INT_FAST32_MIN     (-__LONG_MAX - 1)
#define INT_FAST64_MIN     INT64_MIN
#define UINT_FAST8_MAX     UINT8_MAX
#define UINT_FAST16_MAX    __ULONG_MAX
#define UINT_FAST32_MAX    __ULONG_MAX
#define UINT_FAST64_MAX    UINT64_MAX
#define PTRDIFF_MAX        __LONG_MAX
#define PTRDIFF_MIN        (-__LONG_MAX - 1)
#define INTMAX_MIN         INT64_MIN
#define INTPTR_MIN         (-__LONG_MAX - 1)
#ifdef __WCHAR_MAX__
#define WCHAR_MAX          __WCHAR_MAX__
#define WCHAR_MIN          __WCHAR_MIN__
#else
#define WCHAR_MAX          INT32_MAX
#define WCHAR_MIN          INT32_MIN
#endif
#define WINT_MAX           UINT32_MAX
#define WINT_MIN           0

#define INT8_C(v)          v
#define INT16_C(v)         v
#define INT32_C(v)         v
#define INT64_C(v)         __I64C(v)
#define UINT8_C(v)         v
#define UINT16_C(v)        v
#define UINT32_C(v)        v ## U
#define UINT64_C(v)        __U64C(v)
#define INTMAX_C(v)        __I64C(v)
#define UINTMAX_C(v)       __U64C(v)

#endif
#endif
