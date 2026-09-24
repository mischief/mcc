-- SPDX-License-Identifier: ISC
-- Every escape out of Lua, in one place.
--
-- The compiler itself is arithmetic over strings and tables and needs
-- nothing from the machine it runs on.  The driver does: it has to know
-- what it is running on, find the shared libraries a link would use,
-- make what it wrote runnable, and hand a file to another program.
-- Each of those is one call here, and each backend answers it the way
-- its platform can.
--
-- The names say what is wanted and not how to get it.  `sys.uname` and
-- `sys.sharedlibs` are questions with answers on any platform;
-- `sys.popen` would only move the shell behind a door that a platform
-- without one still cannot open.
--
-- A backend that cannot do something says so rather than pretending:
-- `sys.exec` answers nil and a reason where there is no way to run
-- another program, and the caller already has to handle a link that
-- did not work.
--
-- Which backend is used is settled by what this Lua can do, and
-- MCC_SYS overrides it: `posix` for a unix with a shell, `luaos` for a
-- Lua with no shell and no C extensions.  The override is for bringing
-- a platform up and for testing, and it is taken at its word: asking
-- for `luaos` on a unix writes a program that nothing chmods, because
-- that backend has no chmod to call.

local sys = {}

local NAME = os.getenv and os.getenv("MCC_SYS")

if not NAME then
	-- os.execute and not io.popen.  lua-os has io.popen, in
	-- lib/prog.lua, and it answers nil only when the proc has no
	-- namespace -- so a probe for it finds one and picks the shell
	-- backend on a machine with no shell.  os.execute is the one
	-- lua-os refuses outright.
	NAME = os.execute and "posix" or "luaos"
end

local backend = require("sys." .. NAME)

sys.backend = NAME

-- What the machine is called.  `system` is a name from the SYSTEM table
-- in the driver, lowercased; `machine` is nil where the backend cannot
-- say, and the caller keeps whatever it would have guessed.
function sys.uname() return backend.uname() end

-- Every path matching <dir>/lib<name>.so*, in no particular order.  An
-- empty list means there are none, which is the honest answer on a
-- platform with no shared libraries.
function sys.sharedlibs(dir, name) return backend.sharedlibs(dir, name) end

-- Make a file runnable.  True where that means something and where it
-- does not; nil and a reason only when it should have worked.
function sys.executable(path) return backend.executable(path) end

-- {path, mtime} for each path matching a shell pattern.
function sys.glob(pattern) return backend.glob(pattern) end

-- Run another program.  `argv` is a list of words, unquoted: whatever
-- quoting a shell needs belongs to the backend and not to the caller.
-- Returns true when the program succeeded, or nil and a reason.
function sys.exec(argv, opts) return backend.exec(argv, opts or {}) end

-- A name no other run of this program will pick.  The file is not made.
function sys.tmpname() return backend.tmpname() end

-- The rest exist in every Lua this compiler runs under, so they are
-- here to give one door rather than because they need a backend.  A
-- backend may still replace any of them.
sys.getenv = backend.getenv or os.getenv
sys.remove = backend.remove or os.remove
sys.exit = backend.exit or os.exit
sys.clock = backend.clock or os.clock
sys.date = backend.date or os.date

return sys
