-- SPDX-License-Identifier: ISC
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
	local out, at, depth, q, esc = {}, 1, 0, false, false

	for i = 1, #s do
		local c = s:sub(i, i)

		if esc then
			esc = false
		elseif c == "\\" then
			esc = true
		elseif q then
			if c == '"' then q = false end
		elseif c == '"' then
			q = true
		elseif c == "(" or c == "[" then
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

-- The escapes an assembler string may hold.  Anything else after a
-- backslash stands for itself, which is what a quote and a backslash
-- need.
local ESC = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
	     t = "\t", v = "\v", e = "\27"}

local function unescape(s)
	local out, i = {}, 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			local d = s:sub(i + 1, i + 1)
			local o = s:sub(i + 1, i + 3):match("^[0-7]+")
			local h = d == "x" and
				s:sub(i + 2):match("^%x%x?") or nil

			if o then
				out[#out + 1] = string.char(tonumber(o, 8))
				i = i + 1 + #o
			elseif h then
				out[#out + 1] = string.char(tonumber(h, 16))
				i = i + 2 + #h
			elseif ESC[d] then
				out[#out + 1] = ESC[d]
				i = i + 2
			else
				out[#out + 1] = d
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

-- What `.type` calls each kind of name.
local STT = {notype = 0, object = 1, ["function"] = 2, func = 2,
	     tls_object = 6, gnu_indirect_function = 10,
	     -- the spellings a kernel writes, which have no sigil and
	     -- sometimes no comma before them
	     STT_NOTYPE = 0, STT_OBJECT = 1, STT_FUNC = 2,
	     STT_TLS = 6, STT_GNU_IFUNC = 10}

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
		regalias = {},		-- names given to a register
		-- Which mode the file starts in.  `-m16` and `-m32` say so
		-- for a file that never writes a `.code` directive of its
		-- own, as a kernel's real mode header does not.
		startbits = opt.bits,
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

-- A section with no flags of its own takes them from its name, the
-- way gas does: anything under .text is code, anything under .data or
-- .bss is writable, anything under .rodata is read only, and a name
-- that is none of those gets nothing at all.  The kernel writes
-- `.section .text..__x86.indirect_thunk` and expects code.
local NAMEPFX = {{".text", 5}, {".rodata", 4}, {".data", 6},
		 {".bss", 6}, {".tdata", 6}, {".tbss", 6}}

local function permof(name)
	if NAMEPERM[name] then return NAMEPERM[name] end
	for _, p in ipairs(NAMEPFX) do
		if name:sub(1, #p[1]) == p[1] then return p[2] end
	end
	return 0
end

function Asm:section(name, bss, perm, merge, entsize)
	local s = self.sec[name]
	if not s then
		s = {name = name, off = 0, align = 1, bss = bss or false,
		     perm = perm or permof(name),
		     merge = merge or nil, entsize = entsize or nil,
		     out = buf.new(), relocs = {}}
		self.sec[name] = s
		self.order[#self.order + 1] = s
	end
	-- `.previous` names whatever was in hand before this one.
	if self.cur and self.cur ~= s then self.prevsec = self.cur end
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

function Asm:space(n, fill)
	local s = self.cur

	if self.pass == 2 and not s.bss then
		s.out:add(string.rep(string.char((fill or 0) & 255), n))
	end
	s.off = s.off + n
end

-- Pad up to a multiple of `n`.  A gap in code must decode, or a
-- validator that reads the section straight through loses the
-- instruction after it, so code pads with nops unless the file names
-- another byte.
function Asm:align(n, fill)
	local pad = (-self.cur.off) % n
	if self.cur.align < n then self.cur.align = n end
	if fill == nil and self.cur.perm & 1 ~= 0 then
		fill = self.arch.codefill
	end
	if pad > 0 then self:space(pad, fill) end
end

function Asm:label(name)
	if self.pass < 2 then
		self.syms[name] = self.syms[name] or {}
		self.syms[name].sec = self.cur
		self.syms[name].off = self.cur.off
	end
end

-- What a name is worth outside the object.  A hidden one never reaches
-- the dynamic table, so a shared object that defines it calls its own
-- and nothing can stand in front of it.
local VIS = {default = 0, internal = 1, hidden = 2, protected = 3}

function Asm:visible(name, how)
	self.syms[name] = self.syms[name] or {}
	self.syms[name].vis = VIS[how]
end

-- A weak name loses to a strong one of the same spelling, and a
-- reference to one that nothing defines is zero rather than an error.
function Asm:weak(name)
	self.syms[name] = self.syms[name] or {}
	self.syms[name].global = true
	self.syms[name].weak = true
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
	-- A name the file defined with `.macro` stands for its body.
	if self.macros[m] then
		return self:invoke(m, table.concat(ops, ","))
	end
	return self.arch.inst(self, m, ops)
end

-- Forward: an assignment is a directive, and the expression parser is
-- defined further down with the rest of the scanning.
local evalexpr

-- Take out a `#` comment, which runs to the end of the line.  A `#` in
-- a string is not one, and neither is one in a character literal.
local function uncomment(l)
	local q, esc = nil, false

	for i = 1, #l do
		local c = l:sub(i, i)

		if esc then
			esc = false
		elseif q then
			if c == "\\" then esc = true
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

-- `.word` is the odd one: two bytes on x86, four everywhere else here.
-- The rest say their width in their name or mean the same on every
-- machine gas assembles for.
local DSIZE = {byte = 1, short = 2, value = 2, hword = 2, long = 4,
	       int = 4, quad = 8, dword = 8, xword = 8,
	       ["2byte"] = 2, ["4byte"] = 4, ["8byte"] = 8}

-- A data expression is a sum of places and numbers.  A place is a label,
-- or `.` for the spot being written.  The sum is kept apart: `n` is what
-- is already a number, `sec` counts how many times each section is added
-- or taken away, and `syms` holds the names that are still unknown.  Two
-- labels in one section cancel, which is how a table of patch sites says
-- how long each entry is; one name left over becomes a relocation.
--
-- Multiplication, division and the bitwise operators need both sides to
-- be numbers, which is what an assembler can promise.
local function relnum(v)
	if next(v.sec) ~= nil or #v.syms > 0 then return nil end
	return v.n
end

-- A name in section `sec` that the expression still leans on, so a
-- relocation has something to point at.  A section may hold several
-- labels at the same spot, and any of them says the same place.
local function pick(v, sec)
	for _, p in ipairs(v.places) do
		if p.sign == 1 and p.sec == sec and p.name then return p end
	end
	return nil
end

function Asm:relexpr(text)
	local at = 1
	local function ws() at = text:find("%S", at) or #text + 1 end
	local function want(c)
		ws()
		if text:sub(at, at + #c - 1) == c then
			at = at + #c
			return true
		end
	end
	local function num(n)
		return {n = n, sec = {}, syms = {}, places = {}}
	end
	local function combine(a, b, sign)
		local r = num(a.n + sign * b.n)

		for k, c in pairs(a.sec) do r.sec[k] = c end
		for k, c in pairs(b.sec) do
			local t = (r.sec[k] or 0) + sign * c

			r.sec[k] = t ~= 0 and t or nil
		end
		for _, y in ipairs(a.syms) do r.syms[#r.syms + 1] = y end
		for _, y in ipairs(b.syms) do
			r.syms[#r.syms + 1] = {sym = y.sym,
					       sign = sign * y.sign}
		end
		for _, y in ipairs(a.places) do
			r.places[#r.places + 1] = y
		end
		for _, y in ipairs(b.places) do
			r.places[#r.places + 1] = {sign = sign * y.sign,
				sec = y.sec, off = y.off, name = y.name}
		end
		return r
	end
	local sum, relational

	local function atom()
		ws()
		if want("(") then
			-- Parentheses hold a whole expression, comparison
			-- and all.
			local v = relational()

			if not v or not want(")") then return nil end
			return v
		end
		if want("-") then
			local v = atom()

			return v and combine(num(0), v, -1)
		end
		if want("+") then return atom() end
		if want("~") then
			local v = atom()
			local k = v and relnum(v)

			return k and num(~k)
		end
		local t = text:match("^0[xX]%x+", at) or
			text:match("^0[bB][01]+", at)

		if t then
			at = at + #t
			-- A number may carry the suffix C gives one: a
			-- header hands a constant straight to a template.
			at = at + #(text:match("^[uUlL]+", at) or "")
			local b = t:match("^0[bB](.*)$")

			return num(b and tonumber(b, 2) or tonumber(t))
		end
		-- A number followed by b or f names the nearest local
		-- label of that number, behind or ahead.  It is looked
		-- for before a plain number so that the digits are not
		-- eaten first.
		local loc = text:match("^%d+[bf]%f[%W]", at)

		if not loc then
			t = text:match("^%d+", at)
			if t then
				at = at + #t
				at = at + #(text:match("^[uUlL]+", at) or "")
				return num(tonumber(t))
			end
		end
		-- The spot being written stands for itself.
		if text:sub(at, at) == "." and
		   not text:match("^%.[%w._$]", at) then
			at = at + 1
			local v = num(self.cur.off)

			v.sec[self.cur] = 1
			v.places[1] = {sign = 1, sec = self.cur,
				       off = self.cur.off}
			return v
		end
		local nm = loc or text:match("^[%a._$][%w.$_]*", at)

		if not nm then return nil end
		at = at + #nm
		-- A numeric local label is one of many with that
		-- number, so what it stands for is the resolved name,
		-- not the two characters written: a relocation against
		-- "1b" would name every one of them at once.
		local key = self:numref(nm)
		local d = self.syms[key]

		if d and d.abs then return num(d.abs) end
		if d and d.sec then
			local v = num(d.off)

			v.sec[d.sec] = 1
			v.places[1] = {sign = 1, sec = d.sec, off = d.off,
				       name = key}
			return v
		end
		local v = num(0)

		v.syms[1] = {sym = nm, sign = 1}
		return v
	end

	local function product()
		local a = atom()

		while a do
			ws()
			local op = text:sub(at, at)

			if op ~= "*" and op ~= "/" and op ~= "%" then
				return a
			end
			at = at + 1
			local b = atom()
			local x, y = relnum(a), b and relnum(b)

			if not x or not y then return nil end
			if op == "*" then a = num(x * y)
			elseif y == 0 then return nil
			elseif op == "/" then a = num(x // y)
			else a = num(x % y) end
		end
	end

	local function shift()
		local a = product()

		while a do
			ws()
			local op = text:sub(at, at + 1)

			if op ~= "<<" and op ~= ">>" then return a end
			at = at + 2
			local b = product()
			local x, y = relnum(a), b and relnum(b)

			if not x or not y then return nil end
			a = num(op == "<<" and x << y or x >> y)
		end
	end

	-- Comparison, which a kernel macro uses to decide how much
	-- padding an alternative needs.  True is every bit set, as it
	-- is in gas, so that negating it gives one.
	function relational()
		local a = sum()

		while a do
			ws()
			local two = text:sub(at, at + 1)
			local op

			if two == "==" or two == "!=" or two == "<=" or
			   two == ">=" or two == "<>" then
				op, at = two, at + 2
			else
				local one = text:sub(at, at)

				if (one == "<" or one == ">") and
				   text:sub(at, at + 1) ~= "<<" and
				   text:sub(at, at + 1) ~= ">>" then
					op, at = one, at + 1
				else
					return a
				end
			end
			local b = sum()
			local x, y = relnum(a), b and relnum(b)

			if not x or not y then return nil end
			local t

			if op == "==" then t = x == y
			elseif op == "!=" or op == "<>" then t = x ~= y
			elseif op == "<" then t = x < y
			elseif op == ">" then t = x > y
			elseif op == "<=" then t = x <= y
			else t = x >= y end
			a = num(t and -1 or 0)
		end
	end

	function sum()
		local a = shift()

		while a do
			ws()
			local op = text:sub(at, at)

			if op == "+" or op == "-" then
				at = at + 1
				local b = shift()

				if not b then return nil end
				a = combine(a, b, op == "+" and 1 or -1)
			elseif (op == "&" or op == "|" or op == "^") and
			       text:sub(at, at + 1) ~= "&&" and
			       text:sub(at, at + 1) ~= "||" then
				at = at + 1
				local b = shift()
				local x, y = relnum(a), b and relnum(b)

				if not x or not y then return nil end
				if op == "&" then a = num(x & y)
				elseif op == "|" then a = num(x | y)
				else a = num(x ~ y) end
			else
				return a
			end
		end
	end

	local v = relational()

	ws()
	if at <= #text then return nil end
	return v
end

-- What an expression is worth as a plain number, or nothing if it needs
-- a relocation.  A displacement has to be one.
function Asm:absexpr(text)
	local e = self:relexpr(text)

	return e and relnum(e)
end

-- The same, but an immediate may also be the address of one name plus
-- an offset, which the linker fills in.  Answers a number, or nothing
-- and the name and the offset.
function Asm:symexpr(text)
	local e = self:relexpr(text)

	if not e then return nil end
	local k = relnum(e)

	if k then return k end
	if #e.syms == 1 and e.syms[1].sign == 1 and next(e.sec) == nil then
		return nil, e.syms[1].sym, e.n
	end
	if #e.syms == 0 then
		local one = nil

		for sec, c in pairs(e.sec) do
			if c ~= 1 or one then one = false break end
			one = sec
		end
		local p = one and pick(e, one)

		if p then return nil, p.name, e.n - p.off end
	end
	return nil
end

-- Sixteen bytes, low half first.  The value does not fit in a number, so
-- a hexadecimal one is cut in two where it is written and each half is
-- read on its own.  Anything else is a 64 bit value, sign extended.
function Asm:octa(text)
	text = text:match("^%s*(.-)%s*$")
	local hex = text:match("^0[xX](%x+)$")

	if hex then
		if #hex > 32 then error("octa too wide '" .. text .. "'") end
		hex = ("0"):rep(32 - #hex) .. hex
		self:emit(tonumber(hex:sub(17), 16) or 0, 8)
		self:emit(tonumber(hex:sub(1, 16), 16) or 0, 8)
		return
	end
	local e = self:relexpr(text)
	local k = e and relnum(e)

	if not k then error("bad data item '" .. text .. "'") end
	self:emit(k, 8)
	self:emit(k < 0 and -1 or 0, 8)
end

-- A data item is whatever `relexpr` can make of it: a number, a symbol,
-- a symbol and an offset, or the distance from here to a symbol.
function Asm:datum(size, text)
	local v = tonumber(text)

	if v then return self:emit(v, size) end
	text = text:match("^%s*(.-)%s*$")
	local e = self:relexpr(text)

	if not e then error("bad data item '" .. text .. "'") end
	local k = relnum(e)

	if k then return self:emit(k, size) end
	-- What is left has to be one place, either on its own or measured
	-- from the spot being written.  A name this file has not seen and
	-- a label it has both come to the same thing: a relocation.
	local sym, addend

	if #e.syms == 1 and e.syms[1].sign == 1 and next(e.sec) == nil then
		sym, addend = e.syms[1].sym, e.n
	elseif #e.syms == 0 then
		local one = nil

		for sec, c in pairs(e.sec) do
			if c ~= 1 or one then one = false break end
			one = sec
		end
		local p = one and pick(e, one)

		if p then sym, addend = p.name, e.n - p.off end
	end
	if sym then
		self:reloc(size == 8 and "abs64" or "abs32", sym, addend)
		return self:emit(0, size)
	end
	-- The same, measured from the spot being written, which is what a
	-- table of offsets in a section writes.
	local dot = e.sec[self.cur]

	if size == 4 and dot and dot < 0 and #e.syms <= 1 then
		local rest = {n = e.n, sec = {}, syms = e.syms,
			      places = e.places}

		for sc, c in pairs(e.sec) do
			if sc ~= self.cur then rest.sec[sc] = c end
		end
		if dot ~= -1 then rest.sec[self.cur] = dot + 1 end
		local s2, a2

		if #rest.syms == 1 and rest.syms[1].sign == 1 and
		   next(rest.sec) == nil then
			s2, a2 = rest.syms[1].sym, rest.n
		elseif #rest.syms == 0 then
			local one = nil

			for sc, c in pairs(rest.sec) do
				if c ~= 1 or one then one = false break end
				one = sc
			end
			local p = one and pick(rest, one)

			if p then s2, a2 = p.name, rest.n - p.off end
		end
		if s2 then
			self:reloc("pc32", s2, a2 + self.cur.off)
			return self:emit(0, size)
		end
	end
	-- A label further down the file is not placed yet on the passes
	-- that place them.  The item is the same width either way, so
	-- leave the answer to the pass that writes the bytes.
	if self.pass < 2 then return self:emit(0, size) end
	error("bad data item '" .. text .. "'")
end

-- `.set name, expr` and `name = expr`.  The value is a number, or
-- another symbol this one stands for.
function Asm:assign(name, rest)
	rest = rest:match("^%s*(.-)%s*$")
	-- `.set name, %reg` gives a register a name of its own, which is
	-- how hand written assembly says what each one holds.  It is text,
	-- not a value, so it is kept apart from the symbols.
	-- A name given a register stands for the register that name held
	-- when the line was read, not for the name.  Hand written
	-- assembly rotates a set of them -- `h = g`, `g = f`, `f = e` --
	-- and each has to take the value the one before it had.
	if rest:sub(1, 1) == "%" or self.regalias[rest] then
		local t = rest

		for _ = 1, 8 do
			local n = self.regalias[t]

			if not n then break end
			t = n
		end
		self.regalias[name] = t
		return
	end
	-- A difference of two labels in one section is a number, and a
	-- kernel gives a symbol the length of a function that way.
	local v = tonumber(rest) or evalexpr(rest, self.syms) or
		self:absexpr(rest)

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
-- settles because the list is walked until nothing more changes.  A
-- later pass may move the symbol, so this follows it rather than
-- keeping the first answer.
function Asm:settle()
	local again = true

	while again do
		again = false
		for _, name in ipairs(self.aliases) do
			local d = self.syms[name]
			local o = self.syms[d.alias]

			if o and (o.sec or o.abs) and
			   (d.sec ~= o.sec or d.off ~= o.off or
			    d.abs ~= o.abs) then
				d.sec, d.off, d.abs = o.sec, o.off, o.abs
				again = true
			end
		end
	end
end

-- The strings of a `.ascii` or a `.asciz`: a comma starts a new one,
-- and two written in a row with nothing between them are one.
local function strings(rest)
	local out, cur, i, any = {}, {}, 1, false

	while i <= #rest do
		local c = rest:sub(i, i)

		if c == '"' then
			local j = i + 1

			while j <= #rest do
				local e = rest:sub(j, j)

				if e == "\\" then
					j = j + 2
				elseif e == '"' then
					break
				else
					j = j + 1
				end
			end
			cur[#cur + 1] = unescape(rest:sub(i + 1, j - 1))
			any = true
			i = j + 1
		elseif c == "," then
			out[#out + 1] = table.concat(cur)
			cur, any = {}, false
			i = i + 1
		else
			i = i + 1
		end
	end
	if any or #out == 0 then out[#out + 1] = table.concat(cur) end
	return out
end

function Asm:directive(d, rest)
	if self.arch.directive and self.arch.directive(self, d, rest) then
		return
	end
	if d == "text" or d == "data" then
		self:section("." .. d)
	elseif d == "bss" then
		self:section(".bss", true)
	elseif d == "popsection" then
		local st = self.secstack

		if not st or #st == 0 then
			error(".popsection with nothing pushed")
		end
		self:section(st[#st].name)
		st[#st] = nil
	elseif d == "previous" then
		-- Not the other half of a push: `.previous` swaps the
		-- section in hand with the one before it, and swaps back
		-- if it is written again.
		local p = self.prevsec

		if not p then error(".previous with no section before it") end
		self.prevsec = self.cur
		self.cur = p
	elseif d == "section" or d == "pushsection" then
		if d == "pushsection" then
			local st = self.secstack

			if not st then st = {}; self.secstack = st end
			st[#st + 1] = self.cur
		end
		-- A section name may hold anything but a comma or a
		-- space, and .note.GNU-stack holds a dash.  It may also
		-- be quoted, and then the flags are the quoted string
		-- after it rather than the name itself.
		local name, after = rest:match('^%s*"([^"]*)"%s*(.*)$')

		if not name then
			name = rest:match("^%s*([^,%s]+)")
			after = rest:match("^%s*[^,%s]+%s*(.*)$") or ""
		end
		local fl = after:match('"([^"]*)"')
		local perm, merge, entsize

		if fl then
			-- What the flags say and nothing else: a section
			-- with no `a` is not part of the image, which is
			-- how the kernel writes the ones it keeps only
			-- for a validator to read.
			perm = 0
			if fl:find("a", 1, true) then perm = perm | 4 end
			if fl:find("w", 1, true) then perm = perm | 2 end
			if fl:find("x", 1, true) then perm = perm | 1 end
			merge = fl:find("M", 1, true) ~= nil or nil
			if merge then
				entsize = tonumber(after:match(",%s*(%d+)%s*$"))
			end
		end
		self:section(name, name == ".bss" or
			after:find("@nobits", 1, true) ~= nil, perm,
			merge, entsize)
	elseif d == "set" or d == "equ" then
		local name, rhs = rest:match("^%s*([%w.$_]+)%s*,%s*(.+)$")

		if not name then error("bad ." .. d) end
		self:assign(name, rhs)
	elseif d == "code64" or d == "code32" or d == "code16" then
		-- Which mode the processor reads the bytes in.  A kernel
		-- drops to 32 bits to turn paging off and back on.
		self.bits = tonumber(d:sub(5))
	elseif d == "org" then
		-- `.org n, fill` moves the location counter forward.  It
		-- never moves back, and gas says so.
		local n, f = rest:match("^%s*(.-)%s*,%s*(.*)$")

		n = n or rest
		-- The target is usually a name in this section plus an
		-- offset, so measure it the way an address is measured.
		local want = self:absexpr(n)

		if not want then
			local _, sym, off = self:symexpr(n)
			local d = sym and self.syms[sym]

			if d and d.sec == self.cur then
				want = d.off + (off or 0)
			end
		end
		local pad = (want or self.cur.off) - self.cur.off

		if pad < 0 then
			error(".org moves backwards")
		end
		self:space(pad, f and (tonumber(f) or self:absexpr(f)))
	elseif d == "globl" or d == "global" then
		self:global(rest)
	elseif d == "hidden" or d == "protected" or d == "internal" then
		self:visible(rest, d)
	elseif d == "weak" then
		self:weak(rest)
	elseif d == "balign" or d == "align" or d == "p2align" then
		-- `.p2align n, fill, max`.  The second operand names the
		-- byte and may be left empty; the third is a limit on how
		-- far to pad, which this ignores.
		local n = tonumber((rest:match("^[^,]*")))
		local f = rest:match("^[^,]*,%s*([^,%s]+)")

		if d == "p2align" then n = 1 << (n or 0) end
		self:align(n or 1, f and (tonumber(f) or self:absexpr(f)))
	elseif d == "zero" or d == "space" or d == "skip" then
		-- `.skip n, v` and `.space n, v` may name the byte; .zero
		-- never does.
		local n, v = rest:match("^%s*([^,]*),%s*(.*)$")

		n = n or rest
		-- How much room may turn on a label further down the
		-- file -- a kernel pads an instruction out to the length
		-- of the one that may replace it -- so this is measured
		-- the way an address is, and a round that measures it
		-- differently asks for another.
		local want = tonumber((n:match("^[^,]*"))) or
			self:absexpr(n) or 0

		self.nskip = self.nskip + 1
		local k = self.nskip

		if not self.skipwas or self.skipwas[k] ~= want then
			self.changed = true
		end
		self.skipnow[k] = want
		self:space(want, v and (tonumber(v) or
			as.evalexpr(v, self.syms)) or 0)
	elseif d == "fill" then
		-- `.fill repeat, size, value`: the value is written in
		-- `size` bytes, that many times.  Both default to one
		-- and zero.
		local parts = split(rest)
		local rep = tonumber(parts[1]) or
			self:absexpr(parts[1] or "") or 0
		local sz = parts[2] and (tonumber(parts[2]) or
			self:absexpr(parts[2])) or 1
		local val = parts[3] and (tonumber(parts[3]) or
			as.evalexpr(parts[3], self.syms)) or 0

		for _ = 1, rep do
			if self.pass == 2 and not self.cur.bss then
				self:emit(val, sz)
			else
				self.cur.off = self.cur.off + sz
			end
		end
	elseif d == "altmacro" or d == "noaltmacro" then
		-- Alternate macro syntax.  What this assembler reads of
		-- `.macro` is the same either way, so the switch changes
		-- nothing.
	elseif d == "incbin" then
		-- `.incbin "file"[, skip[, count]]`: the bytes of another
		-- file, laid down where this stands.  A kernel wraps its
		-- real mode image in an object this way.
		local name = rest:match('^%s*"([^"]*)"') or
			rest:match("^%s*([^,%s]+)")
		local skip, count = rest:match('[^,]*,%s*([^,%s]+)%s*,?%s*([^,%s]*)')
		local f = name and io.open(name, "rb")

		if not f then error("cannot read " .. tostring(name)) end
		local text = f:read("a")

		f:close()
		local from = (skip and (tonumber(skip) or
			self:absexpr(skip)) or 0) + 1
		local n = count ~= "" and count and
			(tonumber(count) or self:absexpr(count)) or nil

		self:bytes(text:sub(from, n and (from + n - 1) or #text))
	elseif d == "ascii" or d == "asciz" then
		-- A comma separates one string from the next, and each
		-- may be written as several in a row: what `#` makes of
		-- a macro argument lands here as `"" "\\0"`.
		for _, item in ipairs(strings(rest)) do
			self:bytes(item)
			if d == "asciz" then self:bytes("\0") end
		end
	elseif DSIZE[d] or d == "word" then
		local size = DSIZE[d] or self.arch.wordbytes or 4

		for _, item in ipairs(split(rest)) do
			self:datum(size, item)
		end
	elseif d == "octa" then
		for _, item in ipairs(split(rest)) do
			self:octa(item)
		end
	-- What kind of thing a name is, and how much of it there is.
	-- A validator that walks the code reads both: without them the
	-- section is one run of bytes with no functions in it.
	elseif d == "type" then
		-- `.type name, @function`, and the shape a kernel writes:
		-- `.type name STT_FUNC`, with no comma and no sigil.
		local nm, kind = rest:match(
			"^%s*([%w._$]+)%s*,?%s*[@%%#]?([%w_]+)")

		if nm and STT[kind] then
			self.syms[nm] = self.syms[nm] or {}
			self.syms[nm].styp = STT[kind]
		end
	elseif d == "size" then
		local nm, ex = rest:match("^%s*([%w._$]+)%s*,%s*(.+)$")

		if nm and ex then
			local ok, v = pcall(self.absexpr, self, ex)

			if ok and v then
				self.syms[nm] = self.syms[nm] or {}
				self.syms[nm].size = v
			end
		end
	elseif d == "file" or
	       d == "ident" or d == "local" or d == "option" or
	       d:sub(1, 4) == "cfi_" then
		-- Nothing here needs them.  A `.cfi_` directive describes
		-- how to walk back out of a frame, and this compiler
		-- writes none of its own, so one in a source it is given
		-- is read and dropped rather than turned into a table
		-- nothing else in the output would match.
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
-- `syms` lets a name stand for the value `.set` gave it, which is what
-- a `.if` inside a `.rept` reads to tell one round from the next.
-- Register names met in a condition, each with a number of its own.
local REGID, NREGID = {}, 1 << 40

function evalexpr(s, syms)
	local at = 1

	local function ws() at = s:find("%S", at) or #s + 1 end
	local function want(c)
		ws()
		if s:sub(at, at + #c - 1) == c then
			at = at + #c
			return true
		end
	end
	local sum, logic

	local function atom()
		ws()
		if want("(") then
			-- Parentheses hold a whole expression, comparisons
			-- and all, not only the arithmetic.
			local v = logic()

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
		if t then
			at = at + #t
			return tonumber(t)
		end
		-- A register named in a condition, which is how hand
		-- written assembly asks which one a macro was given.
		-- Each name stands for a number of its own, so two are
		-- equal when they are the same register and not
		-- otherwise.
		local rg = s:match("^%%[%a][%w]*", at)

		if rg then
			at = at + #rg
			if not REGID[rg] then
				NREGID = NREGID + 1
				REGID[rg] = NREGID
			end
			return REGID[rg]
		end
		-- A name that `.set` gave a value stands for it.
		local nm = s:match("^[%a._$][%w.$_]*", at)

		if nm and syms and syms[nm] and syms[nm].abs then
			at = at + #nm
			return syms[nm].abs
		end
		return nil
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
			-- `||` and `&&` belong to the level above, so one
			-- bar is bitwise and two are not.
			elseif s:sub(at, at + 1) ~= "||" and want("|") then
				local b = product()

				if not b then return nil end
				a = a | b
			elseif s:sub(at, at + 1) ~= "&&" and want("&") then
				local b = product()

				if not b then return nil end
				a = a & b
			else
				return a
			end
		end
		return a
	end

	-- Above the arithmetic: the comparisons, then `&&` and `||`, which
	-- a `.if` is written with.  Each answers one or zero.
	local function compare()
		local a = sum()

		if not a then return nil end
		while true do
			ws()
			local op = s:match("^[<>=!]=", at) or
				s:match("^[<>]", at)

			if not op or s:sub(at, at + 1) == "<<" or
			   s:sub(at, at + 1) == ">>" then
				return a
			end
			at = at + #op
			local b = sum()

			if not b then return nil end
			if op == "==" then a = a == b and 1 or 0
			elseif op == "!=" then a = a ~= b and 1 or 0
			elseif op == "<=" then a = a <= b and 1 or 0
			elseif op == ">=" then a = a >= b and 1 or 0
			elseif op == "<" then a = a < b and 1 or 0
			else a = a > b and 1 or 0 end
		end
	end

	function logic()
		local a = compare()

		while a do
			ws()
			if s:sub(at, at + 1) == "&&" then
				at = at + 2
				local b = compare()

				if not b then return nil end
				a = (a ~= 0 and b ~= 0) and 1 or 0
			elseif s:sub(at, at + 1) == "||" then
				at = at + 2
				local b = compare()

				if not b then return nil end
				a = (a ~= 0 or b ~= 0) and 1 or 0
			else
				return a
			end
		end
		return a
	end

	local v = logic()

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
	-- The reference has to be the whole name.  A symbol may hold
	-- digits, an underscore, a dot and a dollar, so
	-- `topo_domain_map_0b_1f` names an array and not two labels.
	return (body:gsub("(%f[%w_.$])(%d+)([fb])(%f[^%w_.$])",
		function(_, n, d, _)
			local k = self.nums[n] or 0

			return numname(n, d == "f" and k + 1 or k)
		end))
end

-- Conditionals, repeats and macros -------------------------------------
--
-- A kernel writes its interrupt stubs once and asks for two hundred and
-- fifty six of them.  That needs `.macro` to write one, `.rept` to ask
-- for them, and `.if` to tell the few that differ from the rest.
--
-- `.altmacro` is what makes `%expr` an argument's value rather than its
-- text, which is the only way a repeat can pass the round it is on.

local ENDOF = {macro = "endm", rept = "endr", irp = "endr"}

-- The conditionals, and how each one decides.
local IFKIND = {}
for _, k in ipairs{"if", "ifdef", "ifndef", "ifeq", "ifne", "ifb",
		   "ifnb", "ifc", "ifnc", "ifeqs", "ifnes"} do
	IFKIND[k] = true
end

-- The two strings `.ifc` and its kin compare.  Either may be bare, in
-- angle brackets or in quotes, and a comma between them is what
-- separates them when they are not bracketed.
local function strpair(rest)
	local function strip(t)
		t = t:match("^%s*(.-)%s*$")
		return t:match("^<(.*)>$") or t:match('^"(.*)"$') or t
	end
	local a, b = rest:match("^%s*<([^>]*)>%s*,?%s*<([^>]*)>%s*$")

	if not a then
		a, b = rest:match('^%s*"([^"]*)"%s*,?%s*"([^"]*)"%s*$')
	end
	if not a then a, b = rest:match("^%s*([^,]*),(.*)$") end
	if not a then return rest, nil end
	return strip(a), strip(b)
end

-- Split a macro's arguments: commas outside parentheses, and under
-- .altmacro a `%` means what follows is worked out rather than passed.
-- The arguments of one invocation, positional in the list and by name
-- in the table.  Under `.altmacro` an argument written with a leading
-- per cent sign is worked out here and the number passed on.
-- The names on a `.macro` line, separated by a comma or by a space
-- that is not inside a default value's parentheses or quotes.
local function paramsplit(s)
	local out, at, depth, q = {}, 1, 0, false

	local function cut(i)
		local t = s:sub(at, i - 1):match("^%s*(.-)%s*$")

		if t ~= "" then out[#out + 1] = t end
		at = i + 1
	end
	for i = 1, #s do
		local c = s:sub(i, i)

		if q then
			if c == '"' then q = false end
		elseif c == '"' then
			q = true
		elseif c == "(" or c == "[" or c == "<" then
			depth = depth + 1
		elseif c == ")" or c == "]" or c == ">" then
			depth = depth - 1
		elseif depth == 0 and (c == "," or c == " " or c == "\t") then
			-- A space right after `=` belongs to the value.
			local before = s:sub(at, i - 1)

			if not before:find("=%s*$") then cut(i) end
		end
	end
	cut(#s + 1)
	return out
end

-- A space separates two arguments as a comma does, but only while the
-- macro still has parameters to fill: gas reads `one 1 + 2` as one
-- argument and `three 10 11 12` as three.  What is left over once they
-- are all filled stays with the last.
local function spacesplit(s, want)
	local out, at, depth, q, esc = {}, 1, 0, false, false

	for i = 1, #s do
		local c = s:sub(i, i)

		if esc then
			esc = false
		elseif c == "\\" then
			esc = true
		elseif q then
			if c == '"' then q = false end
		elseif c == '"' then
			q = true
		elseif c == "(" or c == "[" or c == "<" then
			depth = depth + 1
		elseif c == ")" or c == "]" or c == ">" then
			depth = depth - 1
		elseif depth == 0 and (c == " " or c == "\t") and
		       #out < want - 1 then
			local t = s:sub(at, i - 1):match("^%s*(.-)%s*$")

			if t ~= "" then out[#out + 1] = t end
			at = i + 1
		end
	end
	local t = s:sub(at):match("^%s*(.-)%s*$")

	if t ~= "" then out[#out + 1] = t end
	return out
end

local function argsplit(rest, nparams)
	local out = split(rest or "")

	if not nparams or #out >= nparams then return out end
	local more = {}

	for _, a in ipairs(out) do
		local room = nparams - #more - (#out - #more)

		for _, b in ipairs(spacesplit(a, room + 1)) do
			more[#more + 1] = b
		end
	end
	return more
end

function Asm:macroargs(rest, nparams)
	local out, named = {}, {}

	for _, arg in ipairs(argsplit(rest or "", nparams)) do
		if arg ~= "" then
			local nm, val = arg:match("^([%a_.$][%w.$_]*)%s*=(.*)$")
			local a = val or arg
			-- A quoted argument is passed without its quotes,
			-- which is how a kernel hands a whole instruction
			-- to a macro.  Angle brackets do the same under
			-- .altmacro, for text holding a comma.
			local inner = a:match('^"(.*)"$') or
				a:match("^<(.*)>$")

			if inner then a = inner end
			local e = self.altmacro and a:match("^%%(.+)$")
			local v = e and evalexpr(e, self.syms)

			v = v and tostring(v) or a
			if nm then
				named[nm] = v
			else
				out[#out + 1] = v
			end
		end
	end
	return out, named
end

-- Put the arguments in place of a backslash and the parameter name in
-- the body.  A backslash and empty parentheses end such a name
-- where the text after it would otherwise run on, and a backslash and
-- an at sign count the expansions, so a macro may make a label of its
-- own.
function Asm:expand(m, args, named)
	local out = {}

	for i, line in ipairs(m.body) do
		local t = line

		for k, p in ipairs(m.params) do
			local v = (named or {})[p] or args[k] or
				m.default[k] or ""

			-- An underscore continues a name, so the end of a
			-- parameter is the end of an identifier, not the
			-- first character that is not alphanumeric:
			-- `\\orig_len` names one parameter, never `\\orig`.
			t = t:gsub("\\" .. p .. "%f[^%w_]",
				(v:gsub("%%", "%%%%")))
		end
		t = t:gsub("\\@", tostring(self.nexpand or 0))
		t = t:gsub("\\%(%)", "")
		out[i] = t
	end
	return out
end

function Asm:endcollect(c)
	if c.kind == "macro" then
		self.macros[c.name] = {params = c.params,
				       default = c.default, body = c}
		return
	end
	if c.kind == "irp" then
		for _, v in ipairs(c.vals) do
			for _, line in ipairs(c) do
				local t = line:gsub("\\" .. c.param ..
					"%f[^%w_]", (v:gsub("%%", "%%%%")))

				self:lines((t:gsub("\\%(%)", "")))
			end
		end
		return
	end
	-- A repeat runs its lines again, through everything above, so a
	-- `.set` inside one is seen by the round after it.
	for _ = 1, c.count do
		for _, line in ipairs(c) do self:lines(line) end
	end
end

-- One line of a body, which a macro argument may have turned into more
-- than one statement.
function Asm:lines(l)
	if not l:find(";", 1, true) then return self:line(l) end
	for _, part in ipairs(as.statements(l)) do self:line(part) end
end

function Asm:invoke(name, rest)
	local m = self.macros[name]

	if not m then return false end
	-- `\@` counts the expansions before this one, so the first body
	-- sees zero.
	local args, named = self:macroargs(rest, #m.params)
	local body = self:expand(m, args, named)

	self.nexpand = (self.nexpand or 0) + 1
	for _, line in ipairs(body) do self:lines(line) end
	return true
end

function Asm:skipping()
	local c = self.cond[#self.cond]

	return c ~= nil and not c.on
end

function Asm:line(l)
	-- Gathering the body of a macro or a repeat: every line goes in
	-- until the end that matches the one that opened it.
	if self.collect then
		local d = l:match("^%s*%.(%a+)")

		if ENDOF[d or ""] then
			self.collect.depth = self.collect.depth + 1
		elseif d == "endm" or d == "endr" then
			self.collect.depth = self.collect.depth - 1
			if self.collect.depth == 0 then
				local c = self.collect

				self.collect = nil
				return self:endcollect(c)
			end
		end
		self.collect[#self.collect + 1] = l
		return
	end
	do
		local d, rest = l:match("^%s*%.(%a+)%s*(.*)$")

		if IFKIND[d or ""] then
			local on
			if self:skipping() then
				on = false
			elseif d == "ifdef" or d == "ifndef" then
				local have = self.syms[rest:match("^%S*")] ~= nil

				on = (d == "ifdef") == have
			elseif d == "ifb" or d == "ifnb" then
				-- Whether the rest of the line is blank,
				-- which is how a macro asks if it was
				-- given an argument.
				local blank = rest:match("^%s*$") ~= nil

				on = (d == "ifb") == blank
			elseif d == "ifc" or d == "ifnc" or
			       d == "ifeqs" or d == "ifnes" then
				-- Two strings, the same or not.  `.ifc`
				-- separates them with a comma and takes
				-- them bare or in angle brackets; `.ifeqs`
				-- wants them quoted.
				local a, b = strpair(rest)
				local same = a == b

				on = (d == "ifc" or d == "ifeqs") == same
			else
				local v = evalexpr(rest, self.syms) or 0

				if d == "ifne" then on = v ~= 0
				elseif d == "ifeq" then on = v == 0
				else on = v ~= 0 end
			end
			self.cond[#self.cond + 1] = {on = on, taken = on,
				dead = self:skipping()}
			return
		elseif d == "else" or d == "elseif" then
			local c = self.cond[#self.cond]

			if not c then error("." .. d .. " with no .if") end
			if c.dead then return end
			if c.taken then
				c.on = false
			elseif d == "else" then
				c.on = true
				c.taken = true
			else
				c.on = (evalexpr(rest, self.syms) or 0) ~= 0
				c.taken = c.on
			end
			return
		elseif d == "endif" then
			if #self.cond == 0 then error(".endif with no .if") end
			self.cond[#self.cond] = nil
			return
		end
		if self:skipping() then return end
		if d == "macro" then
			local name, params = rest:match("^(%S+)%s*(.*)$")
			local ps, def = {}, {}

			-- gas separates parameters by a comma or by
			-- space, and a name may carry `:req` or
			-- `:vararg`, which say how it is given rather
			-- than what it is called.  A default value may
			-- hold spaces of its own, so the split follows
			-- the parentheses rather than every space.
			for _, p in ipairs(paramsplit(params or "")) do
				local a = (p:gsub(":%a+$", ""))
				local nm, dv = a:match("^([%w_$.]+)%s*=%s*(.*)$")

				if nm then
					ps[#ps + 1] = nm
					def[#ps] = dv
				elseif a ~= "" then
					ps[#ps + 1] = a
				end
			end
			self.collect = {kind = "macro", name = name,
					params = ps, default = def, depth = 1}
			return
		elseif d == "rept" then
			self.collect = {kind = "rept", depth = 1,
				count = evalexpr(rest, self.syms) or 0}
			return
		elseif d == "irp" or d == "irpc" then
			-- `.irp name, a, b` runs its body once for each
			-- value, with the name standing for it.  `.irpc`
			-- walks the characters of one word instead.
			local args = split(rest or "")
			local nm = table.remove(args, 1) or "x"
			local vals = args

			if d == "irpc" then
				vals = {}
				for c in (args[1] or ""):gmatch(".") do
					vals[#vals + 1] = c
				end
			end
			if #vals == 0 then vals = {""} end
			self.collect = {kind = "irp", depth = 1,
					param = nm, vals = vals}
			return
		elseif d == "error" or d == "warning" then
		local msg = rest:match('^%s*"(.*)"%s*$') or
			rest:match("^%s*(.-)%s*$")

		if d == "error" then error(msg) end
		io.stderr:write("warning: ", msg, "\n")
	elseif d == "purgem" then
			-- Forget a macro, so the name may be given a new
			-- body or stand for an instruction again.
			for _, nm in ipairs(split(rest or "")) do
				self.macros[nm] = nil
			end
			return
		elseif d == "altmacro" then
			self.altmacro = true
			return
		elseif d == "noaltmacro" then
			self.altmacro = false
			return
		end
	end
	-- a whole line of comment, in any of the spellings
	l = l:gsub("^%s*[/*#].*$", "")
	-- On a machine where `#` starts a comment it starts one anywhere;
	-- on arm64 it marks an immediate instead.
	if self.arch.hash then l = uncomment(l) end
	-- Labels, which an asm template may leave indented and which may
	-- be followed by an instruction on the same line.
	while true do
		-- gas lets a space stand between a label and its colon.
		local label, after = l:match("^%s*([%w.$_]+)%s*:%s*(.*)$")

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
	-- The mnemonic runs to the end of its name, not to the next
	-- space: gas reads `MACRO(arg)` as the macro and one operand,
	-- and the kernel invokes its own that way.
	local word, rest = body:match("^([%a._$][%w.$_]*)(.*)$")

	if not word then word, rest = body:match("^(%S+)%s*(.*)$") end
	rest = rest:match("^%s*(.-)%s*$")
	if word:sub(1, 1) == "." then
		-- a directive's operand may be a string, which a numeric
		-- label reference must not be looked for inside
		return self:directive(word:sub(2), rest)
	end
	-- An argument of a macro is text until the body is built, and
	-- the body may define the label the argument refers to: the
	-- kernel hands a whole loop, label and branch, to ALTERNATIVE.
	if self.macros[word] then return self:invoke(word, rest) end
	self:inst(word, split(self:numref(rest)))
end

function Asm:run(text, pass)
	self.pass = pass
	self.cur = nil
	self.nbr = 0
	self.nums = {}
	-- Macros, and whatever conditional or repeat was open, belong to
	-- one sweep over the file and are built again on the next.
	self.macros, self.cond, self.collect = {}, {}, nil
	self.nskip, self.skipnow = 0, {}
	self.secstack, self.prevsec = {}, nil
	self.regalias = {}
	self.altmacro, self.nexpand = false, 0
	self.bits = self.startbits or 64
	for _, s in ipairs(self.order) do s.off = 0 end
	if self.arch.startpass then self.arch.startpass(self, pass) end
	self:section(".text")
	local n = 0
	local file = nil
	local incomment = false
	-- The control variable of a for loop may not be assigned to, so
	-- the line is copied before a comment is taken out of it.
	for raw in text:gmatch("[^\n]*") do
		local l = raw

		n = n + 1
		-- A line marker from the preprocessor says which line of
		-- which file comes next, so an error names the source
		-- rather than the preprocessed text.
		if not incomment and l:sub(1, 1) == "#" then
			local ln, nm = l:match('^#%s*(%d+)%s*"([^"]*)"')

			if ln then
				n = tonumber(ln) - 1
				file = nm
			end
		end
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
					error(("%s%d: %s\n  %s"):format(
						file and (file .. ":") or
						"line ", n, err, part), 0)
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
	local rounds = 0

	repeat
		a.changed = false
		rounds = rounds + 1
		if rounds > 20 then
			error("the layout will not settle", 0)
		end
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
		a.skipwas = a.skipnow
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
