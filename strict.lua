-- SPDX-License-Identifier: ISC
-- Reading a global that was never set is a mistake, so say so.
--
-- A local named later in a file is a global to the code above it, and
-- Lua answers nil rather than complaining.  That turns a reference to
-- something not yet declared into a call on nil, far from the line that
-- wrote it.  This costs a metatable lookup on a miss, which in code
-- that is right never happens.
--
-- Writing is left alone: this compiler sets a handful of globals for
-- the memory report, and declaring them would say nothing.

local strict = {}

function strict.on()
	local m = getmetatable(_G)

	if m and m.__strict then return end
	setmetatable(_G, {
		__strict = true,
		__index = function(_, k)
			if type(k) ~= "string" then return nil end
			error(("undefined global '%s'"):format(k), 2)
		end,
	})
end

-- What the memory report reads before anything has set it.
function strict.get(k)
	return rawget(_G, k)
end

return strict
