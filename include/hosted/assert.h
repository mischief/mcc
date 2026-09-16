#ifndef _ASSERT_H
#define _ASSERT_H

void __assert_fail(const char *expr, const char *file, unsigned line,
		   const char *fn);

#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((e) ? (void)0 : __assert_fail(#e, __FILE__, __LINE__, 0))
#endif

#endif
