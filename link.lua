-- Assemble and link, with this compiler's own assembler and linker.
--
--   lua5.4 link.lua [-t riscv64] -o prog file.s ...

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local as = require "as"
local ld = require "ld"
local elf = require "elf"
local obj = require "obj"
local so = require "so"

-- Where a program goes, for a machine that is not Linux.  qemu's `sim`
-- machine gives the core eight megabytes at 0xfe000000, and looks for the
-- window handlers at the vector base.
local PRESET = {
	xtensa = {
		arch = "xtensa", base = 0xfe000000, detached = true,
		place = {[".window"] = 0x2000},
		symbols = {_stack_top = 0xfe7fffc0},
	},
}

local target, out, files = "riscv64", "a.out", {}
local shared, soname = false, nil
local i = 1
while i <= #arg do
	local a = arg[i]
	if a == "-t" then i = i + 1; target = arg[i]
	elseif a == "-o" then i = i + 1; out = arg[i]
	elseif a == "-shared" then shared = true
	elseif a == "-soname" then i = i + 1; soname = arg[i]
	else files[#files + 1] = a end
	i = i + 1
end

local ARCH = {riscv64 = "riscv", riscv32 = "riscv"}
local preset = PRESET[target] or {}
local opt = {
	arch = preset.arch or ARCH[target] or target,
	xlen = target == "riscv32" and 32 or 64,
}
-- Each file becomes an object beside the output, so that the link reads
-- them back one at a time rather than keeping them all.
local objs = {}
for i, path in ipairs(files) do
	local f = assert(io.open(path))
	local text = f:read("a")
	f:close()
	local ok, u = pcall(as.assemble, text, opt)
	if not ok then
		io.stderr:write(path .. ": " .. tostring(u) .. "\n")
		os.exit(1)
	end
	local name = out .. "." .. i .. ".o"
	local o = assert(io.open(name, "wb"))
	if elf.can(target) then
		o:write(elf.relocatable(u, target))
	else
		o:write(obj.write(u, opt.arch))
	end
	o:close()
	objs[i] = name
end

local f = assert(io.open(out, "wb"))
local ok, err
if shared then
	ok, err = pcall(so.link, objs, f, {soname = soname or
		out:gsub(".*/", "")})
else
	ok, err = pcall(ld.linkfiles, objs, f, {
		target = target, base = preset.base, place = preset.place,
		symbols = preset.symbols, detached = preset.detached,
	})
end
f:close()
for _, name in ipairs(objs) do
	if not os.getenv("KEEPOBJ") then os.remove(name) end
end
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	os.exit(1)
end
