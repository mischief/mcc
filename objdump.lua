-- SPDX-License-Identifier: ISC
-- mobjdump: what is in an object, and what the code in it says.
--
--	mobjdump -d [-j section] [--no-show-raw-insn] file ...
--	mobjdump --at=ADDR [--context=N] file
--
-- `--at` is the one a debugger wants: the instructions around an
-- address, and whose they are.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local elfread = require "elfread"
local ar = require "ar"
local dis = require "dis"
local sys = require "sys"

local prog = sys.getenv("MCC_PROG") or "mobjdump"

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

local o = {raw = true, context = 8}
local files = {}
local i = 1

while i <= #arg do
	local a = arg[i]
	local k, v = a:match("^(%-%-[%w-]+)=(.*)$")

	if k then a = k end
	if a == "-d" or a == "--disassemble" then
		o.dis = true
	elseif a == "-D" or a == "--disassemble-all" then
		o.dis, o.all = true, true
	elseif a == "-r" or a == "--reloc" then
		o.reloc = true
	elseif a == "-t" or a == "--syms" then
		o.syms = true
	elseif a == "-h" or a == "--section-headers" then
		o.headers = true
	elseif a == "-x" then
		o.headers, o.syms, o.info = true, true, true
	elseif a == "-f" or a == "--file-headers" then
		o.info = true
	elseif a == "--no-show-raw-insn" then
		o.raw = false
	elseif a == "--section" then
		o.only = v or die("--section wants a name")
	elseif a == "-j" then
		i = i + 1
		o.only = arg[i] or die("-j wants a section")
	elseif a == "--start-address" then
		o.from = tonumber(v)
	elseif a == "--stop-address" then
		o.to = tonumber(v)
	elseif a == "--at" then
		o.at = tonumber(v) or die("--at wants an address")
	elseif a == "--context" then
		o.context = tonumber(v) or 8
	elseif a:sub(1, 1) == "-" and #a > 1 then
		die("unknown option " .. a)
	else
		files[#files + 1] = a
	end
	i = i + 1
end

if #files == 0 then die("no file named") end
if not (o.dis or o.reloc or o.syms or o.headers or o.info or o.at) then
	o.dis = true
end

-- What objdump calls the format, which a reader uses to tell one
-- machine's object from another's.
local FORMAT = {amd64 = "elf64-x86-64", i386 = "elf32-i386",
		arm64 = "elf64-littleaarch64",
		riscv64 = "elf64-littleriscv",
		riscv32 = "elf32-littleriscv",
		xtensa = "elf32-xtensa-le"}

-- The column an address is printed in: room for the largest and a
-- space in front of it, rounded up to four, eight or sixteen digits,
-- which is the choice objdump makes.
local function hexwidth(top)
	local w = #("%x"):format(top) + 1

	if w <= 4 then return 4 end
	if w <= 8 then return 8 end
	return 16
end

-- What a relocation the loader will apply says about an address.  A
-- slot in the table of addresses holds nothing until then, so the name
-- of what will land there is the only useful thing to print.
local function dynnames(f)
	if f.dynmap then return f.dynmap end
	local t = {}

	f.dynmap = t
	for _, s in ipairs(f.sections) do
		if (s.typ == "rela" or s.typ == "rel") and s.addr ~= 0 then
			for _, r in ipairs(f:relocsin(s)) do
				local n = r.sym and r.sym.name

				if n and n ~= "" then
					t[r.off] = f:fullname(r.sym)
				end
			end
		end
	end
	return t
end

-- The name for an address, as a reader of code wants it beside the
-- number.  Nothing comes back for an address no symbol covers.
local function nameof(f, addr, sec)
	-- Only an object needs the section: there an address is an
	-- offset into one, and the same number names a place in each.
	local sym, off = f:at(addr, f.typ == "rel" and sec or nil)
	local dyn = f.typ ~= "rel" and dynnames(f)[addr]

	if dyn then return ("<%s>"):format(dyn) end
	if not sym then return nil end
	if off == 0 then return ("<%s>"):format(sym.name) end
	return ("<%s+%#x>"):format(sym.name, off)
end

local function rawbytes(s)
	local out = {}

	for c in s:gmatch(".") do out[#out + 1] = ("%02x"):format(c:byte()) end
	return out
end

-- One instruction, printed the way objdump prints it: the address, the
-- bytes it is made of, and the text.  Seven bytes fit on a line and the
-- rest go on the next one.
local function insline(f, w, addr, ins, sec)
	local text = ins.text
	local note = ""

	if ins.target then
		local nm = nameof(f, ins.target, sec)

		text = ("%-6s %s"):format(ins.mnem,
			("%x"):format(ins.target) .. (nm and " " .. nm or ""))
		if ins.indirect then text = ins.text end
	end
	if ins.riptarget then
		local nm = nameof(f, ins.riptarget, sec)

		note = ("        # %x%s"):format(ins.riptarget,
			nm and " " .. nm or "")
	end
	if not o.raw then
		return ("%" .. w .. "x:\t%s%s"):format(addr, text, note)
	end
	local b = rawbytes(ins.bytes or "")
	local lines = {}

	for at = 1, math.max(#b, 1), 7 do
		local part = table.concat(b, " ", at,
			math.min(at + 6, #b))

		if at == 1 then
			lines[#lines + 1] = ("%" .. w .. "x:\t%-21s\t%s%s")
				:format(addr, part, text, note)
		else
			lines[#lines + 1] = ("%" .. w .. "x:\t%s ")
				:format(addr + at - 1, part)
		end
	end
	return table.concat(lines, "\n")
end

-- Disassemble one section, naming each symbol as it is reached.
local function section(f, s, w)
	local bytes = f:contents(s)
	local base = f.typ == "rel" and 0 or s.addr
	local marks = {}

	for _, sym in ipairs(f:syms()) do
		if sym.sec == s and sym.name ~= "" and
		   sym.typ ~= "file" and sym.typ ~= "section" then
			marks[sym.value] = elfread.prefer(
				marks[sym.value], sym)
		end
	end
	io.write(("\nDisassembly of section %s:\n"):format(s.name))
	local m, err = dis.arch(f.arch)

	if not m then
		io.write("... " .. err .. "\n")
		return
	end
	local from = o.from and math.max(0, o.from - base) or 0
	local to = o.to and math.min(#bytes, o.to - base) or #bytes

	for off, ins in dis.each(m, bytes, base, from, to) do
		local addr = base + off

		if marks[addr] then
			io.write(("\n%016x <%s>:\n"):format(addr,
				marks[addr].name))
		end
		io.write(insline(f, w, addr, ins, s), "\n")
	end
end

-- The tables that describe the others, which objdump leaves out unless
-- the loader maps them: in a program the dynamic ones are part of the
-- image and a reader wants to see them.
local TABLE = {rela = true, rel = true, symtab = true, dynsym = true,
	       strtab = true, null = true, group = true,
	       symtab_shndx = true}

local function hidden(s)
	return TABLE[s.typ] and s.flags & elfread.SHF.alloc == 0
end

local function headers(f)
	io.write("\nSections:\n")
	io.write("Idx Name          Size      VMA               ",
		"LMA               File off  Algn\n")
	local idx = 0

	for _, s in ipairs(f.sections) do
		local flags = {}
		local has = s.typ ~= "nobits"
		local alloc = s.flags & elfread.SHF.alloc ~= 0

		if not hidden(s) then
			if has then flags[#flags + 1] = "CONTENTS" end
			if alloc then flags[#flags + 1] = "ALLOC" end
			if alloc and has then flags[#flags + 1] = "LOAD" end
			if #f:relocs(s) > 0 then
				flags[#flags + 1] = "RELOC"
			end
			if s.flags & elfread.SHF.write == 0 then
				flags[#flags + 1] = "READONLY"
			end
			if s.flags & elfread.SHF.exec ~= 0 then
				flags[#flags + 1] = "CODE"
			elseif has and alloc then
				flags[#flags + 1] = "DATA"
			end
			io.write(("%3d %-13s %08x  %016x  %016x  %08x  2**%d\n")
				:format(idx, s.name, s.size, s.addr, s.addr,
					s.off, math.floor(math.log(
						math.max(s.align, 1), 2))))
			io.write("                  ",
				table.concat(flags, ", "), "\n")
			idx = idx + 1
		end
	end
end

-- The seven flag columns objdump prints for a symbol: who can see it,
-- then a few kinds it almost never is, then whether it describes the
-- file rather than the program, then what it names.
local function symflags(s)
	local c = {" ", " ", " ", " ", " ", " ", " "}

	if s.undef or s.bind == "weak" then
		c[1] = " "
	else
		c[1] = s.bind == "local" and "l" or "g"
	end
	if s.bind == "weak" then c[2] = "w" end
	if s.typ == "file" or s.typ == "section" then c[6] = "d" end
	if s.typ == "func" or s.typ == "ifunc" then
		c[7] = "F"
	elseif s.typ == "file" then
		c[7] = "f"
	elseif s.typ == "object" or s.typ == "tls" then
		c[7] = "O"
	end
	return table.concat(c)
end

local function symbols(f, which)
	io.write(("\n%s:\n"):format(which == ".dynsym" and
		"DYNAMIC SYMBOL TABLE" or "SYMBOL TABLE"))
	local w = f.class == 64 and 16 or 8
	local fmt = "%0" .. w .. "x %s %s\t%0" .. w .. "x %s%s\n"

	-- The first entry of every symbol table stands for nothing.
	for i = 2, #f:syms(which) do
		local s = f:syms(which)[i]
		local where = s.undef and "*UND*" or
			(s.abs and "*ABS*" or
			 (s.common and "*COM*" or
			  (s.sec and s.sec.name or "*UND*")))
		local vis = (s.vis ~= "default" and s.vis ~= nil) and
			("." .. s.vis .. " ") or ""
		local name = s.typ == "section" and where or s.name

		io.write(fmt:format(s.value, symflags(s), where, s.size,
			vis, name))
	end
	io.write("\n\n")
end

local function relocs(f)
	for _, s in ipairs(f.sections) do
		local rs = f:relocs(s)

		if #rs > 0 then
			io.write(("\nRELOCATION RECORDS FOR [%s]:\n")
				:format(s.name))
			io.write("OFFSET           TYPE              VALUE\n")
			for _, r in ipairs(rs) do
				local nm = r.sym and r.sym.name or "*none*"
				local a = r.addend or 0

				if nm == "" and r.sym and r.sym.sec then
					nm = r.sym.sec.name
				end
				io.write(("%016x %-16s  %s%s\n"):format(r.off,
					r.name, nm,
					a ~= 0 and ("%s0x%016x"):format(
						a < 0 and "-" or "+",
						a < 0 and -a or a) or ""))
			end
			io.write("\n")
		end
	end
	io.write("\n")
end

-- The instructions around one address, with a word about whether the
-- name beside them is to be trusted.
local function around(f, addr)
	local w, err = dis.window(f, addr, o.context)

	if not w then die(err) end
	local loc = w.loc

	io.write(("%#x is %s+%#x in %s\n"):format(addr, loc.name or "?",
		loc.off or 0, w.sec.name))
	if not loc.sure then
		io.write("warning: uncertain -- ", loc.why or "", "\n")
	end
	local width = hexwidth(addr)

	for k, e in ipairs(w.list) do
		local text = insline(f, width, e.addr, e.ins, w.sec)

		-- An instruction too long for one line of bytes keeps
		-- the mark's indent on the lines that follow.
		io.write(k == w.at and "=> " or "   ",
			(text:gsub("\n", "\n   ")), "\n")
	end
end

-- One object: the file itself, or a member of an archive at an offset
-- inside it.  `shown` is the name objdump prints above it, which for a
-- member is the archive and the member together.
local function dump(path, at0, shown)
	local f, err = elfread.open(path, at0)

	if not f then die(err) end
	io.write(("\n%s:     file format %s\n"):format(shown,
		FORMAT[f.arch] or f.arch))
	if o.info then
		io.write(("architecture: %s, address size %d\nstart address %#x\n")
			:format(f.arch, f.class, f.entry))
	end
	if o.headers then headers(f) end
	if o.syms then symbols(f) end
	if o.reloc then relocs(f) end
	if o.at then around(f, o.at) end
	if o.dis then
		local top = 0

		for _, s in ipairs(f.sections) do
			top = math.max(top, s.addr + s.size)
		end
		local w = hexwidth(top)

		io.write("\n")
		for _, s in ipairs(f.sections) do
			local code = s.flags & elfread.SHF.exec ~= 0
			local keep = o.only and s.name == o.only or
				(not o.only and (o.all and
				 s.flags & elfread.SHF.alloc ~= 0 or code))

			if keep and s.size > 0 and s.typ ~= "nobits" then
				section(f, s, w)
			end
		end
	end
	f:close()
end

for _, path in ipairs(files) do
	-- An archive is read a member at a time, the way objdump reads
	-- one.
	local members = ar.members(path)

	if members then
		io.write(("In archive %s:\n"):format(path))
		for _, m in ipairs(members) do
			dump(path, m.off, m.name)
		end
	else
		dump(path, 0, path)
	end
end
