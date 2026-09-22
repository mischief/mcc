/* SPDX-License-Identifier: 0BSD */
/*
 * The system call a program built by this compiler makes, on a machine
 * that has none: the embedder supplies write and exit as imports, and
 * everything above here goes through __syscall as it does on Linux.
 */

__attribute__((import_module("env"), import_name("write")))
long __wasm_write(long fd, const void *p, long n);

__attribute__((import_module("env"), import_name("exit")))
void __wasm_exit(long code);

long __syscall(long n, long a, long b, long c)
{
	switch (n) {
	case 64:			/* write */
		return __wasm_write(a, (const void *)b, c);
	case 93:			/* exit */
	case 94:			/* exit_group */
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
