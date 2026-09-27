-- SPDX-License-Identifier: ISC
-- mnm: the symbols in an object, the way nm prints them.
--
--	mnm [-n|-v|-p|-r] [-u|-g|--defined-only] [-D] [-S] [-A|-o]
--	    [-P|-B|--format=posix|bsd] [-t d|o|x] file ...
--
-- The letter says where the symbol lives, and a lower case one is a
-- symbol only this file can see.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local elfread = require "mcc.elfread"
local ar = require "mcc.ar"
local sys = require "mcc.sys"

local prog = sys.getenv("MCC_PROG") or "mnm"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

-- Whether any file could not be read, which is what the exit status
-- says once every other file has been printed.
local bad = false
local o = {sort = "name", radix = 16}
local files = {}
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-n" or a == "-v" or a == "--numeric-sort" then
		o.sort = "addr"
	elseif a == "-P" or a == "--portability" or a == "--format=posix" then
		o.posix = true
	elseif a == "-B" or a == "--format=bsd" then
		o.posix = false
	elseif a == "-t" or a:match("^%-%-radix=") or a:match("^%-t.") then
		local r = a:match("=(.*)$") or (a == "-t" and arg[i + 1]) or
			a:sub(3)

		if a == "-t" then i = i + 1 end
		o.radix = ({d = 10, o = 8, x = 16})[r or ""] or
			die("invalid radix " .. tostring(r))
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
			if c == "n" or c == "v" then o.sort = "addr"
			elseif c == "P" then o.posix = true
			elseif c == "B" then o.posix = false
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
local function dump(path, at0, prefix, bare, header)
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
	-- GNU nm sorts with a stable sort, so a tie keeps the order of the
	-- table.  By address, what is undefined comes first, and names
	-- break a tie of address.  Names compare as bytes, which is what
	-- the C locale a kernel build runs in gives.
	for k, s in ipairs(syms) do s.seq = k end
	local function byname(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.seq < b.seq
	end
	if o.sort == "name" then
		table.sort(syms, byname)
	elseif o.sort == "addr" then
		table.sort(syms, function(a, b)
			if a.undef ~= b.undef then return a.undef end
			-- unsigned: a kernel lives at the top of the space
			if not a.undef and a.value ~= b.value then
				return math.ult(a.value, b.value)
			end
			return byname(a, b)
		end)
	end
	if o.reverse then
		for x = 1, #syms // 2 do
			syms[x], syms[#syms - x + 1] =
				syms[#syms - x + 1], syms[x]
		end
	end
	local w = f.class == 64 and 16 or 8
	local R = ({[8] = "o", [10] = "d", [16] = "x"})[o.radix]

	if #syms == 0 and #f:syms(o.which) == 0 then
		io.stderr:write(prog .. ": " .. (bare or path) ..
			": no symbols\n")
	end
	if o.posix and header then io.write(header, ":\n") end
	for _, s in ipairs(syms) do
		local name = o.which == ".dynsym" and f:fullname(s) or
			s.name

		if o.posix then
			-- name, letter, value and size, each as short as
			-- it goes; nothing where a name has no value
			local v = s.undef and (" "):rep(8) or
				("%" .. R .. " %s"):format(s.value, s.size > 0
					and ("%" .. R):format(s.size) or "")

			io.write(o.withname and prefix .. " " or "", name, " ",
				letter(s), " ", v, "\n")
		else
			local addr = s.undef and (" "):rep(w) or
				("%0" .. w .. R):format(s.value)
			local size = o.size and s.size > 0 and
				(" " .. ("%0" .. w .. R):format(s.size)) or ""

			io.write(o.withname and prefix or "",
				addr, size, " ", letter(s), " ", name, "\n")
		end
	end
	f:close()
end

-- The name of each file goes before its symbols when there is more
-- than one, and before each member of an archive; -A puts it on every
-- line instead.  The POSIX form names a member as archive[member].
local many = #files > 1

for _, path in ipairs(files) do
	-- An archive is read a member at a time, the way nm reads one:
	-- the name of each member first, then its symbols.
	local members = ar.members(path)

	if members then
		if many and not o.withname and not o.posix then
			io.write("\n", path, ":\n")
		end
		for _, m in ipairs(members) do
			local full = path .. "[" .. m.name .. "]"

			if not o.withname and not o.posix then
				io.write("\n", m.name, ":\n")
			end
			dump(m.file, m.off, o.posix and full .. ":" or
				path .. ":" .. m.name .. ":", full,
				not o.withname and o.posix and full or nil)
		end
	else
		if many and not o.withname and not o.posix then
			io.write("\n", path, ":\n")
		end
		dump(path, 0, path .. ":", path,
			many and not o.withname and o.posix and path or nil)
	end
end
if bad then sys.exit(1) end
