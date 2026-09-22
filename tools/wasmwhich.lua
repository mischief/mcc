#!/usr/bin/env lua5.4
-- wasmwhich.lua -- name the function at an index in a module.
--
--	wasmwhich.lua module.wasm 215
--
-- An engine reports a failure by index. The export section is the only
-- place a module says a name, so a static function answers nothing but
-- its neighbours place it.

local path, want = arg[1], tonumber(arg[2])

if not path then
	io.stderr:write("usage: wasmwhich.lua module.wasm [index]\n")
	os.exit(1)
end

local f = assert(io.open(path, "rb"))
local d = f:read("a")

f:close()

local at = 9				-- past the magic and the version

local function uleb()
	local r, s = 0, 0

	while true do
		local b = d:byte(at)

		at = at + 1
		r = r | ((b & 0x7f) << s)
		s = s + 7
		if b < 0x80 then return r end
	end
end

local nimport, name = 0, {}

while at <= #d do
	local id = d:byte(at)

	at = at + 1
	local size = uleb()
	local stop = at + size

	if id == 2 then
		for _ = 1, uleb() do
			at = at + uleb()	-- module
			at = at + uleb()	-- field
			local kind = d:byte(at)

			at = at + 1
			uleb()
			if kind == 0 then nimport = nimport + 1 end
		end
	elseif id == 7 then
		for _ = 1, uleb() do
			local n = uleb()
			local s = d:sub(at, at + n - 1)

			at = at + n
			local kind = d:byte(at)

			at = at + 1
			local idx = uleb()

			if kind == 0 then name[idx] = s end
		end
	end
	at = stop
end

if not want then
	print(("%d imports, %d exported functions"):format(nimport,
	    (function() local n = 0 for _ in pairs(name) do n = n + 1 end
	    return n end)()))
	os.exit(0)
end

for i = want, want - 40, -1 do
	if name[i] then
		print(("%d is %s%s"):format(want, name[i],
		    i == want and "" or (", %d after it"):format(want - i)))
		os.exit(0)
	end
end
print(("%d is static; nothing exported within 40 of it"):format(want))
