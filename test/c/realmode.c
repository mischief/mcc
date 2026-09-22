/* SPDX-License-Identifier: ISC */
/* Real mode C.  The processor reads these instructions in 16-bit mode
 * with 32-bit operands, which is what .code16gcc means, and the same
 * lines are built for the host to say what the answers should be.
 * `main16` is the entry; a serial port is the only way out.
 */
#ifdef HOST
#include <stdio.h>
#define emitc(c) fputc((c), stdout)
#else
static void out8(unsigned short port, unsigned char v)
{
	__asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port));
}

static unsigned char in8(unsigned short port)
{
	unsigned char v;

	__asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

static void emitc(char c)
{
	while (!(in8(0x3fd) & 0x20))
		;
	out8(0x3f8, (unsigned char)c);
}
#endif

static void emits(const char *s)
{
	while (*s)
		emitc(*s++);
}

static void emitu(unsigned long long v, int base)
{
	char b[24];
	int i = 0;

	if (v == 0) { emitc('0'); return; }
	while (v) {
		int d = (int)(v % (unsigned)base);

		b[i++] = d < 10 ? (char)('0' + d) : (char)('a' + d - 10);
		v /= (unsigned)base;
	}
	while (i--)
		emitc(b[i]);
}

static void emitd(long long v)
{
	if (v < 0) { emitc('-'); v = -v; }
	emitu((unsigned long long)v, 10);
}

struct point { short x; int y; long long z; };

static int sum(const int *a, int n)
{
	int s = 0, i;

	for (i = 0; i < n; i++)
		s += a[i];
	return s;
}

static int fib(int n)
{
	return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

static const char *name(int k)
{
	switch (k) {
	case 0: return "zero";
	case 3: return "three";
	case 7: return "seven";
	default: return "other";
	}
}

static int arr[8] = {1, 2, 3, 4, 5, 6, 7, 8};
static struct point pt = {-3, 70000, 1234567890123LL};
static char buf[32];

/* A record the size of the boot code's biosregs, moved whole: by
 * assignment, by value into a call, and back out of one.  Each is a
 * block copy, which is a string move in 16-bit mode. */
struct regs {
	unsigned short ax, bx, cx, dx, si, di, bp, sp;
	unsigned int flags;
	unsigned char pad[20];
};

static struct regs rpat = {1, 2, 3, 4, 5, 6, 7, 8, 0x246,
	{9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}};

static struct regs bump(struct regs r)
{
	struct regs out = r;

	out.ax += r.pad[19];
	out.flags ^= 0x800;
	return out;
}

static unsigned int regsum(const struct regs *r)
{
	unsigned int s = r->ax + r->bx + r->cx + r->dx + r->si + r->di +
		r->bp + r->sp + r->flags;
	int i;

	for (i = 0; i < 20; i++)
		s = s * 31 + r->pad[i];
	return s;
}

static void copy(char *d, const char *s, int n)
{
	while (n-- > 0)
		*d++ = *s++;
}

void main16(void)
{
	unsigned long long big = 0x123456789abcdefULL;
	int i;

	emits("rm start\r\n");
	emits("sum "); emitd(sum(arr, 8)); emits("\r\n");
	emits("fib "); emitd(fib(15)); emits("\r\n");
	emits("pt "); emitd(pt.x); emitc(' '); emitd(pt.y); emitc(' ');
	emitd(pt.z); emits("\r\n");
	emits("big "); emitu(big, 16); emitc(' '); emitu(big >> 13, 10);
	emits("\r\n");
	emits("div "); emitd((long long)big / 1000003);
	emitc(' '); emitd((long long)big % 1000003); emits("\r\n");
	copy(buf, "copied string", 14);
	emits("buf "); emits(buf); emits("\r\n");
	for (i = 0; i < 10; i += 3) { emits(name(i)); emitc(' '); }
	emits("\r\n");
	emits("shift ");
	for (i = 0; i < 5; i++) { emitu(1ULL << (i * 13), 10); emitc(' '); }
	emits("\r\n");
	{
		struct regs a = rpat, b;

		b = a;
		b.pad[0] = 99;
		emits("regs "); emitu(regsum(&a), 10); emitc(' ');
		emitu(regsum(&b), 10); emitc(' ');
		b = bump(b);
		emitu(regsum(&b), 10); emitc(' '); emitu(b.ax, 10);
		emits("\r\n");
	}
	emits("rm done\r\n");
#ifndef HOST
	for (;;)
		__asm__ volatile("hlt");
#endif
}

#ifdef HOST
int main(void) { main16(); return 0; }
#endif
