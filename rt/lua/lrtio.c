/* SPDX-License-Identifier: ISC */
/*
 * The io library, after liolib.c.  A file is a userdata holding a FILE;
 * when the last reference to one goes, so does the FILE, which is the
 * one place counting makes something more prompt than a collector.
 */
#define _POSIX_C_SOURCE 200809L
#include "lrtaux.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

typedef struct {
	FILE *f;
	int closed;
	int std;	/* stdin, stdout or stderr, never closed by the collector */
	int popen;
} LFile;

static lr_Table *filemt;
static TValue defin, defout;

static void lfree(void *p)
{
	LFile *lf = p;

	if (!lf->closed && !lf->std && lf->f) {
		if (lf->popen)
			pclose(lf->f);
		else
			fclose(lf->f);
	}
}

static TValue newfile(FILE *f, int std)
{
	lr_Udata *u = lr_newobj(offsetof(lr_Udata, data) + sizeof(LFile),
				LR_UDATA);
	LFile *lf = (LFile *)u->data;
	TValue v;

	u->mt = filemt;
	u->len = sizeof *lf;
	u->free = lfree;
	lf->f = f;
	lf->closed = 0;
	lf->std = std;
	lf->popen = 0;
	LR_SETOBJ(&v, u, LR_UDATA);
	return v;
}

static LFile *tofile(const TValue *v)
{
	if (v->tt != LR_UDATA || ((lr_Udata *)v->v.p)->mt != filemt)
		return NULL;
	return (LFile *)((lr_Udata *)v->v.p)->data;
}

static LFile *checkfile(lr_Closure *self, TValue *base, int nargs, int i)
{
	LFile *lf = i < nargs ? tofile(&base[i]) : NULL;

	if (!lf)
		lr_argexpected(self, base, nargs, i, "FILE*");
	if (lf->closed)
		lr_error("attempt to use a closed file");
	return lf;
}

/* nil, "name: message", errno, as liolib's luaL_fileresult */
static int fileresult(TValue *base, int nargs, int ok, const char *name)
{
	int en = errno;

	if (ok)
		return lr_retbool(base, nargs, 1);
	char msg[512];
	TValue v[3];

	if (name)
		snprintf(msg, sizeof msg, "%s: %s", name, strerror(en));
	else
		snprintf(msg, sizeof msg, "%s", strerror(en));
	LR_SETNIL(&v[0]);
	lr_setstr(&v[1], lr_cstr(msg));
	LR_SETINT(&v[2], en);
	return lr_return(base, nargs, v, 3);
}

/* reading ------------------------------------------------------------------- */

typedef struct {
	char *p;
	size_t n, cap;
} Buf;

static void badd(Buf *b, int c)
{
	if (b->n + 1 > b->cap) {
		b->cap = b->cap ? b->cap * 2 : 128;
		b->p = realloc(b->p, b->cap);
	}
	b->p[b->n++] = (char)c;
}

/* One value read by format fmt into *out: 0 when nothing could be. */
static int readline(FILE *f, int keep, TValue *out)
{
	Buf b = {0};
	int c = EOF;

	while ((c = getc(f)) != EOF && c != '\n')
		badd(&b, c);
	if (c == '\n' && keep)
		badd(&b, c);
	if (c == EOF && b.n == 0) {
		free(b.p);
		return 0;
	}
	lr_setstr(out, lr_newstr(b.p ? b.p : "", b.n));
	free(b.p);
	return 1;
}

static void readall(FILE *f, TValue *out)
{
	Buf b = {0};
	char chunk[4096];
	size_t n;

	while ((n = fread(chunk, 1, sizeof chunk, f)) > 0)
		for (size_t i = 0; i < n; i++)
			badd(&b, chunk[i]);
	lr_setstr(out, lr_newstr(b.p ? b.p : "", b.n));
	free(b.p);
}

static int readchars(FILE *f, size_t n, TValue *out)
{
	char *p = malloc(n ? n : 1);
	size_t got = fread(p, 1, n, f);

	if (got == 0 && n > 0) {
		free(p);
		return 0;
	}
	lr_setstr(out, lr_newstr(p, got));
	free(p);
	return 1;
}

/* A numeral, as liolib's read_number reads one: at most 200 chars. */
static int readnumber(FILE *f, TValue *out)
{
	char buf[201];
	int n = 0, c, hex = 0;

	do {
		c = getc(f);
	} while (c == ' ' || (c >= '\t' && c <= '\r'));
	if (c == '-' || c == '+') {
		buf[n++] = (char)c;
		c = getc(f);
	}
	if (c == '0') {
		buf[n++] = (char)c;
		c = getc(f);
		if (c == 'x' || c == 'X') {
			hex = 1;
			buf[n++] = (char)c;
			c = getc(f);
		}
	}
	for (;;) {
		int ok = hex ? strchr("0123456789abcdefABCDEF", c) != NULL
			     : c >= '0' && c <= '9';

		if (c == EOF || !(ok || c == '.' ||
				  (hex ? c == 'p' || c == 'P'
				       : c == 'e' || c == 'E') ||
				  ((c == '-' || c == '+') && n > 0 &&
				   strchr(hex ? "pP" : "eE", buf[n - 1]))))
			break;
		if (n >= 200)
			break;
		buf[n++] = (char)c;
		c = getc(f);
	}
	if (c != EOF)
		ungetc(c, f);
	buf[n] = 0;
	if (lr_str2num(buf, n, out))
		return 1;
	return 0;
}

/* f:read(...) or io.read(...): formats from base[first] on */
static int gread(lr_Closure *self, TValue *base, int nargs, FILE *f,
		 int first)
{
	TValue out[32];
	int n = 0, nf = nargs - first;

	clearerr(f);
	if (nf <= 0) {
		if (!readline(f, 0, &out[0]))
			LR_SETNIL(&out[0]);
		return lr_return(base, nargs, out, 1);
	}
	if (nf > 32)
		lr_error("too many arguments");
	for (int i = first; i < nargs; i++) {
		int ok;
		TValue *a = &base[i];

		if (a->tt == LR_INT || a->tt == LR_FLT) {
			lr_Int k = lr_checkint(self, base, nargs, i);

			if (k == 0) {
				int c = getc(f);

				ungetc(c, f);
				ok = c != EOF;
				if (ok)
					lr_setstr(&out[n], lr_newstr("", 0));
			} else {
				ok = readchars(f, (size_t)k, &out[n]);
			}
		} else if (a->tt == LR_STR) {
			const char *p = ((lr_Str *)a->v.p)->s;

			if (*p == '*')
				p++;
			switch (*p) {
			case 'n':
				ok = readnumber(f, &out[n]);
				break;
			case 'l':
				ok = readline(f, 0, &out[n]);
				break;
			case 'L':
				ok = readline(f, 1, &out[n]);
				break;
			case 'a':
				readall(f, &out[n]);
				ok = 1;
				break;
			default:
				lr_argerror(self, i, "invalid format");
			}
		} else {
			lr_argerror(self, i, "invalid format");
		}
		if (!ok) {
			LR_SETNIL(&out[n++]);
			break;
		}
		n++;
	}
	if (ferror(f))
		return fileresult(base, nargs, 0, NULL);
	return lr_return(base, nargs, out, n);
}

/* writing ------------------------------------------------------------------- */

static int gwrite(lr_Closure *self, TValue *base, int nargs, FILE *f,
		  int first, TValue *file)
{
	int ok = 1;

	for (int i = first; i < nargs; i++) {
		TValue *a = &base[i];

		if (a->tt == LR_INT) {
			ok = ok && fprintf(f, "%lld", a->v.i) > 0;
		} else if (a->tt == LR_FLT) {
			ok = ok && fprintf(f, "%.14g", a->v.n) > 0;
		} else if (a->tt == LR_STR) {
			lr_Str *s = a->v.p;

			ok = ok && fwrite(s->s, 1, s->len, f) == s->len;
		} else {
			lr_argexpected(self, base, nargs, i, "string");
		}
	}
	if (!ok)
		return fileresult(base, nargs, 0, NULL);
	TValue r = *file;

	lr_retain(&r);
	return lr_return(base, nargs, &r, 1);
}

/* the methods --------------------------------------------------------------- */

static int closefile(TValue *base, int nargs, LFile *lf)
{
	int ok;

	if (lf->std) {
		TValue v[2];

		LR_SETNIL(&v[0]);
		lr_setstr(&v[1], lr_cstr("cannot close standard file"));
		return lr_return(base, nargs, v, 2);
	}
	if (lf->popen) {
		int st = pclose(lf->f);

		lf->closed = 1;
		TValue v[3];

		LR_SETBOOL(&v[0], st == 0);
		lr_setstr(&v[1], lr_cstr("exit"));
		LR_SETINT(&v[2], WIFEXITED(st) ? WEXITSTATUS(st) : st);
		return lr_return(base, nargs, v, 3);
	}
	ok = fclose(lf->f) == 0;
	lf->closed = 1;
	return fileresult(base, nargs, ok, NULL);
}

BUILTIN(f_close)
{
	return closefile(base, nargs, checkfile(self, base, nargs, 0));
}

BUILTIN(f_flush)
{
	LFile *lf = checkfile(self, base, nargs, 0);

	return fileresult(base, nargs, fflush(lf->f) == 0, NULL);
}

BUILTIN(f_read)
{
	LFile *lf = checkfile(self, base, nargs, 0);

	return gread(self, base, nargs, lf->f, 1);
}

BUILTIN(f_write)
{
	LFile *lf = checkfile(self, base, nargs, 0);
	TValue file = base[0];

	return gwrite(self, base, nargs, lf->f, 1, &file);
}

BUILTIN(f_seek)
{
	static const char *const modes[] = {"set", "cur", "end"};
	static const int whence[] = {SEEK_SET, SEEK_CUR, SEEK_END};
	LFile *lf = checkfile(self, base, nargs, 0);
	int op = 1;

	if (nargs > 1 && base[1].tt != LR_NIL) {
		lr_Str *m = lr_checkstr(self, base, nargs, 1);

		op = -1;
		for (int i = 0; i < 3; i++)
			if (strcmp(m->s, modes[i]) == 0)
				op = i;
		if (op < 0)
			lr_argerror(self, 1, "invalid option");
	}
	lr_Int off = lr_optint(self, base, nargs, 2, 0);

	if (fseek(lf->f, (long)off, whence[op]) != 0)
		return fileresult(base, nargs, 0, NULL);
	return lr_retint(base, nargs, (lr_Int)ftell(lf->f));
}

BUILTIN(f_setvbuf)
{
	LFile *lf = checkfile(self, base, nargs, 0);
	lr_Str *m = lr_checkstr(self, base, nargs, 1);
	int mode = strcmp(m->s, "no") == 0 ? _IONBF :
		strcmp(m->s, "full") == 0 ? _IOFBF : _IOLBF;
	lr_Int sz = lr_optint(self, base, nargs, 2, BUFSIZ);

	return fileresult(base, nargs,
			  setvbuf(lf->f, NULL, mode, (size_t)sz) == 0, NULL);
}

BUILTIN(f_tostring)
{
	LFile *lf = tofile(LR_ARG(0));
	char buf[64];

	if (lf && lf->closed)
		snprintf(buf, sizeof buf, "file (closed)");
	else
		snprintf(buf, sizeof buf, "file (%p)", lf ? (void *)lf->f : NULL);
	return lr_retstr(base, nargs, lr_cstr(buf));
}

/* lines: an iterator holding the file and the formats in its boxes */
static lr_Box *box(TValue *v)
{
	lr_Box *b = lr_newobj(sizeof *b, LR_BOX);

	b->v = *v;
	return b;
}

BUILTIN(io_linesaux)
{
	TValue *file = &self->up[0]->v;
	LFile *lf = tofile(file);
	int toclose = self->up[1]->v.tt == LR_TRUE;
	TValue *fmts = &self->up[2]->v;
	lr_Table *ft = fmts->v.p;
	lr_Int nf = lr_rawlen(ft);

	if (lf->closed)
		lr_error("file is already closed");
	/* the formats go where the arguments were, after a dummy file */
	lr_clear(base, nargs);
	TValue *a = base;

	if (a + nf + 2 >= lr_stackend)
		lr_error("stack overflow");
	LR_SETNIL(&a[0]);
	for (lr_Int i = 1; i <= nf; i++)
		lr_move(&a[i], lr_rawgeti(ft, i));
	int n = gread(self, a, (int)nf + 1, lf->f, 1);

	if (n > 0 && base[0].tt != LR_NIL)
		return n;
	if (n > 1 && base[1].tt == LR_STR) {
		/* an error message */
		TValue e = base[1];

		lr_retain(&e);
		lr_errorv(&e);
	}
	if (toclose) {
		fclose(lf->f);
		lf->closed = 1;
	}
	return n;
}

static int makelines(lr_Closure *self, TValue *base, int nargs, int first,
		     TValue *file, int toclose)
{
	lr_Table *ft = lr_tnew(nargs > first ? nargs - first : 0, 0);
	TValue fv, cv, r, tc;

	(void)self;
	if (nargs - first > 250)
		lr_error("too many arguments");
	for (int i = first; i < nargs; i++)
		lr_rawseti(ft, i - first + 1, &base[i]);
	LR_SETOBJ(&fv, ft, LR_TAB);
	LR_SETBOOL(&tc, toclose);
	LR_SETNIL(&r);
	lr_Closure *c = lr_closure(&r, io_linesaux, 3, "lines");

	cv = *file;
	lr_retain(&cv);
	c->up[0] = box(&cv);
	c->up[1] = box(&tc);
	c->up[2] = box(&fv);
	TValue out[4];

	out[0] = r;
	LR_SETNIL(&out[1]);
	LR_SETNIL(&out[2]);
	out[3] = *file;
	lr_retain(&out[3]);
	if (!toclose) {
		lr_release(&out[3]);
		LR_SETNIL(&out[3]);
	}
	return lr_return(base, nargs, out, 4);
}

BUILTIN(f_lines)
{
	checkfile(self, base, nargs, 0);
	TValue file = base[0];

	return makelines(self, base, nargs, 1, &file, 0);
}

/* the library --------------------------------------------------------------- */

static int checkmode(const char *mode)
{
	if (*mode == 0 || !strchr("rwa", *mode++))
		return 0;
	if (*mode == '+')
		mode++;
	return strspn(mode, "b") == strlen(mode);
}

BUILTIN(io_open)
{
	lr_Str *name = lr_checkstr(self, base, nargs, 0);
	const char *mode = nargs > 1 && base[1].tt != LR_NIL ?
		lr_checkstr(self, base, nargs, 1)->s : "r";

	if (!checkmode(mode))
		lr_argerror(self, 1, "invalid mode");
	FILE *f = fopen(name->s, mode);

	if (!f)
		return fileresult(base, nargs, 0, name->s);
	TValue v = newfile(f, 0);

	return lr_return(base, nargs, &v, 1);
}

BUILTIN(io_popen)
{
	lr_Str *cmd = lr_checkstr(self, base, nargs, 0);
	const char *mode = nargs > 1 && base[1].tt != LR_NIL ?
		lr_checkstr(self, base, nargs, 1)->s : "r";

	fflush(NULL);
	FILE *f = popen(cmd->s, mode);

	if (!f)
		return fileresult(base, nargs, 0, cmd->s);
	TValue v = newfile(f, 0);

	((LFile *)((lr_Udata *)v.v.p)->data)->popen = 1;
	return lr_return(base, nargs, &v, 1);
}

BUILTIN(io_tmpfile)
{
	FILE *f = tmpfile();

	(void)self;
	if (!f)
		return fileresult(base, nargs, 0, NULL);
	TValue v = newfile(f, 0);

	return lr_return(base, nargs, &v, 1);
}

BUILTIN(io_type)
{
	lr_checkany(self, base, nargs, 0);
	LFile *lf = tofile(&base[0]);

	if (!lf)
		return lr_retnil(base, nargs);
	return lr_retstr(base, nargs, lr_cstr(lf->closed ? "closed file"
							 : "file"));
}

/* io.input and io.output: with a name, open it; with a file, take it */
static void gdefault(lr_Closure *self, TValue *base, int nargs,
		     TValue *def, const char *mode)
{
	TValue v;

	if (base[0].tt == LR_STR) {
		lr_Str *name = base[0].v.p;
		FILE *f = fopen(name->s, mode);

		if (!f)
			lr_error("cannot open file '%s' (%s)", name->s,
				 strerror(errno));
		v = newfile(f, 0);
	} else {
		checkfile(self, base, nargs, 0);
		v = base[0];
		lr_retain(&v);
	}
	lr_store(def, &v);
}

BUILTIN(io_input)
{
	if (nargs > 0 && base[0].tt != LR_NIL)
		gdefault(self, base, nargs, &defin, "r");
	TValue r = defin;

	lr_retain(&r);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(io_output)
{
	if (nargs > 0 && base[0].tt != LR_NIL)
		gdefault(self, base, nargs, &defout, "w");
	TValue r = defout;

	lr_retain(&r);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(io_read)
{
	LFile *lf = tofile(&defin);

	if (lf->closed)
		lr_error("default input file is closed");
	/* the default file goes ahead of the formats */
	return gread(self, base, nargs, lf->f, 0);
}

BUILTIN(io_write)
{
	LFile *lf = tofile(&defout);

	if (lf->closed)
		lr_error("default output file is closed");
	return gwrite(self, base, nargs, lf->f, 0, &defout);
}

BUILTIN(io_close)
{
	if (nargs == 0 || base[0].tt == LR_NIL) {
		LFile *lf = tofile(&defout);

		return closefile(base, nargs, lf);
	}
	return closefile(base, nargs, checkfile(self, base, nargs, 0));
}

BUILTIN(io_flush)
{
	(void)self;
	return fileresult(base, nargs, fflush(tofile(&defout)->f) == 0, NULL);
}

BUILTIN(io_lines)
{
	if (nargs == 0 || base[0].tt == LR_NIL) {
		TValue file = defin;

		if (tofile(&file)->closed)
			lr_error("default input file is closed");
		return makelines(self, base, nargs, 1, &file, 0);
	}
	lr_Str *name = lr_checkstr(self, base, nargs, 0);
	FILE *f = fopen(name->s, "r");

	if (!f)
		lr_error("%s: %s", name->s, strerror(errno));
	TValue file = newfile(f, 0);
	int n = makelines(self, base, nargs, 1, &file, 1);

	lr_release(&file);
	return n;
}

void lr_openio(lr_Table *g)
{
	lr_gcroot(&defin);
	lr_gcroot(&defout);
	lr_Table *io = lr_newlib(g, "io");
	lr_Table *idx = lr_tnew(0, 8);
	TValue v;

	filemt = lr_tnew(0, 4);
	lr_gcfix(filemt);
	lr_reg(idx, "close", f_close);
	lr_reg(idx, "flush", f_flush);
	lr_reg(idx, "lines", f_lines);
	lr_reg(idx, "read", f_read);
	lr_reg(idx, "seek", f_seek);
	lr_reg(idx, "setvbuf", f_setvbuf);
	lr_reg(idx, "write", f_write);
	LR_SETOBJ(&v, idx, LR_TAB);
	lr_rawsets(filemt, "__index", &v);
	lr_reg(filemt, "__tostring", f_tostring);
	lr_setstr(&v, lr_cstr("FILE*"));
	lr_rawsets(filemt, "__name", &v);
	lr_release(&v);

	lr_reg(io, "open", io_open);
	lr_reg(io, "popen", io_popen);
	lr_reg(io, "tmpfile", io_tmpfile);
	lr_reg(io, "type", io_type);
	lr_reg(io, "input", io_input);
	lr_reg(io, "output", io_output);
	lr_reg(io, "read", io_read);
	lr_reg(io, "write", io_write);
	lr_reg(io, "close", io_close);
	lr_reg(io, "flush", io_flush);
	lr_reg(io, "lines", io_lines);

	TValue in = newfile(stdin, 1), out = newfile(stdout, 1),
	       err = newfile(stderr, 1);

	lr_rawsets(io, "stdin", &in);
	lr_rawsets(io, "stdout", &out);
	lr_rawsets(io, "stderr", &err);
	defin = in;
	defout = out;
	lr_release(&err);
}
