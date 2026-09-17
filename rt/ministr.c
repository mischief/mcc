/*
 * The handful of string functions a program built by this compiler alone
 * needs.  Byte loops: nothing here is on a path that matters.
 */
typedef unsigned long size_t;

size_t strlen(const char *s)
{
	size_t n = 0;

	while (s[n]) n++;
	return n;
}

char *strchr(const char *s, int c)
{
	for (;;) {
		if (*s == (char)c) return (char *)s;
		if (*s == 0) return 0;
		s++;
	}
}

size_t strspn(const char *s, const char *set)
{
	size_t n = 0;

	while (s[n] && strchr(set, s[n]) != 0) n++;
	return n;
}

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

void *memcpy(void *d, const void *s, size_t n)
{
	char *p = (char *)d;
	const char *q = (const char *)s;
	size_t i;

	for (i = 0; i < n; i++) p[i] = q[i];
	return d;
}

void *memset(void *d, int c, size_t n)
{
	char *p = (char *)d;
	size_t i;

	for (i = 0; i < n; i++) p[i] = (char)c;
	return d;
}
