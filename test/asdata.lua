-- The data directives against gas, a case at a time.
--
-- The instruction tests compare .text only, so a directive that lays
-- down bytes needs its own comparison.
--
--   lua5.4 test/asdata.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local as = require "as"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-asdata"

os.execute("mkdir -p " .. dir)

local function slurp(path, mode)
	local f = io.open(path, mode or "r")
	if not f then return nil end
	local s = f:read("a")

	f:close()
	return s
end

-- Each case is one line of data in .text, so that one objcopy reaches it.
local CASES = {
	{"a quote in a string", [[	.ascii	"a\"b"]]},
	{"a hash in a string", [[	.ascii	"a#b"]]},
	{"a quote before a hash", [[	.ascii	"!\"#$%&'()*+,-"]]},
	{"an apostrophe in a string", [[	.ascii	"it's"]]},
	{"a semicolon in a string", [[	.ascii	"a;b"]]},
	{"a slash star in a string", [[	.ascii	"a/*b"]]},
	{"the named escapes", [[	.ascii	"a\tb\nc\rd\be\ff\vg\\h"]]},
	{"an octal escape", [[	.ascii	"a\101\0\377b"]]},
	{"a terminated string", [[	.asciz	"a\"b#c"]]},
	{"bytes", [[	.byte	1, -1, 255, 0]]},
	{"shorts", [[	.short	1, -1, 65535]]},
	{"longs", [[	.long	1, -1, 305419896]]},
	{"quads", [[	.quad	1, -1, 1234605616436508552]]},
	{"a run of zeros", [[	.zero	7]]},
	{"a hidden name", "\t.globl\tv\n\t.hidden\tv\nv:\n\t.byte\t1"},
	{"a weak name", "\t.weak\tx\nx:\n\t.byte\t1"},
	{"a protected name",
	 "\t.globl\tw\n\t.protected\tw\nw:\n\t.byte\t1"},
	-- gas pads an executable section with nops unless the fill byte
	-- is spelled out; this assembler always pads with zero.
	{"alignment after a byte",
	 "\t.byte\t1\n\t.balign\t8,0\n\t.byte\t2"},
}

local function build(body)
	local src = "\t.text\n" .. body .. "\n"
	local f = assert(io.open(dir .. "/d.s", "w"))

	f:write(src)
	f:close()
	if os.execute(("as --64 -o %s/d.o %s/d.s 2>%s/err")
	    :format(dir, dir, dir)) ~= true then
		return nil, (slurp(dir .. "/err") or ""):gsub("\n.*", "")
	end
	os.execute(("objcopy -O binary --only-section=.text " ..
		"%s/d.o %s/d.bin"):format(dir, dir))
	local want = slurp(dir .. "/d.bin", "rb") or ""
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not ok then return nil, tostring(a) end
	return a.sec[".text"].bytes, want
end

local function hex(s)
	return (s:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

for _, c in ipairs(CASES) do
	local got, want = build(c[2])

	if got == nil then
		tap.ok(false, c[1])
		tap.diag(want)
	elseif not tap.ok(got == want, c[1]) then
		tap.diag("ours: " .. hex(got))
		tap.diag("gas:  " .. hex(want))
	end
end
tap.done()
