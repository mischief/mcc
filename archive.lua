-- SPDX-License-Identifier: ISC
-- mar: collect objects into an archive, the way ar does.
--
--	mar [crsuvD...] archive.a object.o ...
--	mar t archive.a
--	mar x archive.a
--
-- The option letters are ar's.  Only what changes the answer is acted
-- on; the rest -- the ones about timestamps, indices and verbosity --
-- are read and ignored, because this writes the same archive either way.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local ar = require "ar"
local sys = require "sys"

local prog = sys.getenv("MCC_PROG") or "mar"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

local mode, out, files = nil, nil, {}
local i = 1

while i <= #arg do
	local a = arg[i]

	if not out and not mode and a:sub(1, 1) ~= "-" and
	   not a:match("%.a$") and not a:match("%.o$") then
		-- the option letters, which ar takes without a dash
		for c in a:gmatch(".") do
			if c == "t" or c == "x" or c == "d" then mode = c end
		end
	elseif a:sub(1, 1) == "-" and #a > 1 and not a:match("%.o$") then
		for c in a:sub(2):gmatch(".") do
			if c == "t" or c == "x" or c == "d" then mode = c end
		end
	elseif not out then
		out = a
	else
		files[#files + 1] = a
	end
	i = i + 1
end

if not out then die("no archive named") end

if mode == "t" then
	for _, m in ipairs(ar.members(out) or die(out .. " is not an archive"))
	do
		print(m.name)
	end
	sys.exit(0)
end

if mode == "x" then
	local ms = ar.members(out) or die(out .. " is not an archive")
	local f = assert(io.open(out, "rb"))

	for _, m in ipairs(ms) do
		f:seek("set", m.off)
		local w = assert(io.open(m.name, "wb"))

		w:write(f:read(m.size))
		w:close()
	end
	f:close()
	sys.exit(0)
end

if mode == "d" then die("deleting from an archive is not supported") end
-- An archive with nothing in it is a real archive: musl makes one for
-- each library that is really part of libc, and a build that links
-- against it has to find a file there.  ar writes the magic line alone.
if #files == 0 then
	local f = assert(io.open(out, "wb"))

	f:write("!<arch>\n")
	f:close()
	sys.exit(0)
end
ar.write(out, files)
