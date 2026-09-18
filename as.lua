-- An assembler for what this compiler emits.
--
-- Not a general assembler: it reads the subset the targets produce, which is
-- small enough to run on the machine the code is for, and near enough to the
-- real thing that `test/as.lua` can assemble every file twice and compare
-- the bytes.  This file holds what every machine shares -- sections, labels,
-- relocations, directives and the passes.  The encoding lives in `as/`.
--
-- The output is sections of bytes plus a symbol table and a list of places
-- that still need an address.  `ld.lua` turns that into something to run.

local buf = require "buf"

local as = {}

local ARCH = {
	riscv = "as.riscv", riscv32 = "as.riscv", riscv64 = "as.riscv",
	xtensa = "as.xtensa", amd64 = "as.amd64", arm64 = "as.arm64",
}

-- parsing --------------------------------------------------------------

local function split(s)
	local out = {}
	for w in s:gmatch("[^,]+") do out[#out + 1] = w:match("^%s*(.-)%s*$") end
	return out
end

local function unescape(s)
	local out, i = {}, 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			local d = s:sub(i + 1, i + 3)
			local o = d:match("^%d%d%d")
			if o then
				out[#out + 1] = string.char(tonumber(o, 8))
				i = i + 4
			else
				out[#out + 1] = s:sub(i + 1, i + 1)
				i = i + 2
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

as.split = split
as.unescape = unescape

local Asm = {}
Asm.__index = Asm

function as.new(opt)
	if type(opt) == "number" then opt = {xlen = opt} end
	opt = opt or {}
	local name = opt.arch or (opt.xlen == 32 and "riscv32" or "riscv64")
	local a = setmetatable({
		xlen = opt.xlen or (name == "riscv32" and 32 or 64),
		arch = require(ARCH[name] or error("no assembler for " .. name)),
		sec = {},		-- name -> section
		order = {},		-- the order they first appeared
		syms = {},		-- name -> {sec, off, global}
		long = {},		-- branches that need the long form
		cur = nil,
	}, Asm)
	if a.arch.init then a.arch.init(a) end
	return a
end

function Asm:section(name, bss)
	local s = self.sec[name]
	if not s then
		s = {name = name, off = 0, align = 1, bss = bss or false,
		     out = buf.new(), relocs = {}}
		self.sec[name] = s
		self.order[#self.order + 1] = s
	end
	self.cur = s
	return s
end

function Asm:emit(word, n)
	local s = self.cur
	if self.pass == 2 and not s.bss then
		local b = {}
		for i = 0, n - 1 do b[i + 1] = string.char(word >> (8 * i) & 255) end
		s.out:add(table.concat(b))
	end
	s.off = s.off + n
end

function Asm:bytes(str)
	local s = self.cur
	if self.pass == 2 and not s.bss then s.out:add(str) end
	s.off = s.off + #str
end

function Asm:space(n)
	local s = self.cur
	if self.pass == 2 and not s.bss then s.out:add(string.rep("\0", n)) end
	s.off = s.off + n
end

function Asm:align(n)
	local pad = (-self.cur.off) % n
	if self.cur.align < n then self.cur.align = n end
	if pad > 0 then self:space(pad) end
end

function Asm:label(name)
	if self.pass < 2 then
		self.syms[name] = self.syms[name] or {}
		self.syms[name].sec = self.cur
		self.syms[name].off = self.cur.off
	end
end

function Asm:global(name)
	self.syms[name] = self.syms[name] or {}
	self.syms[name].global = true
end

-- Where a symbol is, once the sections have addresses.  During pass two
-- the sections do not have them yet, so a reference to one is recorded and
-- filled in by the linker.
-- Only the pass that emits bytes records these.  The passes that place
-- labels run more than once, and what they wrote down was for offsets that
-- have since moved.
function Asm:reloc(kind, sym, addend, pair)
	if self.pass ~= 2 then return end
	self.cur.relocs[#self.cur.relocs + 1] = {
		off = self.cur.off, kind = kind, sym = sym,
		addend = addend or 0, pair = pair,
	}
end

-- A branch or jump to a label in the same section needs no help from the
-- linker: the distance between two offsets does not move.
function Asm:here(sym)
	local d = self.syms[sym]
	if d and d.sec == self.cur then return d.off - self.cur.off end
	return nil
end

-- The same, but only for a label this file owns.  A global may be replaced
-- by another unit at link time, so a jump to one keeps its relocation even
-- when the definition is right here.
function Asm:localhere(sym)
	local d = self.syms[sym]
	if d and d.global then return nil end
	return self:here(sym)
end

function Asm:inst(m, ops)
	return self.arch.inst(self, m, ops)
end

-- directives and the two passes ---------------------------------------

local DSIZE = {byte = 1, short = 2, long = 4, quad = 8}

-- A data item is a number, a symbol, or a symbol plus or minus a number.
function Asm:datum(size, text)
	local v = tonumber(text)
	if v then return self:emit(v, size) end
	local sym, sign, off = text:match("^([%w.$_]+)%s*([+-])%s*(%w+)$")
	local addend = 0
	if sym then
		addend = tonumber(off) * (sign == "-" and -1 or 1)
	else
		sym = text:match("^([%w.$_]+)$")
	end
	if not sym then error("bad data item '" .. text .. "'") end
	self:reloc(size == 8 and "abs64" or "abs32", sym, addend)
	self:emit(0, size)
end

function Asm:directive(d, rest)
	if self.arch.directive and self.arch.directive(self, d, rest) then
		return
	end
	if d == "text" or d == "data" then
		self:section("." .. d)
	elseif d == "bss" then
		self:section(".bss", true)
	elseif d == "section" then
		local name = rest:match("^([%w._$]+)")
		self:section(name, name == ".bss")
	elseif d == "globl" or d == "global" then
		self:global(rest)
	elseif d == "balign" or d == "align" then
		self:align(tonumber(rest))
	elseif d == "zero" or d == "space" then
		self:space(tonumber(rest))
	elseif d == "ascii" or d == "asciz" then
		local str = rest:match('^"(.*)"$')
		self:bytes(unescape(str))
		if d == "asciz" then self:bytes("\0") end
	elseif DSIZE[d] then
		for _, item in ipairs(split(rest)) do
			self:datum(DSIZE[d], item)
		end
	elseif d == "type" or d == "size" or d == "file" or
	       d == "ident" or d == "local" or d == "option" then
		-- nothing here needs them
	else
		error("no directive ." .. d)
	end
end

function Asm:line(l)
	-- comments, in either spelling
	l = l:gsub("/%*.-%*/", " ")
	l = l:gsub("^%s*[/*#].*$", "")
	local label = l:match("^([%w.$_]+):%s*$")
	if label then return self:label(label) end
	local body = l:match("^%s+(.*)$")
	if not body or body == "" then return end
	body = body:match("^(.-)%s*$")
	if body == "" then return end
	local word, rest = body:match("^(%S+)%s*(.*)$")
	rest = rest:match("^%s*(.-)%s*$")
	if word:sub(1, 1) == "." then
		return self:directive(word:sub(2), rest)
	end
	self:inst(word, split(rest))
end

function Asm:run(text, pass)
	self.pass = pass
	self.cur = nil
	self.nbr = 0
	for _, s in ipairs(self.order) do s.off = 0 end
	if self.arch.startpass then self.arch.startpass(self, pass) end
	self:section(".text")
	local n = 0
	local incomment = false
	for l in text:gmatch("[^\n]*") do
		n = n + 1
		if incomment then
			local rest = l:match("%*/(.*)$")
			if rest then
				incomment = false
				l = rest
			else
				l = ""
			end
		end
		if l:find("/%*") and not l:find("%*/") then
			l = l:gsub("/%*.*$", "")
			incomment = true
		end
		if l ~= "" then
			local ok, err = pcall(self.line, self, l)
			if not ok then
				error(("line %d: %s\n  %s"):format(n, err, l), 0)
			end
		end
	end
	if self.arch.endpass then self.arch.endpass(self, pass) end
	for _, s in ipairs(self.order) do s.size = s.off end
end

-- Assemble a whole file.  Two passes: the first places every label, the
-- second emits the bytes, which it can do because nothing here changes size
-- once its operands are known.
function as.assemble(text, opt)
	local a = as.new(opt)
	-- Place the labels, then again if a branch turned out too far to
	-- reach or a constant pool changed size, because either moves
	-- everything after it.
	repeat
		a.changed = false
		-- A form that turns out too short is written down and
		-- widened after the pass, not during it.  Widening one
		-- moves everything after it, and a pass that moved while
		-- it measured would make the next jump look further away
		-- than it is -- and a form once widened is never narrowed.
		a.pending = {}
		-- Two sweeps with the same sizes: the first places every
		-- label, the second measures against them.  One sweep
		-- would measure a label further down the file against the
		-- round before, which moved.
		a:run(text, 0)
		a:run(text, 1)
		for id in pairs(a.pending) do
			if not a.long[id] then
				a.long[id] = true
				a.changed = true
			end
		end
	until not a.changed
	a:run(text, 2)
	for _, s in ipairs(a.order) do
		s.bytes = s.bss and "" or s.out:text()
	end
	return a
end

return as
