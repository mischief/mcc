-- Differential test: compile test/c/prog.c with this compiler and with the
-- system one, run both against the same driver, and compare the output.
--
--   lua5.4 test/cc.lua [amd64|riscv64]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local which = arg[1] or "amd64"

local TOOL = {
	amd64   = {cc = "gcc", run = ""},
	riscv64 = {cc = "riscv64-linux-gnu-gcc -static", run = "qemu-riscv64 "},
}
local tool = assert(TOOL[which], "no toolchain for " .. which)

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-cc-" .. which ..
	"-" .. (arg[2] or "prog")
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

local function fail(what, out)
	io.write("FAIL " .. which .. " " .. what .. "\n" .. (out or "") .. "\n")
	os.exit(1)
end

local which_src = arg[2] or "prog"
local src = here .. "/c/" .. which_src .. ".c"
local main = here .. "/c/" ..
	(which_src == "prog" and "main" or (which_src .. "main")) .. ".c"

local ok, out = shell(("lua5.4 %s/../cc.lua -t %s -I%s/../include %s -o %s/prog.s")
	:format(here, which, here, src, dir))
if not ok then fail("compile", out) end

local rt = here .. "/../rt/softfp.c " .. here .. "/../rt/varargs.c -lm"
ok, out = shell(("%s -w -o %s/mine %s %s/prog.s %s")
	:format(tool.cc, dir, main, dir, rt))
if not ok then fail("assemble/link", out) end

ok, out = shell(("%s -O0 -w -o %s/ref %s %s -lm"):format(tool.cc, dir, main, src))
if not ok then fail("reference build", out) end

local _, mine = shell(tool.run .. dir .. "/mine")
local _, ref  = shell(tool.run .. dir .. "/ref")

if mine ~= ref then
	local a, b = {}, {}
	for l in mine:gmatch("[^\n]*") do a[#a + 1] = l end
	for l in ref:gmatch("[^\n]*") do b[#b + 1] = l end
	io.write("FAIL " .. which .. " output differs\n")
	for i = 1, math.max(#a, #b) do
		if a[i] ~= b[i] then
			io.write(("  line %d\n    mine %s\n    gcc  %s\n")
				:format(i, tostring(a[i]), tostring(b[i])))
		end
	end
	os.exit(1)
end

local n = select(2, mine:gsub("\n", ""))
print(("ok   %s/%s matches gcc on %d lines"):format(which, which_src, n))
