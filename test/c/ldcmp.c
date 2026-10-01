/* SPDX-License-Identifier: ISC */
/* A comparison of two long double constants is decided by their
   values: two different ones may share their low eight bytes. */

#if defined(__x86_64__)
double lq1(void) { return (1.0L != 0x1p-16382L) ? 2.0 : 3.0; }
double lq2(void) { return (0x1p-16382L == 1.0L) ? 2.0 : 3.0; }
int lq3(void) { return 0x1.0000000000000002p0L > 1.0L; }
int lq4(void) { return -0.0L == 0.0L; }
int lq5(void) { return __builtin_nanl("") != __builtin_nanl(""); }
int lq6(void) { return -2.0L <= -0x1.0000000000000002p1L; }
static int sq = 0x1.0000000000000002p0L > 1.0L;
int lq7(void) { return sq; }
#else
double lq1(void) { return 2.0; }
double lq2(void) { return 3.0; }
int lq3(void) { return 1; }
int lq4(void) { return 1; }
int lq5(void) { return 1; }
int lq6(void) { return 0; }
int lq7(void) { return 1; }
#endif
