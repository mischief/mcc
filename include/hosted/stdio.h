#ifndef _STDIO_H
#define _STDIO_H

#include <stddef.h>
#include <stdarg.h>

/* a program only ever holds a pointer to one, so it stays incomplete */
typedef struct _IO_FILE FILE;
typedef long fpos_t[2];

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF		(-1)
#define BUFSIZ		8192
#define FILENAME_MAX	4096
#define FOPEN_MAX	16
#define L_tmpnam	20
#define TMP_MAX		238328
#define SEEK_SET	0
#define SEEK_CUR	1
#define SEEK_END	2
#define _IOFBF		0
#define _IOLBF		1
#define _IONBF		2

FILE *fopen(const char *path, const char *mode);
FILE *freopen(const char *path, const char *mode, FILE *f);
FILE *tmpfile(void);
int fclose(FILE *f);
int fflush(FILE *f);
int setvbuf(FILE *f, char *buf, int mode, size_t size);
void setbuf(FILE *f, char *buf);

int fprintf(FILE *f, const char *fmt, ...);
int printf(const char *fmt, ...);
int sprintf(char *s, const char *fmt, ...);
int snprintf(char *s, size_t n, const char *fmt, ...);
int vfprintf(FILE *f, const char *fmt, va_list ap);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);
int fscanf(FILE *f, const char *fmt, ...);
int sscanf(const char *s, const char *fmt, ...);

int fgetc(FILE *f);
int getc(FILE *f);
int getchar(void);
char *fgets(char *s, int n, FILE *f);
int ungetc(int c, FILE *f);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int putchar(int c);
int fputs(const char *s, FILE *f);
int puts(const char *s);

size_t fread(void *p, size_t size, size_t n, FILE *f);
size_t fwrite(const void *p, size_t size, size_t n, FILE *f);

int fseek(FILE *f, long off, int whence);
long ftell(FILE *f);
void rewind(FILE *f);
int fgetpos(FILE *f, fpos_t *pos);
int fsetpos(FILE *f, const fpos_t *pos);

void clearerr(FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
void perror(const char *s);

int remove(const char *path);
int rename(const char *from, const char *to);
char *tmpnam(char *s);

#endif
