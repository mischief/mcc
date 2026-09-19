-- The linker script: where a program says for itself what its image
-- looks like.  A kernel needs this, because the addresses it runs at
-- are not the ones it is loaded at, and because it finds its own
-- tables by the symbols the script defines around them.
--
-- The subset is the one a kernel writes.  Anything outside it is an
-- error rather than a guess, because a link that quietly did something
-- else would be found much later.

local ldscript = {}

-- tokens ---------------------------------------------------------------

local PUNCT = {
	["{"] = true, ["}"] = true, ["("] = true, [")"] = true,
	[";"] = true, [":"] = true, [","] = true, ["="] = true,
	["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true,
	["&"] = true, ["|"] = true, ["<"] = true, [">"] = true,
}

local function lex(text)
	local t, i, n = {}, 1, #text

	while i <= n do
		local c = text:sub(i, i)

		if c:match("%s") then
			i = i + 1
		elseif text:sub(i, i + 1) == "/*" then
			local e = text:find("*/", i + 2, true)

			i = (e or n) + 2
		elseif c == '"' then
			local e = text:find('"', i + 1, true)

			t[#t + 1] = {k = "str", v = text:sub(i + 1, e - 1)}
			i = e + 1
		elseif c:match("%d") then
			local s, e, num = text:find("^(0[xX]%x+)", i)

			if not num then s, e, num = text:find("^(%d+)", i) end
			local v = tonumber(num)
			local suf = text:sub(e + 1, e + 1)

			if suf == "K" or suf == "k" then
				v, e = v * 1024, e + 1
			elseif suf == "M" or suf == "m" then
				v, e = v * 1024 * 1024, e + 1
			end
			t[#t + 1] = {k = "num", v = v}
			i = e + 1
		elseif c:match("[%a_.$/]") then
			-- a name, a section pattern, or /DISCARD/
			local s, e = text:find("^[%w_.$/*?%[%]-]+", i)

			t[#t + 1] = {k = "name", v = text:sub(s, e)}
			i = e + 1
		elseif PUNCT[c] then
			-- the two-character ones this subset uses
			local two = text:sub(i, i + 1)

			if two == ">>" or two == "<<" then
				t[#t + 1] = {k = two}
				i = i + 2
			else
				t[#t + 1] = {k = c}
				i = i + 1
			end
		else
			error("linker script: unexpected " .. c)
		end
	end
	t[#t + 1] = {k = "eof"}
	return t
end

-- parsing --------------------------------------------------------------

local P = {}
P.__index = P

function P:peek(k) return self.t[self.i + (k or 0)] end
function P:next() local x = self.t[self.i]; self.i = self.i + 1; return x end

function P:is(k, v)
	local x = self.t[self.i]

	return x.k == k and (v == nil or x.v == v)
end

function P:accept(k, v)
	if self:is(k, v) then return self:next() end
end

function P:expect(k, v)
	local x = self:accept(k, v)

	if not x then
		error(("linker script: expected %s, found %s"):format(
			v or k, tostring(self.t[self.i].v or
					 self.t[self.i].k)))
	end
	return x
end

-- An expression, as a closure over the environment it is worked out
-- in.  `.` is the location counter, which moves as the layout runs.
function P:expr()
	return self:sum()
end

function P:sum()
	local a = self:product()

	while true do
		if self:accept("+") then
			local b = self:product()
			local x = a

			a = function(e) return x(e) + b(e) end
		elseif self:accept("-") then
			local b = self:product()
			local x = a

			a = function(e) return x(e) - b(e) end
		else
			return a
		end
	end
end

function P:product()
	local a = self:atom()

	while true do
		if self:accept("*") then
			local b = self:atom()
			local x = a

			a = function(e) return x(e) * b(e) end
		elseif self:accept("/") then
			local b = self:atom()
			local x = a

			a = function(e) return x(e) // b(e) end
		else
			return a
		end
	end
end

local function align(v, a)
	if a <= 1 then return v end
	return ((v + a - 1) // a) * a
end

function P:atom()
	if self:accept("(") then
		local e = self:expr()

		self:expect(")")
		return e
	end
	if self:is("num") then
		local v = self:next().v

		return function() return v end
	end
	local nm = self:expect("name").v

	if nm == "." then
		return function(e) return e.dot end
	end
	if nm == "ALIGN" then
		self:expect("(")
		local a = self:expr()
		local b = self:accept(",") and self:expr() or nil

		self:expect(")")
		if b then
			return function(e) return align(a(e), b(e)) end
		end
		return function(e) return align(e.dot, a(e)) end
	end
	if nm == "ABSOLUTE" then
		self:expect("(")
		local a = self:expr()

		self:expect(")")
		return a
	end
	if nm == "SIZEOF_HEADERS" then
		return function(e) return e.headers end
	end
	if nm == "ADDR" then
		self:expect("(")
		local s = self:expect("name").v

		self:expect(")")
		return function(e) return e.secaddr[s] or 0 end
	end
	-- a symbol the script defined earlier, or one from the objects
	return function(e)
		local v = e.sym[nm]

		if v == nil then
			error("linker script: undefined symbol " .. nm)
		end
		return v
	end
end

-- What goes in an output section: a run of input sections named by
-- pattern, or a symbol the script defines as it goes.
function P:contents()
	local out = {}

	while not self:is("}") do
		if self:accept(";") then
			-- nothing
		elseif self:is("name", "PROVIDE") or
		       self:is("name", "PROVIDE_HIDDEN") then
			self:next()
			self:expect("(")
			local nm = self:expect("name").v

			self:expect("=")
			out[#out + 1] = {set = nm, e = self:expr(),
					 weak = true}
			self:expect(")")
		elseif self:is("name") and self:peek(1).k == "=" then
			local nm = self:next().v

			self:next()
			out[#out + 1] = {set = nm, e = self:expr()}
		elseif self:is("name", "KEEP") then
			self:next()
			self:expect("(")
			out[#out + 1] = self:input()
			self:expect(")")
		else
			out[#out + 1] = self:input()
		end
	end
	return out
end

-- `*(.text .text.*)` or `locore0.o(.text)`: which files, which of
-- their sections.
function P:input()
	-- `*(...)` means every file; the star is punctuation to the
	-- tokenizer, so it is taken by hand here.
	local from = self:accept("*") and "*" or self:expect("name").v

	self:expect("(")
	local pats = {}

	while not self:is(")") do
		if self:accept(",") then
			-- nothing
		elseif self:is("name", "SORT_BY_ALIGNMENT") or
		       self:is("name", "SORT") or
		       self:is("name", "SORT_BY_NAME") then
			self:next()
			self:expect("(")
			pats[#pats + 1] = self:expect("name").v
			self:expect(")")
		else
			pats[#pats + 1] = self:expect("name").v
		end
	end
	self:expect(")")
	return {from = from, pats = pats}
end

function P:sections()
	local out = {}

	self:expect("{")
	while not self:is("}") do
		if self:accept(";") then
			-- nothing
		elseif self:is("name", ".") and self:peek(1).k == "=" then
			self:next()
			self:next()
			out[#out + 1] = {dot = self:expr()}
			self:accept(";")
		elseif self:is("name", "PROVIDE") then
			self:next()
			self:expect("(")
			local nm = self:expect("name").v

			self:expect("=")
			out[#out + 1] = {set = nm, e = self:expr(),
					 weak = true}
			self:expect(")")
			self:accept(";")
		elseif self:is("name") and self:peek(1).k == "=" then
			local nm = self:next().v

			self:next()
			out[#out + 1] = {set = nm, e = self:expr()}
			self:accept(";")
		else
			out[#out + 1] = self:outsec()
		end
	end
	self:expect("}")
	return out
end

function P:outsec()
	local name = self:expect("name").v
	local at, addr

	if not self:is(":") then addr = self:expr() end
	self:expect(":")
	if self:is("name", "AT") then
		self:next()
		self:expect("(")
		at = self:expr()
		self:expect(")")
	end
	local body = {}

	if self:accept("{") then
		body = self:contents()
		self:expect("}")
	end
	-- which segments it belongs to, and the byte a gap is filled with
	local phdrs = {}

	while self:accept(":") do
		phdrs[#phdrs + 1] = self:expect("name").v
	end
	if self:accept("=") then self:expr() end
	self:accept(";")
	return {name = name, addr = addr, at = at, body = body,
		phdrs = phdrs}
end

function P:phdrs()
	local out = {}

	self:expect("{")
	while not self:is("}") do
		local nm = self:expect("name").v
		local ty = self:expect("name").v
		local g = {name = nm, type = ty, flags = nil}

		while not self:is(";") do
			if self:is("name", "FLAGS") then
				self:next()
				self:expect("(")
				g.flags = self:expr()({dot = 0, sym = {},
					secaddr = {}, headers = 0})
				self:expect(")")
			elseif self:is("name", "FILEHDR") then
				self:next()
				g.filehdr = true
			elseif self:is("name", "PHDRS") then
				self:next()
				g.phdrs = true
			else
				self:next()
			end
		end
		self:expect(";")
		out[#out + 1] = g
	end
	self:expect("}")
	return out
end

-- Read a script.  Answers what it said, not what it means: the layout
-- works that out with the objects in hand.
function ldscript.parse(text)
	local p = setmetatable({t = lex(text), i = 1}, P)
	local s = {assigns = {}, sections = nil, phdrs = nil, entry = nil}

	while not p:is("eof") do
		if p:accept(";") then
			-- nothing
		elseif p:is("name", "OUTPUT_FORMAT") or
		       p:is("name", "OUTPUT_ARCH") or
		       p:is("name", "TARGET") or
		       p:is("name", "SEARCH_DIR") or
		       p:is("name", "GROUP") or
		       p:is("name", "INPUT") then
			p:next()
			p:expect("(")
			local depth = 1

			while depth > 0 do
				local x = p:next()

				if x.k == "(" then depth = depth + 1
				elseif x.k == ")" then depth = depth - 1
				elseif x.k == "eof" then
					error("linker script: unbalanced (")
				end
			end
		elseif p:is("name", "ENTRY") then
			p:next()
			p:expect("(")
			s.entry = p:expect("name").v
			p:expect(")")
		elseif p:is("name", "PHDRS") then
			p:next()
			s.phdrs = p:phdrs()
		elseif p:is("name", "SECTIONS") then
			p:next()
			s.sections = p:sections()
		elseif p:is("name") and p:peek(1).k == "=" then
			local nm = p:next().v

			p:next()
			-- Where it stands matters: one written after
			-- SECTIONS may name a symbol the sections gave a
			-- value to, which is how a script measures a span.
			s.assigns[#s.assigns + 1] = {set = nm, e = p:expr(),
						     post = s.sections ~= nil}
			p:accept(";")
		else
			error("linker script: unexpected " ..
				tostring(p:peek().v or p:peek().k))
		end
	end
	return s
end

-- Whether an input section's name matches a pattern from the script.
-- The only wildcard a kernel writes is a trailing star.
function ldscript.match(pat, name)
	if pat == name then return true end
	if pat == "COMMON" then return false end
	local head = pat:match("^(.*)%*$")

	return head ~= nil and name:sub(1, #head) == head
end

-- Lay the units out the way the script says.  Answers the sections in
-- the order they go in the file, the symbols the script defined, and
-- the segments it asked for.
--
-- `units` are the objects, already read; each has `order`, its
-- sections.  A section that no output section claims is dropped, which
-- is what /DISCARD/ means and what a script without a rule for it
-- implies.
function ldscript.layout(s, units, headers)
	local env = {dot = 0, sym = {}, secaddr = {}, headers = headers or 0}
	local out, byphdr = {}, {}

	for _, a in ipairs(s.assigns) do
		if not a.post then env.sym[a.set] = a.e(env) end
	end

	-- every input section, by name, in the order the units came
	local pool = {}

	for _, u in ipairs(units) do
		for _, x in ipairs(u.order) do
			pool[#pool + 1] = {sec = x, unit = u}
		end
	end

	local function take(from, pats, into, addr)
		for _, p in ipairs(pool) do
			if not p.taken then
				local nm = p.sec.name
				local file = p.unit.path and
					p.unit.path:gsub(".*/", "") or ""
				local okfile = from == "*" or file == from
				local hit = false

				for _, pat in ipairs(pats) do
					if ldscript.match(pat, nm) then
						hit = true
						break
					end
				end
				if okfile and hit then
					p.taken = true
					into[#into + 1] = p.sec
				end
			end
		end
	end

	for _, st in ipairs(s.sections) do
		if st.dot then
			env.dot = st.dot(env)
		elseif st.set then
			if not (st.weak and env.sym[st.set]) then
				env.sym[st.set] = st.e(env)
			end
		elseif st.name == "/DISCARD/" then
			for _, it in ipairs(st.body) do
				if it.pats then
					take(it.from, it.pats, {}, 0)
				end
			end
		else
			if st.addr then env.dot = st.addr(env) end
			local at = st.at and st.at(env) or nil
			local start = env.dot
			local mine = {}

			env.secaddr[st.name] = start
			for _, it in ipairs(st.body) do
				if it.set then
					if not (it.weak and env.sym[it.set])
					then
						env.sym[it.set] = it.e(env)
					end
				elseif it.dot then
					env.dot = it.dot(env)
				elseif it.pats then
					local got = {}

					take(it.from, it.pats, got, env.dot)
					-- an input section keeps where it
					-- is loaded, which AT() may move
					for _, x in ipairs(got) do
						env.dot = align(env.dot,
							math.max(x.align, 1))
						x.addr = env.dot
						x.outname = st.name
						x.at = at and
							(at + (env.dot - start))
							or nil
						env.dot = env.dot + x.size
						mine[#mine + 1] = x
						out[#out + 1] = x
					end
				end
			end
			-- a `. = ALIGN(n)` inside the braces moves the end
			st.start, st["end"] = start, env.dot
			for _, g in ipairs(st.phdrs) do
				byphdr[g] = byphdr[g] or {}
				local b = byphdr[g]

				b[#b + 1] = st
			end
			st.at = at
		end
	end
	-- Now the sections have their addresses, so an assignment
	-- written after SECTIONS can measure across them.
	for _, a in ipairs(s.assigns) do
		if a.post then env.sym[a.set] = a.e(env) end
	end
	return out, env.sym, byphdr
end

return ldscript
