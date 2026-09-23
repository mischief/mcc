-- SPDX-License-Identifier: ISC
-- mstrip: take sections and symbols out of an ELF file.
--	mstrip [-g|-S] [-s] [--strip-unneeded] [-R name] [-o out] file ...
-- What is loaded stays where it is.  The kept sections that are not
-- loaded follow it, then the names and the headers, and every index to
-- a section or a symbol is renumbered to match.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local sys = require "sys"

local prog = sys.getenv("MCC_PROG") or "mstrip"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

local SHT_SYMTAB, SHT_STRTAB, SHT_RELA, SHT_NOBITS, SHT_REL = 2, 3, 4, 8, 9
local SHT_GROUP, SHT_SYMTAB_SHNDX = 17, 18
local SHF_ALLOC = 2
local SHN_LORESERVE = 0xff00
local STT_SECTION, STT_FILE = 3, 4

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

-- A section name matches a -R pattern: a trailing star is a prefix.
local function removed(name)
	for _, p in ipairs(remove) do
		if p == name then return true end
		local head = p:match("^(.*)%*$")

		if head and name:sub(1, #head) == head then return true end
	end
	return false
end

local function isdebug(name)
	return name:match("^%.debug") or name:match("^%.zdebug") or
		name:match("^%.stab") or name == ".line" or
		name:match("^%.gnu%.debuglto")
end

local function strip(path, to)
	local f = assert(io.open(path, "rb"))
	local img = f:read("a")

	f:close()
	if img:sub(1, 4) ~= "\127ELF" then die(path .. ": not ELF") end
	local wide = img:byte(5) == 2
	if img:byte(6) ~= 1 then die(path .. ": not little-endian") end
	local A = wide and "<I8" or "<I4"
	local function rd(fmt, at) return (string.unpack(fmt, img, at + 1)) end
	local etype = rd("<I2", 16)
	local shoff = rd(A, wide and 40 or 32)
	local shentsize = rd("<I2", wide and 58 or 46)
	local shnum = rd("<I2", wide and 60 or 48)
	local shstrndx = rd("<I2", wide and 62 or 50)
	local phoff = rd(A, wide and 32 or 28)
	local phentsize = rd("<I2", wide and 54 or 42)
	local phnum = rd("<I2", wide and 56 or 44)

	-- the sections
	local S = {}
	for k = 0, shnum - 1 do
		local at = shoff + k * shentsize
		local s = {}

		s.name = rd("<I4", at)
		s.type = rd("<I4", at + 4)
		if wide then
			s.flags = rd("<I8", at + 8)
			s.addr = rd("<I8", at + 16)
			s.off = rd("<I8", at + 24)
			s.size = rd("<I8", at + 32)
			s.link = rd("<I4", at + 40)
			s.info = rd("<I4", at + 44)
			s.align = rd("<I8", at + 48)
			s.ent = rd("<I8", at + 56)
		else
			s.flags = rd("<I4", at + 8)
			s.addr = rd("<I4", at + 12)
			s.off = rd("<I4", at + 16)
			s.size = rd("<I4", at + 20)
			s.link = rd("<I4", at + 24)
			s.info = rd("<I4", at + 28)
			s.align = rd("<I4", at + 32)
			s.ent = rd("<I4", at + 36)
		end
		s.old = k
		S[k] = s
	end
	local shs = S[shstrndx]
	local function cstr(at)
		return img:match("^[^%z]*", at + 1)
	end
	for k = 0, shnum - 1 do
		S[k].nm = shs and cstr(shs.off + S[k].name) or ""
	end

	-- What goes: debug sections for -g and more; for -s the symbol
	-- table and every other section nothing loads and nothing points
	-- at, except in an object, whose relocations need its symbols.
	local rel = etype == 1
	local gone = {}
	for k = 1, shnum - 1 do
		local s = S[k]
		local nm = s.nm

		if removed(nm) then gone[k] = true end
		if isdebug(nm) and (debug_ or all or unneeded) then
			gone[k] = true
		end
		-- a relocation section for a section that goes, goes
		if (s.type == SHT_RELA or s.type == SHT_REL) and
		   s.flags & SHF_ALLOC == 0 and gone[s.info] then
			gone[k] = true
		end
		if (all or unneeded) and not rel and
		   (s.type == SHT_SYMTAB or
		    (s.type == SHT_STRTAB and k ~= shstrndx and
		     s.flags & SHF_ALLOC == 0)) then
			gone[k] = true
		end
	end
	-- relocations of a debug section that went are found above only
	-- when they come after it; look again for the ones before
	for k = 1, shnum - 1 do
		local s = S[k]

		if (s.type == SHT_RELA or s.type == SHT_REL) and
		   s.flags & SHF_ALLOC == 0 and gone[s.info] then
			gone[k] = true
		end
	end
	-- a group loses the members that went, and goes if none are left
	gone[shstrndx] = false

	-- the new numbering
	local keep, map = {}, {[0] = 0}
	for k = 0, shnum - 1 do
		if not gone[k] then
			keep[#keep + 1] = S[k]
			map[k] = #keep - 1
		end
	end

	-- The symbol table: symbols in sections that went go with them,
	-- and a debug section's own section symbol too.  What is left is
	-- renumbered, and so is every relocation that names one.
	local symmap = {}
	for _, s in ipairs(keep) do
		if s.type == SHT_SYMTAB then
			local es = wide and 24 or 16
			local n = s.size // es
			local out, locals = {}, 0

			symmap[s.old] = {}
			for j = 0, n - 1 do
				local at = s.off + j * es
				local e = img:sub(at + 1, at + es)
				local shndx, info

				if wide then
					info = e:byte(5)
					shndx = string.unpack("<I2", e, 7)
				else
					info = e:byte(13)
					shndx = string.unpack("<I2", e, 15)
				end
				local drop = j > 0 and shndx ~= 0 and
					shndx < SHN_LORESERVE and gone[shndx]

				if (debug_ or all or unneeded) and j > 0 and
				   info & 0xf == STT_FILE and (all or unneeded) then
					drop = true
				end
				if not drop then
					if shndx ~= 0 and shndx < SHN_LORESERVE then
						local nd = string.pack("<I2",
							map[shndx])

						if wide then
							e = e:sub(1, 6) .. nd ..
								e:sub(9)
						else
							e = e:sub(1, 14) .. nd
						end
					end
					symmap[s.old][j] = #out
					out[#out + 1] = e
					if info >> 4 == 0 then locals = #out end
				end
			end
			s.data = table.concat(out)
			s.info = locals
		end
	end
	for _, s in ipairs(keep) do
		if (s.type == SHT_RELA or s.type == SHT_REL) and symmap[s.link]
		then
			local sm = symmap[s.link]
			local es = s.type == SHT_RELA and (wide and 24 or 12) or
				(wide and 16 or 8)
			local body = s.data or img:sub(s.off + 1, s.off + s.size)
			local out = {}

			for j = 0, s.size // es - 1 do
				local e = body:sub(j * es + 1, (j + 1) * es)
				local infoat = wide and 9 or 5
				local fmt = wide and "<I8" or "<I4"
				local rinfo = string.unpack(fmt, e, infoat)
				local sym = wide and rinfo >> 32 or rinfo >> 8
				local typ = wide and rinfo & 0xffffffff or
					rinfo & 0xff
				local ns = sm[sym]

				if sym ~= 0 and not ns then
					die(path .. ": a relocation names a " ..
						"symbol of a section that goes")
				end
				ns = ns or 0
				local ni = wide and (ns << 32 | typ) or
					(ns << 8 | typ)

				out[#out + 1] = e:sub(1, infoat - 1) ..
					string.pack(fmt, ni) ..
					e:sub(infoat + (wide and 8 or 4))
			end
			s.data = table.concat(out)
		end
		if s.type == SHT_GROUP and symmap[s.link] then
			s.info = symmap[s.link][s.info] or 0
		end
	end
	-- section numbers inside groups
	for _, s in ipairs(keep) do
		if s.type == SHT_GROUP then
			local body = s.data or img:sub(s.off + 1, s.off + s.size)
			local out = {body:sub(1, 4)}

			for j = 1, s.size // 4 - 1 do
				local m = string.unpack("<I4", body, j * 4 + 1)

				if not gone[m] then
					out[#out + 1] = string.pack("<I4", map[m])
				end
			end
			s.data = table.concat(out)
		end
	end

	-- the names
	local names, nameat = {"\0"}, {}
	local nlen = 1
	for _, s in ipairs(keep) do
		if s.old ~= 0 then
			if not nameat[s.nm] then
				nameat[s.nm] = nlen
				names[#names + 1] = s.nm .. "\0"
				nlen = nlen + #s.nm + 1
			end
			s.name = nameat[s.nm]
		end
	end
	local shsname = S[shstrndx]
	shsname.data = table.concat(names)

	-- Everything a segment loads stays where it is: the file up to the
	-- end of the last of them is copied as it stands.
	local fixed = phoff + phnum * phentsize
	for k = 0, phnum - 1 do
		local at = phoff + k * phentsize
		local off = rd(A, at + (wide and 8 or 4))
		local fsz = rd(A, at + (wide and 32 or 16))

		if fsz > 0 and off + fsz > fixed then fixed = off + fsz end
	end
	for _, s in ipairs(keep) do
		if s.old ~= 0 and s.flags & SHF_ALLOC ~= 0 and
		   s.type ~= SHT_NOBITS and s.off + s.size > fixed and
		   not s.data then
			fixed = s.off + s.size
		end
	end
	if etype == 1 then fixed = wide and 64 or 52 end
	if fixed > #img then fixed = #img end

	local body = {img:sub(1, fixed)}
	local at = fixed
	for _, s in ipairs(keep) do
		local loaded = s.flags & SHF_ALLOC ~= 0 and etype ~= 1

		if s.old ~= 0 and not loaded and s.type ~= SHT_NOBITS then
			local a = math.max(s.align, 1)
			local pad = (a - at % a) % a
			local bytes = s.data or img:sub(s.off + 1, s.off + s.size)

			body[#body + 1] = ("\0"):rep(pad)
			at = at + pad
			s.off = at
			s.size = #bytes
			body[#body + 1] = bytes
			at = at + #bytes
		elseif s.old ~= 0 and s.type == SHT_NOBITS and etype == 1 then
			s.off = at
		end
	end
	local pad = (8 - at % 8) % 8
	body[#body + 1] = ("\0"):rep(pad)
	at = at + pad
	local newshoff = at
	local hdr = {}
	for _, s in ipairs(keep) do
		local link = s.link

		if (s.type == SHT_SYMTAB or s.type == SHT_RELA or
		    s.type == SHT_REL or s.type == SHT_GROUP or
		    s.type == SHT_SYMTAB_SHNDX or s.link ~= 0) and s.old ~= 0 then
			link = map[s.link] or 0
		end
		local info = s.info

		if (s.type == SHT_RELA or s.type == SHT_REL) and s.old ~= 0 then
			info = map[s.info] or 0
		end
		if wide then
			hdr[#hdr + 1] = string.pack("<I4I4I8I8I8I8I4I4I8I8",
				s.name, s.type, s.flags, s.addr, s.off,
				s.size, link, info, s.align, s.ent)
		else
			hdr[#hdr + 1] = string.pack("<I4I4I4I4I4I4I4I4I4I4",
				s.name, s.type, s.flags, s.addr, s.off,
				s.size, link, info, s.align, s.ent)
		end
	end
	body[#body + 1] = table.concat(hdr)
	local res = table.concat(body)
	-- the ELF header: where the table is, how many, which holds names
	local e = res:sub(1, wide and 64 or 52)
	local function put(s, o, fmt, v)
		local b = string.pack(fmt, v)

		return s:sub(1, o) .. b .. s:sub(o + #b + 1)
	end
	e = put(e, wide and 40 or 32, A, newshoff)
	e = put(e, wide and 60 or 48, "<I2", #keep)
	e = put(e, wide and 62 or 50, "<I2", map[shstrndx])
	res = e .. res:sub(#e + 1)

	local w = assert(io.open(to, "wb"))

	w:write(res)
	w:close()
	-- a program or a library stays one a system can run
	if to ~= path and etype ~= 1 then sys.executable(to) end
end

for _, path in ipairs(files) do
	strip(path, out or path)
end
