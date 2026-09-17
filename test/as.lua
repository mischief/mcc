-- Differential test for the assembler: assemble every file this compiler
-- produces with ours and with the real one, and compare the bytes.
--
-- A word the real one leaves a relocation on is skipped, because it has not
-- decided that word yet and we may have.  Everything else must match
-- exactly.
--
--   lua5.4 test/as.lua file.s ...

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local as = require "as"

local AS = "riscv64-linux-gnu-as"
local OBJCOPY = "riscv64-linux-gnu-objcopy"
local READELF = "riscv64-linux-gnu-readelf"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-as"
os.execute("mkdir -p " .. dir)

local function slurp(path, mode)
	local f = io.open(path, mode or "r")
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

local function gas(path)
	local o = dir .. "/ref.o"
	if os.execute(("%s -mno-relax -o %s %s 2>/dev/null")
	    :format(AS, o, path)) ~= true then
		return nil, "the real assembler refused it"
	end
	os.execute(("%s -O binary --only-section=.text %s %s/ref.bin")
		:format(OBJCOPY, o, dir))
	local bytes = slurp(dir .. "/ref.bin", "rb") or ""
	local skip = {}
	local p = io.popen(("%s -r %s 2>/dev/null"):format(READELF, o))
	local sec
	for l in p:lines() do
		local s = l:match("^Relocation section '%.rela?([%w.]+)'")
		if s then sec = s end
		local off, kind = l:match("^(%x+)%s+%x+%s+(R_%S+)")
		if off and sec == ".text" then
			local w = tonumber(off, 16) // 4
			skip[w] = true
			-- a call relocation covers the pair
			if kind:find("CALL") then skip[w + 1] = true end
		end
	end
	p:close()
	return bytes, skip
end

local total, bad, files = 0, 0, 0
for i = 1, #arg do
	local path = arg[i]
	local text = slurp(path)
	local want, skip = gas(path)
	if not want then
		print("skip " .. path .. ": " .. skip)
	else
		local ok, a = pcall(as.assemble, text, 64)
		if not ok then
			print("FAIL " .. path .. ": " .. tostring(a))
			bad = bad + 1
		else
			local got = a.sec[".text"] and a.sec[".text"].bytes or ""
			for _, r in ipairs(a.sec[".text"] and
					   a.sec[".text"].relocs or {}) do
				skip[r.off // 4] = true
			end
			files = files + 1
			if #got ~= #want then
				print(("FAIL %s: %d bytes, the real one made %d")
					:format(path, #got, #want))
				bad = bad + 1
			else
				for w = 0, #want // 4 - 1 do
					total = total + 1
					if not skip[w] and
					   got:sub(w * 4 + 1, w * 4 + 4) ~=
					   want:sub(w * 4 + 1, w * 4 + 4) then
						if bad < 5 then
							print(("FAIL %s+%d: %s want %s")
							 :format(path, w * 4,
							  (got:sub(w*4+1,w*4+4):gsub(".",
							   function(c) return ("%02x"):format(c:byte()) end)),
							  (want:sub(w*4+1,w*4+4):gsub(".",
							   function(c) return ("%02x"):format(c:byte()) end))))
						end
						bad = bad + 1
					end
				end
			end
		end
	end
end

if bad == 0 then
	print(("ok   assembler matches gas on %d words in %d files")
		:format(total, files))
else
	print(("FAIL %d words differ"):format(bad))
	os.exit(1)
end
