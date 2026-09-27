-- SPDX-License-Identifier: ISC
-- Differential test for the amd64 assembler, one instruction at a time.
--
-- An x86 instruction is not a fixed width, so a whole file cannot be lined
-- up against another the way a RISC-V one can.  Each distinct form the
-- compiler emits is assembled on its own instead, here and by gas, and the
-- bytes compared.
--
--   lua5.4 test/asa64.lua file.s ...

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local as = require "mcc.as"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-asa64"

dir = tap.scratch(dir, true)

local function slurp(path, mode)
	local f = io.open(path, mode or "r")
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

-- a branch or a call needs a target; it gets one right in front of it, so
-- that both assemblers measure the same distance
local JUMPS = {jmp = true, call = true}
local seen, list = {}, {}

for _, path in ipairs(arg) do
	for l in (slurp(path) or ""):gmatch("[^\n]+") do
		local m, rest = l:match("^\t(%S+)%s*(.*)$")
		if m and m:sub(1, 1) ~= "." then
			local jump = JUMPS[m] or
				(m:sub(1, 1) == "j" and #m <= 3)
			local line = "\t" .. m .. (rest == "" and "" or
				("\t" .. rest))
			if not seen[line] then
				seen[line] = true
				local n = #list + 1
				if jump and not rest:find("%*") then
					line = ("L%d:\n\t%s\t%s"):format(n, m,
						(rest:gsub("[^,]+$",
							"L" .. n)))
				end
				list[n] = line
			end
		end
	end
end
if #list == 0 then tap.skipall("no instructions to compare") end

-- Assemble the first n of them, with gas and with ours.
local function build(n)
	local src = "\t.text\nL0:\n" ..
		table.concat(list, "\n", 1, n) .. "\n"
	local f = assert(io.open(dir .. "/all.s", "w"))

	f:write(src)
	f:close()
	if os.execute(("as --64 -o %s/all.o %s/all.s 2>%s/err")
	    :format(dir, dir, dir)) ~= true then
		return nil, (slurp(dir .. "/err") or ""):gsub("\n.*", "")
	end
	os.execute(("objcopy -O binary --only-section=.text " ..
		"%s/all.o %s/all.bin"):format(dir, dir))
	local want = slurp(dir .. "/all.bin", "rb") or ""
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not ok then return nil, tostring(a) end
	return a.sec[".text"].bytes == want
end

local same, err = build(#list)
if same == nil then
	tap.ok(false, "both assemblers take the file")
	tap.diag(err)
	tap.done()
end

if not tap.ok(same,
    ("amd64 assembler matches gas on %d instructions"):format(#list)) then
	-- the first instruction the two disagree on, by halving
	local lo, hi = 1, #list
	while lo < hi do
		local mid = (lo + hi) // 2
		if build(mid) then lo = mid + 1 else hi = mid end
	end
	tap.diag("first differs at: " .. (list[lo] or "?"):gsub("\n", " "))
end
tap.done()
