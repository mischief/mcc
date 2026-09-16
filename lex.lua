-- Tokenizer.  Two characters of lookahead, no buffer beyond the token being
-- built, so the reader can hand over bytes in any size it likes.
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
	"float", "double",
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
} do PUNCT[p] = true end

local ESCAPE = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
		t = "\t", v = "\v", e = "\27",
		["\\"] = "\\", ["'"] = "'", ['"'] = '"', ["?"] = "?"}

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
	-- anything left is floating: 1.5, .5e3, 0x1p4, 1.0f
	body = s:match("^(.-)[fFlL]*$")
	local v = tonumber(body) or tonumber(s)
	if v then return v + 0.0, true end
	return nil
end

function lex.new(read, name, pp)
	local l = setmetatable({read = read, name = name or "-", line = 1,
				pp = pp, bol = true}, lex)
	l.c = read()
	l.d = read()
	-- Two token tables in rotation.  Nothing holds more than the current
	-- token and the one before it, so this is all the storage a token
	-- needs and the tokenizer produces no garbage of its own.
	l.slot = {{}, {}}
	l.turn = 0
	l.buf = {}
	return l
end

function lex:tok(kind, text, val, line)
	self.turn = self.turn % 2 + 1
	local t = self.slot[self.turn]
	t.kind, t.text, t.val, t.line = kind, text, val, line
	t.bol, t.ws = self.bol, self.sawws
	self.bol, self.sawws = false, false
	return t
end

function lex:err(msg)
	error(("%s:%d: %s"):format(self.name, self.line, msg), 0)
end

-- A backslash before a newline splices the lines together, everywhere,
-- so it is handled here and nothing above sees it.
function lex:adv()
	if self.c == "\n" then
		self.line = self.line + 1
		self.bol = true
	end
	self.c = self.d
	self.d = self.read()
	while self.c == "\\" and self.d == "\n" do
		self.line = self.line + 1
		self.c = self.read()
		self.d = self.read()
	end
end

function lex:skip()
	while self.c do
		local c = self.c
		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			self.sawws = true
			self:adv()
		elseif c == "/" and self.d == "*" then
			self.sawws = true
			self:adv()
			self:adv()
			while self.c and not (self.c == "*" and self.d == "/") do
				self:adv()
			end
			if not self.c then self:err("unterminated comment") end
			self:adv()
			self:adv()
		elseif c == "/" and self.d == "/" then
			self.sawws = true
			while self.c and self.c ~= "\n" do self:adv() end
		else
			return
		end
	end
end

-- The character after a backslash.  Octal takes up to three digits and hex
-- takes as many as follow; both wrap to a byte, which is all a narrow
-- character literal or a string can hold.
function lex:escape()
	local c = self.c
	if OCTAL[c] then
		local v, n = 0, 0
		while n < 3 and self.c and OCTAL[self.c] do
			v = v * 8 + tonumber(self.c, 8)
			n = n + 1
			self:adv()
		end
		return string.char(v % 256)
	end
	if c == "x" then
		self:adv()
		local v = 0
		while self.c and HEX[self.c] do
			v = v * 16 + tonumber(self.c, 16)
			self:adv()
		end
		return string.char(v % 256)
	end
	self:adv()
	return ESCAPE[c] or c
end

function lex:literal(quote)
	self:adv()
	local out = self.buf
	for i = #out, 1, -1 do out[i] = nil end
	while self.c and self.c ~= quote do
		local ch = self.c
		if ch == "\\" then
			self:adv()
			out[#out + 1] = self:escape()
			goto continue
		end
		out[#out + 1] = ch
		self:adv()
		::continue::
	end
	if not self.c then self:err("unterminated literal") end
	self:adv()
	return table.concat(out)
end

-- Discard the rest of the line without tokenizing it.  A directive that is
-- being ignored may hold text that is not a token sequence at all, such as
-- the <gnu/stubs-64.h> in a conditional that is switched off.
function lex:skipline()
	while self.c and self.c ~= "\n" do self:adv() end
	if self.c then self:adv() end
end

-- The name after #include, which is not a token sequence: read it raw.
function lex:headername()
	self:skip()
	local close = self.c == "<" and ">" or (self.c == '"' and '"')
	if not close then return nil end
	self:adv()
	local out = {}
	while self.c and self.c ~= close and self.c ~= "\n" do
		out[#out + 1] = self.c
		self:adv()
	end
	if self.c == close then self:adv() end
	return table.concat(out), close == ">"
end

function lex:next()
	self:skip()
	local line = self.line
	if not self.c then
		return self:tok("eof", nil, nil, line)
	end
	local c = self.c

	if c:match("[%a_]") then
		local out = self.buf
		local n = 0
		while self.c and self.c:match("[%w_]") do
			n = n + 1
			out[n] = self.c
			self:adv()
		end
		local s = table.concat(out, "", 1, n)
		if self.pp then
			return self:tok("name", s, nil, line)
		end
		return self:tok(KEYWORD[s] and s or "name", s, nil, line)
	end

	-- A preprocessing number: digits, letters, dots, and a sign only after
	-- an exponent letter.  What it means is decided afterwards.
	if c:match("%d") or (c == "." and self.d and self.d:match("%d")) then
		local out = self.buf
		local n = 0
		while self.c do
			local ch = self.c
			if ch:match("[%w.]") then
				n = n + 1
				out[n] = ch
				self:adv()
				if ch:match("[eEpP]") and self.c
				and (self.c == "+" or self.c == "-") then
					n = n + 1
					out[n] = self.c
					self:adv()
				end
			else
				break
			end
		end
		local s = table.concat(out, "", 1, n)
		local v, isflt = self.number(s)
		if not v then self:err("bad number " .. s) end
		-- Keep the spelling: a macro body is stored as text, and
		-- 0xffffffffffffffffu must not come back as -1.
		return self:tok("num", s, v, line), isflt
	end

	if c == "'" then
		local s = self:literal("'")
		return self:tok("num", nil, s:byte(1) or 0, line)
	end
	if c == '"' then
		return self:tok("str", self:literal('"'), nil, line)
	end

	local s = c
	self:adv()
	while self.c and PUNCT[s .. self.c] do
		s = s .. self.c
		self:adv()
	end
	if not PUNCT[s] then
		self:err("unexpected character " .. c)
	end
	return self:tok(s, nil, nil, line)
end

return lex
