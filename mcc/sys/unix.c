/* SPDX-License-Identifier: ISC */
/* The system calls the driver needs on a unix, as the mcc.sys.unix
   backend.  mcc builds this module itself, so the driver needs no
   third-party Lua module and no shell to ask the machine questions. */

#include <sys/stat.h>
#include <sys/utsname.h>

#include <ctype.h>
#include <errno.h>
#include <glob.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

int luaopen_mcc_sys_unix(lua_State *);

/* {system = lowercase sysname, machine = machine}. */
static int
l_uname(lua_State *L)
{
	struct utsname u;
	char *p;

	if (uname(&u) == -1)
		return luaL_error(L, "uname: %s", strerror(errno));
	for (p = u.sysname; *p; p++)
		*p = tolower((unsigned char)*p);
	lua_createtable(L, 0, 2);
	lua_pushstring(L, u.sysname);
	lua_setfield(L, -2, "system");
	lua_pushstring(L, u.machine);
	lua_setfield(L, -2, "machine");
	return 1;
}

/* Run glob(3) on a pattern and push the list of paths.  With withtime
   set, each entry is {path = p, mtime = t}, and a path that stat(2)
   cannot read is left out. */
static void
pushglob(lua_State *L, const char *pat, int withtime)
{
	glob_t g;
	struct stat st;
	size_t i;
	lua_Integer n = 0;

	lua_newtable(L);
	if (glob(pat, 0, NULL, &g) != 0)
		return;
	for (i = 0; i < g.gl_pathc; i++) {
		if (!withtime) {
			lua_pushstring(L, g.gl_pathv[i]);
			lua_rawseti(L, -2, ++n);
			continue;
		}
		if (stat(g.gl_pathv[i], &st) == -1)
			continue;
		lua_createtable(L, 0, 2);
		lua_pushstring(L, g.gl_pathv[i]);
		lua_setfield(L, -2, "path");
		lua_pushinteger(L, (lua_Integer)st.st_mtime);
		lua_setfield(L, -2, "mtime");
		lua_rawseti(L, -2, ++n);
	}
	globfree(&g);
}

/* Every path matching <dir>/lib<name>.so*. */
static int
l_sharedlibs(lua_State *L)
{
	const char *dir = luaL_checkstring(L, 1);
	const char *name = luaL_checkstring(L, 2);

	lua_pushfstring(L, "%s/lib%s.so*", dir, name);
	pushglob(L, lua_tostring(L, -1), 0);
	return 1;
}

static int
l_glob(lua_State *L)
{
	pushglob(L, luaL_checkstring(L, 1), 1);
	return 1;
}

/* Give a file mode 0755.  Returns true, or nil and the reason. */
static int
l_executable(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);

	if (chmod(path, 0755) == -1) {
		lua_pushnil(L);
		lua_pushfstring(L, "%s: %s", path, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* A fresh name under TMPDIR.  mkstemp(3) reserves it; the file is then
   removed, because the caller wants only the name. */
static int
l_tmpname(lua_State *L)
{
	const char *dir = getenv("TMPDIR");
	char *path;
	int fd;

	if (dir == NULL || *dir == '\0')
		dir = "/tmp";
	lua_pushfstring(L, "%s/mccXXXXXX", dir);
	path = strdup(lua_tostring(L, -1));
	if (path == NULL)
		return luaL_error(L, "tmpname: out of memory");
	fd = mkstemp(path);
	if (fd == -1) {
		free(path);
		return luaL_error(L, "mkstemp: %s", strerror(errno));
	}
	close(fd);
	unlink(path);
	lua_pushstring(L, path);
	free(path);
	return 1;
}

static const luaL_Reg funcs[] = {
	{"uname", l_uname},
	{"sharedlibs", l_sharedlibs},
	{"glob", l_glob},
	{"executable", l_executable},
	{"tmpname", l_tmpname},
	{NULL, NULL}
};

int
luaopen_mcc_sys_unix(lua_State *L)
{
	luaL_newlib(L, funcs);
	return 1;
}
