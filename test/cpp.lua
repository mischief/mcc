-- Differential test for the preprocessor: run a file through this one and
-- through the system cpp, and compare the token streams.
--
--   lua5.4 test/cpp.lua [file.c ...]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local lex = require "lex"
local cpp = require "cpp"

local function stream(toks)
	local out = {}
	for _, t in ipairs(toks) do out[#out + 1] = t end
	return table.concat(out, " ")
end

local function show(t)
	if t.kind == "str" then
		return '"' .. t.text:gsub("[\\\"]", "\\%0") .. '"'
	end
	return t.text or (t.val and tostring(t.val)) or t.kind
end

-- Our own output, as tokens.
local INC = {here .. "/pp", here .. "/../include"}
for _, d in ipairs(os.getenv("CPPINC") and
    (function()
	local t = {}
	for d in os.getenv("CPPINC"):gmatch("[^:]+") do t[#t + 1] = d end
	return t
    end)() or {}) do
	INC[#INC + 1] = d
end

local function mine(path)
	local c = cpp.new{file = path, path = INC}
	local out = {}
	while true do
		local t = c:next()
		if t.kind == "eof" then break end
		out[#out + 1] = show(t)
	end
	return out
end

-- The system cpp's output, lexed with the same lexer so the comparison is
-- of tokens rather than of whitespace.
local function theirs(path)
	local inc = ""
	for _, d in ipairs(INC) do inc = inc .. " -I" .. d end
	local p = io.popen(("gcc -E -P -nostdinc -U__GNUC__ -U__ELF__%s %s 2>/dev/null")
		:format(inc, path))
	local text = p:read("a")
	p:close()
	local i = 0
	local l = lex.new(function()
		i = i + 1
		if i > #text then return nil end
		return text:sub(i, i)
	end, path, true)
	-- Adjacent string literals join after preprocessing, which the system
	-- cpp leaves for the compiler; do it here so both sides agree.
	local out = {}
	local prev
	while true do
		local t = l:next()
		if t.kind == "eof" then break end
		if t.kind == "str" and prev and prev.kind == "str" then
			prev.text = prev.text .. t.text
			out[#out] = show(prev)
		else
			prev = {kind = t.kind, text = t.text}
			out[#out + 1] = show(t)
		end
	end
	return out
end

local files = {}
for _, a in ipairs(arg) do files[#files + 1] = a end
if #files == 0 then files = {here .. "/pp/t3.c"} end

local fail = 0
for _, path in ipairs(files) do
	local a, b = mine(path), theirs(path)
	local name = path:match("[^/]*$")
	if stream(a) == stream(b) then
		print(("ok   cpp %s matches gcc -E on %d tokens"):format(name, #a))
	else
		fail = fail + 1
		print("FAIL cpp " .. name)
		for i = 1, math.max(#a, #b) do
			if a[i] ~= b[i] then
				print(("  token %d\n    mine %s\n    gcc  %s")
					:format(i, tostring(a[i]), tostring(b[i])))
				local lo = math.max(1, i - 6)
				print("    near mine: " ..
					table.concat(a, " ", lo, math.min(#a, i + 6)))
				print("    near gcc : " ..
					table.concat(b, " ", lo, math.min(#b, i + 6)))
				break
			end
		end
	end
end
os.exit(fail == 0 and 0 or 1)
