-- The preprocessor.
--
-- A token filter between the lexer and the parser.  Macro bodies are kept as
-- text and lexed again at each expansion, which costs a little time and saves
-- the memory a token list per macro would take: Lua's own headers are 874
-- macros and 45 KB of body text, and 475 of them take arguments.
--
-- Files nest on a stack and expansions nest on another, with pushed-back
-- tokens riding the expansion stack so that one order governs everything.
-- Nothing else is held.

local lex = require "lex"

local cpp = {}
cpp.__index = cpp

-- Marks the end of a list being expanded, so a nested expansion cannot run
-- off it and start eating the file.
local ENDMARK = {"__end"}

local DIRECTIVE = {
	define = true, undef = true, include = true, include_next = true,
	["if"] = true,
	ifdef = true, ifndef = true, elif = true, ["else"] = true,
	endif = true, error = true, warning = true, pragma = true,
	line = true,
}

function cpp.new(opts)
	local c = setmetatable({
		files = {},		-- stack of open lexers
		exp = {},		-- stack of active expansions and pushbacks
		busy = {},		-- macros that are expanding, by name
		macros = {},
		conds = {},		-- stack of conditional states
		curdir = 0,		-- include directory of the last token
		once = {},		-- files that said #pragma once
		read = {},		-- every file opened, for -MD
		off = 0,		-- how many of them are switched off
		path = opts.path or {},
		-- the whole file, because the tokenizer indexes it.  A
		-- tree of thirty sources reads the same seventy headers
		-- again for each of them -- sixteen megabytes to see one
		-- -- so the text is kept, and a caller that compiles more
		-- than one file can hand the same table to each.
		open = opts.open or function(p)
			local f = io.open(p, "rb")

			if not f then return nil end
			local text = f:read("a")

			f:close()
			return text
		end,
		text = opts.text or {},
		slot = {{}, {}},
		turn = 0,
	}, cpp)
	if os.getenv("MEM") then rawset(_G, "__cpp", c) end
	c.macros.__STDC__ = {body = "1"}
	c.macros.__STDC_VERSION__ = {body = "199901L"}
	-- These two are answered in tryexpand; the entries only make the
	-- lookup find them.
	c.macros.__LINE__ = {body = "0"}
	c.macros.__FILE__ = {body = '""'}
	for k, v in pairs(opts.define or {}) do
		c.macros[k] = cpp.parsedefine(k .. " " .. (v == true and "1" or v))
	end
	c.name = opts.file or "-"
	if opts.file then
		assert(c:include(opts.file, false, true), "cannot open " .. opts.file)
	end
	-- -include names a header to read before the file itself.  They go
	-- on the stack under it, last first, so they are read in order.
	local pre = opts.preinclude or {}
	for i = #pre, 1, -1 do
		-- named from where the compiler was run first, then from
		-- the include path, which is what gcc does
		assert(c:include(pre[i], false, true) or
		       c:include(pre[i], false),
			"cannot open " .. pre[i])
	end
	return c
end

function cpp:err(msg)
	local f = self.files[#self.files]
	error(("%s:%d: %s"):format(f and f.lx.name or "-",
		f and f.lx.line or 0, msg), 0)
end

-- token plumbing -------------------------------------------------------

local function copytok(t)
	return {t[1], t[2], t[3], t[4], t[5], t[6], t[7]}
end

-- A pushed-back token is a one-token expansion, so it is read before
-- anything below it and after anything above it.  One stack, one order.
function cpp:push(t)
	self.exp[#self.exp + 1] = {toks = {t}, i = 1, n = 1, real = true}
end

-- A directive line is read one token too far, and that token belongs to the
-- file it came from, not to whatever #include is about to push on top.
function cpp:pushfile(t)
	local f = self.files[#self.files]
	if f then f.back = t else self:push(t) end
end

-- True when nothing above the file is still producing tokens.  A '#' that
-- came out of a macro is not a directive; one that was merely pushed back
-- still is.  A frame with nothing left in it does not count: it is only
-- waiting to be popped, and popping it early would re-enable its macro.
function cpp:fromfile()
	for i = 1, #self.exp do
		local e = self.exp[i]
		if not e.real and e.i <= #e.toks then return false end
	end
	return true
end

function cpp:pushlist(toks, name)
	self.exp[#self.exp + 1] = {name = name, toks = toks, i = 1,
				   n = #toks}
	if name then self.busy[name] = (self.busy[name] or 0) + 1 end
end

-- The next token as written, with no macro expansion.  This runs for every
-- token of every file, so each frame carries its own length rather than
-- being measured again on the way past.
function cpp:src()
	local exp = self.exp
	local n = #exp

	while n > 0 do
		local e = exp[n]
		local i = e.i

		if i <= e.n then
			e.i = i + 1
			return e.toks[i]
		end
		if e.name then self.busy[e.name] = self.busy[e.name] - 1 end
		exp[n] = nil
		n = n - 1
	end
	local files = self.files

	n = #files
	while n > 0 do
		local f = files[n]

		if f.back then
			local t = f.back

			f.back = nil
			return t
		end
		local t = f.lx:next()

		-- which include directory this file came from, for
		-- #include_next: the file is popped as soon as its last
		-- token is read, so it cannot be asked afterwards
		if t[1] ~= "eof" then
			self.curdir = f.dir or 0
			return t
		end
		files[n] = nil
		n = n - 1
	end
	return {"eof", nil, nil, 0, true, false}
end

function cpp:active(name)
	return (self.busy[name] or 0) > 0
end

-- macros ---------------------------------------------------------------

-- "NAME(a,b) body" or "NAME body", from the text after #define.
function cpp.parsedefine(text)
	local name, rest = text:match("^%s*([A-Za-z_][A-Za-z0-9_]*)(.*)$")
	if not name then return nil end
	local m = {}
	local params = rest:match("^%(([^)]*)%)")
	if params ~= nil and rest:sub(1, 1) == "(" then
		m.params = {}
		for p in params:gmatch("[^,%s]+") do
			-- GNU lets the rest have a name of its own, which
			-- the body then uses in place of __VA_ARGS__.
			local named = p:match("^([A-Za-z_][A-Za-z0-9_]*)%.%.%.$")

			if p == "..." then
				m.variadic = true
				m.params[#m.params + 1] = "__VA_ARGS__"
			elseif named then
				m.variadic = true
				m.params[#m.params + 1] = named
			else
				m.params[#m.params + 1] = p
			end
		end
		rest = rest:sub(#params + 3)
	end
	m.body = rest:gsub("^%s+", "")
	m.name = name
	return m, name
end

-- Measured and dropped: a bounded cache of lexed macro bodies saved 11% of
-- the garbage and cost 87 KB of live memory, which is the wrong trade here.
-- A macro body is stored as text and has to be tokens to be substituted.
-- Tokenizing it again on every expansion is most of what a preprocessor
-- does when a header defines a macro that a thousand lines use, so the
-- tokens are kept and copied.  A redefinition makes a new record and takes
-- its cache with it.
function cpp:bodytokens(m, line)
	local cache = m.toks

	if not cache then
		cache = self:lexstring(m.body, 0)
		m.toks = cache
	end
	local out = {}

	for i = 1, #cache do
		local t = cache[i]

		out[i] = {t[1], t[2], t[3], line, false, t[6]}
	end
	return out
end

-- Lex a body, or an argument, into a fresh token list.
function cpp:lexstring(s, line)
	local l = lex.new(s, "<macro>", true)
	local out = {}
	while true do
		local t = l:next()

		if t[1] == "eof" then break end
		t[4], t[5] = line, false
		out[#out + 1] = t
	end
	return out
end

local function spell(toks)
	local out = {}
	for i, t in ipairs(toks) do
		if i > 1 and t[6] then out[#out + 1] = " " end
		if t[1] == "str" then
			out[#out + 1] = '"' .. t[2]:gsub('[\\"]', "\\%0") .. '"'
		else
			out[#out + 1] = t[2] or (t[3] and tostring(t[3])) or
					t[1]
		end
	end
	return table.concat(out)
end

-- Collect one macro call's arguments, from the '(' onward.
-- One token of a macro argument, with any directive between them
-- handled: a conditional may stand inside a macro call, and a driver
-- writes one there to pick a word by endianness.
function cpp:argtok()
	while true do
		local t = self:src()

		if t[1] == "#" and t[5] and self:fromfile() then
			self:directive()
		elseif t[1] == "eof" or self:emitting() then
			return t
		end
	end
end

function cpp:arguments(m)
	local t = self:argtok()
	if t == ENDMARK or t[1] ~= "(" then
		self:push(t)
		return nil
	end
	local args, cur, depth = {}, {}, 0
	while true do
		t = self:argtok()
		if t == ENDMARK then
			self:push(t)
			self:err("macro call crosses an expansion")
		end
		if t[1] == "eof" then self:err("unterminated macro call") end
		if t[1] == "(" then
			depth = depth + 1
		elseif t[1] == ")" then
			if depth == 0 then
				args[#args + 1] = cur
				break
			end
			depth = depth - 1
		elseif t[1] == "," and depth == 0 then
			local last = m.variadic and #m.params or math.huge
			if #args + 1 < last then
				args[#args + 1] = cur
				cur = {}
				goto continue
			end
		end
		cur[#cur + 1] = t
		::continue::
	end
	if #args == 1 and #args[1] == 0 and #m.params == 0 then
		args = {}
	end
	return args
end

-- Run a token list through expansion and return the result.
function cpp:expandlist(toks)
	local list = {}
	for i = 1, #toks do list[i] = toks[i] end
	list[#list + 1] = ENDMARK
	self:pushlist(list, nil)
	local out = {}
	while true do
		local t = self:src()
		if t == ENDMARK or t[1] == "eof" then break end
		if not self:tryexpand(t) then
			out[#out + 1] = t
		end
	end
	return out
end

-- Substitute arguments into a body and push the result.
function cpp:substitute(m, args, line, ws)
	local body = self:bodytokens(m, line)
	-- What came before the macro name came before its expansion, which
	-- is the space in `movq CPUVAR(SELF),%rax`.
	if body[1] then body[1][6] = ws or false end
	local idx = {}
	for i, p in ipairs(m.params or {}) do idx[p] = i end
	local out = {}
	local i = 1
	while i <= #body do
		local t = body[i]
		local nxt = body[i + 1]
		local k = t[1] == "name" and idx[t[2]]

		-- C23 __VA_OPT__(x): x, but only when the rest is not
		-- empty.  Its own parentheses are balanced, so finding the
		-- end is a count.
		if m.variadic and t[1] == "name" and t[2] == "__VA_OPT__"
		   and nxt and nxt[1] == "(" then
			local rest = args[#m.params] or {}
			local depth, j = 1, i + 2

			while j <= #body and depth > 0 do
				local u = body[j]

				if u[1] == "(" then depth = depth + 1
				elseif u[1] == ")" then
					depth = depth - 1
					if depth == 0 then break end
				end
				if #rest > 0 then
					out[#out + 1] = u
				end
				j = j + 1
			end
			i = j + 1
			goto continue
		end
		if t[1] == "#" and nxt and idx[nxt[2] or ""] then
			out[#out + 1] = {"str",
				spell(args[idx[nxt[2]]] or {}), nil, line,
				false, t[6]}
			i = i + 2
		elseif t[1] == "##" and nxt and #out == 0 then
			-- Nothing on the left: an empty operand of ## is a
			-- place marker, and the paste is the other side.
			local rk = nxt[1] == "name" and idx[nxt[2]]

			for _, u in ipairs(rk and (args[rk] or {}) or {nxt}) do
				out[#out + 1] = copytok(u)
			end
			i = i + 2
		elseif t[1] == "##" and #out > 0 and nxt then
			-- Paste onto what was emitted last, so a chain of
			-- pastes joins left to right.
			local rk = nxt[1] == "name" and idx[nxt[2]]
			local b = rk and (args[rk] or {}) or {nxt}

			-- GNU `, ## rest` with nothing left over takes the
			-- comma with it, so a call may leave the rest out.
			if m.variadic and rk == #m.params and #b == 0 and
			   out[#out][1] == "," then
				out[#out] = nil
				i = i + 2
				goto continue
			end
			local left = out[#out]
			out[#out] = nil
			local ws = left[6]
			local joined = self:lexstring(
				spell{left} .. spell(b), line)
			if joined[1] then joined[1][6] = ws end
			for _, u in ipairs(joined) do out[#out + 1] = u end
			i = i + 2
		elseif k then
			-- An operand of ## goes in unexpanded.
			local sub
			if nxt and nxt[1] == "##" then
				sub = args[k] or {}
			else
				sub = self:expandlist(args[k] or {})
			end
			for j, u in ipairs(sub) do
				local v = copytok(u)
				if j == 1 then v[6] = t[6] end
				out[#out + 1] = v
			end
			i = i + 1
		else
			out[#out + 1] = t
			i = i + 1
		end
		::continue::
	end
	self:pushlist(out, m.name)
end

function cpp:tryexpand(t)
	if t[1] ~= "name" then return false end
	local m = self.macros[t[2]]
	if not m then return false end
	-- A name left alone because its own macro was expanding is left
	-- alone for good.  Field 7 carries that mark, which matters once
	-- the token outlives the expansion: an argument that stands in
	-- several places in a body is one copy each.
	if t[7] and t[7][t[2]] then return false end
	if self:active(t[2]) then
		local h = t[7]

		if not h then h = {}; t[7] = h end
		h[t[2]] = true
		return false
	end
	if t[2] == "__LINE__" then
		self:push({"num", nil, t[4], t[4], false, t[6]})
		return true
	end
	if t[2] == "__FILE__" then
		local f = self.files[#self.files]
		self:push({"str", f and f.lx.name or "-", nil, t[4],
			false, t[6]})
		return true
	end
	if m.params then
		local args = self:arguments(m)
		if not args then return false end
		self:substitute(m, args, t[4], t[6])
	else
		local body = self:bodytokens(m, t[4])
		if body[1] then body[1][6] = t[6] end
		self:pushlist(body, m.name)
	end
	return true
end

-- directives ------------------------------------------------------------

-- The rest of the directive line, as written.  The token that starts the
-- next line is pushed back.
function cpp:line()
	local out = {}
	while true do
		local t = self:src()
		if t[1] == "eof" then return out end
		if t[5] then
			self:pushfile(t)
			return out
		end
		out[#out + 1] = t
	end
end

-- Throw away the rest of a directive line without lexing it.
function cpp:skipline()
	local f = self.files[#self.files]
	if f then
		f.back = nil
		f.lx:skipline()
	else
		self:line()
	end
end

-- How many open conditionals are switched off.  This is asked of every
-- token, so it is counted rather than walked; `setemit` is the only place
-- a flag changes.
function cpp:setemit(c, v)
	if c.emit == v then return end
	self.off = self.off + (v and -1 or 1)
	c.emit = v
end

function cpp:emitting()
	return self.off == 0
end

-- `next` is #include_next: carry on from where the file doing the
-- including was found, rather than starting over.
function cpp:include(name, angled, primary, next)
	local dirs, from = {}, {}
	if not angled and #self.files > 0 then
		local cur = self.files[#self.files].lx.name
		dirs[1] = cur:match("^(.*)/[^/]*$") or "."
		from[1] = 0
	end
	if primary then dirs, from = {""}, {0} end
	-- An ordinary include searches every directory; include_next only
	-- those after the one the including file was found in.
	local after = -1
	for i, d in ipairs(self.path) do
		dirs[#dirs + 1] = d
		from[#from + 1] = i
	end
	if next then after = self.curdir or 0 end
	for k, d in ipairs(dirs) do
		local p = d == "" and name or (d .. "/" .. name)
		local read = from[k] > after and self.text[p]

		if read == nil then
			read = self.open(p) or false
			self.text[p] = read
		end
		if read and from[k] > after then
			self.read[#self.read + 1] = p
			-- A file that asked to be read once is not read
			-- again, wherever the name came from.
			if self.once[p] then return true end
			if #self.files > 60 then self:err("includes too deep") end
			self.files[#self.files + 1] =
				{lx = lex.new(read, p, true), path = p,
				 dir = from[k]}
			return true
		end
	end
	return false
end

-- #if expressions.  Identifiers that survive expansion are zero, as C says.
local PREC = {
	["||"] = 1, ["&&"] = 2, ["|"] = 3, ["^"] = 4, ["&"] = 5,
	["=="] = 6, ["!="] = 6,
	["<"] = 7, ["<="] = 7, [">"] = 7, [">="] = 7,
	["<<"] = 8, [">>"] = 8,
	["+"] = 9, ["-"] = 9,
	["*"] = 10, ["/"] = 10, ["%"] = 10,
}

-- #if arithmetic is integral; anything else is truncated rather than
-- stopping the compile.
local function int(v)
	return math.tointeger(v) or math.tointeger(v // 1) or 0
end

local function evalbin(op, a, b)
	a, b = int(a), int(b)
	if op == "||" then return (a ~= 0 or b ~= 0) and 1 or 0 end
	if op == "&&" then return (a ~= 0 and b ~= 0) and 1 or 0 end
	if op == "|" then return a | b end
	if op == "^" then return a ~ b end
	if op == "&" then return a & b end
	if op == "==" then return a == b and 1 or 0 end
	if op == "!=" then return a ~= b and 1 or 0 end
	if op == "<" then return a < b and 1 or 0 end
	if op == "<=" then return a <= b and 1 or 0 end
	if op == ">" then return a > b and 1 or 0 end
	if op == ">=" then return a >= b and 1 or 0 end
	if op == "<<" then return a << b end
	if op == ">>" then return a >> b end
	if op == "+" then return a + b end
	if op == "-" then return a - b end
	if op == "*" then return a * b end
	if op == "/" then return b == 0 and 0 or a // b end
	if op == "%" then return b == 0 and 0 or a % b end
	return 0
end

function cpp:evalexpr(toks)
	local i = 1
	local function peek() return toks[i] end
	local function take() local t = toks[i]; i = i + 1; return t end
	local unary, binary, cond

	function unary()
		local t = take()
		if not t then return 0 end
		if t[1] == "num" then return t[3] end
		if t[1] == "name" then return 0 end
		if t[1] == "(" then
			local v = cond()
			if peek() and peek()[1] == ")" then take() end
			return v
		end
		if t[1] == "!" then return unary() == 0 and 1 or 0 end
		if t[1] == "-" then return -unary() end
		if t[1] == "+" then return unary() end
		if t[1] == "~" then return ~unary() end
		return 0
	end

	function binary(minp)
		local a = unary()
		while true do
			local t = peek()
			local p = t and PREC[t[1]]
			if not p or p < minp then return a end
			take()
			a = evalbin(t[1], a, binary(p + 1))
		end
	end

	function cond()
		local a = binary(1)
		if peek() and peek()[1] == "?" then
			take()
			local b = cond()
			if peek() and peek()[1] == ":" then take() end
			local c = cond()
			return a ~= 0 and b or c
		end
		return a
	end

	return cond()
end

-- `defined X` is resolved before the line is expanded.
function cpp:resolvedefined(toks)
	local out, i = {}, 1
	while i <= #toks do
		local t = toks[i]
		if t[1] == "name" and t[2] == "defined" then
			local j = i + 1
			local paren = toks[j] and toks[j][1] == "("
			if paren then j = j + 1 end
			local n = toks[j]
			local v = (n and n[1] == "name" and
				   self.macros[n[2]]) and 1 or 0
			j = j + 1
			if paren and toks[j] and toks[j][1] == ")" then
				j = j + 1
			end
			out[#out + 1] = {"num", nil, v, t[4], false, false}
			i = j
		else
			out[#out + 1] = t
			i = i + 1
		end
	end
	return out
end

function cpp:ifvalue(toks)
	return self:evalexpr(self:expandlist(self:resolvedefined(toks))) ~= 0
end

function cpp:directive()
	local d = self:src()
	if d[5] then			-- a bare # is nothing
		self:push(d)
		return
	end
	local name = d[1] == "name" and d[2] or d[1]
	if not DIRECTIVE[name] then
		self:skipline()
		return
	end

	-- conditionals are read even inside a group that is not emitting
	if name == "if" or name == "ifdef" or name == "ifndef" then
		if not self:emitting() then
			self:skipline()
			self.conds[#self.conds + 1] = {emit = false,
						       taken = true}
			self.off = self.off + 1
			return
		end
		local v
		if name == "if" then
			v = self:ifvalue(self:line())
		else
			local t = self:line()[1]
			v = (t and t[1] == "name" and self.macros[t[2]])
				and true or false
			if name == "ifndef" then v = not v end
		end
		self.conds[#self.conds + 1] = {emit = v, taken = v}
		if not v then self.off = self.off + 1 end
		return
	end
	if name == "elif" then
		local c = self.conds[#self.conds]
		if not c then self:err("#elif without #if") end
		if c.taken or not self:emitting_outer() then
			self:skipline()
			self:setemit(c, false)
		else
			self:setemit(c, self:ifvalue(self:line()))
			c.taken = c.taken or c.emit
		end
		return
	end
	if name == "else" then
		local c = self.conds[#self.conds]
		if not c then self:err("#else without #if") end
		self:line()
		self:setemit(c, not c.taken and self:emitting_outer())
		c.taken = true
		return
	end
	if name == "endif" then
		if #self.conds == 0 then self:err("#endif without #if") end
		self:line()
		local c = self.conds[#self.conds]

		if not c.emit then self.off = self.off - 1 end
		self.conds[#self.conds] = nil
		return
	end

	if not self:emitting() then
		self:skipline()
		return
	end

	if name == "define" then
		local toks = self:line()
		local m, key = cpp.parsedefine(spell(toks))
		if not m then self:err("bad #define") end
		self.macros[key] = m
		return
	end
	if name == "undef" then
		local t = self:line()[1]
		if t and t[1] == "name" then self.macros[t[2]] = nil end
		return
	end
	if name == "include" or name == "include_next" then
		local f = self.files[#self.files]
		-- not `f and f.lx:headername()`: an `and` is adjusted to
		-- one value, and the second one says whether the name was
		-- in angle brackets.  Losing it makes every <> search the
		-- including file's own directory first, which is how
		-- <signal.h> finds sys/signal.h and includes itself.
		local hname, angled

		if f then hname, angled = f.lx:headername() end
		if not hname then
			local toks = self:expandlist(self:line())
			local s = spell(toks)
			hname = s:match("^%s*[<\"](.-)[>\"]%s*$")
			angled = s:match("^%s*<") ~= nil
			if not hname then self:err("bad #include") end
		else
			self:line()
		end
		if not self:include(hname, angled, false,
				    name == "include_next") then
			self:err("cannot find " .. hname)
		end
		return
	end
	if name == "error" then
		self:err("#error " .. spell(self:line()))
	end
	if name == "pragma" then
		local toks = self:line()
		if toks[1] and toks[1][2] == "once" then
			local f = self.files[#self.files]
			if f and f.path then self.once[f.path] = true end
		end
		return
	end
	self:skipline()			-- warning, line
end

-- Every conditional above this one is emitting.
function cpp:emitting_outer()
	for i = 1, #self.conds - 1 do
		if not self.conds[i].emit then return false end
	end
	return true
end

-- output ----------------------------------------------------------------

-- The boundary: everything below holds tokens as six slots, and the parser
-- above holds one at a time and reads it by name.
function cpp:out(t)
	self.turn = self.turn % 2 + 1
	local u = self.slot[self.turn]
	local kind = t[1]

	if kind == "name" and lex.KEYWORD[t[2]] then kind = t[2] end
	u.kind, u.text, u.val, u.line = kind, t[2], t[3], t[4]
	-- where it stood on its line and whether anything came before it,
	-- which only -E has any use for
	u.bol, u.ws = t[5], t[6]
	local f = self.files[#self.files]

	u.file = f and f.lx.name
	return u
end

-- One fully expanded token, with directives and switched-off groups gone.
function cpp:scan()
	while true do
		local t = self:src()
		if t[1] == "#" and t[5] and self:fromfile() then
			self:directive()
		elseif t[1] == "eof" then
			return t
		elseif not self:emitting() then
			-- inside a group that is switched off
		elseif t[1] == "name" and t[2] == "_Pragma" then
			-- The operator form of #pragma.  Every pragma this
			-- compiler answers to is a directive, so the whole
			-- thing goes.
			local u = self:src()

			if u[1] ~= "(" then return t end
			repeat u = self:src() until u[1] == ")" or
				u[1] == "eof"
		elseif not self:tryexpand(t) then
			return t
		end
	end
end

function cpp:next()
	local t = self.ahead or self:scan()
	self.ahead = nil
	-- Adjacent string literals join, and either side may have come out of
	-- a macro, so the lookahead has to be past expansion.
	if t[1] == "str" then
		t = copytok(t)
		while true do
			local n = self:scan()
			if n[1] ~= "str" then
				self.ahead = copytok(n)
				break
			end
			t[2] = t[2] .. n[2]
		end
	end
	return self:out(t)
end

return cpp
