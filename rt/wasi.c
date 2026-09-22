/* SPDX-License-Identifier: 0BSD */
/*
 * The embedder's half of rt/wasm.c, written against WASI.  A name
 * beginning `__wasi_` is imported from wasi_snapshot_preview1, so this
 * file is what makes a module run under wasmtime, wasm3 or any other
 * WASI host.
 */

typedef unsigned long long u64;

int __wasi_fd_write(int fd, const void *iovs, int n, int *out);
int __wasi_fd_read(int fd, const void *iovs, int n, int *out);
int __wasi_fd_close(int fd);
int __wasi_fd_seek(int fd, long long off, int whence, u64 *out);
int __wasi_path_open(int dirfd, int dirflags, const char *path, int len,
    int oflags, u64 base, u64 inheriting, int fdflags, int *out);
void __wasi_proc_exit(int code);
int __wasi_clock_time_get(int id, long long precision, u64 *out);
int __wasi_args_sizes_get(int *argc, int *bufsize);
int __wasi_args_get(char **argv, char *buf);
int __wasi_environ_sizes_get(int *count, int *bufsize);
int __wasi_environ_get(char **env, char *buf);
int __wasi_random_get(void *buf, int len);
int __wasi_fd_prestat_get(int fd, char *buf);
int __wasi_fd_prestat_dir_name(int fd, char *path, int len);

struct iovec { const char *base; int len; };

long __wasm_write(long fd, const void *p, long n)
{
	struct iovec v;
	int wrote = 0;

	v.base = (const char *)p;
	v.len = (int)n;
	if (__wasi_fd_write((int)fd, &v, 1, &wrote) != 0) return -1;
	return wrote;
}

long __wasm_read(long fd, void *p, long n)
{
	struct iovec v;
	int got = 0;

	v.base = (const char *)p;
	v.len = (int)n;
	if (__wasi_fd_read((int)fd, &v, 1, &got) != 0) return -1;
	return got;
}

long __wasm_close(long fd)
{
	return __wasi_fd_close((int)fd) == 0 ? 0 : -1;
}

long __wasm_seek(long fd, long off, long whence)
{
	u64 at = 0;

	if (__wasi_fd_seek((int)fd, off, (int)whence, &at) != 0) return -1;
	return (long)at;
}

/*
 * A WASI path is opened below a directory the host handed over, so the
 * first preopen is found once and every path is taken as relative to
 * it.  A leading slash or "./" is dropped, since neither means anything
 * to a host that already chose the root.
 */
static int rootfd = -1;

static void findroot(void)
{
	char buf[16];
	int fd;

	for (fd = 3; fd < 16; fd++) {
		if (__wasi_fd_prestat_get(fd, buf) == 0) {
			rootfd = fd;
			return;
		}
	}
	rootfd = -2;
}

/* rights: everything an ordinary file needs, which is most of them */
#define RIGHTS 0x00000000ffffffffULL

long __wasm_open(const char *path, long flags, long mode)
{
	int fd = -1, len = 0, oflags = 0, fdflags = 0;

	(void)mode;
	if (rootfd == -1) findroot();
	if (rootfd < 0) return -1;
	while (path[0] == '/' || (path[0] == '.' && path[1] == '/'))
		path += (path[0] == '/') ? 1 : 2;
	while (path[len]) len++;
	/* O_CREAT is 0100, O_TRUNC 01000, O_APPEND 02000 on Linux */
	if (flags & 0100) oflags |= 1;		/* creat */
	if (flags & 01000) oflags |= 8;		/* trunc */
	if (flags & 02000) fdflags |= 1;	/* append */
	if (__wasi_path_open(rootfd, 1, path, len, oflags, RIGHTS, RIGHTS,
	    fdflags, &fd) != 0)
		return -1;
	return fd;
}

long __wasm_remove(const char *path)
{
	(void)path;
	return -1;			/* no path_unlink_file here */
}

long __wasm_rename(const char *from, const char *to)
{
	(void)from;
	(void)to;
	return -1;
}

long __wasm_time(void)
{
	u64 ns = 0;

	if (__wasi_clock_time_get(0, 1000000, &ns) != 0) return 0;
	return (long)(ns / 1000000000ULL);
}

void __wasm_exit(long code)
{
	__wasi_proc_exit((int)code);
}

/* nanoseconds on the monotonic clock, for clock() */
u64 __wasm_nanos(void)
{
	u64 ns = 0;

	__wasi_clock_time_get(1, 1000, &ns);
	return ns;
}

long __wasm_random(void *buf, long len)
{
	return __wasi_random_get(buf, (int)len) == 0 ? len : -1;
}

/*
 * The environment, read once into a block this file owns.  getenv walks
 * it, since a WASI host hands it over whole rather than a name at a
 * time.
 */
static char **envp;
static char *envbuf;
static int envn;

void *malloc(unsigned long n);

static void readenv(void)
{
	int count = 0, size = 0;

	envn = -2;
	if (__wasi_environ_sizes_get(&count, &size) != 0) return;
	if (count == 0) { envn = 0; return; }
	envp = (char **)malloc((unsigned long)count * sizeof(char *));
	envbuf = (char *)malloc((unsigned long)size);
	if (!envp || !envbuf) return;
	if (__wasi_environ_get(envp, envbuf) != 0) return;
	envn = count;
}

char *getenv(const char *name)
{
	int i, k;

	if (envn == 0 && !envp) readenv();
	for (i = 0; i < envn; i++) {
		for (k = 0; name[k] && envp[i][k] == name[k]; k++) ;
		if (name[k] == 0 && envp[i][k] == '=') return envp[i] + k + 1;
	}
	return 0;
}

int main(int argc, char **argv);
void exit(int code);

void _start(void)
{
	int argc = 0, size = 0;
	char **argv = 0;
	char *buf = 0;
	static char *none[1];

	if (__wasi_args_sizes_get(&argc, &size) == 0 && argc > 0) {
		argv = (char **)malloc((unsigned long)(argc + 1) *
		    sizeof(char *));
		buf = (char *)malloc((unsigned long)size);
		if (argv && buf && __wasi_args_get(argv, buf) == 0)
			argv[argc] = 0;
		else
			argv = 0;
	}
	if (!argv) { argc = 0; argv = none; }
	exit(main(argc, argv));
}
