-- SPDX-License-Identifier: ISC
-- Lua compiled by this compiler, against the Lua that runs this test.
--
-- Each file in test/lua is built into a program, and the program has to
-- say what the interpreter says of the same file, and exit the same way.
-- Then it is run again with LR_STATS, and what is still live once the
-- program has let go of its globals has to be what is live after an
-- empty program: anything more is a leak.  A file whose first lines say
-- `-- cycles` makes reference cycles on purpose, and only has to answer.
--
--   lua5.4 test/luafe.lua [file.lua...]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or arg[-1] or "lua5.4"
local root = here .. "/.."
local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-luafe",
	true)

local function q(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Everything the command wrote to its standard output and its exit.
local function run(cmd)
	local h = io.popen(cmd .. "; echo \"exit $?\"")
	local out = h:read("a")

	h:close()
	return out
end

local function build(src, exe, opt)
	local out = run(("%s %s/drive.lua %s -o %s %s 2>&1"):format(lua, root,
		opt or "", q(exe), q(src)))

	return out:match("exit 0\n$") ~= nil, out
end

local files = {}

for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then
	local h = io.popen("ls " .. q(root .. "/test/lua") .. "/*.lua")

	for l in h:lines() do files[#files + 1] = l end
	h:close()
end

local empty = dir .. "/empty.lua"
local w = assert(io.open(empty, "w"))

w:write("\n")
w:close()
local ok = build(empty, dir .. "/empty")

if not tap.ok(ok, "an empty program builds") then tap.done() return end
local function live(exe, cwd)
	local out = run(("cd %s && LR_STATS=1 %s 2>&1 >/dev/null"):format(
		q(cwd), q(exe)))

	return out:match("live: [^\n]*")
end
local baseline = live(dir .. "/empty", dir)

-- Each at -O0 and again through the peephole.
for _, opt in ipairs{"-O0", "-O1"} do
for _, src in ipairs(files) do
	local name = src:gsub(".*/", ""):gsub("%.lua$", "") .. opt
	local exe = dir .. "/" .. name
	local cwd = src:match("^(.*)/[^/]*$") or "."
	local built, msg = build(src, exe, opt)

	if not tap.ok(built, name .. " builds") then
		tap.diag(msg)
		goto next
	end
	do
		local want = run(("cd %s && %s %s 2>/dev/null"):format(q(cwd),
			q(lua), q(src:gsub(".*/", ""))))
		local got = run(("cd %s && %s 2>/dev/null"):format(q(cwd),
			q(exe)))

		if not tap.is(got, want, name .. " answers as Lua does") then
			goto next
		end
		local h = io.open(src)
		local head = h:read(200) or ""

		h:close()
		if not head:find("%-%- cycles") then
			tap.is(live(exe, cwd), baseline,
				name .. " leaves nothing live")
		end
	end
	::next::
end
end
tap.done()
