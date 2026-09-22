-- SPDX-License-Identifier: ISC
-- The assembler against the real one, over everything this compiler makes
-- from a Lua source tree.  The corpus is built here so that the test does
-- not depend on another one having run first.
--
--   LUA_SRC=... lua5.4 test/asdiff.lua [riscv|xtensa]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local arch = arg[1] or "riscv"
local TARGET = {xtensa = "xtensa", amd64 = "amd64", riscv = "riscv64",
		arm64 = "arm64"}
local target = TARGET[arch] or "riscv64"
local src = os.getenv("LUA_SRC")
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-asdiff-" .. arch

tap.scratch(dir)

local sources = {}
if src and src ~= "" then
	local p = io.popen("ls " .. src .. "/*.c 2>/dev/null")
	for l in p:lines() do sources[#sources + 1] = l end
	p:close()
end
if #sources == 0 then
	-- no tree to hand: the compiler's own test programs still exercise
	-- most of the instruction set
	local p = io.popen("ls " .. here .. "/c/*.c")
	for l in p:lines() do sources[#sources + 1] = l end
	p:close()
end

local lua = os.getenv("LUA") or "lua5.4"
local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)
if src and src ~= "" then
	inc = inc .. " -I" .. src .. " -I" .. src:gsub("/[^/]*$", "") ..
		"/include"
end

local made = {}
for _, f in ipairs(sources) do
	local b = f:match("([^/]+)%.c$")
	local out = dir .. "/" .. b .. ".s"
	-- position independent, because that is what a module is built
	-- with and it is the harder of the two to encode
	local cmd = ("%s %s/../cc.lua -t %s %s %s %s -o %s 2>/dev/null")
		:format(lua, here, target,
			target == "amd64" and "-fpic" or "", inc, f, out)
	if os.execute(cmd) then made[#made + 1] = out end
end
if #made == 0 then tap.skipall("nothing compiled for " .. arch) end

-- hand the list to the assembler's own differential test
local SCRIPT = {xtensa = "/asxt.lua", amd64 = "/asa64.lua",
		riscv = "/asrv.lua", arm64 = "/asa64r.lua"}
local script = here .. (SCRIPT[arch] or "/asrv.lua")
arg = made
arg[0] = script
dofile(script)
