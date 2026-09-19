/* SPDX-License-Identifier: 0BSD */
/*
 * The handle a program hands __cxa_atexit, so the library can tell
 * which object registered a function.  gcc keeps this in crtbegin,
 * which this compiler does not link; the address of the symbol itself
 * is what a shared object uses and serves a program just as well,
 * because nothing unloads a program.
 *
 * Weak, so that a crtbegin linked for some other reason wins.
 */
extern void *__dso_handle;
__attribute__((weak)) void *__dso_handle = &__dso_handle;
