/* SPDX-License-Identifier: ISC */
/* A long double constant converts from its own bits, not from the
   double nearest it, which may not be its value. */

#if defined(__x86_64__)
unsigned short lc1(void) { return (unsigned short)0x85dcc66f99a33b03p-59L; }
long lc2(void) { return (long)(float)0xa167513e078fda9cp-16445L; }
int lc3(void) { return (int)-0x9c21ffffffffffffp-33L; }
unsigned lc4(void) { return (unsigned)0xf26e36af07bd8266p-16441L; }
double lc5(void) { return (double)0x1.0000000000000c01p0L; }
float lc6(void) { return (float)0x1.0000010000000002p0L; }
double lc7(void) { return (double)0x1p-16382L; }
double lc8(void) { return (double)0x1.fffffffffffffffep1023L; }
double lc9(void) { return (double)0x1.00000000000008p-1074L; }
unsigned long lc10(void) { return (unsigned long)0xfffffffffffff800p0L; }
long lc11(void) { return (long)0.1L; }
static int sk = (int)1234.9L;
int lc12(void) { return sk; }
#else
unsigned short lc1(void) { return 0; }
long lc2(void) { return 0; }
int lc3(void) { return 0; }
unsigned lc4(void) { return 0; }
double lc5(void) { return 0; }
float lc6(void) { return 0; }
double lc7(void) { return 0; }
double lc8(void) { return 0; }
double lc9(void) { return 0; }
unsigned long lc10(void) { return 0; }
long lc11(void) { return 0; }
int lc12(void) { return 0; }
#endif
