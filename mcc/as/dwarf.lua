-- SPDX-License-Identifier: ISC
-- The DWARF 5 line table that `.file` and `.loc` describe, laid out as
-- gas lays it out, so the two assemblers agree byte for byte.
-- A row goes down at the first instruction after each `.loc`.  After
-- the last pass, `finish` writes one sequence per section into
-- .debug_line and the file names into .debug_line_str.

local dwarf = {}

-- The line program's constants, which are what gas picks.
local LINE_BASE, LINE_RANGE, OPCODE_BASE = -5, 14, 13
local MAX_SPECIAL_ADDR = (255 - OPCODE_BASE) // LINE_RANGE
local STDLEN = {0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1}

local DW_LNS_copy, DW_LNS_advance_pc, DW_LNS_advance_line = 1, 2, 3
local DW_LNS_set_file, DW_LNS_set_column, DW_LNS_negate_stmt = 4, 5, 6
local DW_LNS_basic_block, DW_LNS_const_add_pc = 7, 8
local DW_LNS_set_prologue_end, DW_LNS_set_epilogue_begin = 10, 11
local DW_LNS_set_isa = 12
local DW_LNE_end_sequence, DW_LNE_set_address = 1, 2
local DW_LNE_set_discriminator = 4
local DW_LNCT_path, DW_LNCT_directory_index = 1, 2
local DW_FORM_line_strp, DW_FORM_udata = 0x1f, 0x0f

-- The targets whose addresses are four bytes.
local NARROW = {i386 = true, riscv32 = true, xtensa = true}

local function uleb(v)
	local b = {}

	repeat
		local c = v & 0x7f

		v = v >> 7
		b[#b + 1] = string.char(v ~= 0 and (c | 0x80) or c)
	until v == 0
	return table.concat(b)
end

local function sleb(v)
	local b = {}

	while true do
		local c = v & 0x7f

		v = v // 128
		if (v == 0 and c & 0x40 == 0) or (v == -1 and c & 0x40 ~= 0)
		then
			b[#b + 1] = string.char(c)
			return table.concat(b)
		end
		b[#b + 1] = string.char(c | 0x80)
	end
end

local function u(v, n) return string.pack("<I" .. n, v) end

function dwarf.new()
	return {files = {}, dirs = {}, ndirs = 0, rows = {}, stmt = true}
end

-- The number of a directory, which is added if it is new.  One
-- slash at the end is not part of the name.  gas numbers a new one
-- from 1 even while 0 is still empty.
local function dirof(d, dir)
	dir = dir:gsub("/$", "")
	if dir == "" then return 0 end
	for i = 0, d.ndirs - 1 do
		if d.dirs[i] == dir then return i end
	end
	local i = math.max(d.ndirs, 1)

	d.dirs[i], d.ndirs = dir, i + 1
	return i
end

-- The quoted strings on a line, and what follows the last one.
local function quoted(s, unescape)
	local out, i = {}, 1

	while true do
		local a = s:find('"', i, true)

		if not a then break end
		local j = a + 1

		while j <= #s and s:sub(j, j) ~= '"' do
			if s:sub(j, j) == "\\" then j = j + 1 end
			j = j + 1
		end
		out[#out + 1] = unescape(s:sub(a + 1, j - 1))
		i = j + 1
	end
	return out, s:sub(i)
end

-- `.file N "name"` or `.file N "dir" "name"`.  Answers false for the
-- form with no number, which names the source for the symbol table.
-- A name with no directory of its own is split at its last slash.
-- The directory of `.file 0` is directory 0.
function dwarf.file(d, rest, unescape)
	local n, tail = rest:match("^%s*(%d+)%s+(.*)$")

	if not n then return false end
	local q = quoted(tail, unescape)

	n = tonumber(n)
	if #q == 0 then error(".file " .. n .. " names no file") end
	if d.files[n] then return true end
	local dir, name = q[2] and q[1] or nil, q[2] or q[1]

	if n == 0 and dir then
		d.dirs[0] = dir
		d.ndirs = math.max(d.ndirs, 1)
		dir = nil
	end
	if not dir then
		dir, name = name:match("^(.*/)([^/]*)$")
		if not dir then dir, name = "", q[2] or q[1] end
	end
	d.files[n] = {name = name, dir = dirof(d, dir)}
	return true
end

-- `.loc file line [column] [option value]...`.  The answer is the row
-- still to be placed.  is_stmt holds until another .loc changes it;
-- the other options are for this row alone.
function dwarf.loc(d, rest)
	local w = {}

	for t in rest:gmatch("%S+") do w[#w + 1] = t end
	local file, line = tonumber(w[1]), tonumber(w[2])

	if not file or not line then error("bad .loc " .. rest) end
	local r = {file = file, line = line, col = 0, disc = 0, isa = 0}
	local i = 3

	if tonumber(w[3]) then
		r.col = tonumber(w[3])
		i = 4
	end
	while w[i] do
		local o = w[i]

		if o == "basic_block" then
			r.bb = true
		elseif o == "prologue_end" then
			r.pe = true
		elseif o == "epilogue_begin" then
			r.eb = true
		elseif o == "is_stmt" or o == "isa" or
		       o == "discriminator" or o == "view" then
			local v = tonumber(w[i + 1])

			i = i + 1
			if o == "is_stmt" then
				if v ~= 0 and v ~= 1 then
					error("is_stmt takes 0 or 1")
				end
				d.stmt = v == 1
			elseif o == "isa" then
				r.isa = v or error("bad isa")
			elseif o == "discriminator" then
				r.disc = v or error("bad discriminator")
			end
		else
			error("unknown .loc option " .. o)
		end
		i = i + 1
	end
	r.stmt = d.stmt
	return r
end

-- One step of the line program: gas's emit_inc_line_addr.  A line
-- delta of nil ends the sequence.
local function step(out, dline, daddr)
	if dline == nil then
		if daddr == MAX_SPECIAL_ADDR then
			out[#out + 1] = string.char(DW_LNS_const_add_pc)
		elseif daddr ~= 0 then
			out[#out + 1] = string.char(DW_LNS_advance_pc) ..
				uleb(daddr)
		end
		out[#out + 1] = "\0\1" .. string.char(DW_LNE_end_sequence)
		return
	end
	local tmp = dline - LINE_BASE
	local copy = false

	if tmp < 0 or tmp >= LINE_RANGE then
		out[#out + 1] = string.char(DW_LNS_advance_line) .. sleb(dline)
		dline, tmp, copy = 0, -LINE_BASE, true
	end
	if dline == 0 and daddr == 0 then
		out[#out + 1] = string.char(DW_LNS_copy)
		return
	end
	tmp = tmp + OPCODE_BASE
	if daddr < 256 + MAX_SPECIAL_ADDR then
		local op = tmp + daddr * LINE_RANGE

		if op <= 255 then
			out[#out + 1] = string.char(op)
			return
		end
		op = tmp + (daddr - MAX_SPECIAL_ADDR) * LINE_RANGE
		if op <= 255 then
			out[#out + 1] = string.char(DW_LNS_const_add_pc, op)
			return
		end
	end
	out[#out + 1] = string.char(DW_LNS_advance_pc) .. uleb(daddr)
	out[#out + 1] = string.char(copy and DW_LNS_copy or tmp)
end

-- The directory and file tables.  With no `.file 0`, file 0 is file 1
-- and directory 0 the one the assembler runs in.
local function tables(d)
	local dirs, files = {}, {}
	local maxn = 0

	for n in pairs(d.files) do
		if n > maxn then maxn = n end
	end
	for i = 0, d.ndirs - 1 do
		dirs[i + 1] = d.dirs[i] or os.getenv("PWD") or "."
	end
	for n = 0, maxn do
		files[n + 1] = d.files[n] or (n == 0 and d.files[1]) or
			{name = "", dir = 0}
	end
	return dirs, files
end

-- Find or make a section that is not the one in hand.
local function section(a, name, merge)
	local s = a.sec[name]

	if not s then
		local cur, prev = a.cur, a.prevsec

		s = a:section(name, false, 0, merge, merge and 1 or nil)
		a.cur, a.prevsec = cur, prev
		if merge then s.strings = true end
	end
	return s
end

-- A name for the start of a section, which a relocation can point at.
local function base(a, s)
	local nm = ".L.dwarf." .. s.name

	a.syms[nm] = {sec = s, off = 0}
	return nm
end

function dwarf.finish(a, d)
	if #d.rows == 0 then return end
	local W = NARROW[a.target] and 4 or 8
	local abs = W == 8 and "abs64" or "abs32"
	local line = section(a, ".debug_line")
	local str = section(a, ".debug_line_str", true)
	local strbase = base(a, str)
	local at = line.off
	local head, relocs = {}, {}

	local function put(s) head[#head + 1] = s end
	-- A line string: its bytes go to the end of .debug_line_str,
	-- and its offset there into the header.
	local function strp(s)
		relocs[#relocs + 1] = {off = at + #table.concat(head),
			kind = "abs32", sym = strbase, addend = str.off}
		str.out:add(s .. "\0")
		str.off = str.off + #s + 1
		put(u(0, 4))
	end
	local dirs, files = tables(d)

	put(u(0, 4))				-- unit_length
	put(u(5, 2))				-- version
	put(string.char(W, 0))
	put(u(0, 4))				-- header_length
	put(string.char(1, 1, 1, LINE_BASE & 255, LINE_RANGE,
			OPCODE_BASE))
	put(string.char(table.unpack(STDLEN)))
	put(string.char(1, DW_LNCT_path, DW_FORM_line_strp))
	put(uleb(#dirs))
	for _, x in ipairs(dirs) do strp(x) end
	put(string.char(2, DW_LNCT_path, DW_FORM_line_strp,
			DW_LNCT_directory_index, DW_FORM_udata))
	put(uleb(#files))
	for _, f in ipairs(files) do
		strp(f.name)
		put(uleb(f.dir))
	end
	local hlen = #table.concat(head) - 12

	-- One sequence for each section, in the order each first had a
	-- row.
	local order, bysec = {}, {}

	for _, r in ipairs(d.rows) do
		if not bysec[r.sec] then
			bysec[r.sec] = {}
			order[#order + 1] = r.sec
		end
		local t = bysec[r.sec]

		t[#t + 1] = r
	end
	local prog = {}

	for _, s in ipairs(order) do
		local file, ln, col, stmt, isa = 1, 1, 0, true, 0
		local addr

		for _, r in ipairs(bysec[s]) do
			if r.file ~= file then
				prog[#prog + 1] = string.char(DW_LNS_set_file)
					.. uleb(r.file)
				file = r.file
			end
			if r.col ~= col then
				prog[#prog + 1] = string.char(
					DW_LNS_set_column) .. uleb(r.col)
				col = r.col
			end
			if r.disc ~= 0 then
				local v = uleb(r.disc)

				prog[#prog + 1] = "\0" .. uleb(#v + 1) ..
					string.char(DW_LNE_set_discriminator)
					.. v
			end
			if r.isa ~= isa then
				prog[#prog + 1] = string.char(DW_LNS_set_isa)
					.. uleb(r.isa)
				isa = r.isa
			end
			if r.stmt ~= stmt then
				prog[#prog + 1] = string.char(
					DW_LNS_negate_stmt)
				stmt = r.stmt
			end
			if r.bb then
				prog[#prog + 1] = string.char(
					DW_LNS_basic_block)
			end
			if r.pe then
				prog[#prog + 1] = string.char(
					DW_LNS_set_prologue_end)
			end
			if r.eb then
				prog[#prog + 1] = string.char(
					DW_LNS_set_epilogue_begin)
			end
			if not addr then
				prog[#prog + 1] = "\0" .. uleb(W + 1) ..
					string.char(DW_LNE_set_address)
				local off = #table.concat(head) +
					#table.concat(prog)

				relocs[#relocs + 1] = {off = at + off,
					kind = abs, sym = base(a, s),
					addend = r.off}
				prog[#prog + 1] = u(0, W)
				addr = r.off
			end
			step(prog, r.line - ln, r.off - addr)
			ln, addr = r.line, r.off
		end
		step(prog, nil, s.size - addr)
	end
	local body = table.concat(head) .. table.concat(prog)

	body = u(#body - 4, 4) .. body:sub(5, 6) .. body:sub(7, 8) ..
		u(hlen, 4) .. body:sub(13)
	line.out:add(body)
	line.off = line.off + #body
	line.size = line.off
	str.size = str.off
	for _, r in ipairs(relocs) do
		line.relocs[#line.relocs + 1] = r
	end
end

return dwarf
