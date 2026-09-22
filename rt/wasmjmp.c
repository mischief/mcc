/* SPDX-License-Identifier: 0BSD */
/*
 * setjmp and longjmp, which wasm cannot express.
 *
 * A wasm frame leaves only by returning, so a long jump is made of
 * ordinary returns: longjmp records where it is going and sets
 * __wasm_unwind, and the check the assembler writes after every call
 * sends each frame home until the one that called setjmp recognises
 * its own stack pointer.  That frame puts the dispatch state back to
 * the setjmp site and carries on.
 *
 * None of this is written unless the module calls setjmp, so a program
 * that does not pay nothing.
 */

/* what the code around a setjmp fills in before calling */
int __wasm_jmpstate;
void *__wasm_jmpsp;

/* set while a jump is in flight */
int __wasm_unwind;
int __wasm_unwindval;
int __wasm_unwindstate;
void *__wasm_unwindsp;

typedef struct {
	int state;
	void *sp;
} jmpsave;

/* The saving half of setjmp; the returning half is written inline. */
int __setjmp_save(void *env)
{
	jmpsave *e = (jmpsave *)env;

	e->state = __wasm_jmpstate;
	e->sp = __wasm_jmpsp;
	return 0;
}

void longjmp(void *env, int val)
{
	jmpsave *e = (jmpsave *)env;

	__wasm_unwindstate = e->state;
	__wasm_unwindsp = e->sp;
	__wasm_unwindval = val ? val : 1;
	__wasm_unwind = 1;
}

void _longjmp(void *env, int val) { longjmp(env, val); }
