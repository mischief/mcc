/* SPDX-License-Identifier: ISC */
/* An integer constant converts to float rounded once, not through a
   double: the bits below a double's last one can break a float's tie. */

float kf1(void) { return (float)0x4000004000000001LL; }
float kf2(void) { return (float)0x8000008000000001ULL; }
float kf3(void) { return (float)-0x4000004000000001LL; }
float kf4(void) { return (float)0x7fffffbfffffffffLL; }
double kd1(void) { return (double)0x8000000000000401ULL; }
double kd2(void) { return (double)0xfffffffffffffbffULL; }
double kd3(void) { return (double)0x8000000000000400ULL; }
static float sf = 0x4000004000000001LL;
float kf5(void) { return sf; }

#if defined(__x86_64__)
long double kx1(void) { return (long double)0x8000000000000401ULL; }
long double kx2(void) { return (long double)-0x7fffffffffffffffLL; }
#else
double kx1(void) { return 0; }
double kx2(void) { return 0; }
#endif
