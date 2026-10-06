-- SPDX-License-Identifier: ISC
-- Tokenizer for Lua 5.4 source.
--
-- The source is one string and the scanner an index into it, as in the C
-- tokenizer.  A token is a small table: kind, the value it carries, and
-- the line it started on.  Names and keywords are their own kind; every
-- operator is its own spelling as the kind.
--
-- A number is read by this Lua's own tonumber, so the subtype of a
-- numeral, the wrap of a long hexadecimal and the float that a decimal
-- too big for an integer becomes are exactly what the language says.

local lex = {}
lex.__index = lex

local KEYWORD = {}
for _, k in ipairs{
	"and", "break", "do", "else", "elseif", "end", "false", "for",
	"function", "goto", "if", "in", "local", "nil", "not", "or",
	"repeat", "return", "then", "true", "until", "while",
} do KEYWORD[k] = true end

-- Longest first, so that a greedy match on the first that fits is right.
local PUNCT3 = {["..."] = true}
local PUNCT2 = {}
for _, p in ipairs{"==", "~=", "<=", ">=", "//", "::", "<<", ">>",
		   ".."} do
	PUNCT2[p] = true
end
local PUNCT1 = {}
for p in ("+-*/%^#&~|<>=(){}[];:,."):gmatch(".") do PUNCT1[p] = true end

function lex.new(src, name)
	local s = src
	-- A first line starting with # is for the shell, not for Lua.
	if s:sub(1, 1) == "#" then
		local e = s:find("\n", 1, true) or #s + 1

		s = s:sub(e)
	end
	return setmetatable({src = s, pos = 1, line = 1,
			     name = name or "?"}, lex)
end

function lex:err(msg, line)
	error(("%s:%d: %s"):format(self.name, line or self.line, msg), 0)
end

-- A long bracket opens at `pos` if it is `[` then any number of `=`
-- then `[`.  Its level is the count of `=`, or nil if this is not one.
local function longopen(s, pos)
	local eq = s:match("^%[(=*)%[", pos)

	return eq and #eq or nil
end

function lex:longstring(level)
	local s, start = self.src, self.pos
	local open = 2 + level
	local body = start + open
	local close = "]" .. ("="):rep(level) .. "]"
	local e = s:find(close, body, true)

	if not e then self:err("unfinished long string") end
	local text = s:sub(body, e - 1)

	for _ in s:sub(start, e - 1):gmatch("\n") do
		self.line = self.line + 1
	end
	self.pos = e + #close
	-- The first newline straight after the opening bracket is not part
	-- of the string.
	text = text:gsub("^\r\n", "", 1):gsub("^\n\r", "", 1)
		:gsub("^[\r\n]", "", 1)
	-- \r\n, \n\r and \r alone each read as one newline.
	text = text:gsub("\r\n", "\n"):gsub("\n\r", "\n"):gsub("\r", "\n")
	return text
end

local ESC = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
	     v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'"}

local function utf8enc(cp)
	if cp < 0x80 then return string.char(cp) end
	-- The extended form reaches 2^31 the way lua's own does.
	local bytes, lim = {}, 0x3f

	while cp > lim do
		table.insert(bytes, 1, 0x80 | (cp & 0x3f))
		cp = cp >> 6
		lim = lim >> 1
	end
	table.insert(bytes, 1, ((~lim << 1) & 0xff) | cp)
	return string.char(table.unpack(bytes))
end

function lex:shortstring(q)
	local s = self.src
	local i = self.pos + 1
	local out = {}

	while true do
		local c = s:sub(i, i)

		if c == "" or c == "\n" or c == "\r" then
			self:err("unfinished string")
		elseif c == q then
			i = i + 1
			break
		elseif c == "\\" then
			local d = s:sub(i + 1, i + 1)

			if ESC[d] then
				out[#out + 1] = ESC[d]
				i = i + 2
			elseif d == "\n" or d == "\r" then
				out[#out + 1] = "\n"
				self.line = self.line + 1
				i = i + 2
				local e = s:sub(i, i)

				if (e == "\n" or e == "\r") and e ~= d then
					i = i + 1
				end
			elseif d == "x" then
				local h = s:match("^%x%x", i + 2)

				if not h then
					self:err("hexadecimal digit expected")
				end
				out[#out + 1] = string.char(tonumber(h, 16))
				i = i + 4
			elseif d == "z" then
				i = i + 2
				while true do
					local w = s:sub(i, i)

					if w == "\n" then
						self.line = self.line + 1
					elseif not w:match("^%s$") then
						break
					end
					i = i + 1
				end
			elseif d:match("^%d$") then
				local n = s:match("^%d%d?%d?", i + 1)
				local v = tonumber(n)

				if v > 255 then
					self:err("decimal escape too large")
				end
				out[#out + 1] = string.char(v)
				i = i + 1 + #n
			elseif d == "u" then
				local h = s:match("^{(%x+)}", i + 2)

				if not h then self:err("missing '{' in \\u{xxxx}") end
				local cp = tonumber(h, 16)

				if cp >= 0x80000000 then
					self:err("UTF-8 value too large")
				end
				out[#out + 1] = utf8enc(cp)
				i = i + 4 + #h
			else
				self:err("invalid escape sequence '\\" .. d .. "'")
			end
		else
			local j = s:find("[\\\n\r" .. q .. "]", i)

			if not j then self:err("unfinished string") end
			out[#out + 1] = s:sub(i, j - 1)
			i = j
		end
	end
	self.pos = i
	return table.concat(out)
end

function lex:number()
	local s, i = self.src, self.pos
	local text

	if s:match("^0[xX]", i) then
		text = s:match("^0[xX]%x*%.?%x*", i)
		local e = s:match("^[pP][+-]?%d+", i + #text)

		if e then text = text .. e end
	else
		text = s:match("^%d*%.?%d*", i)
		local e = s:match("^[eE][+-]?%d+", i + #text)

		if e then text = text .. e end
	end
	-- A numeral running straight into a name is malformed, as in
	-- `3x` or `0xg`.
	local tail = s:match("^[%w_.]+", i + #text)

	if tail then text = text .. tail end
	local v = tonumber(text)

	if not v then self:err("malformed number near '" .. text .. "'") end
	self.pos = i + #text
	return v
end

-- The next token, or {kind = "eof"}.
function lex:next()
	local s = self.src

	while true do
		local i = self.pos
		local c = s:sub(i, i)

		if c == "" then
			return {kind = "eof", line = self.line}
		elseif c == "\n" then
			self.line = self.line + 1
			self.pos = i + 1
		elseif c == " " or c == "\t" or c == "\r" or c == "\f" or
		       c == "\v" then
			self.pos = i + 1
		elseif c == "-" and s:sub(i + 1, i + 1) == "-" then
			local level = longopen(s, i + 2)

			if level then
				self.pos = i + 2
				self:longstring(level)
			else
				local e = s:find("\n", i, true) or #s + 1

				self.pos = e
			end
		else
			break
		end
	end
	local i = self.pos
	local c = s:sub(i, i)
	local line = self.line

	if c:match("^[%a_]") then
		local w = s:match("^[%w_]+", i)

		self.pos = i + #w
		if KEYWORD[w] then return {kind = w, line = line} end
		return {kind = "name", val = w, line = line}
	end
	if c:match("^%d") or (c == "." and s:match("^%.%d", i)) then
		return {kind = "number", val = self:number(), line = line}
	end
	if c == '"' or c == "'" then
		return {kind = "string", val = self:shortstring(c), line = line}
	end
	if c == "[" then
		local level = longopen(s, i)

		if level then
			return {kind = "string", val = self:longstring(level),
				line = line}
		end
	end
	local p3, p2 = s:sub(i, i + 2), s:sub(i, i + 1)

	if PUNCT3[p3] then
		self.pos = i + 3
		return {kind = p3, line = line}
	elseif PUNCT2[p2] then
		self.pos = i + 2
		return {kind = p2, line = line}
	elseif PUNCT1[c] then
		self.pos = i + 1
		return {kind = c, line = line}
	end
	self:err("unexpected symbol near '" .. c .. "'")
end

return lex
