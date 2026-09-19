-- SPDX-License-Identifier: ISC
-- The preprocessor against the real one, over a whole Lua source tree.
--
--   LUA_SRC=... lua5.4 test/cppall.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local src = os.getenv("LUA_SRC")
if not src or src == "" then
	tap.skipall("set LUA_SRC to a Lua source tree")
end

local files = {}
local p = io.popen("ls " .. src .. "/*.c 2>/dev/null")
for l in p:lines() do files[#files + 1] = l end
p:close()
if #files == 0 then tap.skipall("no sources under " .. src) end

-- cpp.lua reads its include path from the environment, which cannot be set
-- from here, so it is put back through the one place that can: the child
-- does the comparing and its TAP comes straight out.
-- the tree's own headers, whatever sits beside it, and ours: a tree that
-- carries no headers of its own still has to find limits.h
local inc = table.concat({src, src:gsub("/[^/]*$", "") .. "/include",
	here .. "/../include", here .. "/../include/hosted"}, ":")
local cmd = ("CPPINC=%s %s %s/cpp.lua %s"):format(inc,
	os.getenv("LUA") or "lua5.4", here, table.concat(files, " "))
local child = io.popen(cmd)
local out = child:read("a")
local good = child:close()

io.write(out)
if not good and not out:find("\nnot ok") and not out:find("^not ok") then
	tap.ok(false, "the preprocessor test ran")
	tap.done()
end
os.exit(good and 0 or 1)
