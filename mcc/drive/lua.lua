-- SPDX-License-Identifier: ISC
-- A Lua source, compiled to assembly for the target the driver set up.

local P = require "mcc.lua.parse"
local C = require "mcc.lua.code"

return function(d, path, out)
	local h, err = io.open(path)

	if not h then d.die(err) end
	local src = h:read("a")

	h:close()
	local chunk = path:gsub(".*/", "")
	local ok, text = pcall(function()
		return C.compile(P.chunk(src, chunk), d.target(), chunk,
			{pic = d.o.pic})
	end)

	if not ok then d.die(tostring(text)) end
	-- A stage's own buffer, or the name of the file -S writes.
	if type(out) == "string" then
		local w = out == "-" and io.stdout or assert(io.open(out, "w"))

		w:write(text)
		if w ~= io.stdout then w:close() end
		return
	end
	out:write(text)
end
