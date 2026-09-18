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

local obj = require "obj"
local elf = require "elf"

local MAGIC = "!<arch>\n"

local function field(s, n)
	return s .. (" "):rep(n - #s)
end

local function header(name, size)
	return field(name, 16) .. field("0", 12) .. field("0", 6) ..
		field("0", 6) .. field("644", 8) ..
		field(tostring(size), 10) .. "`\n"
end

-- `names` is the member name to write for each path; the default is the
-- last component, which is what ar does.
-- What each member defines, for the index.
local function exported(path)
	local r = elf.is(path, 0) and elf or obj
	local ok, h = pcall(r.header, path, false, 0)

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
	local w = assert(io.open(out, "wb"))
	local long, longlen = {}, 0
	local hdr = {}

	for i, p in ipairs(paths) do
		local name = (names and names[i]) or p:gsub(".*/", "")

		if #name + 1 > 16 then
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

	for i, p in ipairs(paths) do
		local f = assert(io.open(p, "rb"), "cannot open " .. p)

		body[i] = f:read("a")
		f:close()
		sizes[i] = #body[i] + (#body[i] % 2)
	end
	-- The index: every symbol, and the header offset of the member
	-- that has it.  Its own size decides those offsets, and the size
	-- depends only on how many symbols there are.
	local syms, owner = {}, {}

	for i, p in ipairs(paths) do
		for _, nm in ipairs(exported(p)) do
			syms[#syms + 1] = nm
			owner[#syms] = i
		end
	end
	local strings = {}

	for k, nm in ipairs(syms) do strings[k] = nm .. "\0" end
	strings = table.concat(strings)
	local idxlen = 4 + 4 * #syms + #strings
	local at = #MAGIC + 60 + idxlen + (idxlen % 2)
	local longtext = table.concat(long)

	if longlen > 0 then
		at = at + 60 + #longtext + (#longtext % 2)
	end
	local memat = {}

	for i = 1, #paths do
		memat[i] = at
		at = at + 60 + sizes[i]
	end
	w:write(MAGIC)
	local idx = {be32(#syms)}

	for k = 1, #syms do idx[k + 1] = be32(memat[owner[k]]) end
	idx[#idx + 1] = strings
	idx = table.concat(idx)
	w:write(header("/", #idx), idx)
	if #idx % 2 == 1 then w:write("\n") end
	if longlen > 0 then
		w:write(header("//", #longtext), longtext)
		if #longtext % 2 == 1 then w:write("\n") end
	end
	for i = 1, #paths do
		w:write(header(hdr[i], #body[i]), body[i])
		if #body[i] % 2 == 1 then w:write("\n") end
	end
	w:close()
end

-- Every member, as a name and where its bytes are.  Answers nil for a
-- file that is not an archive, so a caller can tell one from an object.
function ar.members(path)
	local f = io.open(path, "rb")

	if not f then return nil end
	if f:read(#MAGIC) ~= MAGIC then
		f:close()
		return nil
	end
	local at = #MAGIC
	local out, names = {}, nil

	while true do
		f:seek("set", at)
		local h = f:read(60)

		if not h or #h < 60 then break end
		local name = h:sub(1, 16):gsub("%s+$", "")
		local size = tonumber((h:sub(49, 58):gsub("%s+$", ""))) or 0

		at = at + 60
		if name == "//" then
			names = f:read(size)
		elseif name ~= "/" and name ~= "/SYM64/" then
			local k = name:match("^/(%d+)$")

			if k and names then
				name = names:sub(k + 1):match("^([^/]*)")
			else
				name = name:gsub("/$", "")
			end
			out[#out + 1] = {name = name, off = at, size = size}
		end
		at = at + size + size % 2
	end
	f:close()
	return out
end

return ar
