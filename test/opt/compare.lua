-- SPDX-License-Identifier: ISC
-- The corpus through every C compiler on the machine, one column each.
--
--   lua5.4 test/opt/compare.lua [--target=boot|m32|amd64] [--jobs N]
--                               [--root DIR] [--out DIR] [--top N]

-- Sizes are code and initialized data summed from the object's
-- sections, as run.lua counts them.  The totals are over the cells
-- every column built, so the columns compare the same work.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local gen = require "mcc.gen"

local o = {target = "boot", jobs = 16, top = 15, root = here .. "/../.."}
local i = 1

while i <= #arg do
	local a = arg[i]

	if a:match("^%-%-target=") then o.target = a:match("=(.*)$")
	elseif a == "--jobs" then i = i + 1; o.jobs = tonumber(arg[i])
	elseif a == "--top" then i = i + 1; o.top = tonumber(arg[i])
	elseif a == "--root" then i = i + 1; o.root = arg[i]
	elseif a == "--out" then i = i + 1; o.out = arg[i]
	else
		io.stderr:write("unknown argument ", a, "\n")
		os.exit(2)
	end
	i = i + 1
end

local lua = os.getenv("LUA") or "lua5.4"
local drive = o.root .. "/drive.lua"
local dir = (o.out or o.root .. "/build/opt") .. "/cmp-" .. o.target

local COMMON = "-Os -fno-pic -fno-stack-protector " ..
	"-fno-asynchronous-unwind-tables -fcf-protection=none -std=gnu11 " ..
	"-fno-strict-aliasing -fomit-frame-pointer"
local ARCH = {
	boot = "-m16 -march=i386 -mregparm=3 -mno-mmx -mno-sse -ffreestanding ",
	m32 = "-m32 -march=i386 -mno-mmx -mno-sse -ffreestanding ",
	amd64 = "-m64 -ffreestanding ",
}
local arch = ARCH[o.target] or error("no target " .. o.target)

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

-- Each compiler's command for one cell, or nil where it cannot build
-- this target at all.
local CC = {
	{name = "gcc", cmd = function(src, obj)
		return ("gcc -c %s%s -o %s %s"):format(arch, COMMON, obj, src)
	end},
	{name = "clang", cmd = function(src, obj)
		local a = arch .. (o.target == "boot" and
			"-mstack-alignment=4 " or "")

		return ("clang -c %s%s -o %s %s"):format(a, COMMON, obj, src)
	end},
	{name = "cproc", only = "amd64", cmd = function(src, obj)
		return ("cproc -c -o %s %s"):format(obj, src)
	end},
	{name = "tcc", only = "amd64", cmd = function(src, obj)
		return ("tcc -c -o %s %s"):format(obj, src)
	end},
	{name = "mcc", cmd = function(src, obj)
		local a = arch .. (o.target == "boot" and
			"-mpreferred-stack-boundary=2 " or "")

		return ("%s %s -c %s%s -o %s %s"):format(lua, drive, a, COMMON,
							  obj, src)
	end},
}

local ccs = {}
for _, c in ipairs(CC) do
	if (not c.only or c.only == o.target) and
	   (c.name == "mcc" or has(c.name)) then
		ccs[#ccs + 1] = c
	end
end

local cells = {}
for _, c in ipairs(gen.cells()) do
	if not (c.i386 and o.target == "amd64") then cells[#cells + 1] = c end
end
gen.write(dir, cells)

os.execute(("rm -rf %s/obj %s/fail %s/log; mkdir -p %s/obj %s/fail %s/log")
	:format(dir, dir, dir, dir, dir, dir))
for _, c in ipairs(ccs) do os.execute("mkdir -p " .. dir .. "/obj/" .. c.name) end

local cmds = assert(io.open(dir .. "/cmds", "w"))
for _, c in ipairs(cells) do
	local src = dir .. "/src/" .. c.name .. ".c"

	for _, cc in ipairs(ccs) do
		local obj = ("%s/obj/%s/%s.o"):format(dir, cc.name, c.name)

		cmds:write(("timeout 60 %s 2>%s/log/%s.%s || touch %s/fail/%s.%s\n")
			:format(cc.cmd(src, obj), dir, c.name, cc.name, dir,
				c.name, cc.name))
	end
end
cmds:close()
io.stdout:flush()
os.execute(("tr '\\n' '\\0' < %s/cmds | xargs -0 -P %d -n 1 sh -c"):format(dir, o.jobs))

local function sizes(sub)
	local out = {}
	local p = io.popen(("readelf -S -W %s/obj/%s/*.o 2>/dev/null"):format(dir, sub))
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

local sz = {}
for _, cc in ipairs(ccs) do
	sz[cc.name] = sizes(cc.name)
	for _, c in ipairs(cells) do
		if io.open(("%s/fail/%s.%s"):format(dir, c.name, cc.name)) then
			sz[cc.name][c.name] = nil
		end
	end
end

-- The cells every compiler built.
local common, unbuilt = {}, {}
for _, c in ipairs(cells) do
	local ok = true

	for _, cc in ipairs(ccs) do
		if not sz[cc.name][c.name] then
			ok = false
			unbuilt[cc.name] = (unbuilt[cc.name] or 0) + 1
		end
	end
	if ok then common[#common + 1] = c end
end

local fam, order = {}, {}
for _, c in ipairs(common) do
	if not fam[c.family] then
		fam[c.family] = {n = 0}
		order[#order + 1] = c.family
	end
	local f = fam[c.family]

	f.n = f.n + 1
	for _, cc in ipairs(ccs) do
		f[cc.name] = (f[cc.name] or 0) + sz[cc.name][c.name]
	end
end
table.sort(order, function(a, b) return fam[a].mcc - fam[a].gcc > fam[b].mcc - fam[b].gcc end)

io.write(("target %s: %d of %d cells built by every compiler\n"):format(
	o.target, #common, #cells))
for _, cc in ipairs(ccs) do
	if unbuilt[cc.name] then
		io.write(("  %s could not build %d\n"):format(cc.name, unbuilt[cc.name]))
	end
end
io.write("\nfamily     cells")
for _, cc in ipairs(ccs) do io.write(("%8s"):format(cc.name)) end
io.write("   mcc/gcc\n")
local tot = {}
for _, k in ipairs(order) do
	local f = fam[k]

	io.write(("%-10s %5d"):format(k, f.n))
	for _, cc in ipairs(ccs) do
		io.write(("%8d"):format(f[cc.name]))
		tot[cc.name] = (tot[cc.name] or 0) + f[cc.name]
	end
	io.write(("   %.2f\n"):format(f.mcc / f.gcc))
end
io.write(("%-10s %5d"):format("total", #common))
for _, cc in ipairs(ccs) do io.write(("%8d"):format(tot[cc.name] or 0)) end
io.write(("   %.2f\n"):format((tot.mcc or 0) / (tot.gcc or 1)))
if #common == 0 then return end

-- Where mcc stands against each of the others, cell by cell.
io.write("\nmcc against each, over the common cells:\n")
for _, cc in ipairs(ccs) do
	if cc.name ~= "mcc" then
		local win, tie, lose, wb, lb = 0, 0, 0, 0, 0

		for _, c in ipairs(common) do
			local m, x = sz.mcc[c.name], sz[cc.name][c.name]

			if m < x then win, wb = win + 1, wb + (x - m)
			elseif m == x then tie = tie + 1
			else lose, lb = lose + 1, lb + (m - x) end
		end
		io.write(("  vs %-6s smaller in %3d cells (%5d bytes), equal %3d, larger in %3d (%6d bytes)\n")
			:format(cc.name, win, wb, tie, lose, lb))
	end
end

-- The cells where mcc beats the best of the rest, and where it trails
-- the best of the rest by most.
local rows = {}
for _, c in ipairs(common) do
	local best, who = math.huge, nil

	for _, cc in ipairs(ccs) do
		if cc.name ~= "mcc" and sz[cc.name][c.name] < best then
			best, who = sz[cc.name][c.name], cc.name
		end
	end
	rows[#rows + 1] = {name = c.name, mcc = sz.mcc[c.name], best = best,
			   who = who}
end
table.sort(rows, function(a, b) return a.mcc - a.best < b.mcc - b.best end)
io.write("\nmcc smaller than every other compiler:\n")
local any = false
for _, r in ipairs(rows) do
	if r.mcc < r.best then
		any = true
		io.write(("  %-28s mcc %4d  best other %4d (%s)\n"):format(
			r.name, r.mcc, r.best, r.who))
	end
end
if not any then io.write("  none\n") end
io.write(("\nfurthest behind the best other compiler (top %d):\n"):format(o.top))
for k = #rows, math.max(1, #rows - o.top + 1), -1 do
	local r = rows[k]

	io.write(("  %-28s mcc %4d  best other %4d (%s)  +%d\n"):format(
		r.name, r.mcc, r.best, r.who, r.mcc - r.best))
end
