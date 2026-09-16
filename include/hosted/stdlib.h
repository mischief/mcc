#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS	0
#define EXIT_FAILURE	1
#define RAND_MAX	2147483647
#define MB_CUR_MAX	((size_t)6)

typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;

void *malloc(size_t n);
void *calloc(size_t n, size_t size);
void *realloc(void *p, size_t n);
void free(void *p);

void abort(void);
void exit(int status);
int atexit(void (*fn)(void));
char *getenv(const char *name);
int system(const char *cmd);

double atof(const char *s);
int atoi(const char *s);
long atol(const char *s);
long long atoll(const char *s);
double strtod(const char *s, char **end);
float strtof(const char *s, char **end);
long strtol(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
long long strtoll(const char *s, char **end, int base);
unsigned long long strtoull(const char *s, char **end, int base);

int abs(int n);
long labs(long n);
div_t div(int a, int b);
ldiv_t ldiv(long a, long b);

int rand(void);
void srand(unsigned seed);

void qsort(void *base, size_t n, size_t size,
	   int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t n, size_t size,
	      int (*cmp)(const void *, const void *));

int mblen(const char *s, size_t n);

#endif
