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
local ENDMARK = {kind = "__end"}

local DIRECTIVE = {
	define = true, undef = true, include = true, ["if"] = true,
	ifdef = true, ifndef = true, elif = true, ["else"] = true,
	endif = true, error = true, warning = true, pragma = true,
	line = true,
}

function cpp.new(opts)
	local c = setmetatable({
		files = {},		-- stack of open lexers
		exp = {},		-- stack of active expansions and pushbacks
		macros = {},
		conds = {},		-- stack of conditional states
		path = opts.path or {},
		open = opts.open or function(p)
			local f = io.open(p, "rb")
			if not f then return nil end
			local buf, pos, done = "", 1, false
			return function()
				if done then return nil end
				if pos > #buf then
					buf = f:read(4096) or ""
					pos = 1
					if buf == "" then
						done = true
						f:close()
						return nil
					end
				end
				local ch = buf:sub(pos, pos)
				pos = pos + 1
				return ch
			end
		end,
		slot = {{}, {}},
		turn = 0,
	}, cpp)
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
	return c
end

function cpp:err(msg)
	local f = self.files[#self.files]
	error(("%s:%d: %s"):format(f and f.lx.name or "-",
		f and f.lx.line or 0, msg), 0)
end

-- token plumbing -------------------------------------------------------

local function copytok(t)
	return {kind = t.kind, text = t.text, val = t.val, line = t.line,
		bol = t.bol, ws = t.ws}
end

-- A pushed-back token is a one-token expansion, so it is read before
-- anything below it and after anything above it.  One stack, one order.
function cpp:push(t)
	self.exp[#self.exp + 1] = {toks = {t}, i = 1, real = true}
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
	self.exp[#self.exp + 1] = {name = name, toks = toks, i = 1}
end

-- The next token as written, with no macro expansion.
function cpp:src()
	while #self.exp > 0 do
		local e = self.exp[#self.exp]
		if e.i <= #e.toks then
			local t = e.toks[e.i]
			e.i = e.i + 1
			return t
		end
		self.exp[#self.exp] = nil
	end
	while #self.files > 0 do
		local f = self.files[#self.files]
		if f.back then
			local t = f.back
			f.back = nil
			return t
		end
		local t = f.lx:next()
		if t.kind ~= "eof" then
			return copytok(t)
		end
		self.files[#self.files] = nil
	end
	return {kind = "eof", bol = true}
end

function cpp:active(name)
	for i = 1, #self.exp do
		if self.exp[i].name == name then return true end
	end
	return false
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
			if p == "..." then
				m.variadic = true
				m.params[#m.params + 1] = "__VA_ARGS__"
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
function cpp:bodytokens(m, line)
	return self:lexstring(m.body, line)
end

-- Lex a body, or an argument, into a fresh token list.
function cpp:lexstring(s, line)
	local i, n = 0, #s
	local l = lex.new(function()
		i = i + 1
		if i > n then return nil end
		return s:sub(i, i)
	end, "<macro>", true)
	local out = {}
	while true do
		local t = l:next()
		if t.kind == "eof" then break end
		local u = copytok(t)
		u.line = line
		u.bol = false
		out[#out + 1] = u
	end
	return out
end

local function spell(toks)
	local out = {}
	for i, t in ipairs(toks) do
		if i > 1 and t.ws then out[#out + 1] = " " end
		if t.kind == "str" then
			out[#out + 1] = '"' .. t.text:gsub('[\\"]', "\\%0") .. '"'
		else
			out[#out + 1] = t.text or (t.val and tostring(t.val)) or
					t.kind
		end
	end
	return table.concat(out)
end

-- Collect one macro call's arguments, from the '(' onward.
function cpp:arguments(m)
	local t = self:src()
	if t == ENDMARK or t.kind ~= "(" then
		self:push(t)
		return nil
	end
	local args, cur, depth = {}, {}, 0
	while true do
		t = self:src()
		if t == ENDMARK then
			self:push(t)
			self:err("macro call crosses an expansion")
		end
		if t.kind == "eof" then self:err("unterminated macro call") end
		if t.kind == "(" then
			depth = depth + 1
		elseif t.kind == ")" then
			if depth == 0 then
				args[#args + 1] = cur
				break
			end
			depth = depth - 1
		elseif t.kind == "," and depth == 0 then
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
		if t == ENDMARK or t.kind == "eof" then break end
		if not self:tryexpand(t) then
			out[#out + 1] = t
		end
	end
	return out
end

-- Substitute arguments into a body and push the result.
function cpp:substitute(m, args, line)
	local body = self:bodytokens(m, line)
	if body[1] then body[1].ws = false end
	local idx = {}
	for i, p in ipairs(m.params or {}) do idx[p] = i end
	local out = {}
	local i = 1
	while i <= #body do
		local t = body[i]
		local nxt = body[i + 1]
		local k = t.kind == "name" and idx[t.text]

		if t.kind == "#" and nxt and idx[nxt.text or ""] then
			out[#out + 1] = {kind = "str",
					 text = spell(args[idx[nxt.text]] or {}),
					 line = line, ws = t.ws}
			i = i + 2
		elseif t.kind == "##" and #out > 0 and nxt then
			-- Paste onto what was emitted last, so a chain of
			-- pastes joins left to right.
			local rk = nxt.kind == "name" and idx[nxt.text]
			local b = rk and (args[rk] or {}) or {nxt}
			local left = out[#out]
			out[#out] = nil
			local ws = left.ws
			local joined = self:lexstring(
				spell{left} .. spell(b), line)
			if joined[1] then joined[1].ws = ws end
			for _, u in ipairs(joined) do out[#out + 1] = u end
			i = i + 2
		elseif k then
			-- An operand of ## goes in unexpanded.
			local sub
			if nxt and nxt.kind == "##" then
				sub = args[k] or {}
			else
				sub = self:expandlist(args[k] or {})
			end
			for j, u in ipairs(sub) do
				local v = copytok(u)
				if j == 1 then v.ws = t.ws end
				out[#out + 1] = v
			end
			i = i + 1
		else
			out[#out + 1] = t
			i = i + 1
		end
	end
	self:pushlist(out, m.name)
end

function cpp:tryexpand(t)
	if t.kind ~= "name" then return false end
	local m = self.macros[t.text]
	if not m or self:active(t.text) then return false end
	if t.text == "__LINE__" then
		self:push({kind = "num", val = t.line, line = t.line, ws = t.ws})
		return true
	end
	if t.text == "__FILE__" then
		local f = self.files[#self.files]
		self:push({kind = "str", text = f and f.lx.name or "-",
			   line = t.line, ws = t.ws})
		return true
	end
	if m.params then
		local args = self:arguments(m)
		if not args then return false end
		self:substitute(m, args, t.line)
	else
		local body = self:bodytokens(m, t.line)
		if body[1] then body[1].ws = t.ws end
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
		if t.kind == "eof" then return out end
		if t.bol then
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

function cpp:emitting()
	for i = 1, #self.conds do
		if not self.conds[i].emit then return false end
	end
	return true
end

function cpp:include(name, angled, primary)
	local dirs = {}
	if not angled and #self.files > 0 then
		local cur = self.files[#self.files].lx.name
		dirs[#dirs + 1] = cur:match("^(.*)/[^/]*$") or "."
	end
	if primary then dirs = {""} end
	for _, d in ipairs(self.path) do dirs[#dirs + 1] = d end
	for _, d in ipairs(dirs) do
		local p = d == "" and name or (d .. "/" .. name)
		local read = self.open(p)
		if read then
			if #self.files > 60 then self:err("includes too deep") end
			self.files[#self.files + 1] =
				{lx = lex.new(read, p, true)}
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
		if t.kind == "num" then return t.val end
		if t.kind == "name" then return 0 end
		if t.kind == "(" then
			local v = cond()
			if peek() and peek().kind == ")" then take() end
			return v
		end
		if t.kind == "!" then return unary() == 0 and 1 or 0 end
		if t.kind == "-" then return -unary() end
		if t.kind == "+" then return unary() end
		if t.kind == "~" then return ~unary() end
		return 0
	end

	function binary(minp)
		local a = unary()
		while true do
			local t = peek()
			local p = t and PREC[t.kind]
			if not p or p < minp then return a end
			take()
			a = evalbin(t.kind, a, binary(p + 1))
		end
	end

	function cond()
		local a = binary(1)
		if peek() and peek().kind == "?" then
			take()
			local b = cond()
			if peek() and peek().kind == ":" then take() end
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
		if t.kind == "name" and t.text == "defined" then
			local j = i + 1
			local paren = toks[j] and toks[j].kind == "("
			if paren then j = j + 1 end
			local n = toks[j]
			local v = (n and n.kind == "name" and
				   self.macros[n.text]) and 1 or 0
			j = j + 1
			if paren and toks[j] and toks[j].kind == ")" then
				j = j + 1
			end
			out[#out + 1] = {kind = "num", val = v, line = t.line}
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
	if d.bol then			-- a bare # is nothing
		self:push(d)
		return
	end
	local name = d.kind == "name" and d.text or d.kind
	if not DIRECTIVE[name] then
		self:skipline()
		return
	end

	-- conditionals are read even inside a group that is not emitting
	if name == "if" or name == "ifdef" or name == "ifndef" then
		if not self:emitting() then
			self:skipline()
			self.conds[#self.conds + 1] = {emit = false, taken = true}
			return
		end
		local v
		if name == "if" then
			v = self:ifvalue(self:line())
		else
			local t = self:line()[1]
			v = (t and t.kind == "name" and self.macros[t.text])
				and true or false
			if name == "ifndef" then v = not v end
		end
		self.conds[#self.conds + 1] = {emit = v, taken = v}
		return
	end
	if name == "elif" then
		local c = self.conds[#self.conds]
		if not c then self:err("#elif without #if") end
		if c.taken or not self:emitting_outer() then
			self:skipline()
			c.emit = false
		else
			c.emit = self:ifvalue(self:line())
			c.taken = c.taken or c.emit
		end
		return
	end
	if name == "else" then
		local c = self.conds[#self.conds]
		if not c then self:err("#else without #if") end
		self:line()
		c.emit = not c.taken and self:emitting_outer()
		c.taken = true
		return
	end
	if name == "endif" then
		if #self.conds == 0 then self:err("#endif without #if") end
		self:line()
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
		if t and t.kind == "name" then self.macros[t.text] = nil end
		return
	end
	if name == "include" then
		local f = self.files[#self.files]
		local hname, angled = f and f.lx:headername()
		if not hname then
			local toks = self:expandlist(self:line())
			local s = spell(toks)
			hname = s:match("^%s*[<\"](.-)[>\"]%s*$")
			angled = s:match("^%s*<") ~= nil
			if not hname then self:err("bad #include") end
		else
			self:line()
		end
		if not self:include(hname, angled) then
			self:err("cannot find " .. hname)
		end
		return
	end
	if name == "error" then
		self:err("#error " .. spell(self:line()))
	end
	self:skipline()			-- warning, pragma, line
end

-- Every conditional above this one is emitting.
function cpp:emitting_outer()
	for i = 1, #self.conds - 1 do
		if not self.conds[i].emit then return false end
	end
	return true
end

-- output ----------------------------------------------------------------

function cpp:out(t)
	self.turn = self.turn % 2 + 1
	local u = self.slot[self.turn]
	u.kind = t.kind
	if t.kind == "name" and lex.KEYWORD[t.text] then u.kind = t.text end
	u.text, u.val, u.line = t.text, t.val, t.line
	u.file = self.files[#self.files] and self.files[#self.files].lx.name
	return u
end

-- One fully expanded token, with directives and switched-off groups gone.
function cpp:scan()
	while true do
		local t = self:src()
		if t.kind == "#" and t.bol and self:fromfile() then
			self:directive()
		elseif t.kind == "eof" then
			return t
		elseif not self:emitting() then
			-- inside a group that is switched off
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
	if t.kind == "str" then
		t = copytok(t)
		while true do
			local n = self:scan()
			if n.kind ~= "str" then
				self.ahead = copytok(n)
				break
			end
			t.text = t.text .. n.text
		end
	end
	return self:out(t)
end

return cpp
