-- SPDX-License-Identifier: ISC
--
-- The compiler's own runtime, built into the object that asked for it.
--
-- A scalar twice the register width lives in memory, and what is not
-- written out inline -- the multiply, the divide, the remainder --
-- reaches a runtime by name.  So do counting bits and the variadic
-- walker.  A freestanding program has none of that to link: linux
-- writes __uint128_t in the KVM guest code, OpenBSD's drm code counts
-- leading zeros, and neither links libgcc.  So the bodies the unit
-- asked for are built into the object, as names of its own.
--
-- Each source is read through a preprocessor of its own, with nothing
-- of the program defined: a build that gives `lo` or `mask` a meaning
-- must not reach it.

local cpp = require "mcc.cpp"
local parse = require "mcc.parse"
local sys = require "mcc.sys"

local widert = {}

-- Counting bits, under the names a compiler runtime gives them.
local BITS = {}
for _, k in ipairs{"ffs", "clz", "ctz", "popcount", "parity"} do
	BITS["__" .. k .. "si2"] = true
	BITS["__" .. k .. "di2"] = true
end

-- One part of the runtime: where it is, which names it answers to, the
-- macro that makes a definition the object's own, and anything else it
-- has to be told.
local PARTS = {
	{file = "rt/wide.c", own = "WFN", wide = true,
	 wants = function(n) return n:sub(1, 4) == "__w_" end,
	 defs = function(t) return {WIDE_HALF = tostring(t.ptrsize)} end},
	{file = "rt/bits.c", own = "BFN",
	 wants = function(n) return BITS[n] end},
	{file = "rt/varargs.c", own = "VFN",
	 wants = function(n) return n == "__va_next" end},
	{file = "rt/atomic.c", own = "AFN",
	 wants = function(n)
		return n:sub(1, 13) == "__mcc_atomic_" or
		       n:sub(1, 7) == "__sync_"
	 end},
}

local function build(p, write, t, root, opts, part, need)
	local f = io.open(root .. "/" .. part.file)

	if not f then return end
	local body = f:read("a")

	f:close()
	local defs = {[part.own] = "static"}

	for k, v in pairs(part.defs and part.defs(t) or {}) do
		defs[k] = v
	end
	for k, v in pairs(t.predef or {}) do defs[k] = v end
	local name = "<mcc runtime " .. part.file .. ">"
	local src = cpp.new{file = name, path = {}, define = defs,
		text = {[name] = body},
		charsigned = t.charsigned ~= false}
	local o = {}

	for k, v in pairs(opts or {}) do o[k] = v end
	o.ssp = false
	local q = parse.new(src, t, write, o)

	-- One unit's labels and strings carry on where the other left
	-- off, because the two land in one file.
	q.g.nlabel, q.nstr = p.g.nlabel, p.nstr
	q.rtneed = need
	q:program()
	p.g.nlabel, p.nstr = q.g.nlabel, q.nstr
end

function widert.emit(p, write, t, root, opts)
	local need = p.rtneed

	if not need or not next(need) then return end
	for _, part in ipairs(PARTS) do
		-- WIDE=1 forces the wide path onto a machine that has
		-- the type natively, and then the reference runtime is
		-- what the answer is measured against.
		if not (part.wide and sys.getenv("WIDE") ~= nil) then
			local want = false

			for name in pairs(need) do
				if part.wants(name) and
				   not (p.defined and p.defined[name]) then
					want = true
				end
			end
			if want then
				build(p, write, t, root, opts, part, need)
			end
		end
	end
end

return widert
