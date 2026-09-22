-- SPDX-License-Identifier: ISC
-- A Lua with no shell and no C extensions: lua-os, and anything else
-- where this compiler is the program rather than a program the system
-- runs.
--
-- Nothing here shells out, because there is nothing to shell out to.
-- Where a question has no answer on such a platform the answer is the
-- empty one and not a guess: there are no shared libraries, making a
-- file runnable means nothing, and another program cannot be run.

local M = {}

-- What to say this machine is.  There is no uname to ask, so the
-- environment says, and "none" -- a freestanding target -- is the
-- honest default.  `-target` on the command line overrides either way.
function M.uname()
	return {system = os.getenv("MCC_SYS_SYSTEM") or "none",
		machine = os.getenv("MCC_SYS_MACHINE")}
end

-- No shared libraries, so no paths to any.
function M.sharedlibs() return {} end

-- Nothing here reads a permission bit, so the file is as runnable as
-- it is going to get.  Saying so is not a lie: the caller asked for
-- the file to be runnable and it is.
function M.executable() return true end

function M.exec()
	return nil, "no way to run another program here"
end

-- No mkstemp and no atomic way to reserve a name, so the name is made
-- from the clock and a counter.  Two compilers running in the same
-- directory at the same instant could collide; one cannot.
local n = 0

function M.tmpname()
	local dir = os.getenv("TMPDIR") or "/tmp"

	n = n + 1
	return ("%s/mcc-%d-%d-%d"):format(dir, os.time(),
		math.floor(os.clock() * 1000000) % 1000000, n)
end

return M
