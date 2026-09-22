/* SPDX-License-Identifier: 0BSD */
/*
 * Buffered files over the system calls in rt/wasm.c.
 *
 * A FILE is a descriptor, one buffer and the flags that say what is in
 * it. Reading and writing share the buffer, as they do everywhere: a
 * stream turns around by flushing first.
 */

typedef unsigned long size_t;
typedef long off_t;

void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
size_t strlen(const char *);
void *malloc(size_t);
void free(void *);

long __syscall(long n, long a, long b, long c);

/* whether stdout goes out a line at a time; the host's runtime says */
extern int __wasm_linebuf;

#define BUFSZ	1024

#define F_READ	1
#define F_WRITE	2
#define F_EOF	4
#define F_ERR	8
#define F_USED	16

typedef struct {
	int fd;
	int flags;
	int len;		/* bytes in the buffer */
	int pos;		/* where the next one is */
	int back;		/* one character put back, or -1 */
	char buf[BUFSZ];
} FILE;

static FILE streams[3 + 16];

FILE *stdin = &streams[0];
FILE *stdout = &streams[1];
FILE *stderr = &streams[2];

static int started;

static void begin(void)
{
	int i;

	for (i = 0; i < 3; i++) {
		streams[i].fd = i;
		streams[i].flags = F_USED | (i == 0 ? F_READ : F_WRITE);
		streams[i].back = -1;
	}
	started = 1;
}

int fflush(FILE *f)
{
	if (!started) begin();
	if (!f) {
		int i, r = 0;

		for (i = 0; i < (int)(sizeof streams / sizeof streams[0]); i++)
			if (streams[i].flags & F_USED) r |= fflush(&streams[i]);
		return r;
	}
	if ((f->flags & F_WRITE) && f->len > 0) {
		long done = 0;

		while (done < f->len) {
			long n = __syscall(64, f->fd, (long)(f->buf + done),
			    f->len - done);

			if (n <= 0) { f->flags |= F_ERR; f->len = 0; return -1; }
			done += n;
		}
		f->len = 0;
	}
	return 0;
}

static int fill(FILE *f)
{
	long n;

	/* whatever asked the question is shown before the answer is
	   waited for */
	if (f->fd == 0) fflush(stdout);
	if (f->flags & (F_EOF | F_ERR)) return -1;
	n = __syscall(63, f->fd, (long)f->buf, BUFSZ);
	if (n < 0) { f->flags |= F_ERR; return -1; }
	if (n == 0) { f->flags |= F_EOF; return -1; }
	f->len = (int)n;
	f->pos = 0;
	return 0;
}

int fputc(int c, FILE *f)
{
	if (!started) begin();
	if (f->len >= BUFSZ && fflush(f) != 0) return -1;
	f->buf[f->len++] = (char)c;
	/* a terminal wants its line now, and nothing here knows if it is
	   one, so an unbuffered stream is the safe reading of both.  A
	   host where each write is costly says otherwise: then a line
	   waits until the buffer fills, input is read, or the program
	   ends. */
	if ((c == '\n' && __wasm_linebuf) || f->fd == 2) {
		if (fflush(f) != 0) return -1;
	}
	return (unsigned char)c;
}

int putc(int c, FILE *f) { return fputc(c, f); }
int putchar(int c) { return fputc(c, stdout); }

int fputs(const char *s, FILE *f)
{
	while (*s) if (fputc(*s++, f) < 0) return -1;
	return 0;
}

int puts(const char *s)
{
	if (fputs(s, stdout) < 0) return -1;
	return fputc('\n', stdout) < 0 ? -1 : 0;
}

int fgetc(FILE *f)
{
	if (!started) begin();
	if (f->back >= 0) { int c = f->back; f->back = -1; return c; }
	if (f->pos >= f->len && fill(f) != 0) return -1;
	return (unsigned char)f->buf[f->pos++];
}

int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }

int ungetc(int c, FILE *f)
{
	if (c < 0) return -1;
	f->back = (unsigned char)c;
	f->flags &= ~F_EOF;
	return (unsigned char)c;
}

char *fgets(char *s, int n, FILE *f)
{
	int i = 0;

	if (n <= 0) return 0;
	while (i < n - 1) {
		int c = fgetc(f);

		if (c < 0) break;
		s[i++] = (char)c;
		if (c == '\n') break;
	}
	if (i == 0) return 0;
	s[i] = 0;
	return s;
}

size_t fwrite(const void *p, size_t sz, size_t n, FILE *f)
{
	const char *b = p;
	size_t total = sz * n, i;

	for (i = 0; i < total; i++)
		if (fputc(b[i], f) < 0) return sz ? i / sz : 0;
	return n;
}

size_t fread(void *p, size_t sz, size_t n, FILE *f)
{
	char *b = p;
	size_t total = sz * n, i;

	for (i = 0; i < total; i++) {
		int c = fgetc(f);

		if (c < 0) break;
		b[i] = (char)c;
	}
	return sz ? i / sz : 0;
}

int feof(FILE *f) { return (f->flags & F_EOF) != 0; }
int ferror(FILE *f) { return (f->flags & F_ERR) != 0; }
void clearerr(FILE *f) { f->flags &= ~(F_EOF | F_ERR); }

FILE *fopen(const char *path, const char *mode)
{
	int i, flags = 0, want = 0;
	long fd;

	if (!started) begin();
	for (i = 3; i < (int)(sizeof streams / sizeof streams[0]); i++)
		if (!(streams[i].flags & F_USED)) break;
	if (i == (int)(sizeof streams / sizeof streams[0])) return 0;

	if (mode[0] == 'r') { flags = 0; want = F_READ; }
	else if (mode[0] == 'w') { flags = 01 | 0100 | 01000; want = F_WRITE; }
	else if (mode[0] == 'a') { flags = 01 | 0100 | 02000; want = F_WRITE; }
	else return 0;
	if (mode[1] == '+' || (mode[1] == 'b' && mode[2] == '+'))
		{ flags = (flags & ~1) | 02; want = F_READ | F_WRITE; }

	fd = __syscall(1024, (long)path, flags, 0666);
	if (fd < 0) return 0;
	streams[i].fd = (int)fd;
	streams[i].flags = F_USED | want;
	streams[i].len = 0;
	streams[i].pos = 0;
	streams[i].back = -1;
	return &streams[i];
}

int fclose(FILE *f)
{
	int r = fflush(f);

	if (f->fd > 2) __syscall(57, f->fd, 0, 0);
	f->flags = 0;
	return r;
}

FILE *freopen(const char *path, const char *mode, FILE *f)
{
	fclose(f);
	return fopen(path, mode);
}

int fseek(FILE *f, long off, int whence)
{
	fflush(f);
	f->pos = f->len = 0;
	f->back = -1;
	f->flags &= ~F_EOF;
	return __syscall(62, f->fd, off, whence) < 0 ? -1 : 0;
}

long ftell(FILE *f)
{
	long at = __syscall(62, f->fd, 0, 1);

	if (at < 0) return -1;
	if (f->flags & F_WRITE) return at + f->len;
	return at - (f->len - f->pos) - (f->back >= 0 ? 1 : 0);
}

void rewind(FILE *f) { fseek(f, 0, 0); }
int setvbuf(FILE *f, char *b, int mode, size_t n) { return 0; }
void setbuf(FILE *f, char *b) { }

int remove(const char *p) { return (int)__syscall(35, (long)p, 0, 0); }
int rename(const char *a, const char *b)
{
	return (int)__syscall(38, (long)a, (long)b, 0);
}

/*
 * A name in the directory the host handed over that nothing has yet:
 * the probe is an open, since a WASI host may offer nothing else to
 * ask with.  The counter starts from the clock so two runs differ.
 */
char *tmpnam(char *s)
{
	static char own[20];
	static unsigned long n;
	int tries, i;

	if (!s) s = own;
	if (!n) n = (unsigned long)__syscall(201, 0, 0, 0) % 1000000;
	for (tries = 0; tries < 1000; tries++) {
		unsigned long v = n++ % 1000000;
		long fd;

		memcpy(s, "lua_", 4);
		for (i = 9; i >= 4; i--) { s[i] = (char)('0' + v % 10); v /= 10; }
		s[10] = 0;
		fd = __syscall(1024, (long)s, 0, 0);
		if (fd < 0) return s;
		__syscall(57, fd, 0, 0);
	}
	return 0;
}

/* not removed at exit: a WASI host need not offer a way to */
FILE *tmpfile(void)
{
	char name[20];

	if (!tmpnam(name)) return 0;
	return fopen(name, "w+");
}
