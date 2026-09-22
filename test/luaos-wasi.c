/* SPDX-License-Identifier: 0BSD */
/*
 * The lua-os wasm machine's host calls, over WASI, so the module runs
 * headless under a WASI engine with no page around it.  Built into the
 * module, these are defined rather than imported.
 *
 * Input is read whole at start, since host_read must not block and a
 * WASI host need not offer a way to ask whether a byte is waiting.
 */

typedef unsigned long size_t;
typedef unsigned long long u64;

int __wasi_fd_write(int fd, const void *iovs, int n, int *out);
int __wasi_fd_read(int fd, const void *iovs, int n, int *out);
int __wasi_clock_time_get(int id, long long precision, u64 *out);
int __wasi_random_get(void *buf, int len);
void __wasi_proc_exit(int code);

void wasm_boot(u64 membytes, int w, int h);

struct iovec { const char *base; int len; };

static char in[65536];
static int inlen, inpos;

void host_write(const void *p, size_t n)
{
	struct iovec v;
	int wrote;

	v.base = (const char *)p;
	v.len = (int)n;
	__wasi_fd_write(1, &v, 1, &wrote);
}

int host_read(void)
{
	return inpos < inlen ? (unsigned char)in[inpos++] : -1;
}

u64 host_now_ns(void)
{
	u64 ns = 0;

	__wasi_clock_time_get(1, 1000, &ns);
	return ns;
}

long long host_now_unix(void)
{
	u64 ns = 0;

	__wasi_clock_time_get(0, 1000000, &ns);
	return (long long)(ns / 1000000000ULL);
}

/* nothing to wait on once the input is spent: the machine is done */
void host_wait(int ms)
{
	(void)ms;
	if (inpos >= inlen) __wasi_proc_exit(0);
}

int host_random(void *p, size_t n)
{
	return __wasi_random_get(p, (int)n) == 0;
}

void host_exit(int code) { __wasi_proc_exit(code); }

int host_fb_open(int w, int h, void *pixels) { (void)w; (void)h; (void)pixels; return 0; }
void host_fb_flush(int x, int y, int w, int h) { (void)x; (void)y; (void)w; (void)h; }
int host_kbd(void) { return -1; }
int host_ptr(int *x, int *y, int *b) { (void)x; (void)y; (void)b; return 0; }
int host_ws_open(const char *u, size_t n) { (void)u; (void)n; return -1; }
int host_ws_state(int id) { (void)id; return -1; }
int host_ws_send(int id, const void *p, size_t n) { (void)id; (void)p; (void)n; return -1; }
int host_ws_recv(int id, void *p, size_t m) { (void)id; (void)p; (void)m; return -1; }
void host_ws_close(int id) { (void)id; }
int host_blk_size(void) { return 0; }
int host_blk_read(int lba, void *p, int n) { (void)lba; (void)p; (void)n; return -1; }
int host_blk_write(int lba, const void *p, int n) { (void)lba; (void)p; (void)n; return -1; }

void _start(void)
{
	struct iovec v;
	int got;

	for (;;) {
		v.base = in + inlen;
		v.len = (int)sizeof in - inlen;
		if (v.len <= 0 || __wasi_fd_read(0, &v, 1, &got) != 0 ||
		    got <= 0)
			break;
		inlen += got;
	}
	wasm_boot(64ULL * 1024 * 1024, 0, 0);
	__wasi_proc_exit(0);
}
