-- SPDX-License-Identifier: ISC
-- xtensa offsets past what an instruction reaches.  -mlongcalls loads a
-- call's address and uses callx8, and without it the linker refuses a
-- call8 past 512 KiB.  A block copy moves its pointers past 1020 bytes.
--
--   lua5.4 test/xtreach.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-xtreach"

tap.scratch(dir)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))
	f:write(text)
	f:close()
	return dir .. "/" .. name
end

local near = write("near.c", "int far(int);\n" ..
	"int _start(void) { return far(20); }\n" ..
	"__asm__(\".text\\n\\t.space 700000\");\n")
local far = write("far.c", "int far(int x) { return x * 2 + 1; }\n")
local cc = "lua5.4 " .. here .. "/../drive.lua --target=xtensa -S "
local link = "lua5.4 " .. here .. "/../link.lua -t xtensa -o " .. dir

local ok, out = shell(cc .. far .. " -o " .. dir .. "/far.s")
tap.ok(ok, "the callee compiles")

for _, long in ipairs{false, true} do
	local flag = long and "-mlongcalls " or ""
	local s = dir .. (long and "/long.s" or "/short.s")

	ok, out = shell(cc .. flag .. near .. " -o " .. s)
	tap.ok(ok, flag .. "compiles")
	local f = io.open(s)
	local text = f and f:read("a") or ""
	if f then f:close() end
	if long then
		tap.ok(text:find("callx8") and not text:find("\tcall8"),
			"-mlongcalls calls through a register")
	else
		tap.ok(text:find("\tcall8\tfar"), "a plain call is call8")
	end
	ok, out = shell(link .. "/prog " .. s .. " " .. dir .. "/far.s")
	if long then
		tap.ok(ok, "a long call links")
		if not ok then tap.diag(out) end
	else
		tap.ok(not ok and out:find("past what it reaches"),
			"a call8 past its reach is refused")
		if ok then tap.diag(out) end
	end
end

-- Every load and store a copy of 3 KiB writes reaches its offset.
local big = write("big.c", "struct b { char c[3001]; long t; };\n" ..
	"void cp(struct b *d, struct b *s) { *d = *s; }\n")
ok, out = shell(cc .. big .. " -o " .. dir .. "/big.s")
tap.ok(ok, "a copy of 3 KiB compiles")
local worst = 0
for line in ok and io.lines(dir .. "/big.s") or function() end do
	local mn, off = line:match("^\t([ls]%d+u?i)\t[^,]+,[^,]+,(%-?%d+)")
	local scale = {l32i = 4, s32i = 4, l16ui = 2, s16i = 2,
		       l8ui = 1, s8i = 1}

	if mn and scale[mn] then
		local over = tonumber(off) - 255 * scale[mn]

		if over > worst then worst = over end
	end
end
tap.is(worst, 0, "no load or store past its offset field")

tap.done()
