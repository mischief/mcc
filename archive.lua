-- SPDX-License-Identifier: ISC
-- mar: collect objects into an archive, the way ar does.
--
--	mar [rqd][csuvD...] archive.a object.o ...
--	mar s archive.a
--	mar t archive.a
--	mar x archive.a [member ...]
--	mranlib archive.a ...
--
-- The option letters are ar's.  r replaces or adds, q adds, d removes;
-- every archive written here has a symbol index, so s and ranlib only
-- give one to an archive something else wrote.  The letters about
-- timestamps and verbosity are read and ignored.

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
local index, thin, fullpath, noindex = false, false, false, false
local i = 1

-- `ranlib a.a ...` gives each archive its index.
if prog:match("ranlib$") then
	for _, a in ipairs(arg) do
		if a:sub(1, 1) ~= "-" then
			local ms = ar.members(a) or die(a .. " is not an archive")
			local items = {}

			local isthin = false

			for k, m in ipairs(ms) do
				items[k] = {src = m.file, off = m.off,
					    size = m.size, name = m.name}
				isthin = isthin or m.thin
			end
			ar.writeitems(a, items, isthin)
		end
	end
	sys.exit(0)
end

local function letters(w)
	for c in w:gmatch(".") do
		if c == "t" or c == "x" or c == "d" or c == "r" or
		   c == "q" then
			mode = c
		elseif c == "s" then
			index = true
		elseif c == "S" then
			noindex = true
		elseif c == "T" then
			thin = true
		elseif c == "P" then
			fullpath = true
		end
	end
end

while i <= #arg do
	local a = arg[i]

	if not out and not mode and not index and a:sub(1, 1) ~= "-" and
	   not a:match("%.a$") and not a:match("%.o$") then
		-- the option letters, which ar takes without a dash
		letters(a)
	elseif a:sub(1, 1) == "-" and #a > 1 and not a:match("%.o$") then
		letters(a:sub(2))
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
	local want = {}

	for _, n in ipairs(files) do want[n] = true end
	for _, m in ipairs(ms) do
		if #files == 0 or want[m.name] then
			local f = assert(io.open(m.file, "rb"))

			f:seek("set", m.off)
			local w = assert(io.open(m.name:gsub(".*/", ""), "wb"))

			w:write(f:read(m.size))
			w:close()
			f:close()
		end
	end
	sys.exit(0)
end

-- What is there already: `r` replaces a member of the same name and
-- adds the rest, `q` adds, `d` removes, and `s` alone only writes the
-- index, which every archive written here has anyway.
local items = {}
local old = ar.members(out)

if old then
	for k, m in ipairs(old) do
		items[k] = {src = m.file, off = m.off, size = m.size,
			    name = m.name}
		thin = thin or m.thin or false
	end
end

-- A thin archive names each member by its path from the archive's own
-- directory, which a build gives from where it runs.
local outdir = out:match("^(.*)/[^/]*$")

local function relative(p)
	if p:match("^/") or not outdir then return p end
	if p:sub(1, #outdir + 1) == outdir .. "/" then
		return p:sub(#outdir + 2)
	end
	return ("../"):rep(select(2, outdir:gsub("[^/]+", ""))) .. p
end
if mode == "d" then
	local gone = {}

	for _, n in ipairs(files) do gone[n] = true end
	local keep = {}

	for _, it in ipairs(items) do
		if not gone[it.name] then keep[#keep + 1] = it end
	end
	items = keep
else
	-- What goes in for one file: itself, or, for a thin archive
	-- given to a thin one, its members, as GNU ar flattens them.
	local adds = {}

	for _, p in ipairs(files) do
		local ms = thin and ar.members(p)

		if ms and ms[1] and ms[1].thin then
			for _, m in ipairs(ms) do
				adds[#adds + 1] = {path = m.file,
					name = relative(m.file)}
			end
		else
			adds[#adds + 1] = {path = p, name = thin and
				relative(p) or (fullpath and p or
				p:gsub(".*/", ""))}
		end
	end
	-- A file replaces a member that was there before, once.  Two
	-- files of one name in one command both go in, as GNU ar and
	-- llvm-ar do: nsd's library has three parser.o.
	local was, used = #items, {}

	for _, it in ipairs(adds) do
		local at

		if mode ~= "q" then
			for k = 1, was do
				if items[k].name == it.name and not used[k] then
					at = k
					break
				end
			end
		end
		if at then
			items[at], used[at] = it, true
		else
			items[#items + 1] = it
		end
	end
end
-- An archive with nothing in it is a real archive: musl makes one for
-- each library that is really part of libc, and a build that links
-- against it has to find a file there.  ar writes the magic line alone.
if #items == 0 then
	local f = assert(io.open(out, "wb"))

	f:write(thin and "!<thin>\n" or "!<arch>\n")
	f:close()
	sys.exit(0)
end
ar.writeitems(out, items, thin, noindex and not index)
