/* SPDX-License-Identifier: ISC */
/*
 * A Lua module, to be built by this compiler and loaded by an interpreter
 * built by another one.  Everything the C API hands over crosses the ABI:
 * the state pointer, integers of every width, doubles in their own
 * registers, strings, variadic calls, and a callback that reenters Lua.
 */
#include <stddef.h>
#include <stdarg.h>

#include "lua.h"
#include "lauxlib.h"

/* doubles, which live in their own registers */
static int l_mix(lua_State *L)
{
	lua_Integer a = luaL_checkinteger(L, 1);
	lua_Number b = luaL_checknumber(L, 2);
	lua_Integer c = luaL_checkinteger(L, 3);
	lua_Number d = luaL_checknumber(L, 4);

	lua_pushnumber(L, (lua_Number)a * b + (lua_Number)c * d);
	lua_pushinteger(L, a * c);
	return 2;
}

/* eight arguments, so that the last of them arrive on the stack */
static double eight(double a, double b, double c, double d,
		    double e, double f, double g, double h)
{
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8;
}

static int l_eight(lua_State *L)
{
	int i;
	double v[8];

	for (i = 0; i < 8; i++)
		v[i] = (double)luaL_checknumber(L, i + 1);
	lua_pushnumber(L, eight(v[0], v[1], v[2], v[3],
				v[4], v[5], v[6], v[7]));
	return 1;
}

/* integers and floats interleaved, which fill two register files at once */
static double straddle(int a, double b, long c, double d, int e,
		       double f, long g)
{
	return (double)a + b + (double)c + d + (double)e + f + (double)g;
}

static int l_straddle(lua_State *L)
{
	lua_pushnumber(L, straddle((int)luaL_checkinteger(L, 1),
		luaL_checknumber(L, 2), (long)luaL_checkinteger(L, 3),
		luaL_checknumber(L, 4), (int)luaL_checkinteger(L, 5),
		luaL_checknumber(L, 6), (long)luaL_checkinteger(L, 7)));
	return 1;
}

/* a variadic call into the library, which reads the register save area */
static int l_format(lua_State *L)
{
	lua_pushfstring(L, "%s=%d/%f/%s", luaL_checkstring(L, 1),
		(int)luaL_checkinteger(L, 2), luaL_checknumber(L, 3),
		lua_typename(L, lua_type(L, 4)));
	return 1;
}

/* our own variadic function, which has to build the same save area */
static long long sumof(int n, ...)
{
	va_list ap;
	long long t = 0;
	int i;

	va_start(ap, n);
	for (i = 0; i < n; i++) {
		if (i % 2 == 0)
			t += va_arg(ap, long long);
		else
			t += (long long)va_arg(ap, double);
	}
	va_end(ap);
	return t;
}

static int l_sum(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)sumof(6,
		(long long)luaL_checkinteger(L, 1), luaL_checknumber(L, 2),
		(long long)luaL_checkinteger(L, 3), luaL_checknumber(L, 4),
		(long long)luaL_checkinteger(L, 5), luaL_checknumber(L, 6)));
	return 1;
}

/* strings, through a buffer the library writes into */
static int l_rot(lua_State *L)
{
	size_t n, i;
	const char *s = luaL_checklstring(L, 1, &n);
	luaL_Buffer b;
	char *p = luaL_buffinitsize(L, &b, n);

	for (i = 0; i < n; i++) {
		char c = s[i];

		if (c >= 'a' && c <= 'z')
			c = (char)('a' + (c - 'a' + 13) % 26);
		else if (c >= 'A' && c <= 'Z')
			c = (char)('A' + (c - 'A' + 13) % 26);
		p[i] = c;
	}
	luaL_pushresultsize(&b, n);
	return 1;
}

/* back into Lua, which is the interpreter calling us calling it */
static int l_apply(lua_State *L)
{
	int i;
	lua_Integer t = 0;

	luaL_checktype(L, 1, LUA_TFUNCTION);
	for (i = 1; i <= 5; i++) {
		lua_pushvalue(L, 1);
		lua_pushinteger(L, i);
		lua_call(L, 1, 1);
		t += luaL_checkinteger(L, -1);
		lua_pop(L, 1);
	}
	lua_pushinteger(L, t);
	return 1;
}

/* sixty-four bit arithmetic, which a thirty-two bit target lowers to calls */
static int l_wide(lua_State *L)
{
	long long a = (long long)luaL_checkinteger(L, 1);
	long long b = (long long)luaL_checkinteger(L, 2);

	lua_pushinteger(L, (lua_Integer)(a * b));
	lua_pushinteger(L, (lua_Integer)(a / (b == 0 ? 1 : b)));
	lua_pushinteger(L, (lua_Integer)(a % (b == 0 ? 1 : b)));
	lua_pushinteger(L, (lua_Integer)(a >> 3));
	return 4;
}

static const luaL_Reg funcs[] = {
	{"mix", l_mix},
	{"eight", l_eight},
	{"straddle", l_straddle},
	{"format", l_format},
	{"sum", l_sum},
	{"rot", l_rot},
	{"apply", l_apply},
	{"wide", l_wide},
	{NULL, NULL},
};

int luaopen_compmod(lua_State *L)
{
	luaL_newlib(L, funcs);
	return 1;
}
