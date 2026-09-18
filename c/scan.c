/*
 * The tokenizer's inner loop, as a Lua module.
 *
 * Nothing here decides anything: it finds where a token starts and ends,
 * counts the lines it crossed, and hands the pieces back.  Which names are
 * keywords, what a number is worth -- lex.lua keeps all of that, so the two
 * paths cannot drift apart on anything but where a token ends.
 *
 *	kind, text, pos, line, tokline, bol, ws, val =
 *		scan.next(s, pos, line, pp)
 *
 * `pos` and `line` are where to start and come back as where to carry on.
 * `bol` is true when the token is the first on its line and `ws` when
 * anything was skipped before it, which is what a directive is recognised
 * by.  A caller that has no module at all gets the same answers from the
 * Lua in lex.lua.
 */
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#define BS  '\\'
#define NL  '\n'

struct scan {
	const char *s;
	size_t n, p;		/* the text, its length, where we are */
	long line;
	int bol, ws;
};

static int at(struct scan *k, size_t off)
{
	size_t p = k->p + off;

	return p < k->n ? (unsigned char)k->s[p] : -1;
}

/* a backslash before a newline joins the two lines, everywhere */
static void splice(struct scan *k)
{
	while (k->p + 1 < k->n && k->s[k->p] == BS && k->s[k->p + 1] == NL) {
		k->line++;
		k->p += 2;
	}
}

static int cur(struct scan *k)
{
	splice(k);
	return at(k, 0);
}

static void step(struct scan *k)
{
	if (k->p < k->n && k->s[k->p] == NL) {
		k->line++;
		k->bol = 1;
	}
	k->p++;
	splice(k);
}

static int alpha(int c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static int digit(int c) { return c >= '0' && c <= '9'; }
static int alnum(int c) { return alpha(c) || digit(c); }

static void skip(struct scan *k)
{
	for (;;) {
		int c = at(k, 0);

		if (c < 0)
			return;
		if (c == ' ' || c == '\t' || c == '\r' ||
		    c == '\f' || c == '\v') {
			k->p++;
			k->ws = 1;
		} else if (c == NL) {
			k->p++;
			k->line++;
			k->bol = 1;
			k->ws = 1;
		} else if (c == BS && at(k, 1) == NL) {
			k->p += 2;
			k->line++;
		} else if (c == '/' && at(k, 1) == '*') {
			k->p += 2;
			while (k->p < k->n &&
			    !(k->s[k->p] == '*' && at(k, 1) == '/')) {
				if (k->s[k->p] == NL)
					k->line++;
				k->p++;
			}
			if (k->p >= k->n)
				return;		/* lex.lua says the words */
			k->p += 2;
			k->ws = 1;
		} else if (c == '/' && at(k, 1) == '/') {
			while (k->p < k->n && k->s[k->p] != NL) {
				if (k->s[k->p] == BS && at(k, 1) == NL)
					k->line++;
				k->p++;
			}
			k->ws = 1;
		} else {
			return;
		}
	}
}

/*
 * The operators, longest first: every proper prefix of one is itself one,
 * so the longest that matches is the answer.
 */
static const char *const PUNCT[] = {
	"<<=", ">>=", "...",
	"##", "->", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>",
	"+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--",
	"#", "(", ")", "{", "}", "[", "]", ";", ",", "=", "+", "-", "*",
	"/", "%", "&", "|", "^", "~", "!", "<", ">", "?", ":", ".",
	0
};

/* a literal, with the escapes worked out */
static int literal(lua_State *L, struct scan *k, int quote)
{
	luaL_Buffer b;

	luaL_buffinit(L, &b);
	step(k);
	for (;;) {
		int c = cur(k);

		if (c < 0 || c == quote)
			break;
		if (c != BS) {
			luaL_addchar(&b, (char)c);
			step(k);
			continue;
		}
		step(k);
		c = cur(k);
		if (c >= '0' && c <= '7') {
			int v = 0, n = 0;

			while (n < 3 && (c = cur(k)) >= '0' && c <= '7') {
				v = v * 8 + (c - '0');
				n++;
				step(k);
			}
			luaL_addchar(&b, (char)(v & 255));
		} else if (c == 'x') {
			int v = 0;

			step(k);
			for (;;) {
				c = cur(k);
				if (digit(c))
					v = v * 16 + (c - '0');
				else if (c >= 'a' && c <= 'f')
					v = v * 16 + (c - 'a' + 10);
				else if (c >= 'A' && c <= 'F')
					v = v * 16 + (c - 'A' + 10);
				else
					break;
				v &= 255;
				step(k);
			}
			luaL_addchar(&b, (char)v);
		} else {
			static const char from[] = "abfnrtve\\'\"?";
			static const char to[] = "\a\b\f\n\r\t\v\33\\'\"?";
			const char *p = c < 0 ? 0 : strchr(from, c);

			luaL_addchar(&b, p && *p ? to[p - from] : (char)c);
			step(k);
		}
	}
	if (cur(k) < 0)
		return 0;
	step(k);
	luaL_pushresult(&b);
	return 1;
}

static int l_next(lua_State *L)
{
	struct scan k;
	size_t n;
	long tokline;
	int c;

	k.s = luaL_checklstring(L, 1, &n);
	k.n = n;
	k.p = (size_t)luaL_checkinteger(L, 2) - 1;
	k.line = (long)luaL_checkinteger(L, 3);
	k.bol = lua_toboolean(L, 5);
	k.ws = lua_toboolean(L, 6);

	skip(&k);
	tokline = k.line;
	c = at(&k, 0);
	if (c < 0) {
		lua_pushliteral(L, "eof");
		lua_pushnil(L);
	} else if (alpha(c)) {
		size_t from = k.p;

		while (k.p < k.n && alnum((unsigned char)k.s[k.p]))
			k.p++;
		if (at(&k, 0) == BS && at(&k, 1) == NL) {
			/* a name cut in half by a splice: the slow way */
			luaL_Buffer b;

			luaL_buffinit(L, &b);
			luaL_addlstring(&b, k.s + from, k.p - from);
			while ((c = cur(&k)) >= 0 && alnum(c)) {
				luaL_addchar(&b, (char)c);
				step(&k);
			}
			/* the buffer keeps its own slot, so the kind goes
			 * on after it and the two are swapped */
			luaL_pushresult(&b);
			lua_pushliteral(L, "name");
			lua_insert(L, -2);
		} else {
			lua_pushliteral(L, "name");
			lua_pushlstring(L, k.s + from, k.p - from);
		}
	} else if (digit(c) || (c == '.' && digit(at(&k, 1)))) {
		luaL_Buffer b;

		luaL_buffinit(L, &b);
		for (;;) {
			c = cur(&k);
			if (c < 0 || !(alnum(c) || c == '.'))
				break;
			luaL_addchar(&b, (char)c);
			step(&k);
			if ((c == 'e' || c == 'E' || c == 'p' || c == 'P')) {
				int s = cur(&k);

				if (s == '+' || s == '-') {
					luaL_addchar(&b, (char)s);
					step(&k);
				}
			}
		}
		luaL_pushresult(&b);
		lua_pushliteral(L, "num");
		lua_insert(L, -2);
	} else if (c == '\'' || c == '"') {
		int quote = c;

		if (!literal(L, &k, quote)) {
			lua_pushliteral(L, "bad");
			lua_pushnil(L);
		} else if (quote == '\'') {
			size_t len;
			const char *text = lua_tolstring(L, -1, &len);
			int first = len ? (unsigned char)text[0] : 0;

			lua_pop(L, 1);
			lua_pushliteral(L, "chr");
			lua_pushinteger(L, first);
		} else {
			lua_pushliteral(L, "str");
			lua_insert(L, -2);
		}
	} else {
		const char *const *p;
		char want[4];
		int i;

		for (i = 0; i < 3; i++) {
			int b = at(&k, (size_t)i);

			want[i] = b < 0 ? 0 : (char)b;
		}
		want[3] = 0;
		for (p = PUNCT; *p; p++) {
			size_t len = strlen(*p);

			if (strncmp(want, *p, len) == 0) {
				k.p += len;
				break;
			}
		}
		if (!*p) {
			lua_pushliteral(L, "bad");
			lua_pushnil(L);
		} else {
			lua_pushstring(L, *p);
			lua_pushnil(L);
		}
	}
	lua_pushinteger(L, (lua_Integer)k.p + 1);
	lua_pushinteger(L, k.line);
	lua_pushinteger(L, tokline);
	lua_pushboolean(L, k.bol);
	lua_pushboolean(L, k.ws);
	return 7;
}

/*
 * The same scan, filling the token in place: the tokenizer keeps two token
 * tables in rotation and hands one over, so a whole token costs one call
 * and no allocation but its text.
 *
 *	class = scan.fill(lexer, token, keywords or false)
 *
 * class is 0 when the token is finished, 1 when it is a number whose value
 * the caller must work out, and 2 when nothing here is a token at all.
 */
static int l_fill(lua_State *L)
{
	struct scan k;
	size_t n;
	long tokline;
	int c, class = 0;

	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, 2, LUA_TTABLE);
	lua_getfield(L, 1, "s");
	k.s = luaL_checklstring(L, -1, &n);
	k.n = n;
	lua_getfield(L, 1, "p");
	k.p = (size_t)lua_tointeger(L, -1) - 1;
	lua_getfield(L, 1, "line");
	k.line = (long)lua_tointeger(L, -1);
	lua_getfield(L, 1, "bol");
	k.bol = lua_toboolean(L, -1);
	lua_getfield(L, 1, "sawws");
	k.ws = lua_toboolean(L, -1);
	lua_pop(L, 4);				/* the string stays */

	skip(&k);
	tokline = k.line;
	c = at(&k, 0);
	lua_pushnil(L);				/* text */
	lua_pushnil(L);				/* val */
	if (c < 0) {
		lua_pushliteral(L, "eof");
	} else if (alpha(c)) {
		size_t from = k.p;

		while (k.p < k.n && alnum((unsigned char)k.s[k.p]))
			k.p++;
		if (at(&k, 0) == BS && at(&k, 1) == NL) {
			luaL_Buffer b;

			luaL_buffinit(L, &b);
			luaL_addlstring(&b, k.s + from, k.p - from);
			while ((c = cur(&k)) >= 0 && alnum(c)) {
				luaL_addchar(&b, (char)c);
				step(&k);
			}
			luaL_pushresult(&b);
		} else {
			lua_pushlstring(L, k.s + from, k.p - from);
		}
		lua_replace(L, -3);		/* text */
		/* a keyword only outside the preprocessor */
		if (lua_istable(L, 3)) {
			lua_pushvalue(L, -2);
			lua_gettable(L, 3);
			if (lua_toboolean(L, -1)) {
				lua_pop(L, 1);
				lua_pushvalue(L, -2);
				goto done;
			}
			lua_pop(L, 1);
		}
		lua_pushliteral(L, "name");
	} else if (digit(c) || (c == '.' && digit(at(&k, 1)))) {
		luaL_Buffer b;

		luaL_buffinit(L, &b);
		for (;;) {
			c = cur(&k);
			if (c < 0 || !(alnum(c) || c == '.'))
				break;
			luaL_addchar(&b, (char)c);
			step(&k);
			if (c == 'e' || c == 'E' || c == 'p' || c == 'P') {
				int sign = cur(&k);

				if (sign == '+' || sign == '-') {
					luaL_addchar(&b, (char)sign);
					step(&k);
				}
			}
		}
		luaL_pushresult(&b);
		lua_replace(L, -3);
		lua_pushliteral(L, "num");
		class = 1;
	} else if (c == '\'' || c == '"') {
		int quote = c;

		if (!literal(L, &k, quote)) {
			lua_pushliteral(L, "bad");
			class = 2;
		} else if (quote == '\'') {
			size_t len;
			const char *text = lua_tolstring(L, -1, &len);

			lua_pushinteger(L, len ? (unsigned char)text[0] : 0);
			lua_replace(L, -3);	/* val */
			lua_pop(L, 1);
			lua_pushliteral(L, "num");
		} else {
			lua_replace(L, -3);	/* text */
			lua_pushliteral(L, "str");
		}
	} else {
		const char *const *p;
		char want[4];
		int i;

		for (i = 0; i < 3; i++) {
			int b = at(&k, (size_t)i);

			want[i] = b < 0 ? 0 : (char)b;
		}
		want[3] = 0;
		for (p = PUNCT; *p; p++) {
			size_t len = strlen(*p);

			if (strncmp(want, *p, len) == 0) {
				k.p += len;
				break;
			}
		}
		if (*p) {
			lua_pushstring(L, *p);
		} else {
			lua_pushliteral(L, "bad");
			class = 2;
		}
	}
done:
	lua_setfield(L, 2, "kind");
	lua_setfield(L, 2, "val");
	lua_setfield(L, 2, "text");
	lua_pushinteger(L, tokline);
	lua_setfield(L, 2, "line");
	lua_pushboolean(L, k.bol);
	lua_setfield(L, 2, "bol");
	lua_pushboolean(L, k.ws);
	lua_setfield(L, 2, "ws");

	lua_pushinteger(L, (lua_Integer)k.p + 1);
	lua_setfield(L, 1, "p");
	lua_pushinteger(L, k.line);
	lua_setfield(L, 1, "line");
	lua_pushboolean(L, 0);
	lua_setfield(L, 1, "bol");
	lua_pushboolean(L, 0);
	lua_setfield(L, 1, "sawws");

	lua_pushinteger(L, class);
	return 1;
}

static const luaL_Reg funcs[] = {
	{"fill", l_fill},
	{"next", l_next},
	{NULL, NULL},
};

int luaopen_scan(lua_State *L)
{
	luaL_newlib(L, funcs);
	return 1;
}
