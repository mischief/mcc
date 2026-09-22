/* SPDX-License-Identifier: ISC */
#include "inc.h"
#include "inc.h"          /* the guard must make this a no-op */
#include "twoarm.h"
#include "twoarm.h"       /* an #else arm is not a guard: read again */

#define ONE 1
#define TWO (ONE + ONE)
#define ADD(a, b) ((a) + (b))
#define STR(x) #x
#define XSTR(x) STR(x)
#define CAT(a, b) a ## b
#define EMPTY
#define REC REC
#define INDIRECT ADD
#define CALL(f, x) f(x, x)
#define VA(fmt, ...) printf(fmt, __VA_ARGS__)
#define NOARG() 42
#define PAREN (1 + 2)
#define USEPAREN ADD PAREN

int a = TWO;
int b = ADD(3, ADD(4, 5));
char *s = STR(hello   world);
char *t = XSTR(TWO);
int CAT(foo, bar) = 7;
int c = EMPTY 9;
int d = REC;
int e = INDIRECT(1, 2);
int f = CALL(ADD, 5);
int g = NOARG();
int h = MAX(3, 4);
int CONCAT3(x, y, z) = 1;
int i = ADD((1, 2), 3);

#if defined(ONE) && TWO == 2 && !defined(NOPE)
int yes = 1;
#endif
#if HDR_ONE > 0 ? 1 : 0
int tern = 1;
#endif
#if 1 + 2 * 3 == 7 && (8 >> 2) == 2 && (5 % 3) == 2
int arith = 1;
#endif
#if 0
vanish
#elif 0
also vanish
#elif 1
int elif2 = 1;
#else
no
#endif
#ifdef ONE
#  ifndef NOPE
int nested = 1;
#  endif
#endif
#undef ONE
#ifndef ONE
int undone = 1;
#endif
char *joined = "abc" "def";
long lines = __LINE__;

/* A block comment opened on a directive line inside a group that is
 * switched off runs past the newline: what follows belongs to the
 * comment, apostrophe and all. */
#ifdef NOT_DEFINED_ANYWHERE
#define SKIPPED_A 1 /* opened here, with the locale's apostrophe
			and a "quote and a 'nother */
#define SKIPPED_B 2
#endif
#ifdef NOT_DEFINED_ANYWHERE
#define SKIPPED_C 3 // a line comment with an apostrophe's
#endif
int after_skipped_comments;

/* `#` answers with the spelling of its argument, not with the value:
 * the spelling of "\0" is four characters and its value is one, and a
 * kernel builds its export table out of exactly that difference. */
#define SPELL(x) #x
#define SPELLV(x) SPELL(x)
#define EMPTYNS ""

const char *spell_asciz = SPELL(.asciz "GPL");
const char *spell_nul = SPELL(.ascii EMPTYNS "\0");
const char *spell_esc = SPELL("a\tb\\c\"d");
const char *spell_char = SPELL('e' '\0' '\\' '\'');
const char *spell_wide = SPELL(L"w" u8"v" U"z");
const char *spell_num = SPELL(1.0f 0x1p3 07 0xffffffffffffffffu);
const char *spell_thru = SPELLV(EMPTYNS "\0");

/* A macro body keeps the spelling of a literal in it, which is what
 * the operator has to answer with when the body is stringified. */
#define BODYNUL .ascii "" "\0"
#define BODYCHR x '\n' y
const char *spell_body = SPELL(BODYNUL);
const char *spell_bodychr = SPELL(BODYCHR);
const char *spell_bodyv = SPELLV(BODYNUL);
