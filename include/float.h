/* SPDX-License-Identifier: ISC */
/* Freestanding header: IEEE 754 binary32 and binary64. */
#ifndef _FLOAT_H
#define _FLOAT_H

#define FLT_RADIX       2

#define FLT_MANT_DIG    24
#define FLT_DIG         6
#define FLT_MIN_EXP     (-125)
#define FLT_MAX_EXP     128
#define FLT_EPSILON     1.19209290e-07F
#define FLT_MIN         1.17549435e-38F
#define FLT_MAX         3.40282347e+38F
#define FLT_MIN_10_EXP  (-37)
#define FLT_MAX_10_EXP  38

#define DBL_MANT_DIG    53
#define DBL_DIG         15
#define DBL_MIN_EXP     (-1021)
#define DBL_MAX_EXP     1024
#define DBL_EPSILON     2.2204460492503131e-16
#define DBL_MIN         2.2250738585072014e-308
#define DBL_MAX         1.7976931348623157e+308
#define DBL_MIN_10_EXP  (-307)
#define DBL_MAX_10_EXP  308

/* On a machine with the x87 extended type, long double is that type;
   anywhere else it is the double. */
#if __LDBL_MANT_DIG__ == 64
#define LDBL_MANT_DIG   64
#define LDBL_DIG        18
#define LDBL_MIN_EXP    (-16381)
#define LDBL_MAX_EXP    16384
#define LDBL_EPSILON    1.0842021724855044340e-19L
#define LDBL_TRUE_MIN   3.6451995318824746025e-4951L
#define LDBL_MIN        3.3621031431120935063e-4932L
#define LDBL_MAX        1.1897314953572317650e+4932L
#define LDBL_MIN_10_EXP (-4931)
#define LDBL_MAX_10_EXP 4932
#define DECIMAL_DIG     21
#define LDBL_DECIMAL_DIG 21
#else
#define LDBL_MANT_DIG   DBL_MANT_DIG
#define LDBL_DIG        DBL_DIG
#define LDBL_MIN_EXP    DBL_MIN_EXP
#define LDBL_MAX_EXP    DBL_MAX_EXP
#define LDBL_EPSILON    DBL_EPSILON
#define LDBL_MIN        DBL_MIN
#define LDBL_MAX        DBL_MAX
#define LDBL_MIN_10_EXP DBL_MIN_10_EXP
#define LDBL_MAX_10_EXP DBL_MAX_10_EXP
#define DECIMAL_DIG     17
#define LDBL_DECIMAL_DIG DECIMAL_DIG
#endif
#define DBL_DECIMAL_DIG 17
#define FLT_DECIMAL_DIG 9

/* Rounding is to nearest and arithmetic is done in the type itself:
   this compiler asks the machine for neither of the alternatives. */
#define FLT_ROUNDS      1
#define FLT_EVAL_METHOD 0
#define FLT_HAS_SUBNORM 1
#define DBL_HAS_SUBNORM 1
#define LDBL_HAS_SUBNORM 1

#endif
