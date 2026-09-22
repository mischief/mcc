/* SPDX-License-Identifier: 0BSD */
/*
 * The string, character and memory half of a C library, for a machine
 * whose whole runtime this compiler carries. Nothing here touches the
 * host: every one is arithmetic over memory.
 */

typedef unsigned long size_t;

void *memcpy(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
char *strchr(const char *s, int c);

void *memmove(void *d, const void *s, size_t n)
{
	char *a = d;
	const char *b = s;

	if (a == b || n == 0) return d;
	if (a < b) { while (n--) *a++ = *b++; return d; }
	a += n; b += n;
	while (n--) *--a = *--b;
	return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *p = a, *q = b;

	while (n--) { if (*p != *q) return *p - *q; p++; q++; }
	return 0;
}

void *memchr(const void *s, int c, size_t n)
{
	const unsigned char *p = s;

	while (n--) { if (*p == (unsigned char)c) return (void *)p; p++; }
	return 0;
}

char *strcpy(char *d, const char *s)
{
	char *r = d;

	while ((*d++ = *s++) != 0) ;
	return r;
}

char *strncpy(char *d, const char *s, size_t n)
{
	char *r = d;

	while (n && (*d = *s)) { d++; s++; n--; }
	while (n--) *d++ = 0;
	return r;
}

char *strcat(char *d, const char *s)
{
	strcpy(d + strlen(d), s);
	return d;
}

int strncmp(const char *a, const char *b, size_t n)
{
	while (n--) {
		unsigned char x = *a++, y = *b++;

		if (x != y) return x - y;
		if (x == 0) return 0;
	}
	return 0;
}

int strcoll(const char *a, const char *b) { return strcmp(a, b); }

char *strrchr(const char *s, int c)
{
	const char *last = 0;

	for (;; s++) {
		if (*s == (char)c) last = s;
		if (*s == 0) return (char *)last;
	}
}

char *strpbrk(const char *s, const char *set)
{
	for (; *s; s++) {
		const char *t;

		for (t = set; *t; t++)
			if (*s == *t) return (char *)s;
	}
	return 0;
}

char *strstr(const char *h, const char *needle)
{
	size_t n = strlen(needle);

	if (n == 0) return (char *)h;
	for (; *h; h++)
		if (*h == *needle && strncmp(h, needle, n) == 0)
			return (char *)h;
	return 0;
}

/* ---- ctype, the C locale and no other ---- */

int isdigit(int c) { return c >= '0' && c <= '9'; }
int isxdigit(int c)
{
	return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int isalpha(int c) { return islower(c) || isupper(c); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isspace(int c)
{
	return c == ' ' || (c >= '\t' && c <= '\r');
}
int iscntrl(int c) { return (unsigned)c < 32 || c == 127; }
int isgraph(int c) { return c > 32 && c < 127; }
int isprint(int c) { return c >= 32 && c < 127; }
int ispunct(int c) { return isgraph(c) && !isalnum(c); }
int tolower(int c) { return isupper(c) ? c + 32 : c; }
int toupper(int c) { return islower(c) ? c - 32 : c; }
