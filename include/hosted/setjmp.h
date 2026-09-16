#ifndef _SETJMP_H
#define _SETJMP_H

/*
 * The register save area, the flag that says whether the signal mask was
 * saved, and the mask itself.  A program may keep one inside a structure of
 * its own, so the size has to be at least what glibc uses, even though
 * nothing here reads the contents: 200 bytes on x86-64, 344 on riscv64,
 * where twelve floating point registers are callee saved as well.
 */
#if defined(__riscv)
#define __JMP_BUF_WORDS 43
#else
#define __JMP_BUF_WORDS 25
#endif

typedef struct {
	long __opaque[__JMP_BUF_WORDS];
} __jmp_buf_tag;

typedef __jmp_buf_tag jmp_buf[1];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);
int _setjmp(jmp_buf env);
void _longjmp(jmp_buf env, int val);

#endif
