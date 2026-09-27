-- SPDX-License-Identifier: ISC
-- Tokens: reading the next one, capturing a body to build later, playing
-- it back, and what a scan of captured tokens can tell before the body
-- is built -- its labels, what it writes, and which locals earn a register.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local words = require "mcc.parse.words"
local ASMKW = words.ASMKW

local function copytok(t)
	return {kind = t.kind, text = t.text, val = t.val, line = t.line,
		file = t.file, pfx = t.pfx}
end

-- A reader hands over a table of its own for each token, so one may be
-- kept as it is.
function P:adv()
	if self.ahead then
		self.tok = self.ahead
		self.ahead = nil
	else
		self.tok = self.lx:next()
	end
	return self.tok
end

function P:peek()
	if not self.ahead then
		self.ahead = self.lx:next()
	end
	return self.ahead
end

-- A token list read the way the lexer is read, so a body put aside can
-- be parsed later without being preprocessed again.
--
-- The tokens are kept flat, six slots to a token, rather than as a list
-- of tables.  A body of a hundred tokens then costs about five kilobytes
-- instead of twenty, and a header full of `static inline` functions
-- nothing calls is what this is for.
local Replay = {}
Replay.__index = Replay

local NFIELD = 6

function Replay:next()
	local i = self.i
	local f = self.f

	-- The count is kept, not asked for: a token whose text or value
	-- is nothing leaves a hole, and a table with one has no length.
	if i > self.n then
		return {kind = "eof", line = self.line, file = self.file}
	end
	self.i = i + NFIELD
	return {kind = f[i], text = f[i + 1], val = f[i + 2],
		line = f[i + 3], file = f[i + 4], pfx = f[i + 5]}
end

-- Where a name is written, by the token that stands beside it.  The
-- answer is the last such place, which is all a label needs: what it
-- has to forget is a value a later write could change.
local WROTE = {["="] = true, ["+="] = true, ["-="] = true,
	       ["*="] = true, ["/="] = true, ["%="] = true,
	       ["&="] = true, ["|="] = true, ["^="] = true,
	       ["<<="] = true, [">>="] = true,
	       ["++"] = true, ["--"] = true}

-- How deep in braces each label of a body stands.  A goto has to run
-- what the blocks it leaves left behind, and which blocks those are is
-- settled by where the label is, which may be further down than the
-- goto.
local function scanlabels(f, n, from, d)
	local out = {}

	for i = from or 1, n, NFIELD do
		local k = f[i]

		if k == "{" then
			d = d + 1
		elseif k == "}" then
			d = d - 1
			if d <= 0 then break end
		elseif k == "name" and f[i + NFIELD] == ":" and
		       f[i + 2 * NFIELD] ~= ":" then
			-- `name :` where a statement may start.  A name
			-- followed by `::` is something else, and a label
			-- named twice is not C.
			out[f[i + 1]] = out[f[i + 1]] or d
		end
	end
	return out
end

local function scanwrites(f, n)
	local w, g, any, wv = {}, {}, false, {}

	for i = 1, n, NFIELD do
		if f[i] == "name" then
			local nm = f[i + 1]
			local nx = f[i + NFIELD]
			local pv = i > NFIELD and f[i - NFIELD] or nil

			-- `x = `, `x += `, `x++`; and `++x`, and `&x`,
			-- whose holder may write through it.
			if WROTE[nx or ""] or WROTE[pv or ""] or
			   pv == "&" then
				w[nm] = i
				-- `x = <one thing>;` is a write whose
				-- value can be read off the tokens, and
				-- one that writes what is already there
				-- changes nothing.
				local v = nx == "=" and
					f[i + 2 * NFIELD] ~= nil and
					f[i + 3 * NFIELD] == ";" and
					{kind = f[i + 2 * NFIELD],
					 text = f[i + 2 * NFIELD + 1],
					 val = f[i + 2 * NFIELD + 2]} or false

				local l = wv[nm]

				if not l then l = {}; wv[nm] = l end
				l[#l + 1] = {at = i, v = v}
			end
			-- The first jump to a label is the earliest
			-- place a run can arrive from.
			if pv == "goto" and not g[nm] then g[nm] = i end
		end
		-- `goto *e` can arrive at any label whose address was
		-- taken, and which one is not written down.
		if f[i] == "goto" and f[i + NFIELD] == "*" then
			any = true
		end
	end
	return {w = w, g = g, any = any, wv = wv}
end

-- Which locals are worth keeping in a register for the whole body,
-- read off the tokens before the body is parsed.  A name is a
-- candidate when nothing takes its address and nothing names it in an
-- asm template, because either of those wants a place in memory.  The
-- order is how often it is mentioned: a name read in a loop is worth
-- more than one read once, and the tokens do not say which is which,
-- so the count is the whole of the guess.
local NOPIN = {
	-- A label is not a value, and a name after one of these is not
	-- the local being counted.
	["goto"] = true, ["sizeof"] = true,
}

-- The node for a declared local: the slot, or the register when one
-- was set aside for it.
local function autoof(s)
	local e = tree.auto(s.ty, s.off)

	if s.pin then e.pin = s.pin end
	return e
end

local function scanpins(f, n)
	local count, out, bad = {}, {}, {}

	for i = 1, n, NFIELD do
		if f[i] == "&" then
			-- What the address is taken of, which may be
			-- behind any number of parentheses: lua writes
			-- `memcpy(&b[0], &(v), sizeof(v))` in a macro and
			-- the name arrives with a bracket in front of it.
			-- An index or a member reaches this through an
			-- array or a record, and neither is ever kept in
			-- a register, so the name alone is what matters.
			local j = i + NFIELD

			while f[j] == "(" do j = j + NFIELD end
			if f[j] == "name" then bad[f[j + 1]] = true end
		end
		if f[i] == "name" then
			local nm = f[i + 1]
			local pv = i > NFIELD and f[i - NFIELD] or nil
			local nx = f[i + NFIELD]

			-- A name that is a label, or that a goto reaches.
			if NOPIN[pv or ""] or nx == ":" then
				bad[nm] = true
			elseif nx == "(" then
				-- a call, so the name is a function and
				-- not a local this can do anything with
			elseif not count[nm] then
				count[nm] = 1
				out[#out + 1] = nm
			else
				count[nm] = count[nm] + 1
			end
		end
		-- An asm template may name a local as a memory operand,
		-- and `"+m"(x)` takes its address with no `&` anywhere.
		-- The constraints are not read here, so the whole body
		-- is refused.  `asm` is a name to the lexer, not a kind
		-- of its own, which is where this went wrong the first
		-- time: the test passed and the bail had never fired.
		if f[i] == "name" and ASMKW[f[i + 1]] then return {} end
	end

	local keep = {}

	for _, nm in ipairs(out) do
		if not bad[nm] then keep[#keep + 1] = nm end
	end
	table.sort(keep, function(a, b)
		if count[a] ~= count[b] then return count[a] > count[b] end
		return a < b
	end)
	return keep, count
end

-- How many times a name has to be mentioned before a register is
-- worth spending on it.  The register costs a save and a restore;
-- each mention it saves is a load or a store that does not happen.
local PINUSE = 4

-- Pick the locals this body will keep in registers.  The tokens are
-- in hand and the body has not been parsed, so all this knows is the
-- names and how often each is mentioned.  Which of them turn out to
-- be locals of a type a register can hold is decided as each is
-- declared; a name that turns out to be a global or a function
-- simply never asks.
function P:choosepins(rec)
	self.pins, self.pinused = nil, nil

	local regs = self.t.pinregs

	if not regs or #regs == 0 or self.nopin then return end

	local names, count = scanpins(rec.f, rec.n)
	local want = {}
	local n = 0

	for _, nm in ipairs(names) do
		if count[nm] < PINUSE or n >= #regs then break end
		n = n + 1
		want[nm] = regs[n]
	end
	if n == 0 then return end
	self.pins, self.pinused = want, {}
	-- Where each of them is kept while a call runs.  A slot rather
	-- than a push: the frame is already the right size and the
	-- right alignment, and a push would change both.  A register
	-- the body turns out not to use costs a word of stack and
	-- nothing else.
	self.pinslot = {}
	for i = 1, n do
		self.pinslot[regs[i]] = self:alloc(self.word)
	end
end

-- The tokens of a function body, the brace that opens it to the one
-- that closes it, taken off the input.
-- The names of the builtin that takes a block off the stack.
local ALLOCA = {alloca = true, __builtin_alloca = true}

-- Fold a condition at the tokens, before anything is parsed.  It
-- answers nil unless every token is a number or an operator, so a name,
-- a call or a `sizeof` leaves the body alone.  A configuration test the
-- preprocessor has already answered -- `!IS_ENABLED(X)` is `!0` by the
-- time it arrives here -- is what this is for.
local KPREC = {
	["||"] = 1, ["&&"] = 2, ["|"] = 3, ["^"] = 4, ["&"] = 5,
	["=="] = 6, ["!="] = 6,
	["<"] = 7, [">"] = 7, ["<="] = 7, [">="] = 7,
	["<<"] = 8, [">>"] = 8,
	["+"] = 9, ["-"] = 9,
	["*"] = 10, ["/"] = 10, ["%"] = 10,
}

local function kbin(op, a, b)
	if op == "||" then return (a ~= 0 or b ~= 0) and 1 or 0 end
	if op == "&&" then return (a ~= 0 and b ~= 0) and 1 or 0 end
	if op == "|" then return a | b end
	if op == "^" then return a ~ b end
	if op == "&" then return a & b end
	if op == "==" then return a == b and 1 or 0 end
	if op == "!=" then return a ~= b and 1 or 0 end
	if op == "<" then return a < b and 1 or 0 end
	if op == ">" then return a > b and 1 or 0 end
	if op == "<=" then return a <= b and 1 or 0 end
	if op == ">=" then return a >= b and 1 or 0 end
	if op == "<<" or op == ">>" then
		if b < 0 or b > 63 then return nil end
		return op == "<<" and (a << b) or (a >> b)
	end
	if op == "+" then return a + b end
	if op == "-" then return a - b end
	if op == "*" then return a * b end
	if b == 0 then return nil end
	return op == "/" and (a // b) or (a % b)
end

-- One operand and everything binding tighter than `prec` after it.
-- Answers the value and the index past what it read, or nil.
local function keval(f, i, last, prec)
	local k, v = f[i], f[i + 2]

	if k == nil or i > last then return nil end
	if k == "num" then
		if math.type(v) ~= "integer" then return nil end
		i = i + NFIELD
	elseif k == "!" or k == "~" or k == "-" or k == "+" then
		local a

		a, i = keval(f, i + NFIELD, last, 11)
		if a == nil then return nil end
		if k == "!" then v = a == 0 and 1 or 0
		elseif k == "~" then v = ~a
		elseif k == "-" then v = -a
		else v = a
		end
	elseif k == "(" then
		v, i = keval(f, i + NFIELD, last, 0)
		if v == nil or f[i] ~= ")" then return nil end
		i = i + NFIELD
	else
		return nil
	end
	while i <= last do
		local op = f[i]
		local p = KPREC[op]

		if not p or p <= prec then break end

		local b

		b, i = keval(f, i + NFIELD, last, p)
		if b == nil then return nil end
		v = kbin(op, v, b)
		if v == nil then return nil end
	end
	return v, i
end

-- A body that opens with `if (C) return E;` on a condition that holds
-- is, for the purpose of building it where it was called, the body
-- `{ return E; }`: nothing after the return can run.  Answers that
-- shorter body, or nil.  The kernel writes a whole function this way --
-- a constant guard, then a page of code the configuration turns off --
-- and the call has to fold for the code after it to die with it.
-- What may stand between the brace and the guard: plain statements
-- that end in a semicolon, which is what a declaration is.  Anything
-- that decides where to go next, or opens a block, or can be jumped
-- to, means the guard is not the statement it looks like.
local KSTOP = {
	["if"] = true, ["else"] = true, ["for"] = true, ["while"] = true,
	["do"] = true, ["switch"] = true, ["case"] = true,
	["default"] = true, ["goto"] = true, ["return"] = true,
	["{"] = true, ["}"] = true, [":"] = true,
}

local function guardfold(f, n)
	if n < 3 * NFIELD or f[1] ~= "{" then return nil end

	-- To the first `if` that starts a statement of its own.  What
	-- comes before it is kept: a declaration runs whether the guard
	-- holds or not.  btf_parse_base in linux declares two locals
	-- before its test.
	local i, d, prev = 1 + NFIELD, 0, "{"

	while i <= n do
		local k = f[i]

		if d == 0 and k == "if" then break end
		if k == "(" or k == "[" then d = d + 1
		elseif k == ")" or k == "]" then d = d - 1
		elseif d == 0 and KSTOP[k] then return nil
		end
		prev = k
		i = i + NFIELD
	end
	-- A statement of its own follows a semicolon or the brace.
	if i > n or (prev ~= ";" and prev ~= "{") then return nil end

	local head = i

	if f[i + NFIELD] ~= "(" then return nil end
	i = i + NFIELD

	-- The matching close, so the condition is bounded before it is
	-- read.
	local depth, j = 0, i

	while j <= n do
		if f[j] == "(" then depth = depth + 1
		elseif f[j] == ")" then
			depth = depth - 1
			if depth == 0 then break end
		end
		j = j + NFIELD
	end
	if j > n then return nil end

	local v, e = keval(f, i + NFIELD, j - NFIELD, 0)

	-- The condition has to be settled, hold, and account for every
	-- token between the parentheses.
	if v == nil or v == 0 or e ~= j then return nil end

	local k = j + NFIELD
	local brace = f[k] == "{"

	if brace then k = k + NFIELD end
	if f[k] ~= "return" then return nil end

	-- To the semicolon that ends the return, at the depth it starts
	-- at, so a compound literal inside it does not end it early.
	local first, d = k, 0

	while k <= n do
		local t = f[k]

		if t == "(" or t == "[" or t == "{" then d = d + 1
		elseif t == ")" or t == "]" or t == "}" then d = d - 1
		elseif t == ";" and d == 0 then break
		end
		k = k + NFIELD
	end
	if k > n or f[k] ~= ";" then return nil end
	if brace and f[k + NFIELD] ~= "}" then return nil end

	-- The brace, everything up to the guard, then the return the
	-- guard takes.  The guard itself is settled, so it goes.
	local g, m = {}, 0

	for x = 1, head - 1 do g[x] = f[x] end
	m = head - 1
	for x = first, k + NFIELD - 1 do
		m = m + 1
		g[m] = f[x]
	end
	-- The brace that closed the body closes the short one.
	for x = 1, NFIELD do g[m + x] = f[n - NFIELD + x] end
	m = m + NFIELD
	return g, m
end

function P:capture()
	local f, depth, n = {}, 0, 0
	local once = false
	local instatic = false

	while true do
		local t = self.tok

		if t.kind == "eof" then self:err("unterminated body") end
		f[n + 1], f[n + 2], f[n + 3] = t.kind, t.text, t.val
		f[n + 4], f[n + 5], f[n + 6] = t.line, t.file, t.pfx
		n = n + NFIELD
		-- One object shared by every call, or a block taken off
		-- the stack: building the body twice would make two.
		if ALLOCA[t.text or ""] then once = true end
		-- An object inside the body is one object however many
		-- copies of the body there are, and a copy names the
		-- same one.  A label address is the exception: the
		-- labels of each copy are its own, so a table of them
		-- belongs to the copy that built it.
		if t.kind == "static" then instatic = true
		elseif t.kind == ";" then instatic = false
		elseif instatic and t.kind == "&&" then once = true
		end
		if t.kind == "{" then
			depth = depth + 1
		elseif t.kind == "}" then
			depth = depth - 1
			if depth == 0 then
				self:adv()
				break
			end
		end
		self:adv()
	end
	-- A body that is one `return` is worth building where it was
	-- called however many tokens it holds: the kernel writes its
	-- configuration tests that way, and most of what makes them
	-- long -- a `_Generic` on the type, a `sizeof` on the width --
	-- settles to nothing at all.
	local nsemi, depth = 0, 0

	for i = 1, n, NFIELD do
		local k = f[i]

		if k == "{" then depth = depth + 1
		elseif k == "}" then depth = depth - 1
		elseif k == ";" and depth == 1 then nsemi = nsemi + 1
		end
	end
	local single = nsemi == 1 and f[1] == "{" and
		f[1 + NFIELD] == "return"
	local rec = {f = f, n = n, name = self.lx.name, ntok = n // NFIELD,
		once = once, single = single or nil,
		line = f[n - 2], file = f[n - 1]}

	-- The same body without the code a constant guard has already
	-- turned off.  Only building it where it was called reads this;
	-- the body left out of line stays whole.
	if not single then
		local g, m = guardfold(f, n)

		if g then
			rec.fold = {f = g, n = m, name = rec.name,
				    ntok = m // NFIELD, once = once,
				    single = true, line = rec.line,
				    file = rec.file}
		end
	end
	return rec
end

-- A reader over a captured body.  One is made for each pass over it,
-- so a body may be replayed at every place that calls it.
function P:reader(rec)
	return setmetatable({f = rec.f, i = 1, n = rec.n, name = rec.name,
			     rec = rec,
			     line = rec.line, file = rec.file}, Replay)
end

-- Parse something out of a list of tokens taken earlier.  The input the
-- parser was reading is put back afterwards.
function P:replay(rec, f, ...)
	local olx, otok, oahead = self.lx, self.tok, self.ahead

	self.lx, self.ahead = self:reader(rec), nil
	self:adv()
	f(self, ...)
	self.lx, self.tok, self.ahead = olx, otok, oahead
end

function P:accept(k)
	if self.tok.kind == k then
		local t = self.tok
		self:adv()
		return t
	end
end

function P:expect(k)
	return self:accept(k) or self:err("expected " .. k .. ", found " ..
		(self.tok.text or self.tok.kind))
end

return {
	NFIELD = NFIELD,
	autoof = autoof,
	copytok = copytok,
	scanlabels = scanlabels,
	scanwrites = scanwrites,
}
