/* SPDX-License-Identifier: ISC */
#ifndef _MATH_H
#define _MATH_H

#define HUGE_VAL	__builtin_huge_val()
#define HUGE_VALF	__builtin_huge_valf()
#define INFINITY	__builtin_huge_valf()
#define NAN		__builtin_nan("")

double acos(double x);
double asin(double x);
double atan(double x);
double atan2(double y, double x);
double ceil(double x);
double cos(double x);
double cosh(double x);
double exp(double x);
double fabs(double x);
double floor(double x);
double fmod(double x, double y);
double frexp(double x, int *e);
double ldexp(double x, int e);
double log(double x);
double log10(double x);
double log2(double x);
double modf(double x, double *ip);
double pow(double x, double y);
double sin(double x);
double sinh(double x);
double sqrt(double x);
double tan(double x);
double tanh(double x);

float fabsf(float x);
float sqrtf(float x);

/* glibc exports these as functions; the type-generic macros are gcc only */
int __isnan(double x);
int __isinf(double x);
int __finite(double x);
#define isnan(x)    __isnan((double)(x))
#define isinf(x)    __isinf((double)(x))
#define isfinite(x) __finite((double)(x))

#endif
