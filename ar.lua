-- The archive, which is what a build system asks a compiler to collect
-- objects into.
--
-- The format is the usual one: a magic line, then a header and the bytes
-- for each member, every member starting on an even offset.  A name too
-- long for the sixteen-byte field goes in a table of its own, which is a
-- member called "//", and the header then names the offset into it.
--
-- There is no symbol index.  The linker here reads every member's header
-- anyway to learn what it defines, which costs one pass over a table of
-- sizes and is simpler than keeping a second copy of the same facts.

local ar = {}

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
	w:write(MAGIC)
	if longlen > 0 then
		local t = table.concat(long)

		w:write(header("//", #t), t)
		if #t % 2 == 1 then w:write("\n") end
	end
	for i, p in ipairs(paths) do
		local f = assert(io.open(p, "rb"), "cannot open " .. p)
		local body = f:read("a")

		f:close()
		w:write(header(hdr[i], #body), body)
		if #body % 2 == 1 then w:write("\n") end
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
