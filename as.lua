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

-- Operands, which a comma separates except inside brackets: an x86
-- index form and an arm64 place both hold one.
local function split(s)
	local out, at, depth = {}, 1, 0

	for i = 1, #s do
		local c = s:sub(i, i)

		if c == "(" or c == "[" then
			depth = depth + 1
		elseif c == ")" or c == "]" then
			depth = depth - 1
		elseif c == "," and depth == 0 then
			out[#out + 1] = s:sub(at, i - 1):match("^%s*(.-)%s*$")
			at = i + 1
		end
	end
	local last = s:sub(at):match("^%s*(.-)%s*$")

	if last ~= "" then out[#out + 1] = last end
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
		aliases = {},		-- names given the place of another
		long = {},		-- branches that need the long form
		cur = nil,
	}, Asm)
	if a.arch.init then a.arch.init(a) end
	return a
end

-- `perm` is what may be done with the section: read is 4, write 2,
-- execute 1, the way a program header spells it.  A section that does
-- not say takes what its name usually means.
local NAMEPERM = {[".text"] = 5, [".init"] = 5, [".reset"] = 5,
		  [".rodata"] = 4}

function Asm:section(name, bss, perm)
	local s = self.sec[name]
	if not s then
		s = {name = name, off = 0, align = 1, bss = bss or false,
		     perm = perm or NAMEPERM[name] or 6,
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

-- Where a system call instruction stands, and which call it makes.
-- OpenBSD will not let a program make one from anywhere it has not been
-- told about ahead of time, so the assembler notes each one as it goes.
function Asm:syscallsite(sysno)
	if self.pass ~= 2 or not sysno then return end
	local t = self.cur.syscalls or {}

	self.cur.syscalls = t
	t[#t + 1] = {off = self.cur.off, sysno = sysno}
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

-- Forward: an assignment is a directive, and the expression parser is
-- defined further down with the rest of the scanning.
local evalexpr

-- Take out a `#` comment, which runs to the end of the line.  A `#` in
-- a string is not one, and neither is one in a character literal.
local function uncomment(l)
	local q = nil

	for i = 1, #l do
		local c = l:sub(i, i)

		if q then
			if c == "\\" then q = q
			elseif c == q then q = nil end
		elseif c == '"' or c == "'" then
			q = c
		elseif c == "#" then
			return l:sub(1, i - 1)
		end
	end
	return l
end

-- directives and the two passes ---------------------------------------

local DSIZE = {byte = 1, short = 2, long = 4, quad = 8}

-- A data item is a number, a symbol, or a symbol plus or minus a number.
function Asm:datum(size, text)
	local v = tonumber(text)
	if v then return self:emit(v, size) end
	text = text:match("^%s*(.-)%s*$")
	-- A name .set to a number stands for that number here.
	local d = self.syms[text]

	if d and d.abs then return self:emit(d.abs, size) end
	-- The distance between two labels in one section, which a table
	-- of patch sites writes to say how long each one is.
	local a, b = text:match("^%(?%s*([%w.$_]+)%s*%-%s*([%w.$_]+)%s*%)?$")

	if a then
		local da = self.syms[self:numref(a)]
		local db = self.syms[self:numref(b)]

		if da and db and da.sec and da.sec == db.sec then
			return self:emit(da.off - db.off, size)
		end
	end
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

-- `.set name, expr` and `name = expr`.  The value is a number, or
-- another symbol this one stands for.
function Asm:assign(name, rest)
	rest = rest:match("^%s*(.-)%s*$")
	local v = tonumber(rest) or evalexpr(rest)

	self.syms[name] = self.syms[name] or {}
	if v then
		self.syms[name].abs = v
		self.syms[name].sec = nil
		return
	end
	-- The symbol it stands for may not be here yet, so the answer
	-- waits until the pass is over.
	self.syms[name].alias = rest
	self.aliases[#self.aliases + 1] = name
end

-- Give every alias the place of the symbol it names.  A chain of them
-- settles because the list is walked until nothing more changes.
function Asm:settle()
	local again = true

	while again do
		again = false
		for _, name in ipairs(self.aliases) do
			local d = self.syms[name]
			local o = self.syms[d.alias]

			if o and (o.sec or o.abs) and not d.sec and
			   not d.abs then
				d.sec, d.off, d.abs = o.sec, o.off, o.abs
				again = true
			end
		end
	end
end

function Asm:directive(d, rest)
	if self.arch.directive and self.arch.directive(self, d, rest) then
		return
	end
	if d == "text" or d == "data" then
		self:section("." .. d)
	elseif d == "bss" then
		self:section(".bss", true)
	elseif d == "popsection" or d == "previous" then
		local st = self.secstack

		if not st or #st == 0 then
			error("." .. d .. " with nothing pushed")
		end
		self.cur = st[#st]
		st[#st] = nil
	elseif d == "section" or d == "pushsection" then
		if d == "pushsection" then
			local st = self.secstack

			if not st then st = {}; self.secstack = st end
			st[#st + 1] = self.cur
		end
		-- a section name may hold anything but a comma or a
		-- space, and .note.GNU-stack holds a dash
		local name = rest:match("^([^,%s]+)")
		local fl = rest:match('"([^"]*)"')
		local perm

		if fl then
			perm = 4
			if fl:find("w", 1, true) then perm = perm | 2 end
			if fl:find("x", 1, true) then perm = perm | 1 end
		end
		self:section(name, name == ".bss" or
			rest:find("@nobits", 1, true) ~= nil, perm)
	elseif d == "set" or d == "equ" then
		local name, rhs = rest:match("^%s*([%w.$_]+)%s*,%s*(.+)$")

		if not name then error("bad ." .. d) end
		self:assign(name, rhs)
	elseif d == "code64" then
		-- long mode is the only mode this assembler has
	elseif d == "globl" or d == "global" then
		self:global(rest)
	elseif d == "balign" or d == "align" or d == "p2align" then
		-- the fill byte and the maximum skip, if given, change
		-- nothing here: the gap is zeroed either way
		local n = tonumber((rest:match("^[^,]*")))

		if d == "p2align" then n = 1 << (n or 0) end
		self:align(n or 1)
	elseif d == "zero" or d == "space" then
		self:space(tonumber((rest:match("^[^,]*"))) or 0)
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

-- Take out block comments, but not what is inside a string: an assembler
-- string may hold "/*" and a C source full of glob patterns does.
-- Answers the line and whether a comment is still open at the end of it.
local function decomment(l, open)
	local out, i, n = {}, 1, #l

	while i <= n do
		local two = l:sub(i, i + 1)

		if open then
			if two == "*/" then
				open = false
				i = i + 2
			else
				i = i + 1
			end
		elseif l:sub(i, i) == '"' then
			local j = i + 1

			while j <= n do
				local d = l:sub(j, j)
				if d == "\\" then j = j + 2
				elseif d == '"' then break
				else j = j + 1 end
			end
			out[#out + 1] = l:sub(i, j)
			i = j + 1
		elseif two == "/*" then
			open = true
			out[#out + 1] = " "
			i = i + 2
		else
			out[#out + 1] = l:sub(i, i)
			i = i + 1
		end
	end
	return table.concat(out), open
end

as.decomment = decomment

-- A constant expression in an operand, which an assembler is expected
-- to work out: `$(16*8)` and the like.  Answers nil for anything that
-- names a symbol, so the caller can fall back to a relocation.
function evalexpr(s)
	local at = 1

	local function ws() at = s:find("%S", at) or #s + 1 end
	local function want(c)
		ws()
		if s:sub(at, at + #c - 1) == c then
			at = at + #c
			return true
		end
	end
	local sum

	local function atom()
		ws()
		if want("(") then
			local v = sum()

			if not v or not want(")") then return nil end
			return v
		end
		if want("-") then
			local v = atom()

			return v and -v
		end
		if want("~") then
			local v = atom()

			return v and ~v
		end
		if want("+") then return atom() end
		local t = s:match("^0[xX]%x+", at)
		local b = not t and s:match("^0[bB][01]+", at)

		if b then
			at = at + #b
			return tonumber(b:sub(3), 2)
		end
		t = t or s:match("^%d+", at)
		if not t then return nil end
		at = at + #t
		return tonumber(t)
	end

	local function product()
		local a = atom()

		while a do
			ws()
			if want("*") then
				local b = atom()

				if not b then return nil end
				a = a * b
			elseif s:sub(at, at) == "/" then
				at = at + 1
				local b = atom()

				if not b or b == 0 then return nil end
				a = a // b
			else
				return a
			end
		end
		return a
	end

	function sum()
		local a = product()

		while a do
			ws()
			if want("<<") then
				local b = product()

				if not b then return nil end
				a = a << b
			elseif want(">>") then
				local b = product()

				if not b then return nil end
				a = a >> b
			elseif want("+") then
				local b = product()

				if not b then return nil end
				a = a + b
			elseif s:sub(at, at) == "-" then
				at = at + 1
				local b = product()

				if not b then return nil end
				a = a - b
			elseif want("|") then
				local b = product()

				if not b then return nil end
				a = a | b
			elseif want("&") then
				local b = product()

				if not b then return nil end
				a = a & b
			else
				return a
			end
		end
		return a
	end

	local v = sum()

	ws()
	if at <= #s then return nil end
	return v
end

as.evalexpr = evalexpr

-- Split a line on the semicolons that separate statements, leaving
-- alone any inside a string.
function as.statements(l)
	if not l:find(";", 1, true) then return {l} end
	local out, at, q = {}, 1, false

	for i = 1, #l do
		local c = l:sub(i, i)

		if c == '"' and l:sub(i - 1, i - 1) ~= "\\" then
			q = not q
		elseif c == ";" and not q then
			out[#out + 1] = l:sub(at, i - 1)
			at = i + 1
		end
	end
	out[#out + 1] = l:sub(at)
	-- what follows a separator is an instruction, so it is indented
	for i = 2, #out do
		if not out[i]:match("^[ \t]") then
			out[i] = "\t" .. out[i]
		end
	end
	return out
end

-- A numeric label may be written again and again; a reference says
-- which one by direction.  Each is given a name of its own here.
local function numname(n, k)
	return (".Lnum%s_%d"):format(n, k)
end

function Asm:numlabel(n)
	self.nums[n] = (self.nums[n] or 0) + 1
	return numname(n, self.nums[n])
end

function Asm:numref(body)
	if not body:find("%d[fb]") then return body end
	return (body:gsub("(%f[%w])(%d+)([fb])(%f[%W])", function(_, n, d, _)
		local k = self.nums[n] or 0

		return numname(n, d == "f" and k + 1 or k)
	end))
end

function Asm:line(l)
	-- a whole line of comment, in any of the spellings
	l = l:gsub("^%s*[/*#].*$", "")
	-- On a machine where `#` starts a comment it starts one anywhere;
	-- on arm64 it marks an immediate instead.
	if self.arch.hash then l = uncomment(l) end
	-- Labels, which an asm template may leave indented and which may
	-- be followed by an instruction on the same line.
	while true do
		local label, after = l:match("^%s*([%w.$_]+):%s*(.*)$")

		if not label then break end
		if label:match("^%d+$") then
			self:label(self:numlabel(label))
		else
			self:label(label)
		end
		if after == "" then return end
		l = "\t" .. after
	end
	-- `name = expr` names a value or another symbol, the same as .set
	local nm, rhs = l:match("^%s*([%a._$][%w.$_]*)%s*=%s*(.+)$")

	if nm then return self:assign(nm, rhs) end
	-- An instruction or a directive need not be indented: the
	-- preprocessor writes a token at the column it came from.
	local body = l:match("^%s*(.*)$")
	if not body or body == "" then return end
	body = body:match("^(.-)%s*$")
	if body == "" then return end
	local word, rest = body:match("^(%S+)%s*(.*)$")
	rest = rest:match("^%s*(.-)%s*$")
	if word:sub(1, 1) == "." then
		-- a directive's operand may be a string, which a numeric
		-- label reference must not be looked for inside
		return self:directive(word:sub(2), rest)
	end
	self:inst(word, split(self:numref(rest)))
end

function Asm:run(text, pass)
	self.pass = pass
	self.cur = nil
	self.nbr = 0
	self.nums = {}
	for _, s in ipairs(self.order) do s.off = 0 end
	if self.arch.startpass then self.arch.startpass(self, pass) end
	self:section(".text")
	local n = 0
	local incomment = false
	for l in text:gmatch("[^\n]*") do
		n = n + 1
		if incomment or l:find("/%*", 1, false) then
			l, incomment = decomment(l, incomment)
		end
		-- A semicolon separates two instructions on one line,
		-- which is how a C program writes more than one in an
		-- asm template.
		if l ~= "" then
			for _, part in ipairs(as.statements(l)) do
				local ok, err = pcall(self.line, self, part)

				if not ok then
					error(("line %d: %s\n  %s")
						:format(n, err, part), 0)
				end
			end
		end
	end
	if self.arch.endpass then self.arch.endpass(self, pass) end
	self:settle()
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
