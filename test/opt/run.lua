-- SPDX-License-Identifier: ISC
-- Build the optimizer corpus with gcc and with mcc, and say where the
-- bytes differ.  One cell is one function in one file, so the size of
-- its object is the size of that function.
--
--   lua5.4 test/opt/run.lua [--target=boot|m32|amd64] [--jobs N]
--                           [--top N] [--family F] [--save] [--no-ratchet]
--                           [--asm CELL] [--run] [--out DIR]
--
-- boot is the flag set a kernel's real mode setup is built with, which
-- is the target that matters; m32 and amd64 say which costs are the
-- machine's and which are the compiler's.
--
-- `--save` writes test/opt/baseline-<target>.tsv.  A later run compares
-- against it and fails when any cell grew, so a change that buys bytes
-- in one place and spends them in another is seen.
--
-- `--asm CELL` prints gcc's and mcc's assembly for one cell, which is
-- the loop: look, change the compiler, run again.
--
-- `--run` builds every cell that can run on the host into one program
-- twice, once with each compiler, runs both under a timeout and
-- compares what they print.  Only m32 and amd64 can.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../../?.lua;" .. package.path
local gen = require "gen"

local root = here .. "/../.."
local lua = os.getenv("LUA") or "lua5.4"
local drive = root .. "/drive.lua"

local o = {target = "boot", jobs = 16, top = 30, out = root .. "/build/opt"}
local i = 1

while i <= #arg do
	local a = arg[i]

	if a:match("^%-%-target=") then o.target = a:match("=(.*)$")
	elseif a == "--jobs" then i = i + 1; o.jobs = tonumber(arg[i])
	elseif a == "--top" then i = i + 1; o.top = tonumber(arg[i])
	elseif a == "--family" then i = i + 1; o.family = arg[i]
	elseif a == "--out" then i = i + 1; o.out = arg[i]
	elseif a == "--asm" then i = i + 1; o.asm = arg[i]
	elseif a == "--save" then o.save = true
	elseif a == "--no-ratchet" then o.noratchet = true
	elseif a == "--run" then o.run = true
	elseif a == "--verbose" or a == "-v" then o.verbose = true
	else
		io.stderr:write("unknown argument ", a, "\n")
		os.exit(2)
	end
	i = i + 1
end

local COMMON = "-Os -fno-pic -fno-stack-protector " ..
	"-fno-asynchronous-unwind-tables -fcf-protection=none -std=gnu11 " ..
	"-fno-strict-aliasing -fomit-frame-pointer"

local FLAGS = {
	boot = "-m16 -march=i386 -mregparm=3 -mpreferred-stack-boundary=2 " ..
	       "-mno-mmx -mno-sse -ffreestanding " .. COMMON,
	m32 = "-m32 -march=i386 -mno-mmx -mno-sse -ffreestanding " .. COMMON,
	amd64 = "-m64 -ffreestanding " .. COMMON,
}

local flags = FLAGS[o.target] or error("no target " .. o.target)
local dir = o.out .. "/" .. o.target

local function sh(cmd)
	if o.verbose then io.stderr:write(cmd, "\n") end
	-- What was written so far goes out before the child writes.
	io.stdout:flush()
	return os.execute(cmd)
end

local function readall(path)
	local f = io.open(path)

	if not f then return nil end
	local s = f:read("a")

	f:close()
	return s
end

-- The cells, written fresh every run: the generator is the source.
local cells = gen.write(dir)

if o.family then
	local keep = {}

	for _, c in ipairs(cells) do
		if c.family == o.family or c.name == o.family then
			keep[#keep + 1] = c
		end
	end
	cells = keep
end

-- One cell, both compilers, both assemblies side by side.
if o.asm then
	local c

	for _, x in ipairs(cells) do
		if x.name == o.asm then c = x end
	end
	if not c then error("no cell " .. o.asm) end
	local src = dir .. "/src/" .. c.name .. ".c"

	sh(("gcc -S %s -o %s/%s.gcc.s %s"):format(flags, dir, c.name, src))
	sh(("%s %s -S %s -o %s/%s.mcc.s %s"):format(lua, drive, flags, dir,
						     c.name, src))
	io.write("=== gcc ===\n")
	for line in io.lines(dir .. "/" .. c.name .. ".gcc.s") do
		if not line:match("^%s*%.") and not line:match("^%.L") or
		   line:match("^%.L%d+:") then
			io.write(line, "\n")
		end
	end
	io.write("=== mcc ===\n")
	for line in io.lines(dir .. "/" .. c.name .. ".mcc.s") do
		if not line:match("^%s*%.") or line:match("^%.L%d+:") then
			io.write(line, "\n")
		end
	end
	return
end

-- Every compile, in parallel.  A failure leaves a file behind rather
-- than stopping the rest: a cell mcc cannot build is a finding too.
sh(("rm -rf %s/gcc %s/mcc %s/fail %s/log && mkdir -p %s/gcc %s/mcc %s/fail %s/log")
	:format(dir, dir, dir, dir, dir, dir, dir, dir))

local cmds = assert(io.open(dir .. "/cmds", "w"))

for _, c in ipairs(cells) do
	local src = dir .. "/src/" .. c.name .. ".c"

	cmds:write(("timeout 60 gcc -c %s -o %s/gcc/%s.o %s 2>%s/log/%s.gcc || touch %s/fail/%s.gcc\n")
		:format(flags, dir, c.name, src, dir, c.name, dir, c.name))
	cmds:write(("timeout 60 %s %s -c %s -o %s/mcc/%s.o %s 2>%s/log/%s.mcc || touch %s/fail/%s.mcc\n")
		:format(lua, drive, flags, dir, c.name, src, dir, c.name,
			dir, c.name))
end
cmds:close()
sh(("tr '\\n' '\\0' < %s/cmds | xargs -0 -P %d -n 1 sh -c"):format(dir, o.jobs))

-- Code and initialized data, which is what a link script has to place.
-- Summed by section name rather than read off `size`, because gcc
-- writes a .note.gnu.property that `size` counts as text and no image
-- carries.
local function sizes(sub)
	local out = {}
	local p = io.popen(("readelf -S -W %s/%s/*.o 2>/dev/null"):format(dir, sub))
	local cur

	for line in p:lines() do
		local file = line:match("^File: .*/([^/]+)%.o$")

		if file then
			cur = file
			out[cur] = 0
		else
			local name, size = line:match("^%s*%[%s*%d+%]%s+(%S+)%s+%S+%s+%x+%s+%x+%s+(%x+)")

			if cur and name and (name:match("^%.text") or
					     name:match("^%.rodata") or
					     name:match("^%.data")) then
				out[cur] = out[cur] + tonumber(size, 16)
			end
		end
	end
	p:close()
	return out
end

local gs, ms = sizes("gcc"), sizes("mcc")

local function failed(name, cc)
	return io.open(("%s/fail/%s.%s"):format(dir, name, cc)) ~= nil
end

-- The baseline this run is measured against.
local basefile = ("%s/baseline-%s.tsv"):format(here, o.target)
local base = {}

for line in (readall(basefile) or ""):gmatch("[^\n]+") do
	local name, g, m = line:match("^(%S+)\t%S+\t(%S+)\t(%S+)")

	if name and name ~= "cell" then
		base[name] = {gcc = tonumber(g), mcc = tonumber(m)}
	end
end

local rows = {}
local fam = {}
local tg, tm, nfail = 0, 0, 0

for _, c in ipairs(cells) do
	local g, m = gs[c.name], ms[c.name]
	local r = {name = c.name, family = c.family, gcc = g, mcc = m}

	if failed(c.name, "gcc") then r.gcc = nil end
	if failed(c.name, "mcc") then r.mcc = nil end
	rows[#rows + 1] = r
	if r.gcc and r.mcc then
		tg, tm = tg + r.gcc, tm + r.mcc
		local f = fam[c.family] or {n = 0, gcc = 0, mcc = 0}

		f.n, f.gcc, f.mcc = f.n + 1, f.gcc + r.gcc, f.mcc + r.mcc
		fam[c.family] = f
	else
		nfail = nfail + 1
	end
end

-- The table every run writes, and the one --save keeps.
local function writetsv(path)
	local f = assert(io.open(path, "w"))

	f:write("cell\tfamily\tgcc\tmcc\tdelta\n")
	for _, r in ipairs(rows) do
		f:write(("%s\t%s\t%s\t%s\t%s\n"):format(r.name, r.family,
			r.gcc or "FAIL", r.mcc or "FAIL",
			(r.gcc and r.mcc) and (r.mcc - r.gcc) or "-"))
	end
	f:close()
end

writetsv(dir .. "/sizes.tsv")

io.write(("target %s: %d cells, gcc %d bytes, mcc %d bytes, %.2fx, %d unbuilt\n")
	:format(o.target, #rows, tg, tm, tg > 0 and tm / tg or 0, nfail))

local fams = {}
for k in pairs(fam) do fams[#fams + 1] = k end
table.sort(fams, function(a, b) return fam[a].mcc - fam[a].gcc > fam[b].mcc - fam[b].gcc end)
io.write("\nfamily      cells    gcc    mcc  delta  ratio\n")
for _, k in ipairs(fams) do
	local f = fam[k]

	io.write(("%-10s %6d %6d %6d %6d  %.2f\n"):format(k, f.n, f.gcc, f.mcc,
		f.mcc - f.gcc, f.mcc / f.gcc))
end

local sorted = {}
for _, r in ipairs(rows) do
	if r.gcc and r.mcc then sorted[#sorted + 1] = r end
end
table.sort(sorted, function(a, b)
	local da, db = a.mcc - a.gcc, b.mcc - b.gcc

	if da ~= db then return da > db end
	return a.name < b.name
end)
io.write(("\ntop %d cells by delta\n"):format(o.top))
for k = 1, math.min(o.top, #sorted) do
	local r = sorted[k]

	io.write(("%-28s gcc %4d  mcc %4d  +%-4d %.1fx\n"):format(r.name, r.gcc,
		r.mcc, r.mcc - r.gcc, r.mcc / r.gcc))
end

local unbuilt = {}
for _, r in ipairs(rows) do
	if not r.mcc then unbuilt[#unbuilt + 1] = r.name .. " (mcc)" end
	if not r.gcc then unbuilt[#unbuilt + 1] = r.name .. " (gcc)" end
end
if #unbuilt > 0 then
	io.write("\nunbuilt: ", table.concat(unbuilt, ", "), "\n")
	io.write("  first error lines:\n")
	for _, r in ipairs(rows) do
		if not r.mcc then
			local e = readall(("%s/log/%s.mcc"):format(dir, r.name)) or ""

			io.write("  ", r.name, ": ", e:match("[^\n]*") or "", "\n")
		end
	end
end

-- Against the baseline: every cell that moved, and the sum.
local worse = 0

if next(base) then
	local moved = {}
	local btot, ntot = 0, 0

	for _, r in ipairs(rows) do
		local b = base[r.name]

		if b and b.mcc and r.mcc then
			btot, ntot = btot + b.mcc, ntot + r.mcc
			if r.mcc ~= b.mcc then
				moved[#moved + 1] = r
				r.was = b.mcc
				if r.mcc > b.mcc then worse = worse + 1 end
			end
		end
	end
	table.sort(moved, function(a, b)
		return (a.mcc - a.was) < (b.mcc - b.was)
	end)
	io.write(("\nagainst baseline: mcc %d -> %d (%+d), %d cells moved, %d grew\n")
		:format(btot, ntot, ntot - btot, #moved, worse))
	for _, r in ipairs(moved) do
		io.write(("  %-28s %4d -> %4d  %+d\n"):format(r.name, r.was, r.mcc,
			r.mcc - r.was))
	end
end

if o.save then
	writetsv(basefile)
	io.write("\nsaved ", basefile, "\n")
end

-- The program made of every cell that can run, built twice and run.
if o.run then
	if o.target == "boot" then
		io.write("\n--run: boot code cannot run on the host; use m32 or amd64\n")
		os.exit(1)
	end
	local runflags = flags:gsub("%-ffreestanding", "")
	local objs = {}

	for _, c in ipairs(cells) do
		if not c.norun and ms[c.name] and gs[c.name] then
			objs[#objs + 1] = c.name
		end
	end
	local function link(cc)
		local list = {}

		for _, n in ipairs(objs) do
			list[#list + 1] = ("%s/%s/%s.o"):format(dir, cc, n)
		end
		local m = o.target == "m32" and "-m32" or "-m64"

		return sh(("gcc %s -no-pie -o %s/prog.%s %s/src/driver.c %s 2>%s/log/link.%s")
			:format(m, dir, cc, dir, table.concat(list, " "),
				dir, cc))
	end
	local ok = true

	for _, cc in ipairs{"gcc", "mcc"} do
		if not link(cc) then
			io.write("\n--run: link failed for ", cc, ", see ",
				 dir, "/log/link.", cc, "\n")
			ok = false
		end
	end
	if ok then
		for _, cc in ipairs{"gcc", "mcc"} do
			sh(("timeout 20 %s/prog.%s > %s/out.%s 2>&1; echo \"exit $?\" >> %s/out.%s")
				:format(dir, cc, dir, cc, dir, cc))
		end
		local a, b = readall(dir .. "/out.gcc"), readall(dir .. "/out.mcc")

		if a == b then
			io.write(("\n--run: %d cells, both programs agree\n"):format(#objs))
		else
			io.write("\n--run: OUTPUT DIFFERS\n")
			sh(("diff %s/out.gcc %s/out.mcc | head -40"):format(dir, dir))
			ok = false
		end
	end
	if not ok then os.exit(1) end
end

if worse > 0 and not o.noratchet then
	io.write("\nratchet: cells grew against the baseline\n")
	os.exit(1)
end
