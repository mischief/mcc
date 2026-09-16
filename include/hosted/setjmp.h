#ifndef _SETJMP_H
#define _SETJMP_H

/*
 * Two hundred bytes on x86-64 glibc: the register save area, the flag that
 * says whether the signal mask was saved, and the mask itself.  A program
 * may keep one inside a structure of its own, so the size has to be right
 * even though nothing here reads the contents.
 */
typedef struct {
	long __opaque[25];
} __jmp_buf_tag;

typedef __jmp_buf_tag jmp_buf[1];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);
int _setjmp(jmp_buf env);
void _longjmp(jmp_buf env, int val);

#endif
