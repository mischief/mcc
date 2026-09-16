-- Driver: read a C file, write assembly.
--
--   lua5.4 cc.lua [-t target] [-Idir] [-DNAME[=v]] [-E] file.c [-o out]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local cpp   = require "cpp"
local parse = require "parse"

local target, input, output = "amd64", nil, nil
local ppath, defs, ponly = {}, {}, false

local i = 1
local function value(a)
	if #a > 2 then return a:sub(3) end
	i = i + 1
	return arg[i]
end

while i <= #arg do
	local a = arg[i]
	if a == "-t" then
		i = i + 1
		target = arg[i]
	elseif a == "-o" then
		i = i + 1
		output = arg[i]
	elseif a == "-E" then
		ponly = true
	elseif a:sub(1, 2) == "-I" then
		ppath[#ppath + 1] = value(a)
	elseif a:sub(1, 2) == "-D" then
		local d = value(a)
		local k, v = d:match("^([^=]+)=(.*)$")
		defs[k or d] = v or true
	elseif a:sub(1, 2) == "-U" then
		defs[value(a)] = nil
	else
		input = a
	end
	i = i + 1
end

if not input then
	io.stderr:write("usage: cc.lua [-t target] [-Idir] [-DNAME] file.c\n")
	os.exit(2)
end

local t = require("target." .. target)

-- The machine facts a header may ask about.  A -D on the command line wins,
-- so a build can still say something different.
for k, v in pairs(t.predef or {}) do
	if defs[k] == nil then defs[k] = v end
end

local w = output and assert(io.open(output, "w")) or io.stdout
local src = cpp.new{file = input, path = ppath, define = defs}

local function run()
	if ponly then
		-- One token a line.  The parser is the real consumer, so there
		-- is no text layout to reproduce.
		while true do
			local tk = src:next()
			if tk.kind == "eof" then return end
			if tk.kind == "str" then
				w:write('"', (tk.text:gsub('[\\"]', "\\%0")), '"\n')
			else
				w:write(tk.text or tostring(tk.val or tk.kind), "\n")
			end
		end
	end
	local p = parse.new(src, t, function(s) w:write(s) end)
	p:program()
end

local ok, err = pcall(run)
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	os.exit(1)
end

if os.getenv("ARENA") then
	local tree = require "tree"
	local live, peak, pool = tree.arena()
	io.stderr:write(("arena: %d live, %d peak, %d pooled\n")
		:format(live, peak, pool))
end

if output then w:close() end
