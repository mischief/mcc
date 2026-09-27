-- SPDX-License-Identifier: ISC
-- A unix with a shell, and luaposix when it is there.
--
-- luaposix is a soft dependency on purpose.  This compiler builds the
-- whole of Lua for three architectures, so needing a compiled Lua
-- module before it can run would make its own bootstrap circular.
-- `lua5.4 drive.lua` on a box with nothing but stock Lua has to keep
-- working, and it does: every call here falls back to the shell.
--
-- What luaposix buys where it is present is not speed.  It is that
-- none of this has to be quoted, parsed back out of `ls`, or run at
-- all, so it works where /bin/sh does not exist.

local ok, posix = pcall(require, "posix")

if not ok then posix = nil end

local M = {}

local function lines(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	local out = {}

	if not p then return out end
	for l in p:lines() do out[#out + 1] = l end
	p:close()
	return out
end

-- Shell quoting, in the one place that needs it.  A word of ordinary
-- characters stands for itself; anything else goes in single quotes,
-- and a single quote inside is closed, escaped and reopened.
local function quote(s)
	if s:match("^[%w@%%_%-%+=:,./]+$") then return s end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.uname()
	if posix and posix.sys and posix.sys.utsname then
		local u = posix.sys.utsname.uname()

		if u then
			return {system = (u.sysname or ""):lower(),
				machine = u.machine}
		end
	end
	local s = lines("uname -s")[1]
	local m = lines("uname -m")[1]

	return {system = s and s:lower() or nil, machine = m}
end

function M.sharedlibs(dir, name)
	if posix and posix.glob then
		-- glob wants its flags; with no second argument it
		-- answers "integer expected, got no value".
		return posix.glob.glob(("%s/lib%s.so*"):format(dir, name),
			0) or {}
	end
	-- The star has to reach the shell unquoted, so the parts that
	-- came from outside are quoted and it is not.
	return lines(("ls -1 %s/lib%s.so*")
		:format(quote(dir), quote(name)))
end

-- The paths matching a shell pattern, and when each was last written.
-- Without luaposix this answers nothing, which callers treat as no
-- match.
function M.glob(pattern)
	if not (posix and posix.glob and posix.sys and posix.sys.stat) then
		return {}
	end
	local out = {}

	for _, p in ipairs(posix.glob.glob(pattern, 0) or {}) do
		local st = posix.sys.stat.stat(p)

		if st then out[#out + 1] = {path = p, mtime = st.st_mtime} end
	end
	return out
end

function M.executable(path)
	if posix and posix.sys and posix.sys.stat then
		local st = posix.sys.stat
		local mode = st.S_IRUSR | st.S_IWUSR | st.S_IXUSR |
			     st.S_IRGRP | st.S_IXGRP |
			     st.S_IROTH | st.S_IXOTH

		return st.chmod(path, mode) and true or nil
	end
	return os.execute("chmod +x " .. quote(path)) and true or nil
end

function M.exec(argv, opts)
	local words = {}

	for i = 1, #argv do words[i] = quote(argv[i]) end
	local line = table.concat(words, " ")

	if opts.verbose then io.stderr:write(line .. "\n") end
	if os.execute(line) then return true end
	return nil, line .. ": did not succeed"
end

function M.tmpname()
	if posix and posix.stdlib and posix.stdlib.mkstemp then
		local dir = os.getenv("TMPDIR") or "/tmp"
		local fd, path = posix.stdlib.mkstemp(dir .. "/mccXXXXXX")

		if fd then
			posix.unistd.close(fd)
			os.remove(path)
			return path
		end
	end
	-- os.tmpname makes the file as well as the name, and only the
	-- name is wanted.
	local t = os.tmpname()

	os.remove(t)
	return t
end

return M
