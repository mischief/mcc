-- SPDX-License-Identifier: ISC
-- A Lua module built by this compiler, loaded by an interpreter that was
-- not, and the other way round.
--
-- A shared object is where the calling convention stops being a private
-- arrangement: everything on the other side of a call was built by another
-- compiler and agrees to nothing beyond the ABI.  Both modules are loaded
-- into both interpreters, and all four have to say the same thing.
--
--   lua5.4 test/mod.lua <interpreter> <reference interpreter>

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local function full(path)
	if not path or path:sub(1, 1) == "/" then return path end
	local p = io.popen("pwd")
	local cwd = p:read("l")
	p:close()
	return cwd .. "/" .. path
end

here = full(here)

local lua = os.getenv("LUA") or "lua5.4"
local src = os.getenv("LUA_SRC")
local interp = {mine = full(arg[1]), ref = full(arg[2])}

if not src or src == "" or not interp.mine or not interp.ref then
	tap.skipall("needs LUA_SRC and two interpreters")
end

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-mod"
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir .. "/mine " ..
	dir .. "/ref")

-- The soft float runtime goes in because this compiler lowers double
-- arithmetic to calls.  The ABI still hands the values over in the
-- registers the platform names, which is the thing under test.
local srcs = {here .. "/c/mod.c", here .. "/../rt/softfp.c",
	      here .. "/../rt/varargs.c"}
local objs = {}

for i, f in ipairs(srcs) do
	local s = ("%s/mine/%d.s"):format(dir, i)
	local ok, out = shell(("%s %s/../cc.lua -t amd64 -fpic " ..
		"-I%s/../include -I%s/../include/hosted -I%s %s -o %s")
		:format(lua, here, here, here, src, f, s))
	if not ok then
		tap.ok(false, "the module compiles")
		tap.diag(out)
		tap.done()
	end
	objs[i] = s
end

-- our own assembler and our own linker, so that nothing in the file this
-- is about came from another toolchain
local ok, out = shell(("%s %s/../link.lua -t amd64 -shared " ..
	"-o %s/mine/compmod.so %s")
	:format(lua, here, dir, table.concat(objs, " ")))
if not tap.ok(ok and true or false, "the module links as a shared object") then
	tap.diag(out)
	tap.done()
end

ok, out = shell(("gcc -shared -fPIC -w -I%s -o %s/ref/compmod.so %s/c/mod.c")
	:format(src, dir, here))
if not ok then
	tap.ok(false, "the reference module builds")
	tap.diag(out)
	tap.done()
end

-- every module under every interpreter
local said, first = {}, nil
for _, mod in ipairs{"mine", "ref"} do
	for _, who in ipairs{"mine", "ref"} do
		local name = mod .. " module in " .. who .. " lua"
		local _, s = shell(("cd %s/%s && %s -e 'package.cpath=\"./?.so\"' %s/c/mod.lua")
			:format(dir, mod, interp[who], here))
		said[name] = s
		first = first or name
	end
end

if not tap.ok(said[first]:find("Uryyb", 1, true) ~= nil,
    "the module loads and runs") then
	tap.diag(said[first])
	tap.done()
end

local n = select(2, said[first]:gsub("\n", ""))
for name, s in pairs(said) do
	if name ~= first then
		if not tap.ok(s == said[first],
		    ("%s answers as %s does (%d lines)"):format(name, first, n))
		then
			local a, b = {}, {}
			for l in s:gmatch("[^\n]*") do a[#a + 1] = l end
			for l in said[first]:gmatch("[^\n]*") do
				b[#b + 1] = l
			end
			for i = 1, math.max(#a, #b) do
				if a[i] ~= b[i] then
					tap.diag(("line %d\n  %s\n  %s")
						:format(i, tostring(a[i]),
							tostring(b[i])))
				end
			end
		end
	end
end
tap.done()
