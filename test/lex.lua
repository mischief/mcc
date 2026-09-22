-- SPDX-License-Identifier: ISC
-- What the tokenizer makes of the spellings a program is allowed to use
-- and a test program cannot easily hold: line endings, splices inside a
-- comment, digraphs, and the characters a name may be written with.
--
--   lua5.4 test/lex.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local lex = require "lex"

-- The token stream as kinds and texts, one word each, so a case reads as
-- what the source says rather than as a table.
local function toks(src)
	-- Preprocessing mode: it is how the compiler reads a file, and a
	-- keyword is still a name at that point.
	local l = lex.new(src, "-", true)
	local out = {}

	while true do
		local t = l:next()

		if t[1] == "eof" then break end
		out[#out + 1] = t[2] or t[1]
	end
	return table.concat(out, " ")
end

local function case(name, src, want)
	local got = tap.try(name, toks, src)

	if got ~= nil then tap.is(got, want, name) end
end

case("crlf splice",
	"int a\r\n= \\\r\n3;\r\n", "int a = 3 ;")
case("line comment spliced on",
	"int a = 1; // one \\\n and still the comment\nint b;",
	"int a = 1 ; int b ;")
case("block comment over a line",
	"int /* two\nlines */ a;", "int a ;")
case("digraphs for brackets and braces",
	"int a<:2:> = <%1,2%>;", "int a [ 2 ] = { 1 , 2 } ;")
case("digraphs for the directive characters",
	"%:define CAT(a,b) a%:%:b", "# define CAT ( a , b ) a ## b")
case("a name may start with a dollar",
	"int $x, y$z;", "int $x , y$z ;")
case("a lone apostrophe is a token",
	"#define aqu(x) x'\nint a;", "# define aqu ( x ) x ' int a ;")
case("a character constant spliced in two",
	"char c = '\\\n\\0';", "char c = '\\000' ;")
case("an escaped apostrophe still closes",
	"char c = '\\'';", "char c = '\\047' ;")
case("a name may hold utf-8",
	"int \195\169t\195\169;", "int \195\169t\195\169 ;")

-- A wide literal carries code points, not the bytes that spell them.
local function points(src)
	local l = lex.new(src, "-")
	local t = l:next()
	local out = {}

	for _, v in ipairs(t[3] or {}) do out[#out + 1] = ("%x"):format(v) end
	return table.concat(out, " ")
end

local function wide(name, src, want)
	local got = tap.try(name, points, src)

	if got ~= nil then tap.is(got, want, name) end
end

wide("utf-8 source in a wide literal", 'U"a\195\169z"', "61 e9 7a")
wide("a hex escape keeps its whole value", 'U"\\x1f9b4"', "1f9b4")
wide("an octal escape is not cut to a byte", 'U"\\777"', "1ff")
wide("a universal character name", 'u"\\u00e9\\U0001f9b4"', "e9 1f9b4")
wide("a narrow literal carries no points", '"\195\169"', "")

tap.done()
