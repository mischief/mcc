-- Assemble and link, with this compiler's own assembler and linker.
--
--   lua5.4 link.lua [-t riscv64] -o prog file.s ...

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local as = require "as"
local ld = require "ld"

local target, out, files = "riscv64", "a.out", {}
local i = 1
while i <= #arg do
	local a = arg[i]
	if a == "-t" then i = i + 1; target = arg[i]
	elseif a == "-o" then i = i + 1; out = arg[i]
	else files[#files + 1] = a end
	i = i + 1
end

local xlen = target == "riscv32" and 32 or 64
local units = {}
for _, path in ipairs(files) do
	local f = assert(io.open(path))
	local text = f:read("a")
	f:close()
	local ok, u = pcall(as.assemble, text, xlen)
	if not ok then
		io.stderr:write(path .. ": " .. tostring(u) .. "\n")
		os.exit(1)
	end
	units[#units + 1] = u
end

local ok, img = pcall(ld.link, units, {target = target})
if not ok then
	io.stderr:write(tostring(img) .. "\n")
	os.exit(1)
end
local f = assert(io.open(out, "wb"))
f:write(img)
f:close()
