/* SPDX-License-Identifier: 0BSD */
/*
 * A wasm program for lua-os.  Its one way out is lua-os's system call,
 * imported from the host as luaos.syscall and served by lua-os: the
 * page only carries each call across, and the numbers are the ones
 * rt/wasm.c answers under WASI, with three of lua-os's own below.
 */

#define SYS_ARGS	1100	/* argv, NUL separated, into (a, b) */
#define SYS_NANOS	1101	/* a monotonic count, eight bytes at a */
#define SYS_RANDOM	1102	/* b bytes of entropy at a */

__attribute__((import_module("luaos"), import_name("syscall")))
long __luaos_syscall(long n, long a, long b, long c);

void *malloc(unsigned long n);
int main(int argc, char **argv);
void exit(int code);

long __syscall(long n, long a, long b, long c)
{
	return __luaos_syscall(n, a, b, c);
}

void __exit(long n, long code)
{
	(void)n;
	__luaos_syscall(93, code, 0, 0);
	for (;;) ;			/* the host does not come back */
}

unsigned long long __wasm_nanos(void)
{
	unsigned long long ns = 0;

	__luaos_syscall(SYS_NANOS, (long)&ns, 0, 0);
	return ns;
}

long __wasm_time(void)
{
	return __luaos_syscall(201, 0, 0, 0);
}

long __wasm_random(void *buf, long len)
{
	return __luaos_syscall(SYS_RANDOM, (long)buf, len, 0);
}

/* lua-os hands a program no environment */
char *getenv(const char *name)
{
	(void)name;
	return 0;
}

void _start(void)
{
	static char *none[1];
	char **argv = none;
	char *buf;
	long len = __luaos_syscall(SYS_ARGS, 0, 0, 0);
	int argc = 0, i;

	if (len > 0 && (buf = (char *)malloc((unsigned long)len)) != 0 &&
	    __luaos_syscall(SYS_ARGS, (long)buf, len, 0) == len) {
		for (i = 0; i < len; i++) if (buf[i] == 0) argc++;
		argv = (char **)malloc((unsigned long)(argc + 1) *
		    sizeof(char *));
		if (argv) {
			char *p = buf;

			for (i = 0; i < argc; i++) {
				argv[i] = p;
				while (*p) p++;
				p++;
			}
			argv[argc] = 0;
		} else {
			argv = none;
			argc = 0;
		}
	}
	exit(main(argc, argv));
}
