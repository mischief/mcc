-- SPDX-License-Identifier: ISC
-- The debug information `-g` asks for, as assembler text: a `.loc`
-- before each statement, and a DWARF 5 unit that names each function
-- and the range of code it covers.  The assembler builds the line
-- table from the `.loc` lines.

local dwinfo = {}

local D = {}
D.__index = D

local DW_TAG_compile_unit, DW_TAG_subprogram = 0x11, 0x2e
local DW_AT_name, DW_AT_stmt_list, DW_AT_low_pc = 0x03, 0x10, 0x11
local DW_AT_high_pc, DW_AT_language, DW_AT_comp_dir = 0x12, 0x13, 0x1b
local DW_AT_producer, DW_AT_decl_file, DW_AT_decl_line = 0x25, 0x3a, 0x3b
local DW_AT_external, DW_AT_ranges = 0x3f, 0x55
local DW_FORM_addr, DW_FORM_data8, DW_FORM_string = 0x01, 0x07, 0x08
local DW_FORM_udata, DW_FORM_sec_offset = 0x0f, 0x17
local DW_FORM_flag_present = 0x19
local DW_LANG_C11 = 0x1d
local DW_UT_compile = 0x01
local DW_RLE_end_of_list, DW_RLE_start_end = 0x00, 0x06

-- The abbreviations, by number: the tag, whether it has children, and
-- the attributes in the order a record writes them.
local ABBREV = {
	{DW_TAG_compile_unit, true, {
		{DW_AT_producer, DW_FORM_string},
		{DW_AT_language, 0x0b},			-- data1
		{DW_AT_name, DW_FORM_string},
		{DW_AT_comp_dir, DW_FORM_string},
		{DW_AT_low_pc, DW_FORM_addr},
		{DW_AT_ranges, DW_FORM_sec_offset},
		{DW_AT_stmt_list, DW_FORM_sec_offset}}},
	-- a function other units can call
	{DW_TAG_subprogram, false, {
		{DW_AT_external, DW_FORM_flag_present},
		{DW_AT_name, DW_FORM_string},
		{DW_AT_decl_file, DW_FORM_udata},
		{DW_AT_decl_line, DW_FORM_udata},
		{DW_AT_low_pc, DW_FORM_addr},
		{DW_AT_high_pc, DW_FORM_data8}}},
	-- a static one
	{DW_TAG_subprogram, false, {
		{DW_AT_name, DW_FORM_string},
		{DW_AT_decl_file, DW_FORM_udata},
		{DW_AT_decl_line, DW_FORM_udata},
		{DW_AT_low_pc, DW_FORM_addr},
		{DW_AT_high_pc, DW_FORM_data8}}},
}

-- `name` is the source file as the preprocessor names it, `dir` the
-- directory the compiler runs in, `ptrsize` the width of an address.
function dwinfo.new(name, dir, ptrsize)
	return setmetatable({name = name, dir = dir, ptrsize = ptrsize,
			     files = {[name] = 1}, nfile = 1, funcs = {}},
			    D)
end

-- A string as the assembler reads one.
local function quote(s)
	return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

-- The lines that open the unit: the file of the whole unit, and the
-- directory it was compiled in.
function D:start()
	return ("\t.file 0 %s %s\n\t.file 1 %s\n"):format(quote(self.dir),
		quote(self.name), quote(self.name))
end

-- The directives that put the line `tok` came from on the next
-- instruction.  A file gets its number, and its `.file`, the first
-- time a line names it.
function D:loc(tok)
	local name = tok.file or self.name
	local n = self.files[name]
	local s = ""

	if not n then
		self.nfile = self.nfile + 1
		n = self.nfile
		self.files[name] = n
		s = ("\t.file %d %s\n"):format(n, quote(name))
	end
	return s .. ("\t.loc %d %d\n"):format(n, tok.line or 0)
end

-- The lines that put the line of the opening brace `tok` on the
-- prologue of the function `name`.
function D:func(name, static, tok)
	local s = self:loc(tok)

	self.cur = {name = name, static = static, line = tok.line or 0,
		    file = self.files[tok.file or self.name],
		    endl = (".Ldwfe%d"):format(#self.funcs + 1)}
	return s
end

-- The end of the function in hand: the label that closes its range.
function D:funcend()
	local f = self.cur

	self.cur = nil
	self.funcs[#self.funcs + 1] = f
	return f.endl .. ":\n"
end

local function uleb(v)
	local b = {}

	repeat
		local c = v & 0x7f

		v = v >> 7
		b[#b + 1] = ("0x%x"):format(v ~= 0 and (c | 0x80) or c)
	until v == 0
	return "\t.byte\t" .. table.concat(b, ",") .. "\n"
end

-- The sections that describe the unit.  With no function there is no
-- code to describe and nothing is written.
function D:finish()
	if #self.funcs == 0 then return "" end
	local addr = self.ptrsize == 8 and ".quad" or ".long"
	local o = {}
	local function w(s) o[#o + 1] = s end

	w("\t.section\t.debug_abbrev,\"\",@progbits\n")
	w(".Ldwabbrev:\n")
	for i, a in ipairs(ABBREV) do
		w(uleb(i))
		w(uleb(a[1]))
		w(("\t.byte\t%d\n"):format(a[2] and 1 or 0))
		for _, at in ipairs(a[3]) do
			w(uleb(at[1]))
			w(uleb(at[2]))
		end
		w("\t.byte\t0,0\n")
	end
	w("\t.byte\t0\n")

	w("\t.section\t.debug_info,\"\",@progbits\n")
	w(".Ldwinfo:\n")
	w("\t.long\t.Ldwinfoend-.Ldwinfo-4\n")
	w(("\t.value\t5\n\t.byte\t%d,%d\n"):format(DW_UT_compile,
		self.ptrsize))
	w("\t.long\t.Ldwabbrev\n")
	w(uleb(1))
	w("\t.string\t" .. quote("mcc") .. "\n")
	w(("\t.byte\t%d\n"):format(DW_LANG_C11))
	w("\t.string\t" .. quote(self.name) .. "\n")
	w("\t.string\t" .. quote(self.dir) .. "\n")
	w("\t" .. addr .. "\t0\n")
	w("\t.long\t.Ldwranges\n")
	w("\t.long\t.Ldwline\n")
	for _, f in ipairs(self.funcs) do
		w(uleb(f.static and 3 or 2))
		w("\t.string\t" .. quote(f.name) .. "\n")
		w(uleb(f.file or 1))
		w(uleb(f.line))
		w(("\t%s\t%s\n"):format(addr, f.name))
		w(("\t.quad\t%s-%s\n"):format(f.endl, f.name))
	end
	w("\t.byte\t0\n")
	w(".Ldwinfoend:\n")

	w("\t.section\t.debug_rnglists,\"\",@progbits\n")
	w(".Ldwrl:\n")
	w("\t.long\t.Ldwrlend-.Ldwrl-4\n")
	w(("\t.value\t5\n\t.byte\t%d,0\n\t.long\t0\n"):format(self.ptrsize))
	w(".Ldwranges:\n")
	for _, f in ipairs(self.funcs) do
		w(("\t.byte\t%d\n"):format(DW_RLE_start_end))
		w(("\t%s\t%s\n\t%s\t%s\n"):format(addr, f.name, addr, f.endl))
	end
	w(("\t.byte\t%d\n"):format(DW_RLE_end_of_list))
	w(".Ldwrlend:\n")

	-- The assembler fills this one in from the `.loc` lines.
	w("\t.section\t.debug_line,\"\",@progbits\n")
	w(".Ldwline:\n")
	w("\t.text\n")
	return table.concat(o)
end

return dwinfo
