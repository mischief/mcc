-- SPDX-License-Identifier: ISC
-- The archive, which is what a build system asks a compiler to collect
-- objects into.
--
-- The format is the usual one: a magic line, then a header and the bytes
-- for each member, every member starting on an even offset.  A name too
-- long for the sixteen-byte field goes in a table of its own, which is a
-- member called "//", and the header then names the offset into it.
--
-- The first member is the symbol index, named "/": a count, one offset
-- per symbol, then the names.  The linker here does not need it -- it
-- reads every member's header anyway -- but GNU ld will not look at an
-- archive without one.

local ar = {}

local elf = require "mcc.elf"

local MAGIC = "!<arch>\n"
local THIN = "!<thin>\n"

local function field(s, n)
	return s .. (" "):rep(n - #s)
end

local function header(name, size)
	-- The long name table carries no date, owner or mode, as GNU ar
	-- writes it.
	if name == "//" then
		return field(name, 48) .. field(tostring(size), 10) .. "`\n"
	end
	-- and the index has mode 0
	if name == "/" then
		return field(name, 16) .. field("0", 12) .. field("0", 6) ..
			field("0", 6) .. field("0", 8) ..
			field(tostring(size), 10) .. "`\n"
	end
	return field(name, 16) .. field("0", 12) .. field("0", 6) ..
		field("0", 6) .. field("644", 8) ..
		field(tostring(size), 10) .. "`\n"
end

-- `names` is the member name to write for each path; the default is the
-- last component, which is what ar does.
-- What each member defines, for the index.
local function exported(path, off)
	local r = elf
	local ok, h = pcall(r.header, path, false, off or 0)

	if not ok then return {} end
	local out = {}

	for name, d in pairs(h.syms) do
		if d.global then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

local function be32(v)
	return string.pack(">I4", v)
end

function ar.write(out, paths, names)
	local items = {}

	for i, p in ipairs(paths) do
		items[i] = {path = p,
			    name = (names and names[i]) or p:gsub(".*/", "")}
	end
	return ar.writeitems(out, items)
end

-- Write an archive from items: each is a file ({path, name}) or a member
-- of an archive ({src, off, size, name}).  Everything is read before
-- the output is opened, so an archive may be rewritten from itself.
-- A thin archive (`thin`) keeps only the headers, and every name is a
-- path, relative to where the archive is, in the long name table.
function ar.writeitems(out, items, thin, noindex)
	local long, longlen = {}, 0
	local hdr = {}
	local paths = items

	for i, it in ipairs(items) do
		local name = it.name

		if #name + 1 > 16 or thin then
			hdr[i] = "/" .. longlen
			long[#long + 1] = name .. "/\n"
			longlen = longlen + #name + 2
		else
			hdr[i] = name .. "/"
		end
	end
	-- The bodies first, so that the index can say where each one
	-- lands.  An archive is small next to what made it.
	local body, sizes = {}, {}

	for i, it in ipairs(items) do
		local f = assert(io.open(it.path or it.src, "rb"),
			"cannot open " .. (it.path or it.src))

		if it.src then
			f:seek("set", it.off)
			body[i] = f:read(it.size) or ""
		else
			body[i] = f:read("a")
		end
		f:close()
		sizes[i] = thin and 0 or #body[i] + (#body[i] % 2)
	end
	-- The index: every symbol, and the header offset of the member
	-- that has it.  Its own size decides those offsets, and the size
	-- depends only on how many symbols there are.
	local syms, owner = {}, {}

	for i, it in ipairs(items) do
		for _, nm in ipairs(exported(it.path or it.src, it.off)) do
			syms[#syms + 1] = nm
			owner[#syms] = i
		end
	end
	local strings = {}

	for k, nm in ipairs(syms) do strings[k] = nm .. "\0" end
	strings = table.concat(strings)
	local idxlen = 4 + 4 * #syms + #strings
	-- `ar S` writes no index at all.
	local at = noindex and #MAGIC or #MAGIC + 60 + idxlen + (idxlen % 2)
	local magic = thin and THIN or MAGIC
	local longtext = table.concat(long)

	-- GNU ar pads the table inside its own size.
	if #longtext % 2 == 1 then longtext = longtext .. "\n" end

	if longlen > 0 then
		at = at + 60 + #longtext + (#longtext % 2)
	end
	local memat = {}
	local w = assert(io.open(out, "wb"))

	for i = 1, #paths do
		memat[i] = at
		at = at + 60 + sizes[i]
	end
	w:write(magic)
	local idx = {be32(#syms)}

	for k = 1, #syms do idx[k + 1] = be32(memat[owner[k]]) end
	idx[#idx + 1] = strings
	idx = table.concat(idx)
	if not noindex then
		w:write(header("/", #idx), idx)
		if #idx % 2 == 1 then w:write("\n") end
	end
	if longlen > 0 then
		w:write(header("//", #longtext), longtext)
		if #longtext % 2 == 1 then w:write("\n") end
	end
	for i = 1, #paths do
		if thin then
			w:write(header(hdr[i], #body[i]))
		else
			w:write(header(hdr[i], #body[i]), body[i])
			if #body[i] % 2 == 1 then w:write("\n") end
		end
	end
	w:close()
end

-- Every member, as a name and where its bytes are.  Answers nil for a
-- file that is not an archive, so a caller can tell one from an object.
function ar.members(path)
	local f = io.open(path, "rb")

	if not f then return nil end
	local magic = f:read(#MAGIC)
	-- A thin archive holds only the headers: each member is the file
	-- its name gives, relative to where the archive is.
	local thin = magic == THIN

	if magic ~= MAGIC and not thin then
		f:close()
		return nil
	end
	local dir = path:match("^(.*)/[^/]*$")
	local at = #MAGIC
	local out, names = {}, nil
	-- The symbol index: each name and the header of the member that
	-- defines it.  "/" has four-byte offsets, "/SYM64/" eight.
	local index, byhdr = nil, {}

	while true do
		f:seek("set", at)
		local h = f:read(60)

		if not h or #h < 60 then break end
		local name = h:sub(1, 16):gsub("%s+$", "")
		local size = tonumber((h:sub(49, 58):gsub("%s+$", ""))) or 0

		local hdrat = at

		at = at + 60
		if name == "//" then
			names = f:read(size)
		elseif name == "/" or name == "/SYM64/" then
			local w = name == "/" and 4 or 8
			local s = f:read(size) or ""
			local n = #s >= w and string.unpack(">I" .. w, s) or 0

			if #s >= w + n * w then
				local p = w + n * w + 1

				index = {}
				for k = 1, n do
					local off = string.unpack(">I" .. w, s,
						1 + k * w)
					local e = s:find("\0", p, true) or #s + 1

					index[#index + 1] = {s:sub(p, e - 1), off}
					p = e + 1
				end
			end
		else
			local k = name:match("^/(%d+)$")

			if k and names then
				-- a long name ends with "/\n", and in
				-- a thin archive it is a path
				name = names:sub(k + 1):match("^(.-)/\n") or
					names:sub(k + 1):match("^([^/]*)")
			else
				name = name:gsub("/$", "")
			end
			if thin then
				local file = name

				if dir and not name:match("^/") then
					file = dir .. "/" .. name
				end
				out[#out + 1] = {name = name, off = 0,
						 size = size, file = file,
						 thin = true}
				-- no body follows the header
				at = at - size - size % 2
			else
				out[#out + 1] = {name = name, off = at,
						 size = size, file = path}
			end
			byhdr[hdrat] = out[#out]
		end
		at = at + size + size % 2
	end
	f:close()
	-- The index by name, to the member itself.  A name two members
	-- define goes to the first, as a linker takes it.
	local byname

	if index then
		byname = {}
		for _, e in ipairs(index) do
			local m = byhdr[e[2]]

			if m and not byname[e[1]] then byname[e[1]] = m end
		end
	end
	return out, byname
end

return ar
