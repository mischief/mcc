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
		if built then
			local _r

			_r, ref = shell(("%s/ref-%s")
				:format(dir, base))
		end
	end
	n = n + 1
	if not ok then tap.diag(out) end
	tap.ok(ok and mine == ref, "elf object: " .. base)
end

-- What -fvisibility writes into the symbol table, which decides whether a
-- shared object calls its own definition or one the program put in front
-- of it.
do
	local src = dir .. "/vis.c"
	local f = assert(io.open(src, "w"))

	f:write([[
int plain = 1;
int hid(void) { return plain; }
__attribute__((visibility("default"))) int shown(void) { return 2; }
/* the attribute sticks to the name, as a header's declaration does */
__attribute__((visibility("default"))) int api(void);
int api(void) { return 4; }
static int own(void) { return 3; }
int uses(void) { return own(); }
]])
	f:close()

	local function symbols(cmd)
		local ok, out = shell(cmd)

		if not ok then return nil, out end
		ok, out = shell(("readelf -sW %s/vis.o"):format(dir))
		if not ok then return nil, out end
		local list = {}
		for l in out:gmatch("[^\n]+") do
			local bind, vis, name =
				l:match("%s(%u+)%s+(%u+)%s+%S+%s+(%S+)%s*$")
			-- Only the names another object can see: gcc also
			-- keeps a local symbol for each static and for the
			-- file, and this compiler resolves those away.
			if bind == "GLOBAL" and name and name:match("^%a") then
				list[#list + 1] = bind .. " " .. vis ..
					" " .. name
			end
		end
		table.sort(list)
		return table.concat(list, "\n")
	end

	local mine, err = symbols(("%s %s/../drive.lua -c -t amd64 " ..
		"-fvisibility=hidden %s -o %s/vis.o")
		:format(lua, here, src, dir))
	local ref
	if mine then
		ref, err = symbols(("%s -c -fvisibility=hidden %s -o %s/vis.o")
			:format(CC, src, dir))
	end
	if not (mine and ref) then tap.diag(err or "?") end
	if not tap.ok(mine ~= nil and mine == ref, "-fvisibility=hidden") then
		tap.diag("ours: " .. (mine or "?"):gsub("\n", "; "))
		tap.diag("gcc:  " .. (ref or "?"):gsub("\n", "; "))
	end
end
tap.done()
