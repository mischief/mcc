-- SPDX-License-Identifier: ISC
-- msize: the sizes of the sections in an ELF file, the way size prints
-- them.
--
--	msize file ...
--
-- One line per file, and one per member of an archive, as GNU size does.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local elfread = require "elfread"
local ar = require "ar"
local sys = require "sys"

local prog = sys.getenv("MCC_PROG") or "msize"

local SHF = elfread.SHF

local files = {}
for _, a in ipairs(arg) do
	if a:sub(1, 1) == "-" then
		io.stderr:write(prog .. ": unknown option " .. a .. "\n")
		sys.exit(1)
	end
	files[#files + 1] = a
end
if #files == 0 then files[1] = "a.out" end

-- The three columns, summed over the sections that fall into them.
local function measure(path, at0)
	local f, err = elfread.open(path, at0)

	if not f then
		io.stderr:write(prog .. ": " .. err .. "\n")
		return nil
	end
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
	f:close()
	return text, data, bss
end

local function col(n, w)
	return ("%" .. w .. "d"):format(n)
end

local function line(t, d, b, name)
	local tot = t + d + b
	local wt = math.max(7, #tostring(t))
	local wd = math.max(7, #tostring(d))
	local wb = math.max(7, #tostring(b))
	local wdt = math.max(7, #tostring(tot))
	local hex = string.format("%x", tot)
	hex = string.rep(" ", math.max(0, 7 - #hex)) .. hex
	io.write(col(t, wt), "\t", col(d, wd), "\t", col(b, wb),
		"\t", col(tot, wdt), "\t", hex, "\t", name, "\n")
end

io.write("   text\t   data\t    bss\t    dec\t    hex\tfilename\n")
for _, path in ipairs(files) do
	local members = ar.members(path)

	if members then
		for _, m in ipairs(members) do
			local t, d, b = measure(m.file, m.off)

			if t then
				line(t, d, b, m.name .. " (ex " .. path .. ")")
			end
		end
	else
		local t, d, b = measure(path, 0)

		if t then
			line(t, d, b, path)
		end
	end
end
