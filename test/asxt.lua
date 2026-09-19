-- SPDX-License-Identifier: ISC
-- Differential test for the Xtensa assembler.
--
-- gas is asked not to transform anything, so it assembles what is written
-- rather than what it would rather write: no narrow forms, no relaxation,
-- no literal pools.  That leaves the encoding, which is what this compares,
-- one instruction at a time over every form the compiler emits.
--
-- Pools and branch relaxation are ours alone and are not checked here.
--
--   lua5.4 test/asxt.lua file.s ...

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local tap = require "test.tap"

local as = require "as"

local ESP = os.getenv("ESPTOOLS") or
	os.getenv("HOME") .. "/.espressif/tools/xtensa-esp-elf"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-asxt"

local function look()
	local p = io.popen("ls -d " .. ESP .. "/*/xtensa-esp-elf/bin " ..
		"2>/dev/null | head -1")
	local d = p:read("l")
	p:close()
	return d
end

local bin = look()
if not bin then
	tap.skipall("no xtensa toolchain under " .. ESP)
end
local AS = bin .. "/xtensa-esp32s3-elf-as"
local OBJCOPY = bin .. "/xtensa-esp32s3-elf-objcopy"

os.execute("mkdir -p " .. dir)

local function slurp(path, mode)
	local f = io.open(path, mode or "r")
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

-- Every distinct instruction, with a label operand pointed at one the test
-- file defines so that both assemblers see the same distance.
-- A branch reaches 128 bytes, so each one gets a label of its own right
-- in front of it.  call8 needs its target aligned and is covered by
-- test/xtensa/enc.s instead.
local BRANCH = {beq = true, bne = true, blt = true, bge = true,
		bltu = true, bgeu = true, beqz = true, bnez = true,
		j = true}
local seen, list = {}, {}

for _, path in ipairs(arg) do
	local text = slurp(path) or ""
	for l in text:gmatch("[^\n]+") do
		local m, rest = l:match("^\t(%S+)%s*(.*)$")
		if m and m:sub(1, 1) ~= "." then
			local branch = BRANCH[m]
			-- a constant too wide for movi becomes a literal,
			-- which gas will not write without transforming
			local v = m == "movi" and rest:match(",(.*)$")
			local wide = v and (not tonumber(v) or
				tonumber(v) < -2048 or tonumber(v) > 2047)
			local line = "\t" .. m .. "\t" .. rest
			if m == "call8" or m == "callx8" then line = nil end
			if line and not wide and not seen[line] then
				seen[line] = true
				if branch then
					local n = #list + 1
					line = ("L%d:\n\t%s\t%s"):format(n, m,
						(rest:gsub("[^,]+$", "L" .. n)))
				end
				list[#list + 1] = line
			end
		end
	end
end

local src = {"\t.text", "\t.align\t4", "f:", "L:"}
for _, l in ipairs(list) do src[#src + 1] = l end
src = table.concat(src, "\n") .. "\n"

local f = assert(io.open(dir .. "/all.s", "w"))
f:write(src)
f:close()

if os.execute(("%s --no-transform -o %s/all.o %s/all.s 2>%s/err")
    :format(AS, dir, dir, dir)) ~= true then
	tap.ok(false, "gas takes the file")
	tap.diag((slurp(dir .. "/err") or ""):gsub("\n.*", ""))
	tap.done()
end
os.execute(("%s -O binary --only-section=.text %s/all.o %s/all.bin")
	:format(OBJCOPY, dir, dir))

local want = slurp(dir .. "/all.bin", "rb") or ""
local ok, a = pcall(as.assemble, src, {arch = "xtensa"})
if not ok then
	tap.ok(false, "our assembler takes the file")
	tap.diag(tostring(a))
	tap.done()
end
local mine = a.sec[".text"].bytes

if not tap.ok(mine == want,
    ("xtensa assembler matches gas on %d instructions"):format(#list)) then
	tap.diag(("%d bytes, gas %d"):format(#mine, #want))
	for i = 1, math.min(#mine, #want) do
		if mine:sub(i, i) ~= want:sub(i, i) then
			tap.diag(("first differ at byte %d"):format(i - 1))
			break
		end
	end
end
tap.done()
