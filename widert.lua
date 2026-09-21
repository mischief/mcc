-- SPDX-License-Identifier: ISC
--
-- A scalar twice the register width lives in memory, and what is not
-- written out inline -- the multiply, the divide, the remainder --
-- reaches a runtime by name.  A freestanding program has none to link:
-- linux writes __uint128_t in the KVM guest code and links no libgcc.
-- So the bodies the unit asked for are built into the object, as names
-- of its own.
--
-- The source is read through a preprocessor of its own, with nothing of
-- the program defined: a build that gives `lo` or `mask` a meaning must
-- not reach it.

local cpp = require "cpp"
local parse = require "parse"

local widert = {}

function widert.emit(p, write, t, root, opts)
	local need = p.rtneed

	if not need or not next(need) or os.getenv("WIDE") ~= nil then
		return
	end
	local want = false

	for name in pairs(need) do
		if name:sub(1, 4) == "__w_" and not p.globals[name] then
			want = true
		end
	end
	if not want then return end
	local f = io.open(root .. "/rt/wide.c")

	if not f then return end
	local body = f:read("a")

	f:close()
	local defs = {WFN = "static", WIDE_HALF = tostring(t.ptrsize)}

	for k, v in pairs(t.predef or {}) do defs[k] = v end
	local name = "<mcc wide runtime>"
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
end

return widert
