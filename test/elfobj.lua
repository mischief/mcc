-- The ELF object against the real toolchain: what this compiler writes
-- has to assemble, link and run under binutils.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-elfobj"
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local lua = os.getenv("LUA") or "lua5.4"
local CC = os.getenv("CC") or "gcc"
local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	local ok = p:close()
	return ok and true or false, out
end

local srcs = {"prog", "types", "init", "lang", "rec"}
local n = 0

for _, base in ipairs(srcs) do
	local src = here .. "/c/" .. base .. ".c"
	local main = here .. "/c/" ..
		(base == "prog" and "main" or (base .. "main")) .. ".c"
	local objs = {}
	local ok, out = true, ""

	for i, f in ipairs{src, main} do
		objs[i] = ("%s/%s%d.o"):format(dir, base, i)
		ok, out = shell(("%s %s/../drive.lua --elf -c -t amd64 %s %s -o %s")
			:format(lua, here, inc, f, objs[i]))
		if not ok then break end
	end
	if ok then
		local rt = here .. "/../rt/softfp.c " ..
			here .. "/../rt/varargs.c " ..
			here .. "/../rt/wide.c " ..
			here .. "/../rt/widefp.c -lm"

		ok, out = shell(("%s -w -o %s/%s %s %s %s"):format(CC,
			dir, base, objs[1], objs[2], rt))
	end
	local mine
	if ok then ok, mine = shell(dir .. "/" .. base) end
	local ref = ""
	if ok then
		local built
		built, ref = shell(("%s -O0 -w -o %s/ref-%s %s %s -lm"):format(
			CC, dir, base, src, main))
		if built then _, ref = shell(("%s/ref-%s"):format(dir, base)) end
	end
	n = n + 1
	if not ok then tap.diag(out) end
	tap.ok(ok and mine == ref, "elf object: " .. base)
end
tap.done()
