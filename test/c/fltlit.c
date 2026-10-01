/* SPDX-License-Identifier: ISC */
/* Float and long double literals rounded once from their digits.  A
   double between rounds twice where it lands halfway. */

float lf1(void) { return 1.000000059604644775390626f; }
float lf2(void) { return 1.000000059604644775390625f; }
float lf3(void) { return 0x1.0000010000000001p0f; }
float lf4(void) { return 0x1.000003p0f; }
float lf5(void) { return 0x1p-150f; }
float lf6(void) { return 0x1.0000000001p-150f; }
float lf7(void) { return 0x1.ffffffp127f; }
float lf8(void) { return 2.1019476964872256063855943749348741969203929295e-45f; }
static float sf = 0x1.0000010000000001p0f;
float lf9(void) { return sf; }

#if defined(__x86_64__)
long double ll1(void) { return 0xda7f3f0fcc04840dp-32L; }
long double ll2(void) { return 0xae1988870fddbacdp-16400L; }
long double ll3(void) { return -0x8da7593fcb98ddd9p-16412L; }
long double ll4(void) { return 0x1.0000000000000001p0L; }
long double ll5(void) { return 0x1.0000000000000003p0L; }
long double ll6(void) { return 0x1.8p-16446L; }
long double ll7(void) { return 0x1p16384L; }
long double ll8(void) { return 18446744073709551617.0L; }
long double ll9(void) { return 1.82e-4951L; }
#else
double ll1(void) { return 0; }
double ll2(void) { return 0; }
double ll3(void) { return 0; }
double ll4(void) { return 0; }
double ll5(void) { return 0; }
double ll6(void) { return 0; }
double ll7(void) { return 0; }
double ll8(void) { return 0; }
double ll9(void) { return 0; }
#endif
