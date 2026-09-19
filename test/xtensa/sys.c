/* SPDX-License-Identifier: ISC */
/*
 * The few calls newlib needs, answered by the simulator's simcall.
 */
#include <sys/stat.h>
#include <reent.h>

/* the espressif newlib expects the system to hand out a reentrancy
 * structure; one for the one thread here is enough */
static struct _reent onereent = _REENT_INIT(onereent);

struct _reent *__getreent(void)
{
	return &onereent;
}

static int sc(int n, int a, int b, int c)
{
	register int r2 __asm__("a2") = n;
	register int r3 __asm__("a3") = a;
	register int r4 __asm__("a4") = b;
	register int r5 __asm__("a5") = c;

	__asm__ volatile ("simcall" : "+r"(r2) : "r"(r3), "r"(r4), "r"(r5)
			  : "memory");
	return r2;
}

int _write(int fd, const char *p, int n) { return sc(4, fd, (int)p, n); }
int _read(int fd, char *p, int n)        { return sc(3, fd, (int)p, n); }
int _close(int fd)                       { (void)fd; return 0; }
int _lseek(int fd, int off, int w)       { (void)fd; (void)off; (void)w; return 0; }
int _isatty(int fd)                      { (void)fd; return 1; }
int _fstat(int fd, struct stat *st)      { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _getpid(void)                        { return 1; }
int _kill(int pid, int s)                { (void)pid; (void)s; return 0; }
void _exit(int c)                        { sc(1, c, 0, 0); for (;;); }

extern char _end[];
static char *brk;

void *_sbrk(int n)
{
	char *p;

	if (brk == 0) brk = _end;
	p = brk;
	brk += n;
	return p;
}
