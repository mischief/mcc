-- SPDX-License-Identifier: ISC
-- mobjcopy: copy an ELF file, leaving sections and symbols out, or
-- write its loaded bytes as a flat image.
--	mobjcopy [-O binary] [-S|-g|--strip-unneeded] [-x] [-R section]
--		[-K symbol] [-j section] [--add-section name=file] [-v]
--		in [out]
-- These are the operations OpenBSD's boot blocks and release sets use.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local sys = require "mcc.sys"
local elfstrip = require "mcc.elfstrip"

local prog = sys.getenv("MCC_PROG") or "mobjcopy"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

local opts = {remove = {}, keep = {}, add = {}}
local ofmt, verbose = nil, false
local files = {}
local i = 1

-- `-R x`, `-Rx` and `--remove-section=x` are one option three ways.
local function value(a, short, long)
	if a == short or a == long then
		i = i + 1
		return arg[i] or die(a .. " wants a value")
	end
	if long and a:sub(1, #long + 1) == long .. "=" then
		return a:sub(#long + 2)
	end
	if #a > #short and a:sub(1, #short) == short then
		return a:sub(#short + 1)
	end
	return nil
end

while i <= #arg do
	local a = arg[i]
	local v

	if a == "-S" or a == "--strip-all" then
		opts.all = true
	elseif a == "-g" or a == "--strip-debug" then
		opts.debug = true
	elseif a == "--strip-unneeded" then
		opts.unneeded = true
	elseif a == "-x" or a == "--discard-all" then
		opts.locals = true
	elseif a == "-X" or a == "--discard-locals" or a == "-p" or
	       a == "--preserve-dates" or a == "-D" or
	       a == "--enable-deterministic-archives" then
		-- compiler labels are not kept apart, and dates are not kept
	elseif a == "-v" or a == "--verbose" then
		verbose = true
	elseif a:sub(1, 1) ~= "-" or a == "-" then
		files[#files + 1] = a
	else
		v = value(a, "-O", "--output-target")
		if v then
			ofmt = v
		else
			v = value(a, "-I", "--input-target")
			if not v then v = value(a, "-F", "--target") end
			if v then
				if v:match("^efi") or v:match("^pe") then
					die("no PE output yet: " .. v)
				end
				if a:match("^%-F") or a:match("^%-%-target") then
					ofmt = v
				end
			else
				v = value(a, "--add-section", "--add-section")
				if v then
					local nm, file = v:match("^([^=]+)=(.+)$")

					if not nm then
						die("--add-section NAME=FILE")
					end
					local f = io.open(file, "rb") or
						die("cannot open " .. file)

					opts.add[#opts.add + 1] = {name = nm,
						data = f:read("a")}
					f:close()
					goto nextarg
				end
				v = value(a, "-R", "--remove-section")
				if v then
					opts.remove[#opts.remove + 1] = v
				else
					v = value(a, "-K", "--keep-symbol")
					if v then
						opts.keep[v] = true
					else
						v = value(a, "-j", "--only-section")
						if not v then
							die("unknown option " .. a)
						end
						opts.only = opts.only or {}
						opts.only[#opts.only + 1] = v
					end
				end
			end
		end
	end
	::nextarg::
	i = i + 1
end
if #files == 0 or #files > 2 then die("usage: " .. prog .. " [options] in [out]") end
local from, to = files[1], files[2] or files[1]

-- The bytes every allocated section holds, each where it is loaded, as
-- one flat image from the lowest of them to the end of the highest.
-- The gaps between are zeros.  A section's load address comes from the
-- segment around it: a boot block runs where p_paddr says.
local function binary(path)
	local f = assert(io.open(path, "rb"))
	local img = f:read("a")

	f:close()
	if img:sub(1, 4) ~= "\127ELF" then die(path .. ": not ELF") end
	local wide = img:byte(5) == 2
	local A = wide and "<I8" or "<I4"
	local function rd(fmt, at) return (string.unpack(fmt, img, at + 1)) end
	local phoff = rd(A, wide and 32 or 28)
	local shoff = rd(A, wide and 40 or 32)
	local phentsize = rd("<I2", wide and 54 or 42)
	local phnum = rd("<I2", wide and 56 or 44)
	local shentsize = rd("<I2", wide and 58 or 46)
	local shnum = rd("<I2", wide and 60 or 48)
	local segs = {}

	for k = 0, phnum - 1 do
		local at = phoff + k * phentsize
		local g = {}

		g.type = rd("<I4", at)
		if wide then
			g.vaddr, g.paddr = rd(A, at + 16), rd(A, at + 24)
			g.memsz = rd(A, at + 40)
		else
			g.vaddr, g.paddr = rd(A, at + 8), rd(A, at + 12)
			g.memsz = rd(A, at + 20)
		end
		if g.type == 1 then segs[#segs + 1] = g end
	end
	local pieces, lo, hi = {}, nil, nil

	for k = 1, shnum - 1 do
		local at = shoff + k * shentsize
		local typ = rd("<I4", at + 4)
		local flags = rd(A, at + 8)
		local addr = rd(A, at + (wide and 16 or 12))
		local off = rd(A, at + (wide and 24 or 16))
		local size = rd(A, at + (wide and 32 or 20))

		if flags & 2 ~= 0 and typ ~= 8 and size > 0 then
			local lma = addr

			for _, g in ipairs(segs) do
				if addr >= g.vaddr and addr < g.vaddr + g.memsz then
					lma = g.paddr + (addr - g.vaddr)
				end
			end
			pieces[#pieces + 1] = {lma = lma,
				bytes = img:sub(off + 1, off + size)}
			lo = math.min(lo or lma, lma)
			hi = math.max(hi or 0, lma + size)
		end
	end
	if not lo then return "" end
	table.sort(pieces, function(x, y) return x.lma < y.lma end)
	local out, at = {}, lo

	for _, p in ipairs(pieces) do
		if p.lma > at then
			out[#out + 1] = ("\0"):rep(p.lma - at)
			at = p.lma
		end
		-- a section that overlaps the one before it wins where it lies
		if p.lma < at then
			local keep = table.concat(out)
			local cut = p.lma - lo

			out = {keep:sub(1, cut), p.bytes, keep:sub(cut + #p.bytes + 1)}
			at = math.max(at, p.lma + #p.bytes)
		else
			out[#out + 1] = p.bytes
			at = at + #p.bytes
		end
	end
	return table.concat(out)
end

-- The name GNU gives the input's format, which -v prints.
local function bfdname(path)
	local f = io.open(path, "rb")
	local h = f and f:read(20) or ""

	if f then f:close() end
	if h:sub(1, 4) ~= "\127ELF" then return "unknown" end
	local mach = string.unpack("<I2", h, 19)
	local NAME = {[3] = "i386", [62] = "x86-64", [183] = "littleaarch64",
		      [243] = "littleriscv"}

	return ("elf%d-%s"):format(h:byte(5) == 2 and 64 or 32,
		NAME[mach] or "little")
end

if verbose then
	local fmt = bfdname(from)

	print(("copy from `%s' [%s] to `%s' [%s]"):format(from, fmt, to,
		ofmt or fmt))
end
if ofmt == "binary" then
	local bytes = binary(from)
	local w = assert(io.open(to, "wb"))

	w:write(bytes)
	w:close()
	sys.exit(0)
end
if ofmt and not ofmt:match("^elf") then die("no output format " .. ofmt) end
local ok, err = pcall(elfstrip.strip, from, to, opts)

if not ok then die(tostring(err)) end
