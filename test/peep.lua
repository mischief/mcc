-- SPDX-License-Identifier: ISC
-- What the peephole promises about the code it leaves behind.
--
-- A rule that stops firing costs bytes and fails nothing: the program
-- still answers the same, which is all the differential tests ask.  So
-- the shapes a rule is there to remove are checked for directly, over
-- every program in the corpus rather than over one written here.
--
--   lua5.4 test/peep.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-peep"

tap.scratch(dir)

local sources = {}
do
	local p = io.popen("ls " .. here .. "/c/*.c")

	for l in p:lines() do sources[#sources + 1] = l end
	p:close()
end
if #sources == 0 then tap.skipall("no sources to compile") end

-- Every name for one machine register, so that a rule asking whether
-- a value dies can tell %rax from %eax and %al.
local WHICH = {}
for i, names in ipairs{
	{"al", "ax", "eax", "rax"}, {"bl", "bx", "ebx", "rbx"},
	{"cl", "cx", "ecx", "rcx"}, {"dl", "dx", "edx", "rdx"},
	{"sil", "si", "esi", "rsi"}, {"dil", "di", "edi", "rdi"},
	{"bpl", "bp", "ebp", "rbp"}, {"spl", "sp", "esp", "rsp"},
	{"r8b", "r8w", "r8d", "r8"}, {"r9b", "r9w", "r9d", "r9"},
	{"r10b", "r10w", "r10d", "r10"}, {"r11b", "r11w", "r11d", "r11"},
	{"r12b", "r12w", "r12d", "r12"}, {"r13b", "r13w", "r13d", "r13"},
	{"r14b", "r14w", "r14d", "r14"}, {"r15b", "r15w", "r15d", "r15"},
} do
	for _, n in ipairs(names) do WHICH["%" .. n] = i end
end

-- An add of a constant into a register, read once by a load that
-- writes the same register back.  The constant belongs in the
-- displacement and the add should be gone.
local function unfolded(path)
	local lines = {}

	for l in io.lines(path) do lines[#lines + 1] = l end
	local n = 0

	for i = 1, #lines - 1 do
		local mn, k, r = lines[i]:match("^\t(add[ql])\t%$(%-?%d+),(%%%w+)$")

		if mn and k ~= "0" then
			local m2, a, b = lines[i + 1]
				:match("^\t(mov%w*)\t([^,]+),(%S+)$")

			if m2 and a == "(" .. r .. ")" and
			   WHICH[b] and WHICH[b] == WHICH[r] then
				n = n + 1
				if n == 1 then
					tap.diag(path .. ":\n  " ..
						lines[i] .. "\n  " ..
						lines[i + 1])
				end
			end
		end
	end
	return n
end

local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

for _, target in ipairs{"amd64", "i386"} do
	local left, built = 0, 0

	for _, src in ipairs(sources) do
		local out = ("%s/%s-%s.s"):format(dir, target,
			src:match("([^/]+)%.c$"))
		local cmd = ("%s %s/../drive.lua -S -O1 -w -t %s %s %s -o %s" ..
			" 2>/dev/null"):format(lua, here, target, inc, src, out)

		os.execute(cmd)
		local f = io.open(out)

		if f then
			f:close()
			built = built + 1
			left = left + unfolded(out)
		end
	end
	tap.ok(built > 0, target .. " has something to look at")
	tap.is(left, 0, target ..
		" folds a constant add into the displacement after it")
end

tap.done()
