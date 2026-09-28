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
-- Which backend is used is settled by what this Lua can load, and
-- MCC_SYS overrides it: `unix` is the C module mcc builds and installs
-- beside the driver, `luaos` a Lua with no C extensions.  The override
-- is taken at its word.  A build of the unix module itself runs before
-- the module exists, so it names luaos and says the system through
-- MCC_SYS_SYSTEM and MCC_SYS_MACHINE.

local sys = {}

local NAME = os.getenv and os.getenv("MCC_SYS")
local backend

if NAME then
	backend = require("mcc.sys." .. NAME)
else
	local ok, m = pcall(require, "mcc.sys.unix")

	if ok then
		NAME, backend = "unix", m
	else
		NAME, backend = "luaos", require("mcc.sys.luaos")
	end
end

sys.backend = NAME

-- Shell quoting for exec.  A word of ordinary characters stands for
-- itself; anything else goes in single quotes, and a single quote
-- inside is closed, escaped and reopened.
local function quote(s)
	if s:match("^[%w@%%_%-%+=:,./]+$") then return s end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The default exec: os.execute where this Lua has it.
local function shellexec(argv, opts)
	local words = {}

	if not os.execute then
		return nil, "no way to run another program here"
	end
	for i = 1, #argv do words[i] = quote(argv[i]) end
	local line = table.concat(words, " ")

	if opts.verbose then io.stderr:write(line .. "\n") end
	if os.execute(line) then return true end
	return nil, line .. ": did not succeed"
end

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
function sys.exec(argv, opts)
	return (backend.exec or shellexec)(argv, opts or {})
end

-- The words that start this program again, to which its own arguments
-- are added, or nil where exec cannot start it.  The default is the Lua
-- that runs this script, with its options, on the same script.
local function shellself()
	if not (os.execute and arg and arg[-1]) then return nil end
	local k = -1

	while arg[k - 1] do k = k - 1 end
	return table.move(arg, k, 0, 1, {})
end

function sys.self() return (backend.self or shellself)() end

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
