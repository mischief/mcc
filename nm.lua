-- SPDX-License-Identifier: ISC
-- mnm: the symbols in an object, the way nm prints them.
--
--	mnm [-n] [-u] [-g] [-D] [-S] [--defined-only] file ...
--
-- The letter says where the symbol lives, and a lower case one is a
-- symbol only this file can see.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local elfread = require "elfread"
local ar = require "ar"
local sys = require "sys"

local prog = sys.getenv("MCC_PROG") or "mnm"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

-- Whether any file could not be read, which is what the exit status
-- says once every other file has been printed.
local bad = false
local o = {sort = "name"}
local files = {}
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-n" or a == "--numeric-sort" then
		o.sort = "addr"
	elseif a == "-p" or a == "--no-sort" then
		o.sort = "none"
	elseif a == "-u" or a == "--undefined-only" then
		o.undef = true
	elseif a == "-g" or a == "--extern-only" then
		o.global = true
	elseif a == "-D" or a == "--dynamic" then
		o.which = ".dynsym"
	elseif a == "-S" or a == "--print-size" then
		o.size = true
	elseif a == "--defined-only" then
		o.defined = true
	elseif a == "-r" or a == "--reverse-sort" then
		o.reverse = true
	elseif a == "-A" or a == "-o" or a == "--print-file-name" then
		o.withname = true
	elseif a:sub(1, 1) == "-" and #a > 1 then
		-- The letters nm takes together, as in `nm -ng`.
		if a:sub(2, 2) == "-" then die("unknown option " .. a) end
		for c in a:sub(2):gmatch(".") do
			if c == "n" then o.sort = "addr"
			elseif c == "p" then o.sort = "none"
			elseif c == "u" then o.undef = true
			elseif c == "g" then o.global = true
			elseif c == "D" then o.which = ".dynsym"
			elseif c == "S" then o.size = true
			elseif c == "r" then o.reverse = true
			elseif c == "A" or c == "o" then
				-- -o is -A, as lorder asks for it
				o.withname = true
			else die("unknown option -" .. c)
			end
		end
	else
		files[#files + 1] = a
	end
	i = i + 1
end

if #files == 0 then files[1] = "a.out" end

local SHF = elfread.SHF

-- Which letter a symbol answers to.  The kind comes first, because a
-- name that stands for nothing has no section to ask.
local function letter(s)
	local c

	if s.undef then
		c = s.bind == "weak" and (s.typ == "object" and "v" or "w")
			or "U"
		return c
	end
	if s.common then return "C" end
	-- A name the loader resolves by calling code, which is neither
	-- where it stands nor what it says.
	if s.typ == "ifunc" then return "i" end
	if s.abs then c = "A"
	elseif not s.sec then c = "?"
	else
		local f = s.sec.flags

		if f & SHF.alloc == 0 then
			-- Not mapped at all: a note or a comment is a
			-- debugging symbol, and anything else is a
			-- section nm has no letter for.
			c = f & SHF.write == 0 and "N" or "?"
		elseif s.sec.typ == "nobits" then c = "B"
		elseif f & SHF.exec ~= 0 then c = "T"
		elseif f & SHF.write ~= 0 then c = "D"
		else c = "R"
		end
	end
	-- A weak definition says so instead of saying where it is.
	if s.bind == "weak" then
		c = s.typ == "object" and "V" or "W"
	elseif s.bind == "local" then
		c = c:lower()
	end
	return c
end

local function wanted(s)
	if s.name == "" then return false end
	if s.typ == "file" or s.typ == "section" then return false end
	if o.undef and not s.undef then return false end
	if o.defined and s.undef then return false end
	if o.global and s.bind == "local" then return false end
	return true
end

-- One object: the file itself, or a member of an archive at an offset
-- inside it.  `prefix` is what -A puts in front of every line.
local function dump(path, at0, prefix)
	local f, err = elfread.open(path, at0)

	if not f then
		io.stderr:write(prog .. ": " .. err .. "\n")
		bad = true
		return
	end
	local syms = {}

	for _, s in ipairs(f:syms(o.which)) do
		if wanted(s) then syms[#syms + 1] = s end
	end
	if o.sort == "name" then
		table.sort(syms, function(a, b)
			if a.name ~= b.name then return a.name < b.name end
			return a.value < b.value
		end)
	elseif o.sort == "addr" then
		-- Two names at one address keep the order the table
		-- gave them, which is what a stable sort by address is.
		table.sort(syms, function(a, b)
			if a.undef ~= b.undef then return a.undef end
			if a.value ~= b.value then return a.value < b.value end
			return a.num < b.num
		end)
	end
	if o.reverse then
		for x = 1, #syms // 2 do
			syms[x], syms[#syms - x + 1] =
				syms[#syms - x + 1], syms[x]
		end
	end
	local w = f.class == 64 and 16 or 8

	for _, s in ipairs(syms) do
		local addr = s.undef and (" "):rep(w) or
			("%0" .. w .. "x"):format(s.value)
		local size = o.size and s.size > 0 and
			(" " .. ("%0" .. w .. "x"):format(s.size)) or ""

		local name = o.which == ".dynsym" and f:fullname(s) or
			s.name

		io.write(o.withname and prefix or "",
			addr, size, " ", letter(s), " ", name, "\n")
	end
	f:close()
end

for _, path in ipairs(files) do
	-- An archive is read a member at a time, the way nm reads one:
	-- the name of each member first, then its symbols.
	local members = ar.members(path)

	if members then
		for _, m in ipairs(members) do
			if not o.withname then
				io.write("\n", m.name, ":\n")
			end
			dump(m.file, m.off, path .. ":" .. m.name .. ":")
		end
	else
		dump(path, 0, path .. ":")
	end
end
if bad then sys.exit(1) end
