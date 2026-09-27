/* SPDX-License-Identifier: ISC */
/* Freestanding header: the compiler supplies this one, not the library. */
#ifndef _STDDEF_H
#define _STDDEF_H

/* The target says how wide these are: size_t is unsigned int on i386. */
#ifdef __SIZE_TYPE__
typedef __SIZE_TYPE__ size_t;
#else
typedef unsigned long size_t;
#endif
#ifdef __PTRDIFF_TYPE__
typedef __PTRDIFF_TYPE__ ptrdiff_t;
#else
typedef long ptrdiff_t;
#endif
/* wchar_t is a keyword in C++, which may read this header too. */
#ifndef __cplusplus
#ifdef __WCHAR_TYPE__
typedef __WCHAR_TYPE__ wchar_t;
#else
typedef int wchar_t;
#endif
#endif

#ifdef __cplusplus
#define NULL 0
#else
#define NULL ((void *)0)
#endif
#define offsetof(type, member) ((size_t)&(((type *)0)->member))

#endif
