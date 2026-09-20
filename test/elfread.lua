-- SPDX-License-Identifier: ISC
-- The ELF reader against nm and readelf, over objects this compiler
-- made, and the address lookup against what the symbol table says.
--
--	lua5.4 test/elfread.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local elfread = require "elfread"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-elfread"

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function run(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	local out = p:read("a") or ""

	p:close()
	return out
end

local function have(prog)
	return run("command -v " .. prog):match("%S") ~= nil
end

if not have("nm") then tap.skipall("no binutils to compare against") end

-- One object per test program, built by this compiler, so that what is
-- read back is what this compiler writes.
local objs = {}
local sources = {}
local p = io.popen("ls " .. here .. "/c/*.c 2>/dev/null")

for l in p:lines() do sources[#sources + 1] = l end
p:close()
if #sources == 0 then tap.skipall("no test programs to compile") end

local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

for i, f in ipairs(sources) do
	if i > 12 then break end
	local b = f:match("([^/]+)%.c$")
	local out = dir .. "/" .. b .. ".o"
	local cmd = ("%s %s/../drive.lua -c -t amd64 %s %s -o %s")
		:format(lua, here, inc, f, out)

	if os.execute(cmd .. " 2>/dev/null") then
		objs[#objs + 1] = out
	end
end
if #objs == 0 then tap.skipall("nothing compiled") end

-- The symbol table, against nm.  The order two tools put equal names in
-- is a matter of collation, so the lines are compared as a set.
local function nmlines(cmd)
	local t = {}

	for l in run(cmd):gmatch("[^\n]+") do t[#t + 1] = l end
	table.sort(t)
	return t
end

for _, o in ipairs(objs) do
	local want = nmlines("nm " .. o)
	local got = nmlines(("%s %s/../nm.lua %s"):format(lua, here, o))
	local same = #want == #got

	if same then
		for i = 1, #want do
			if want[i] ~= got[i] then
				same = false
				tap.diag(("want %s\ngot  %s")
					:format(want[i], got[i]))
				break
			end
		end
	else
		tap.diag(("nm printed %d lines, mnm printed %d")
			:format(#want, #got))
	end
	tap.ok(same, "mnm agrees with nm on " .. o:match("[^/]+$"))
end

-- The sections, against readelf: name, size and address, which is what
-- a linker reads and so what a mistake here would break.
if have("readelf") then
	for _, o in ipairs(objs) do
		local f = assert(elfread.open(o))
		local want, got = {}, {}

		for l in run("readelf -SW " .. o):gmatch("[^\n]+") do
			local n, t, a, off, sz = l:match(
				"%[%s*%d+%]%s+(%S+)%s+(%S+)%s+(%x+)%s+(%x+)%s+(%x+)")

			if n and n ~= "NULL" then
				want[#want + 1] = ("%s %s %s"):format(n,
					tonumber(a, 16), tonumber(sz, 16))
			end
		end
		for _, s in ipairs(f.sections) do
			if s.index > 0 then
				got[#got + 1] = ("%s %s %s"):format(s.name,
					s.addr, s.size)
			end
		end
		tap.is(table.concat(got, "\n"), table.concat(want, "\n"),
			"sections agree with readelf on " ..
			o:match("[^/]+$"))
		f:close()
	end
end

-- The three listings objdump prints from the same tables: the section
-- headers, the symbols and the relocations.
for _, o in ipairs(objs) do
	for _, flag in ipairs{"-h", "-t", "-r"} do
		local want = run(("objdump %s %s"):format(flag, o))
		local got = run(("%s %s/../objdump.lua %s %s")
			:format(lua, here, flag, o))

		if want ~= got and #want > 0 then
			local wl, gl = {}, {}

			for l in want:gmatch("[^\n]*\n") do wl[#wl + 1] = l end
			for l in got:gmatch("[^\n]*\n") do gl[#gl + 1] = l end
			for i = 1, math.max(#wl, #gl) do
				if wl[i] ~= gl[i] then
					tap.diag(("line %d\nwant %sgot  %s")
						:format(i, wl[i] or "(none)\n",
							gl[i] or "(none)\n"))
					break
				end
			end
		end
		tap.ok(want == got, ("mobjdump %s agrees with objdump on %s")
			:format(flag, o:match("[^/]+$")))
	end
end

-- Address to symbol: every symbol's own address answers with itself at
-- an offset of zero, and one byte in answers with an offset of one.
for _, o in ipairs(objs) do
	local f = assert(elfread.open(o))
	local ok, first = true, nil

	for _, s in ipairs(f:syms()) do
		if s.typ == "func" and s.sec and s.size > 1 then
			local a, off = f:at(s.value, s.sec)
			local b, off2 = f:at(s.value + 1, s.sec)

			if not (a and a.name == s.name and off == 0) or
			   not (b and b.name == s.name and off2 == 1) then
				ok = false
				first = first or s.name
			end
		end
	end
	tap.ok(ok, "every function is found at its own address in " ..
		o:match("[^/]+$") .. (first and (" (" .. first .. ")") or ""))
	f:close()
end

-- A name that is not there is not found, and a name that is carries
-- the section it was defined in.
local f = assert(elfread.open(objs[1]))

tap.ok(f:sym("a name no object defines") == nil, "an absent name is nil")
local any = nil

for _, s in ipairs(f:syms()) do
	if s.typ == "func" and s.sec then any = s break end
end
if any then
	local s = f:sym(any.name)

	tap.ok(s and s.value == any.value and s.sec == any.sec,
		"a name looks up to the symbol it came from")
else
	tap.skip("a name looks up to the symbol it came from", "no functions")
end
f:close()

-- What locate says about itself.  A function's own address is certain.
-- An address in the padding after one is still attributed to it, and
-- that is the answer that has to say it is a guess, because a function
-- whose symbol the assembler dropped looks exactly the same.
local first, gap = nil, nil

f = assert(elfread.open(objs[1]))
for _, s in ipairs(f:syms()) do
	if s.typ == "func" and s.sec and s.size > 4 then
		first = first or s
		local past = s.value + s.size + 1
		local who = f:at(past, s.sec)

		if not gap and who == s then gap = s end
	end
end
if first then
	local at = f:locate(first.value, first.sec)

	tap.ok(at.name == first.name and at.off == 0 and at.sure,
		"a function's own address is certain")
else
	tap.skip("a function's own address is certain", "no sized function")
end
if gap then
	local past = f:locate(gap.value + gap.size + 1, gap.sec)

	tap.ok(not past.sure and past.why ~= nil,
		"an address past the end of a function is not")
	tap.diag(past.why or "")
else
	tap.skip("an address past the end of a function is not",
		"no padding after a function")
end
f:close()

tap.done()
