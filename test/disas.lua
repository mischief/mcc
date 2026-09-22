-- SPDX-License-Identifier: ISC
-- The disassembler against objdump, and against the assembler.
--
-- One check prints the code the way objdump does and compares the two
-- line for line.  The other assembles what came out and compares the
-- bytes: a decoder and an encoder that disagree cannot both be right.
--
--	lua5.4 test/disas.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local elfread = require "elfread"
local dis = require "dis"
local as = require "as"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-disas"

tap.scratch(dir)

local function run(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	local out = p:read("a") or ""

	p:close()
	return out
end

if run("command -v objdump"):match("%S") == nil then
	tap.skipall("no objdump to compare against")
end

-- The corpus: this compiler's own output for its own test programs,
-- assembled by its own assembler, so the bytes under test are the ones
-- it writes.
local objs, sources = {}, {}
local p = io.popen("ls " .. here .. "/c/*.c 2>/dev/null")

for l in p:lines() do sources[#sources + 1] = l end
p:close()
if #sources == 0 then tap.skipall("no test programs to compile") end

local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

for _, f in ipairs(sources) do
	local b = f:match("([^/]+)%.c$")
	local out = dir .. "/" .. b .. ".o"
	local cmd = ("%s %s/../drive.lua -c -t amd64 %s %s -o %s")
		:format(lua, here, inc, f, out)

	if os.execute(cmd .. " 2>/dev/null") then
		objs[#objs + 1] = out
	end
end
if #objs == 0 then tap.skipall("nothing compiled") end

-- objdump, line for line ------------------------------------------------

for _, o in ipairs(objs) do
	local want = run("objdump -d " .. o)
	local got = run(("%s %s/../objdump.lua -d %s"):format(lua, here, o))
	local name = o:match("[^/]+$")

	if want == got then
		tap.ok(true, "mobjdump -d agrees with objdump on " .. name)
	else
		local wl, gl = {}, {}

		for l in want:gmatch("[^\n]*\n?") do wl[#wl + 1] = l end
		for l in got:gmatch("[^\n]*\n?") do gl[#gl + 1] = l end
		for i = 1, math.max(#wl, #gl) do
			if wl[i] ~= gl[i] then
				tap.diag(("line %d\nwant %s got  %s")
					:format(i, wl[i] or "(none)\n",
						gl[i] or "(none)\n"))
				break
			end
		end
		tap.ok(false, "mobjdump -d agrees with objdump on " .. name)
	end
end

-- there and back again ---------------------------------------------------

-- The disassembly of a section as something the assembler will take:
-- every instruction on a line, with a label wherever a branch lands so
-- that the distances come out the same.
local function source(m, bytes, marks)
	local out = {"\t.text"}
	local at = {}

	for off, ins in dis.each(m, bytes, 0, 0, #bytes) do
		at[#at + 1] = {off = off, ins = ins}
		if ins.target then marks[ins.target] = true end
	end
	for _, e in ipairs(at) do
		if marks[e.off] then
			out[#out + 1] = ("L%d:"):format(e.off)
		end
		local text = e.ins.text

		if e.ins.target and not e.ins.indirect then
			-- The distance has to be measured the same way,
			-- and only a label does that.
			text = ("%s %s"):format(e.ins.mnem,
				("L%d"):format(e.ins.target))
		end
		out[#out + 1] = "\t" .. text
	end
	return table.concat(out, "\n") .. "\n", at
end

local function roundtrip(o)
	local f = assert(elfread.open(o))
	local sec = f:find(".text")

	if not sec or sec.size == 0 then
		f:close()
		return nil
	end
	local bytes = f:contents(sec)
	local m = assert(dis.arch(f.arch))
	local marks = {}
	local src = source(m, bytes, marks)

	f:close()
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not ok then return false, tostring(a), src end
	local again = a.sec[".text"] and a.sec[".text"].bytes or ""

	if again == bytes then return true end
	for i = 1, math.min(#again, #bytes) do
		if again:sub(i, i) ~= bytes:sub(i, i) then
			return false, ("byte %d of %d differs: %02x not %02x")
				:format(i, #bytes, again:byte(i),
					bytes:byte(i)), src
		end
	end
	return false, ("%d bytes came back, not %d"):format(#again, #bytes),
		src
end

for _, o in ipairs(objs) do
	local name = o:match("[^/]+$")
	local ok, why, src = roundtrip(o)

	if ok == nil then
		tap.skip("round trip through " .. name, "no code")
	else
		if not ok then
			tap.diag(why)
			local w = io.open(dir .. "/" .. name .. ".s", "w")

			if w then
				w:write(src or "")
				w:close()
				tap.diag("wrote " .. dir .. "/" .. name .. ".s")
			end
		end
		tap.ok(ok, "round trip through " .. name)
	end
end

-- the window a debugger asks for -----------------------------------------

-- An address that is where an instruction begins comes back in step,
-- with the instruction at the address marked.  One byte later does not,
-- and has to say so rather than print the wrong instructions quietly.
local f = assert(elfread.open(objs[1]))
local fn = nil

for _, s in ipairs(f:syms()) do
	if s.typ == "func" and s.sec and s.size > 16 then
		fn = s
		break
	end
end
if not fn then
	tap.skip("a window around an address", "no function to look at")
else
	local m = assert(dis.arch(f.arch))
	local bytes = f:contents(fn.sec)
	local wide = nil

	-- One that is more than a byte long, so that the address after
	-- its first byte is inside it and not the start of the next.
	for off, ins in dis.each(m, bytes, 0, fn.value,
	    fn.value + fn.size) do
		if ins.len > 1 then
			wide = off
			break
		end
	end
	local second = wide or fn.value
	local w = assert(dis.window(f, second, 4))

	tap.ok(w.sync, "a window at an instruction is in step")
	tap.ok(w.list[w.at] and w.list[w.at].addr == second,
		"the marked instruction is the one asked for")
	tap.ok(w.loc.name == fn.name, "and it belongs to " .. fn.name)
	local off = dis.window(f, second + 1, 4)

	tap.ok(off and not off.sync and not off.loc.sure,
		"a window inside an instruction says it is not in step")
end
f:close()

-- Where control may go next.  A return goes nowhere this can name, a
-- conditional branch goes two ways, and everything else falls through.
local fell, two, none = 0, 0, 0
local g = assert(elfread.open(objs[1]))
local gs = g:find(".text")
local gm = assert(dis.arch(g.arch))

for off, ins in dis.each(gm, g:contents(gs), 0, 0, gs.size) do
	local to, indirect = dis.follow(ins, off)

	if ins.kind == "ret" then
		none = none + (#to == 0 and 1 or 0)
	elseif ins.kind == "jcc" then
		two = two + ((#to == 2 and to[1] == off + ins.len and
			to[2] == ins.target) and 1 or 0)
	elseif not ins.kind and not indirect then
		fell = fell + ((#to == 1 and to[1] == off + ins.len) and
			1 or 0)
	end
end
g:close()
tap.ok(none > 0, "a return goes nowhere: " .. none)
tap.ok(two > 0, "a conditional branch goes two ways: " .. two)
tap.ok(fell > 0, "everything else falls through: " .. fell)

tap.done()
