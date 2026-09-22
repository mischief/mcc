-- SPDX-License-Identifier: ISC
-- The peephole: small rewrites over the assembly a function was given,
-- for the cases the code table cannot see because it looks at one tree
-- node at a time.
--
-- A rule reads the last few instructions and either answers with what to
-- put in their place or leaves them alone.  Nothing here reorders, and a
-- window never spans a label, because something may jump to it.
--
-- It runs as a sliding window rather than over the whole function: a
-- rule reaches back a fixed distance, so only that many lines need to be
-- held, and the rest goes straight out.  The biggest function this
-- compiler has met is a quarter of a megabyte of assembly, and holding
-- one line of it costs more than the line.
--
-- The rules are the target's: what an instruction means is its business.
-- Only the walking is here.

local peep = {}

-- One line, split into what a rule asks about.  Two operands is all any
-- rule here looks at, so they are fields and not a list.
local function parse(l, line)
	l.text, l.mnem, l.a, l.b, l.label = line, nil, nil, nil, nil

	local body = line:match("^[ \t]+(.*)$")

	if not body then
		l.label = line:match("^([%w.$_]+):")
		return l
	end
	if body:sub(1, 1) == "." then return l end
	-- An inline asm template is one line and may hold several
	-- instructions.  A rule that rebuilds a line from a mnemonic
	-- and two operands would make nonsense of it, so it is left
	-- without one and nothing matches.
	if body:find(";", 1, true) then return l end
	local m, rest = body:match("^(%S+)[ \t]*(.*)$")

	l.mnem = m
	if rest and rest ~= "" then
		rest = rest:gsub("[ \t]+$", "")
		local a, b = rest:match("^([^,]*),(.*)$")

		if a then
			l.a, l.b = a, b
		else
			l.a = rest
		end
	end
	return l
end

-- `lines` is an iterator, so the function need not be held as one
-- string to be read a line at a time.
function peep.run(lines, rules, out)
	if not rules or #rules == 0 then
		for line in lines do
			out(line)
			out("\n")
		end
		return
	end
	-- the window, oldest first, and a pool so that a line costs one
	-- table for the whole function rather than one each
	local win, n, pool, np = {}, 0, {}, 0
	local most = 1

	for _, r in ipairs(rules) do
		if r.n > most then most = r.n end
	end

	local function release(l)
		np = np + 1
		pool[np] = l
	end

	local function flush(keep)
		while n > keep do
			out(win[1].text)
			out("\n")
			release(win[1])
			table.move(win, 2, n, 1)
			win[n] = nil
			n = n - 1
		end
	end

	-- Try every rule at every start the window allows, newest first,
	-- until none fires.  A rule answers with the lines that replace
	-- the ones it read.
	local function settle()
		local again = true

		while again do
			again = false
			for start = math.max(1, n - most + 1), n do
				for _, r in ipairs(rules) do
					if start + r.n - 1 == n then
						local hit = r.f(win, start)

						if hit then
							local kept = {}

							for _, x in ipairs(hit)
							do
								kept[x] = true
							end
							for k = start, n do
								if not kept[win[k]]
								then
									release(win[k])
								end
								win[k] = nil
							end
							n = start - 1
							for _, x in ipairs(hit)
							do
								n = n + 1
								win[n] = x
							end
							again = true
							break
						end
					end
				end
				if again then break end
			end
		end
	end

	for line in lines do
		n = n + 1
		local l = pool[np]

		if l then pool[np], np = nil, np - 1 else l = {} end
		win[n] = parse(l, line)
		settle()
		flush(most)
	end
	flush(0)
end

-- A line a rule makes for itself.  It is parsed like any other, so a
-- later rule sees it the same way.
function peep.line(text)
	return parse({}, text)
end

return peep
