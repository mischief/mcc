-- SPDX-License-Identifier: ISC
-- Parser for Lua 5.4: source to a tree of statements and expressions,
-- with every name already resolved.
--
-- A name is a local of this function, an upvalue reached through the
-- functions around it, or a global, which is a field of whatever _ENV is
-- where it is read.  Settling that here means the code generator never
-- looks a name up, and it means each local knows before any code is
-- written for it whether a function inside captures it: a captured local
-- lives in a box of its own, and the box has to be made where the local
-- is declared.
--
-- The tree is plain tables with `k` saying what each node is.

local lex = require "mcc.lua.lex"

local P = {}
P.__index = P

-- Binary operators: left and right priority, as lparser.c has them.
local BINPRI = {
	["or"] = {1, 1}, ["and"] = {2, 2},
	["<"] = {3, 3}, [">"] = {3, 3}, ["<="] = {3, 3}, [">="] = {3, 3},
	["~="] = {3, 3}, ["=="] = {3, 3},
	["|"] = {4, 4}, ["~"] = {5, 5}, ["&"] = {6, 6},
	["<<"] = {7, 7}, [">>"] = {7, 7},
	[".."] = {9, 8},
	["+"] = {10, 10}, ["-"] = {10, 10},
	["*"] = {11, 11}, ["/"] = {11, 11}, ["//"] = {11, 11}, ["%"] = {11, 11},
	["^"] = {14, 13},
}
local UNARYPRI = 12

function P:adv()
	self.tok = self.ahead or self.lx:next()
	self.ahead = nil
end

function P:peek()
	self.ahead = self.ahead or self.lx:next()
	return self.ahead
end

function P:err(msg, line)
	self.lx:err(msg, line or self.tok.line)
end

local function show(t)
	if t.kind == "name" then return t.val end
	if t.kind == "string" or t.kind == "number" then
		return tostring(t.val)
	end
	if t.kind == "eof" then return "<eof>" end
	return t.kind
end

function P:check(kind)
	if self.tok.kind ~= kind then
		self:err(("'%s' expected near '%s'"):format(kind, show(self.tok)))
	end
end

function P:expect(kind)
	self:check(kind)
	self:adv()
end

function P:accept(kind)
	if self.tok.kind == kind then
		self:adv()
		return true
	end
	return false
end

-- `what` opened at line `line`; say so when its close is missing.
function P:match(what, who, line)
	if self.tok.kind == what then
		self:adv()
		return
	end
	if line == self.tok.line then
		self:expect(what)
	end
	self:err(("'%s' expected (to close '%s' at line %d) near '%s'")
		:format(what, who, line, show(self.tok)))
end

function P:name()
	self:check("name")
	local v = self.tok.val

	self:adv()
	return v
end

-- functions and scopes ----------------------------------------------------

local function newfunc(parent, line)
	return {parent = parent, line = line, params = {}, upvals = {},
		actvars = {}, vararg = false, blocks = {}, nfunc = 0}
end

function P:openblock(loop)
	local fs = self.fs
	local b = {nact = #fs.actvars, loop = loop}

	fs.blocks[#fs.blocks + 1] = b
	return b
end

function P:closeblock()
	local fs = self.fs
	local b = table.remove(fs.blocks)

	for i = #fs.actvars, b.nact + 1, -1 do fs.actvars[i] = nil end
end

function P:newvar(name, attrib)
	return {name = name, attrib = attrib, captured = false, fs = self.fs}
end

function P:activate(v)
	local a = self.fs.actvars

	a[#a + 1] = v
end

-- The index of the upvalue in `fs` that reaches `v`, made if need be.
-- `v` is a local of `fs.parent` or an upvalue of it.
local function upindex(fs, name, instack, ref)
	for i, u in ipairs(fs.upvals) do
		if u.instack == instack and u.ref == ref then return i end
	end
	-- The local at the end of the chain, whichever function it is in.
	local var = instack and ref or fs.parent.upvals[ref].var

	fs.upvals[#fs.upvals + 1] = {name = name, instack = instack, ref = ref,
				     var = var}
	return #fs.upvals
end

-- A local written after its declaration has to be shared by every
-- closure that captures it; one that never is can be copied into each.
local function written(t)
	if (t.k == "local" or t.k == "upval") and t.var then
		t.var.assigned = true
	end
end

-- Resolve `name` in `fs`: {k = "local", var} or {k = "upval", idx}, or
-- nil when no function out to the main chunk declares it.
local function resolve(fs, name)
	if not fs then return nil end
	for i = #fs.actvars, 1, -1 do
		local v = fs.actvars[i]

		if v.name == name then return {k = "local", var = v} end
	end
	for i, u in ipairs(fs.upvals) do
		if u.name == name then
			return {k = "upval", idx = i, var = u.var}
		end
	end
	local outer = resolve(fs.parent, name)

	if not outer then return nil end
	if outer.k == "local" then
		outer.var.captured = true
		return {k = "upval", idx = upindex(fs, name, true, outer.var),
			var = outer.var}
	end
	return {k = "upval", idx = upindex(fs, name, false, outer.idx),
		var = outer.var}
end

function P:singlevar(name)
	local r = resolve(self.fs, name)

	if r then
		r.name = name
		return r
	end
	-- A free name is a field of _ENV, which the main chunk always has.
	local env = resolve(self.fs, "_ENV")

	return {k = "index", obj = env, key = {k = "str", v = name},
		name = name}
end

-- expressions -------------------------------------------------------------

-- One value of an expression that might give several.
local MULTI = {call = true, method = true, vararg = true}

function P:explist()
	local l = {self:expr()}

	while self:accept(",") do l[#l + 1] = self:expr() end
	return l
end

function P:funcargs(line)
	local t = self.tok

	if t.kind == "string" then
		self:adv()
		return {{k = "str", v = t.val}}
	elseif t.kind == "{" then
		return {self:table()}
	elseif t.kind == "(" then
		self:adv()
		if self.tok.kind == ")" then
			self:adv()
			return {}
		end
		local l = self:explist()

		self:match(")", "(", line)
		return l
	end
	self:err("function arguments expected")
end

function P:primary()
	local t = self.tok

	if t.kind == "name" then
		self:adv()
		return self:singlevar(t.val)
	elseif t.kind == "(" then
		local line = t.line

		self:adv()
		local e = self:expr()

		self:match(")", "(", line)
		-- Parentheses cut a call or a vararg to one value.
		if MULTI[e.k] then return {k = "paren", e = e} end
		return e
	end
	self:err("unexpected symbol near '" .. show(t) .. "'")
end

function P:suffixed()
	local e = self:primary()

	while true do
		local t = self.tok
		local line = t.line

		if t.kind == "." then
			self:adv()
			e = {k = "index", obj = e,
			     key = {k = "str", v = self:name()}, line = line}
		elseif t.kind == "[" then
			self:adv()
			local key = self:expr()

			self:expect("]")
			e = {k = "index", obj = e, key = key, line = line}
		elseif t.kind == ":" then
			self:adv()
			local name = self:name()

			e = {k = "method", obj = e, name = name,
			     args = self:funcargs(line), line = line}
		elseif t.kind == "(" or t.kind == "string" or t.kind == "{" then
			e = {k = "call", fn = e, args = self:funcargs(line),
			     line = line}
		else
			return e
		end
	end
end

function P:table()
	local line = self.tok.line
	local items = {}

	self:expect("{")
	while self.tok.kind ~= "}" do
		if self.tok.kind == "name" and self:peek().kind == "=" then
			local k = {k = "str", v = self:name()}

			self:adv()
			items[#items + 1] = {key = k, val = self:expr()}
		elseif self.tok.kind == "[" then
			self:adv()
			local k = self:expr()

			self:expect("]")
			self:expect("=")
			items[#items + 1] = {key = k, val = self:expr()}
		else
			items[#items + 1] = {val = self:expr()}
		end
		if not self:accept(",") and not self:accept(";") then break end
	end
	self:match("}", "{", line)
	return {k = "table", items = items, line = line}
end

function P:simple()
	local t = self.tok

	if t.kind == "number" then
		self:adv()
		if math.type(t.val) == "integer" then
			return {k = "int", v = t.val}
		end
		return {k = "flt", v = t.val}
	elseif t.kind == "string" then
		self:adv()
		return {k = "str", v = t.val}
	elseif t.kind == "nil" then
		self:adv()
		return {k = "nil"}
	elseif t.kind == "true" then
		self:adv()
		return {k = "true"}
	elseif t.kind == "false" then
		self:adv()
		return {k = "false"}
	elseif t.kind == "..." then
		if not self.fs.vararg then
			self:err("cannot use '...' outside a vararg function")
		end
		self:adv()
		return {k = "vararg"}
	elseif t.kind == "{" then
		return self:table()
	elseif t.kind == "function" then
		local line = t.line

		self:adv()
		return self:body(false, line)
	end
	return self:suffixed()
end

local UNOP = {["not"] = "not", ["-"] = "unm", ["~"] = "bnot",
	      ["#"] = "len"}

function P:subexpr(limit)
	local e
	local u = UNOP[self.tok.kind]

	if u then
		local line = self.tok.line

		self:adv()
		e = {k = "un", op = u, a = self:subexpr(UNARYPRI), line = line}
	else
		e = self:simple()
	end
	while true do
		local op = self.tok.kind
		local pri = BINPRI[op]

		if not pri or pri[1] <= limit then break end
		local line = self.tok.line

		self:adv()
		local b = self:subexpr(pri[2])

		if op == "and" or op == "or" then
			e = {k = op, a = e, b = b, line = line}
		else
			e = {k = "bin", op = op, a = e, b = b, line = line}
		end
	end
	return e
end

function P:expr()
	return self:subexpr(0)
end

-- A function body: parameters, block, end.  `method` adds `self`.
function P:body(method, line)
	local fs = newfunc(self.fs, line)

	self.fs.nfunc = self.fs.nfunc + 1
	self.fs = fs
	self:openblock()
	if method then
		local v = self:newvar("self")

		fs.params[#fs.params + 1] = v
		self:activate(v)
	end
	self:expect("(")
	if self.tok.kind ~= ")" then
		repeat
			if self.tok.kind == "..." then
				self:adv()
				fs.vararg = true
				break
			end
			local v = self:newvar(self:name())

			fs.params[#fs.params + 1] = v
			self:activate(v)
		until not self:accept(",")
	end
	self:expect(")")
	fs.body = self:block()
	fs.lastline = self.tok.line
	self:match("end", "function", line)
	self:closeblock()
	self.fs = fs.parent
	return {k = "func", f = fs, line = line}
end

-- statements --------------------------------------------------------------

local ENDBLOCK = {["return"] = true, ["end"] = true, ["else"] = true,
		  ["elseif"] = true, ["until"] = true, eof = true}

-- The statements of a block, in a scope the caller has opened.
function P:stats()
	local l = {}

	while not ENDBLOCK[self.tok.kind] do
		local s = self:stat()

		if s then l[#l + 1] = s end
	end
	if self.tok.kind == "return" then
		local line = self.tok.line

		self:adv()
		local vals = {}

		if not ENDBLOCK[self.tok.kind] and self.tok.kind ~= ";" then
			vals = self:explist()
		end
		self:accept(";")
		l[#l + 1] = {k = "return", vals = vals, line = line}
		if not ENDBLOCK[self.tok.kind] or self.tok.kind == "return" then
			self:err("'end' expected near '" ..
				show(self.tok) .. "'")
		end
	end
	return l
end

-- A block in a scope of its own.
function P:block(loop)
	self:openblock(loop)
	local l = self:stats()

	self:closeblock()
	return {k = "block", body = l}
end

function P:attrib()
	if not self:accept("<") then return nil end
	local a = self:name()

	if a ~= "const" and a ~= "close" then
		self:err("unknown attribute '" .. a .. "'")
	end
	self:expect(">")
	return a
end

function P:localstat(line)
	local vars = {}

	repeat
		local v = self:newvar(self:name())

		v.attrib = self:attrib()
		vars[#vars + 1] = v
	until not self:accept(",")
	local vals = {}

	if self:accept("=") then vals = self:explist() end
	-- The new names are not in scope until the statement is over: in
	-- `local x = x` the right hand x is the outer one.
	for _, v in ipairs(vars) do self:activate(v) end
	return {k = "local", vars = vars, vals = vals, line = line}
end

function P:funcname()
	local line = self.tok.line
	local e = self:singlevar(self:name())
	local method = false

	while self.tok.kind == "." do
		self:adv()
		e = {k = "index", obj = e, key = {k = "str", v = self:name()},
		     line = line}
	end
	if self:accept(":") then
		e = {k = "index", obj = e, key = {k = "str", v = self:name()},
		     line = line}
		method = true
	end
	return e, method
end

function P:forstat(line)
	local n1 = self:name()

	if self.tok.kind == "=" then
		self:adv()
		local a = self:expr()

		self:expect(",")
		local b = self:expr()
		local c

		if self:accept(",") then c = self:expr() end
		self:expect("do")
		self:openblock(true)
		local v = self:newvar(n1)

		self:activate(v)
		local body = self:block()

		self:closeblock()
		self:match("end", "for", line)
		return {k = "numfor", var = v, a = a, b = b, c = c,
			body = body, line = line}
	end
	local names = {n1}

	while self:accept(",") do names[#names + 1] = self:name() end
	self:expect("in")
	local vals = self:explist()

	self:expect("do")
	self:openblock(true)
	local vars = {}

	for i, n in ipairs(names) do
		vars[i] = self:newvar(n)
		self:activate(vars[i])
	end
	local body = self:block()

	self:closeblock()
	self:match("end", "for", line)
	return {k = "genfor", vars = vars, vals = vals, body = body,
		line = line}
end

local ASSIGNABLE = {["local"] = true, upval = true, index = true}

function P:exprstat()
	local line = self.tok.line
	local e = self:suffixed()

	if self.tok.kind == "=" or self.tok.kind == "," then
		local targets = {e}

		while self:accept(",") do targets[#targets + 1] = self:suffixed() end
		self:expect("=")
		local vals = self:explist()

		for _, t in ipairs(targets) do
			written(t)
			if not ASSIGNABLE[t.k] then
				self:err("syntax error near '" ..
					show(self.tok) .. "'")
			end
			if t.k == "local" and t.var.attrib then
				self:err(("attempt to assign to const " ..
					  "variable '%s'"):format(t.var.name))
			end
		end
		return {k = "assign", targets = targets, vals = vals,
			line = line}
	end
	if e.k ~= "call" and e.k ~= "method" then
		self:err("syntax error near '" .. show(self.tok) .. "'")
	end
	return {k = "callstat", call = e, line = line}
end

function P:stat()
	local t = self.tok
	local line = t.line
	local k = t.kind

	if k == ";" then
		self:adv()
		return nil
	elseif k == "if" then
		local arms = {}

		self:adv()
		local c = self:expr()

		self:expect("then")
		arms[1] = {cond = c, body = self:block()}
		local els

		while true do
			if self.tok.kind == "elseif" then
				self:adv()
				local c2 = self:expr()

				self:expect("then")
				arms[#arms + 1] = {cond = c2, body = self:block()}
			elseif self.tok.kind == "else" then
				self:adv()
				els = self:block()
				self:match("end", "if", line)
				break
			else
				self:match("end", "if", line)
				break
			end
		end
		return {k = "if", arms = arms, els = els, line = line}
	elseif k == "while" then
		self:adv()
		local c = self:expr()

		self:expect("do")
		local body = self:block(true)

		self:match("end", "while", line)
		return {k = "while", cond = c, body = body, line = line}
	elseif k == "do" then
		self:adv()
		local b = self:block()

		self:match("end", "do", line)
		return b
	elseif k == "for" then
		self:adv()
		return self:forstat(line)
	elseif k == "repeat" then
		self:adv()
		-- The condition sees the body's locals, so one scope covers
		-- both.
		self:openblock(true)
		local body = self:stats()

		self:match("until", "repeat", line)
		local c = self:expr()

		self:closeblock()
		return {k = "repeat", body = {k = "block", body = body},
			cond = c, line = line}
	elseif k == "function" then
		self:adv()
		local target, method = self:funcname()
		local f = self:body(method, line)

		written(target)
		f.f.name = target.name or (target.key and target.key.v)
		return {k = "assign", targets = {target}, vals = {f},
			line = line}
	elseif k == "local" then
		self:adv()
		if self:accept("function") then
			local v = self:newvar(self:name())

			-- The function can call itself, so the name is in
			-- scope for its own body.
			self:activate(v)
			local f = self:body(false, line)

			f.f.name = v.name
			-- Its own name, inside its body, is the function
			-- itself, as long as nothing assigns the name again.
			f.f.selfvar = v
			return {k = "local", vars = {v}, vals = {f}, line = line,
				recursive = true}
		end
		return self:localstat(line)
	elseif k == "::" then
		self:adv()
		local name = self:name()

		self:expect("::")
		return {k = "label", name = name, line = line}
	elseif k == "return" then
		self:err("unexpected return")
	elseif k == "break" then
		self:adv()
		return {k = "break", line = line}
	elseif k == "goto" then
		self:adv()
		return {k = "goto", name = self:name(), line = line}
	end
	return self:exprstat()
end

-- The main chunk: a vararg function whose one upvalue is _ENV.
function P.chunk(src, name)
	local self = setmetatable({lx = lex.new(src, name)}, P)
	local fs = newfunc(nil, 0)

	fs.vararg = true
	fs.upvals[1] = {name = "_ENV", instack = true, ref = "env"}
	fs.name = "main chunk"
	self.fs = fs
	self:adv()
	fs.body = self:block()
	if self.tok.kind ~= "eof" then
		self:err("'<eof>' expected near '" .. show(self.tok) .. "'")
	end
	return fs
end

return P
