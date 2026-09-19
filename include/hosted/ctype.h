/* SPDX-License-Identifier: ISC */
#ifndef _CTYPE_H
#define _CTYPE_H

/* glibc exports every one of these as a real function as well as a macro */
int isalnum(int c);
int isalpha(int c);
int iscntrl(int c);
int isdigit(int c);
int isgraph(int c);
int islower(int c);
int isprint(int c);
int ispunct(int c);
int isspace(int c);
int isupper(int c);
int isxdigit(int c);
int tolower(int c);
int toupper(int c);

#endif
