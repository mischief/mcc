-- End to end with nothing but this compiler: compile, assemble and link a
-- program with our own tools, and run it against the same program built by
-- the system toolchain.
--
--   lua5.4 test/self.lua [riscv64]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local root = here .. "/.."
local target = arg[1] or "riscv64"
-- one directory per run, because the harness runs these side by side
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-self-" .. target ..
	(arg[2] and ("-" .. arg[2]) or "")
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

-- The Xtensa build is bare metal: qemu's `sim` machine, our own reset code
-- for the build this compiler makes and the one in test/xtensa for gcc's.
local function xcc()
	local p = io.popen("ls -d " .. os.getenv("HOME") ..
		"/.espressif/tools/xtensa-esp*-elf/*/xtensa-esp*-elf/bin/" ..
		"xtensa-esp32-elf-gcc 2>/dev/null")
	local path = p:read("l")
	p:close()
	return path
end

local RUN = {
	amd64 = "",
	riscv64 = "qemu-riscv64 ",
	xtensa = "timeout 180 qemu-system-xtensa -M sim -cpu dc233c" ..
		 " -nographic -monitor none -semihosting -kernel ",
}
local REF = {amd64 = "gcc -static -no-pie -w -O0",
	     riscv64 = "riscv64-linux-gnu-gcc -static -w -O0"}
if target == "xtensa" then
	local g = xcc()
	REF.xtensa = g and (g .. " -w -nostartfiles -mlongcalls" ..
		" -mtext-section-literals -T " .. here .. "/xtensa/ld.script " ..
		here .. "/xtensa/crt.S " .. here .. "/xtensa/sys.c")
end
local run, ref = RUN[target], REF[target]
if not run or not ref then
	tap.skipall("no toolchain for " .. target)
end

local RT = "rt/miniio.c rt/varargs.c rt/ministr.c rt/softfp.c rt/wide.c " ..
	   "rt/widefp.c"
local INC = "-Iinclude -Iinclude/freestanding"

local function shell(cmd)
	local p = io.popen("cd " .. root .. " && " .. cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

-- `init` is left out on Xtensa: the reference build reaches newlib's printf
-- through the simulator one write at a time, and does not finish.
local tests = {"prog", "types", "lang", "va", "init"}
if target == "xtensa" then tests = {"prog", "types", "lang", "va"} end
-- one name runs that one, so that the harness can run them side by side
if arg[2] then tests = {arg[2]} end
local ok = 0
for _, t in ipairs(tests) do
	local main = t == "prog" and "main" or (t .. "main")
	local src = ("test/c/%s.c test/c/%s.c"):format(t, main)
	local good, out = shell(("./cclink -t %s %s %s %s -o %s/%s")
		:format(target, INC, src, RT, dir, t))
	if not good then
		tap.ok(false, t .. " builds")
		tap.diag((out:gsub("\n.*", "")))
	else
		-- the reference build gets only the header that declares
		-- printf: our stdarg.h is for this compiler, not for gcc
		shell(("%s -Iinclude/freestanding -o %s/%s.ref %s")
			:format(ref, dir, t, src))
		local _, mine = shell(run .. dir .. "/" .. t)
		local _, want = shell(run .. dir .. "/" .. t .. ".ref")
		if tap.ok(mine == want, t .. " answers as gcc's does") then
			ok = ok + 1
		else
			local a, b = {}, {}
			for l in mine:gmatch("[^\n]*") do a[#a + 1] = l end
			for l in want:gmatch("[^\n]*") do b[#b + 1] = l end
			for i = 1, math.max(#a, #b) do
				if a[i] ~= b[i] then
					tap.diag(("line %d\n  mine %s\n  gcc  %s")
						:format(i, tostring(a[i]),
							tostring(b[i])))
					break
				end
			end
		end
	end
end
tap.done()
