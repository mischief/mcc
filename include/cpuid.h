/* SPDX-License-Identifier: ISC */
/* The cpuid instruction, under the names gcc and clang give it. */
#ifndef _CPUID_H
#define _CPUID_H

#define __cpuid(level, a, b, c, d)					\
	__asm__ __volatile__("cpuid"					\
		: "=a"(a), "=b"(b), "=c"(c), "=d"(d)			\
		: "0"(level))

#define __cpuid_count(level, count, a, b, c, d)				\
	__asm__ __volatile__("cpuid"					\
		: "=a"(a), "=b"(b), "=c"(c), "=d"(d)			\
		: "0"(level), "2"(count))

/* The highest leaf in the range ext names: 0, or 0x80000000.  sig
   gets the vendor's first word when it is not null. */
static __inline unsigned int
__get_cpuid_max(unsigned int ext, unsigned int *sig)
{
	unsigned int a, b, c, d;

	__cpuid(ext, a, b, c, d);
	if (sig)
		*sig = b;
	return a;
}

/* 0 when the leaf is past the highest the processor has. */
static __inline int
__get_cpuid(unsigned int leaf, unsigned int *a, unsigned int *b,
    unsigned int *c, unsigned int *d)
{
	unsigned int ext = leaf & 0x80000000;

	if (__get_cpuid_max(ext, 0) < leaf)
		return 0;
	__cpuid(leaf, *a, *b, *c, *d);
	return 1;
}

static __inline int
__get_cpuid_count(unsigned int leaf, unsigned int sub, unsigned int *a,
    unsigned int *b, unsigned int *c, unsigned int *d)
{
	unsigned int ext = leaf & 0x80000000;

	if (__get_cpuid_max(ext, 0) < leaf)
		return 0;
	__cpuid_count(leaf, sub, *a, *b, *c, *d);
	return 1;
}

#endif
