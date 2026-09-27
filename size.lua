-- SPDX-License-Identifier: ISC
-- msize: the sizes of the sections in an ELF file, the way GNU size
-- prints them.
--
--	msize [-A|-B|--format=sysv|berkeley] [-d|-o|-x|--radix=N] [-t] file ...
--
-- Berkeley: one line per file, and one per member of an archive, with
-- text, data and bss summed.  System V: a table of every section.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local elfread = require "mcc.elfread"
local ar = require "mcc.ar"
local sys = require "mcc.sys"

local prog = sys.getenv("MCC_PROG") or "msize"

local SHF = elfread.SHF

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

local sysv, radix, totals = false, 10, false
local status = 0
local files = {}

for _, a in ipairs(arg) do
	if a == "-A" or a == "--format=sysv" or a == "--format=SysV" then
		sysv = true
	elseif a == "-B" or a == "--format=berkeley" then
		sysv = false
	elseif a == "-d" then
		radix = 10
	elseif a == "-o" then
		radix = 8
	elseif a == "-x" then
		radix = 16
	elseif a:match("^%-%-radix=") then
		radix = tonumber(a:match("=(.*)$"))
		if radix ~= 8 and radix ~= 10 and radix ~= 16 then
			die("invalid radix")
		end
	elseif a == "-t" or a == "--totals" then
		totals = true
	elseif a:sub(1, 1) == "-" and a ~= "-" then
		die("unknown option " .. a)
	else
		files[#files + 1] = a
	end
end
if #files == 0 then files[1] = "a.out" end

-- A number as size writes one in the radix asked for: octal and hex
-- carry their prefix, and zero keeps it.
local function num(n)
	if radix == 8 then return ("0%o"):format(n) end
	if radix == 16 then return ("0x%x"):format(n) end
	return ("%d"):format(n)
end

-- Every file named, and each member of an archive: the path, the
-- offset of the member, the name size prints, and the archive.
local function each(fn)
	for _, path in ipairs(files) do
		local members = ar.members(path)

		if members then
			for _, m in ipairs(members) do
				fn(m.file, m.off, m.name, path)
			end
		elseif not io.open(path, "rb") then
			io.stderr:write(("%s: '%s': No such file\n")
				:format(prog, path))
			status = 1
		else
			fn(path, 0, path, nil)
		end
	end
end

local function open(path, at0)
	local f, err = elfread.open(path, at0)

	if not f then
		io.stderr:write(prog .. ": " .. err .. "\n")
		status = 1
	end
	return f
end

-- Berkeley's three columns, summed over the allocated sections.
local function measure(f)
	local text, data, bss = 0, 0, 0

	for _, s in ipairs(f.sections) do
		if s.flags & SHF.alloc ~= 0 then
			-- Code is text even where it may be written,
			-- which a kernel has.
			if s.flags & SHF.exec ~= 0 then
				text = text + s.size
			elseif s.typ == "nobits" then
				bss = bss + s.size
			elseif s.flags & SHF.write ~= 0 then
				data = data + s.size
			else
				text = text + s.size
			end
		end
	end
	return text, data, bss
end

local function berkeley()
	local tt, td, tb, head = 0, 0, 0, false
	-- The heading goes before the first line, and not at all when no
	-- file could be read.
	local function row(t, d, b, name)
		local tot = t + d + b

		if not head then
			io.write("   text\t   data\t    bss\t    ",
				radix == 8 and "oct" or "dec",
				"\t    hex\tfilename\n")
			head = true
		end
		io.write(("%7s\t%7s\t%7s\t"):format(num(t), num(d), num(b)),
			(radix == 8 and "%7o" or "%7d"):format(tot), "\t",
			("%7x"):format(tot), "\t", name, "\n")
	end

	each(function(path, at0, name, archive)
		local f = open(path, at0)

		if not f then return end
		local t, d, b = measure(f)

		f:close()
		tt, td, tb = tt + t, td + d, tb + b
		row(t, d, b, archive and (name .. " (ex " .. archive .. ")")
			or name)
	end)
	if totals and head then row(tt, td, tb, "(TOTALS)") end
end

-- The sections a System V table lists: every one a linker would keep
-- as a section of its own.  An object's symbol and string tables and
-- its relocations belong to the sections they describe.
local function listed(s)
	if s.typ == "null" or s.typ == "symtab" or
	   s.typ == "symtab_shndx" then
		return false
	end
	if s.flags & SHF.alloc == 0 and s.typ == "strtab" then return false end
	if (s.typ == "rela" or s.typ == "rel") and s.info ~= 0 and
	   s.flags & SHF.alloc == 0 then
		return false
	end
	return true
end

local function sysvtable()
	each(function(path, at0, name, archive)
		local f = open(path, at0)

		if not f then return end
		local rows, total = {}, 0
		local namew, sizew, addrw = #"section", #"size", #"addr"

		for _, s in ipairs(f.sections) do
			if listed(s) then
				local r = {s.name, num(s.size), num(s.addr)}

				rows[#rows + 1] = r
				total = total + s.size
				namew = math.max(namew, #r[1])
				sizew = math.max(sizew, #r[2])
				addrw = math.max(addrw, #r[3])
			end
		end
		f:close()
		sizew = math.max(sizew, #num(total))
		local fmt = "%-" .. namew .. "s   %" .. sizew .. "s   %" ..
			addrw .. "s\n"

		if archive then
			io.write(name, "   (ex ", archive, "):\n")
		else
			io.write(name, "  :\n")
		end
		io.write(fmt:format("section", "size", "addr"))
		for _, r in ipairs(rows) do
			io.write(fmt:format(r[1], r[2], r[3]))
		end
		io.write(("%-" .. namew .. "s   %" .. sizew .. "s\n\n\n")
			:format("Total", num(total)))
	end)
end

if sysv then sysvtable() else berkeley() end
sys.exit(status)
