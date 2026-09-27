-- SPDX-License-Identifier: ISC
-- mstrip: take sections and symbols out of an ELF file.
--	mstrip [-g|-S] [-s] [--strip-unneeded] [-R name] [-o out] file ...
-- What is loaded stays where it is.  The kept sections that are not
-- loaded follow it, then the names and the headers, and every index to
-- a section or a symbol is renumbered to match.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local sys = require "mcc.sys"

local prog = sys.getenv("MCC_PROG") or "mstrip"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

local debug_, all, unneeded, out = false, false, false, nil
local remove, files = {}, {}
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-g" or a == "-S" or a == "-d" or a == "--strip-debug" then
		debug_ = true
	elseif a == "-s" or a == "--strip-all" then
		all = true
	elseif a == "--strip-unneeded" then
		unneeded = true
	elseif a == "-R" or a == "--remove-section" then
		i = i + 1
		remove[#remove + 1] = arg[i] or die(a .. " wants a name")
	elseif a:match("^%-%-remove%-section=") then
		remove[#remove + 1] = a:match("=(.*)$")
	elseif a:match("^%-R.") then
		remove[#remove + 1] = a:sub(3)
	elseif a == "-o" then
		i = i + 1
		out = arg[i] or die("-o wants a file")
	elseif a:match("^%-o.") then
		out = a:sub(3)
	elseif a == "-p" or a == "--preserve-dates" or a == "-D" or
	       a == "--enable-deterministic-archives" or a == "-x" or
	       a == "--discard-all" or a == "-X" or a == "--discard-locals" then
		-- nothing here keeps dates or local labels apart
	elseif a:sub(1, 1) == "-" then
		die("unknown option " .. a)
	else
		files[#files + 1] = a
	end
	i = i + 1
end
if #files == 0 then die("no input files") end
if out and #files > 1 then die("-o takes one input") end
if not (debug_ or unneeded or #remove > 0) then all = true end

local elfstrip = require "mcc.elfstrip"

for _, path in ipairs(files) do
	local ok, err = pcall(elfstrip.strip, path, out or path,
		{debug = debug_, all = all, unneeded = unneeded,
		 remove = remove})

	if not ok then die(tostring(err)) end
end
