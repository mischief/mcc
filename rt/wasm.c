/* SPDX-License-Identifier: 0BSD */
/*
 * The system calls a program makes, on a machine that has none: the
 * embedder supplies them and everything above here goes through
 * __syscall as it does on Linux.
 */

long __wasm_write(long fd, const void *p, long n);
long __wasm_read(long fd, void *p, long n);
long __wasm_open(const char *path, long flags, long mode);
long __wasm_close(long fd);
long __wasm_seek(long fd, long off, long whence);
long __wasm_remove(const char *path);
long __wasm_rename(const char *from, const char *to);
long __wasm_time(void);
void __wasm_exit(long code);

long __syscall(long n, long a, long b, long c)
{
	switch (n) {
	case 63: return __wasm_read(a, (void *)b, c);
	case 64: return __wasm_write(a, (const void *)b, c);
	case 57: return __wasm_close(a);
	case 62: return __wasm_seek(a, b, c);
	case 35: return __wasm_remove((const char *)a);
	case 38: return __wasm_rename((const char *)a, (const char *)b);
	case 201: return __wasm_time();
	case 1024: return __wasm_open((const char *)a, b, c);
	case 93:
	case 94:
		__wasm_exit(a);
		return 0;
	}
	return -38;			/* ENOSYS */
}

void __exit(long n, long code)
{
	(void)n;
	__wasm_exit(code);
}
