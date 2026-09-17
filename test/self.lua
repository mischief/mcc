-- End to end with nothing but this compiler: compile, assemble and link a
-- program with our own tools, and run it against the same program built by
-- the system toolchain.
--
--   lua5.4 test/self.lua [riscv64]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/.."
local target = arg[1] or "riscv64"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-self-" .. target
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local RUN = {riscv64 = "qemu-riscv64 "}
local REF = {riscv64 = "riscv64-linux-gnu-gcc -static -w -O0"}
local run, ref = RUN[target], REF[target]
if not run or not ref then
	print("skip self: no toolchain for " .. target)
	os.exit(0)
end

local RT = "rt/miniio.c rt/varargs.c rt/ministr.c"
local INC = "-Iinclude -Iinclude/freestanding"

local function shell(cmd)
	local p = io.popen("cd " .. root .. " && " .. cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

-- No floating point here: rt/softfp.c is written in C doubles, so this
-- compiler lowers its own multiply into a call to itself.  A soft float
-- runtime written in integers would fix that, and is what a freestanding
-- build needs anyway.
local tests = {"prog", "types", "lang"}
local ok = 0
for _, t in ipairs(tests) do
	local main = t == "prog" and "main" or (t .. "main")
	local src = ("test/c/%s.c test/c/%s.c"):format(t, main)
	local good, out = shell(("./cclink -t %s %s %s %s -o %s/%s")
		:format(target, INC, src, RT, dir, t))
	if not good then
		print(("FAIL self/%s: %s"):format(t, (out:gsub("\n.*", ""))))
	else
		-- the reference build gets only the header that declares
		-- printf: our stdarg.h is for this compiler, not for gcc
		shell(("%s -Iinclude/freestanding -o %s/%s.ref %s")
			:format(ref, dir, t, src))
		local _, mine = shell(run .. dir .. "/" .. t)
		local _, want = shell(run .. dir .. "/" .. t .. ".ref")
		if mine == want then
			ok = ok + 1
		else
			print("FAIL self/" .. t .. " output differs")
			local a, b = {}, {}
			for l in mine:gmatch("[^\n]*") do a[#a + 1] = l end
			for l in want:gmatch("[^\n]*") do b[#b + 1] = l end
			for i = 1, math.max(#a, #b) do
				if a[i] ~= b[i] then
					print(("  line %d\n    mine %s\n    gcc  %s")
						:format(i, tostring(a[i]),
							tostring(b[i])))
					break
				end
			end
		end
	end
end
if ok == #tests then
	print(("ok   %s built by this compiler alone answers as gcc's does" ..
	       " (%d programs)"):format(target, ok))
else
	os.exit(1)
end
