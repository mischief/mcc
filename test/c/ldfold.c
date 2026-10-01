/* SPDX-License-Identifier: ISC */
/* Long double constants fold in the long double's own precision. */

#if defined(__x86_64__)
typedef long double ld;

ld lk1(void) { return 0x3fffffffffffffp10 + ((ld)16777219.0f); }
ld lk2(void) { return 1.0L + 0x1p-60L; }
ld lk3(void) { return 1.0L / 3.0L; }
ld lk4(void) { return 0x1p1000L * 0x1p100L; }
ld lk5(void) { return 0x1p-16440L * 0x1.8p-5L; }
ld lk6(void) { return 0x1.fffffffffffffffep16383L * 2.0L; }
ld lk7(void) { return 1.0L - 0x1.0000000000000002p0L; }
ld lk8(void) { return 3.0L / 0x1.0000000000000002p0L; }
ld lk9(void) { return 0x1p-16382L - 0x1p-16445L; }
static ld sk = 2.0L / 3.0L;
ld lk10(void) { return sk; }
#else
typedef double ld;

ld lk1(void) { return 0; }
ld lk2(void) { return 0; }
ld lk3(void) { return 0; }
ld lk4(void) { return 0; }
ld lk5(void) { return 0; }
ld lk6(void) { return 0; }
ld lk7(void) { return 0; }
ld lk8(void) { return 0; }
ld lk9(void) { return 0; }
ld lk10(void) { return 0; }
#endif
