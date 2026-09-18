-- The C scanner against the Lua one.
--
-- The module decides where a token ends and nothing else, so the two paths
-- must produce the same tokens over any file.  This runs both over every
-- source it can find and compares them one token at a time.
--
--   lua5.4 test/scan.lua file.c ...

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lex = require "lex"
local ok, scan = pcall(require, "scan")

if not ok then tap.skipall("no scan module built") end

local files = {}
for _, p in ipairs(arg) do files[#files + 1] = p end
if #files == 0 then
	local p = io.popen("ls " .. here .. "/c/*.c " .. here .. "/../rt/*.c")

	for l in p:lines() do files[#files + 1] = l end
	p:close()
end

local function tokens(text, name, fast)
	local l = lex.new(text, name, true)
	local out = {}

	while true do
		local t = fast and l:next() or l:slownext()

		out[#out + 1] = ("%s|%s|%s|%s|%s|%d"):format(t[1],
			tostring(t[2]), tostring(t[3]), tostring(t[5]),
			tostring(t[6]), t[4])
		if t[1] == "eof" then break end
	end
	return out
end

local n, bad = 0, 0

for _, path in ipairs(files) do
	local f = io.open(path, "rb")

	if f then
		local text = f:read("a")

		f:close()
		local a = tokens(text, path, true)
		local b = tokens(text, path, false)
		local same = #a == #b

		if same then
			for i = 1, #a do
				if a[i] ~= b[i] then
					same = false
					tap.diag(("%s token %d\n  C   %s\n  Lua %s")
						:format(path, i, a[i], b[i]))
					break
				end
			end
		else
			tap.diag(("%s: %d tokens, Lua %d")
				:format(path, #a, #b))
		end
		n = n + #a
		if not same then bad = bad + 1 end
	end
end

tap.ok(bad == 0, ("the C scanner agrees with the Lua one on %d tokens " ..
	"in %d files"):format(n, #files))
tap.done()
