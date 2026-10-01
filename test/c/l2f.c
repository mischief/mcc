/* SPDX-License-Identifier: ISC */
/* A 64-bit integer converts to float rounded once.  A 32-bit target
   that goes through a double first rounds twice. */

float sl2f(long long x) { return x; }
float ul2f(unsigned long long x) { return x; }
