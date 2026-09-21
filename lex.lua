-- SPDX-License-Identifier: ISC
-- Tokenizer.  A token is six slots rather than six named fields: the array
-- part of a table is a vector where the hash part is a hash, and a token is
-- made for every token of every file.  The slots are
--
--	1 kind   2 text   3 val   4 line   5 bol   6 ws
--
-- Only lex.lua and cpp.lua see this shape; cpp:out hands the parser a token
-- with names, because the parser holds one at a time and does not care.
--
-- The whole source is one string and the scanner is an index
-- into it, because a character at a time through a closure costs a call and
-- a one-byte string for every byte of every file, and the front end is most
-- of what this compiler does.
--
-- In preprocessing mode an identifier is never a keyword, because at that
-- stage it might still be a macro name or a macro parameter.  Every token
-- carries `bol`, true when it is the first on its line, which is how a
-- directive is recognised and where it ends.

local lex = {}
lex.__index = lex

local KEYWORD = {}
for _, k in ipairs{
	"char", "short", "int", "long", "unsigned", "signed", "void",
	"float", "double", "_Bool",
	"struct", "union", "enum", "typedef", "sizeof",
	"const", "volatile", "static", "extern", "register", "inline",
	"if", "else", "while", "for", "do", "return", "break", "continue",
	"switch", "case", "default", "goto",
} do KEYWORD[k] = true end

-- Every proper prefix of an operator is itself an operator, so one set is
-- enough to extend greedily.  ".." is in the table only so that the walk can
-- reach "..."; C has no such operator and the parser rejects it.
local PUNCT = {}
for _, p in ipairs{
	"<<=", ">>=", "...", "..", "##", "#", "->",
	"==", "!=", "<=", ">=", "&&", "||", "<<", ">>",
	"+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--",
	"(", ")", "{", "}", "[", "]", ";", ",", "=", "+", "-", "*", "/",
	"%", "&", "|", "^", "~", "!", "<", ">", "?", ":", ".",
	-- assembly writes these, and the preprocessor hands them on
	"$", "@", "`", "\\", "'",
} do PUNCT[p] = true end

local ESCAPE = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
		t = "\t", v = "\v", e = "\27",
		["\\"] = "\\", ["'"] = "'", ['"'] = '"', ["?"] = "?"}

local ALPHA, DIGIT = {}, {}
for b = 0, 255 do
	local c = string.char(b)

	ALPHA[b] = c:match("[%a_]") ~= nil
	DIGIT[b] = c:match("%d") ~= nil
end

-- A character constant as it would be written.  A macro body is kept as
-- text, so a token with no spelling of its own comes back as a bare
-- number stuck to whatever stood before it.
local function chrspell(v, pfx)
	local p = pfx or ""

	if v >= 32 and v < 127 and v ~= 39 and v ~= 92 then
		return p .. "'" .. string.char(v) .. "'"
	end
	-- The spelling has to lex back to the same value, so a negative
	-- one is written as the byte it came from.
	if v < 0 and v >= -128 then v = v + 256 end
	if v >= 0 and v < 256 then return p .. ("'\\%03o'"):format(v) end
	return tostring(v)
end

-- What a literal may be prefixed with, which says what its characters
-- are.  This compiler has one kind of character, so the prefix only has
-- to stay attached to what it belongs to.
local STRPREFIX = {u8 = true, u = true, U = true, L = true}

local OCTAL = {}
for d in ("01234567"):gmatch(".") do OCTAL[d] = true end
local HEX = {}
for d in ("0123456789abcdefABCDEF"):gmatch(".") do HEX[d] = true end

lex.KEYWORD = KEYWORD

-- Split a preprocessing number into its value and its suffix.  Returns the
-- value and whether it is a floating one.
function lex.number(s)
	local hex = s:match("^0[xX]%x+")
	if hex and not s:match("^0[xX]%x*%.") and not s:match("[pP]") then
		return math.tointeger(tonumber(hex)) or tonumber(hex), false
	end
	-- A binary constant, which GNU C had before C23 named it.
	local bin = s:match("^0[bB]([01]+)[uUlL]*$")

	if bin then
		local v = 0

		for d in bin:gmatch("[01]") do
			v = v * 2 + (d:byte() - 48)
		end
		return v, false
	end
	local body = s:match("^(.-)[uUlL]*$")
	if body ~= "" and body:match("^%d+$") then
		if body:match("^0[0-7]+$") then
			return tonumber(body:sub(2), 8), false
		end
		-- Build it by hand: a value past the signed range wraps, which
		-- is what an unsigned constant means and what #if needs.
		local v = 0
		for d in body:gmatch("%d") do
			v = v * 10 + (d:byte() - 48)
		end
		return v, false
	end
	-- anything left is floating: 1.5, .5e3, 0x1p4, 1.0f.  An i or a j
	-- at the end makes it the imaginary part of a complex value,
	-- which is how <complex.h> spells the imaginary unit.
	body = s:match("^(.-)[fFlL]*$")
	local v = tonumber(body) or tonumber(s)

	if v then return v + 0.0, true end
	local re = s:match("^(.-)[iIjJ][fFlL]*$") or
		s:match("^(.-)[fFlL]*[iIjJ]$")

	if re then
		local w = tonumber((re:match("^(.-)[fFlL]*$"))) or
			tonumber(re)

		if w then return w + 0.0, true, true end
	end
	return nil
end

-- `src` is the text.  A function is taken too, and drained, for a caller
-- that has one.
-- `charsigned` says whether plain char is signed on the target, which
-- decides what a character constant above 127 is worth.
--
-- `asm` says the text is assembly.  There a backslash and a newline
-- splice two lines into one and everything on them belongs to the line
-- the first began on, because one line is one statement.  In C the two
-- halves keep the lines they were written on.
function lex.new(src, name, pp, charsigned, asm)
	if type(src) == "function" then
		local out, piece = {}, src()
		while piece do
			out[#out + 1] = piece
			piece = src()
		end
		src = table.concat(out)
	end
	local l = setmetatable({s = src, p = 1, n = #src,
				name = name or "-", line = 1,
				charsigned = charsigned ~= false,
				asm = asm or false, held = 0,
				pp = pp, bol = true, sawws = false}, lex)
	-- Two token tables in rotation.  Nothing holds more than the current
	-- token and the one before it, so this is all the storage a token
	-- needs and the tokenizer produces no garbage of its own.
	l.slot = {{}, {}}
	l.turn = 0
	l.buf = {}
	return l
end

-- The byte under the scanner, and the one after it.  A backslash before a
-- newline splices the lines together everywhere, so it is stepped over
-- here and nothing above sees it.
local BS, NL = 92, 10

local function splice(l)
	local s, p = l.s, l.p
	while s:byte(p) == BS and s:byte(p + 1) == NL do
		-- In assembly the count is held until the line really
		-- ends, so every token of a spliced line answers with
		-- the line it began on and the lines after it are still
		-- numbered right.
		if l.asm then l.held = l.held + 1
		else l.line = l.line + 1 end
		p = p + 2
	end
	l.p = p
end

-- What a literal was written as, with the line splices taken out.
-- Splicing happens before anything is tokenised, so a backslash and
-- a newline inside a string are not part of it: `#` stringizes what
-- is left, and gcc prints "xyzw" where the source said "xy\<newline>zw".
local function spelling(l, start)
	local t = l.s:sub(start, l.p - 1)

	if t:find("\\\n", 1, true) then t = t:gsub("\\\n", "") end
	return t
end

-- A real newline, which lets go of whatever splices were held.
local function endline(l, n)
	l.line = l.line + n + l.held
	l.held = 0
end

function lex:at()
	if self.s:byte(self.p) == BS then splice(self) end
	return self.s:byte(self.p)
end

function lex:after()
	local b = self:at()
	if b == nil then return nil end
	local p = self.p + 1
	local s = self.s
	while s:byte(p) == BS and s:byte(p + 1) == NL do p = p + 2 end
	return s:byte(p)
end

-- A fresh token each time.  It used to be two tables in rotation, which
-- meant whoever wanted to keep one had to copy it, and everyone did: a
-- table written twice costs more than a table written once.
-- `raw` is the literal exactly as it was written, quotes and escapes
-- and all.  `#` has to answer with the spelling, not with the value:
-- `#x` of `"\0"` is four characters, and the value is one.
function lex:tok(kind, text, val, line, pfx, raw)
	local t = {kind, text, val, line, self.bol, self.sawws, nil, pfx,
		   nil, raw}

	self.bol, self.sawws = false, false
	return t
end

function lex:err(msg)
	error(("%s:%d: %s"):format(self.name, self.line, msg), 0)
end

function lex:adv()
	if self.s:byte(self.p) == NL then
		endline(self, 1)
		self.bol = true
	end
	self.p = self.p + 1
	if self.s:byte(self.p) == BS then splice(self) end
end

-- Whitespace and comments.  The runs are found in one call each rather
-- than a byte at a time.
function lex:skip()
	local s = self.s
	while true do
		local p = self.p
		local b = s:byte(p)

		if b == nil then return end
		-- form feed and vertical tab are whitespace too, and a C
		-- library header is as likely to hold one as anything
		if b == 32 or b == 9 or b == 13 or b == 12 or b == 11 then
			local _, to = s:find("^[ \t\r\f\v]+", p)

			self.p = to + 1
			self.sawws = true
		elseif b == NL then
			local _, to = s:find("^\n+", p)

			endline(self, to - p + 1)
			self.p = to + 1
			self.bol, self.sawws = true, true
		elseif b == BS and s:byte(p + 1) == NL then
			splice(self)
		elseif b == 47 and s:byte(p + 1) == 42 then	-- /*
			local at = s:find("*/", p + 2, true)

			if not at then self:err("unterminated comment") end
			local from = p
			while true do
				local nl = s:find("\n", from, true)

				if not nl or nl > at then break end
				endline(self, 1)
				from = nl + 1
			end
			self.p = at + 2
			self.sawws = true
		elseif b == 47 and s:byte(p + 1) == 47 then	-- //
			local at = s:find("\n", p + 2, true)

			self.p = at or (self.n + 1)
			self.sawws = true
		else
			return
		end
	end
end

-- The character after a backslash.  Octal takes up to three digits and hex
-- takes as many as follow; both wrap to a byte, which is all a narrow
-- character literal or a string can hold.
function lex:escape()
	local s = self.s
	local c = string.char(self:at() or 0)

	if OCTAL[c] then
		local _, to, run = s:find("^([0-7][0-7]?[0-7]?)", self.p)

		self.p = to + 1
		return string.char(tonumber(run, 8) % 256)
	end
	if c == "x" then
		local _, to, run = s:find("^x(%x+)", self.p)

		if not to then self:err("empty hex escape") end
		self.p = to + 1
		local v = 0
		for i = 1, #run do
			v = (v * 16 + tonumber(run:sub(i, i), 16)) % 256
		end
		return string.char(v)
	end
	self:adv()
	return ESCAPE[c] or c
end

function lex:literal(quote)
	local q = quote:byte()

	self:adv()
	local out = self.buf
	for i = #out, 1, -1 do out[i] = nil end
	while true do
		local b = self:at()

		if b == nil or b == q then break end
		if b == BS then
			self:adv()
			out[#out + 1] = self:escape()
		else
			-- everything up to the next backslash or quote in
			-- one piece
			local s = self.s
			local at = s:find("[\\%" .. quote .. "]", self.p)

			if not at then at = self.n + 1 end
			out[#out + 1] = s:sub(self.p, at - 1)
			self.p = at
		end
	end
	if self:at() == nil then self:err("unterminated literal") end
	self:adv()
	return table.concat(out)
end

-- Discard the rest of the line without tokenizing it.  A directive that is
-- being ignored may hold text that is not a token sequence at all, such as
-- the <gnu/stubs-64.h> in a conditional that is switched off.
-- Skip the rest of a directive line.  A block comment opened on that
-- line runs past the newline, so this follows it to its end: what comes
-- after belongs to the comment and is not the next line.
function lex:skipline()
	local s, n = self.s, self.n
	local i = self.p
	-- A line with no comment, no string and no splice in it ends at
	-- the first newline and nothing between here and there has to be
	-- read.  A kernel switches most of itself off, so most of what
	-- this walks is that line.
	local nl = s:find("\n", i, true)

	if nl then
		local q = s:find("[/\"'\\]", i)

		if not q or q > nl then
			self.p = nl
			self:adv()
			return
		end
	end

	while i <= n do
		local c = s:byte(i)

		if c == NL then
			-- a spliced line is one line
			if s:byte(i - 1) ~= BS then
				self.p = i
				self:adv()
				return
			end
			endline(self, 1)
			i = i + 1
		elseif c == 47 and s:byte(i + 1) == 42 then	-- /*
			i = i + 2
			while i <= n do
				local d = s:byte(i)

				if d == 42 and s:byte(i + 1) == 47 then
					i = i + 2
					break
				end
				if d == NL then endline(self, 1) end
				i = i + 1
			end
		elseif c == 47 and s:byte(i + 1) == 47 then	-- //
			while i <= n and s:byte(i) ~= NL do i = i + 1 end
		elseif c == 34 or c == 39 then
			local q = c

			i = i + 1
			while i <= n do
				local d = s:byte(i)

				if d == 92 then
					i = i + 2
				elseif d == q or d == NL then
					break
				else
					i = i + 1
				end
			end
			if s:byte(i) == q then i = i + 1 end
		else
			i = i + 1
		end
	end
	self.p = n + 1
end

-- The name after #include, which is not a token sequence: read it raw.
function lex:headername()
	self:skip()
	local b = self:at()
	local close = b == 60 and 62 or (b == 34 and 34)

	if not close then return nil end
	self:adv()
	local out = {}
	while true do
		local c = self:at()

		if c == nil or c == close or c == NL then break end
		out[#out + 1] = string.char(c)
		self:adv()
	end
	if self:at() == close then self:adv() end
	return table.concat(out), close == 62
end

function lex:next()
	self:skip()
	local line = self.line
	local s, p = self.s, self.p
	local b = s:byte(p)
	local pfx
	-- Where this token starts, so a literal can keep its spelling.
	local start = p

	if b == nil then
		return self:tok("eof", nil, nil, line)
	end

	-- an identifier, in one call unless a splice interrupts it
	if ALPHA[b] then
		local _, to = s:find("^[%w_$]+", p)
		local text = s:sub(p, to)

		-- A prefix belongs to the literal after it, not to the
		-- name before it.
		local nx = s:byte(to + 1)

		if STRPREFIX[text] and (nx == 34 or nx == 39) then
			self.p, b, pfx = to + 1, nx, text
		else
			self.p = to + 1
			if s:byte(to + 1) == BS then
				text = text .. self:tail("^[%w_$]+")
			end
			if self.pp then
				return self:tok("name", text, nil, line)
			end
			return self:tok(KEYWORD[text] and text or "name",
				text, nil, line)
		end
	end

	-- A preprocessing number: digits, letters, dots, and a sign only
	-- after an exponent letter.  What it means is decided afterwards.
	if DIGIT[b] or (b == 46 and DIGIT[s:byte(p + 1) or 0]) then
		local out, n = self.buf, 0
		while true do
			local from = self.p
			local _, to = s:find("^[%w_.]+", from)

			if not to then break end
			n = n + 1
			out[n] = s:sub(from, to)
			self.p = to + 1
			local e = s:byte(to)
			local sign = s:byte(to + 1)

			if (e == 101 or e == 69 or e == 112 or e == 80) and
			   (sign == 43 or sign == 45) then
				n = n + 1
				out[n] = string.char(sign)
				self.p = to + 2
			elseif s:byte(self.p) == BS then
				splice(self)
				if not s:find("^[%w_.]", self.p) then break end
			else
				break
			end
		end
		local text = table.concat(out, "", 1, n)
		local v, isflt = self.number(text)

		-- Keep the spelling: a macro body is stored as text, and
		-- 0xffffffffffffffffu must not come back as -1.
		return self:tok("num", text, v, line), isflt
	end

	if b == 39 then
		-- In assembly an apostrophe may be an apostrophe: gas
		-- reads `# don't loop` as a comment, and a character
		-- constant never runs past the end of its line.  One with
		-- no closing quote before the newline stands for itself.
		if self.asm then
			local nl = self.s:find("\n", self.p + 1, true)
			local q = self.s:find("'", self.p + 1, true)

			if not q or (nl and q > nl) then
				self:adv()
				return self:tok("'", nil, nil, line)
			end
		end
		local v = (self:literal("'")):byte(1) or 0

		-- A plain character constant has the type of char, so on a
		-- target where char is signed one above 127 is negative.
		if not pfx and self.charsigned and v > 127 then
			v = v - 256
		end
		return self:tok("num", chrspell(v, pfx), v, line, pfx,
			spelling(self, start))
	end
	if b == 34 then
		local v = self:literal('"')

		return self:tok("str", v, nil, line, pfx,
			spelling(self, start))
	end

	local text = string.char(b)

	self:adv()
	while true do
		local c = self:at()

		if not c or not PUNCT[text .. string.char(c)] then break end
		text = text .. string.char(c)
		self:adv()
	end
	if not PUNCT[text] then
		self:err("unexpected character " .. string.char(b))
	end
	return self:tok(text, nil, nil, line)
end

-- What follows a splice, when a token was cut in half by one.
function lex:tail(pat)
	local out = {}
	while self.s:byte(self.p) == BS do
		splice(self)
		local _, to = self.s:find(pat, self.p)

		if not to then break end
		out[#out + 1] = self.s:sub(self.p, to)
		self.p = to + 1
	end
	return table.concat(out)
end

return lex
