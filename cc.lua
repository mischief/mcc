-- SPDX-License-Identifier: ISC
-- Driver: read a C file, write assembly.
--
--   lua5.4 cc.lua [-t target] [-Idir] [-DNAME[=v]] [-E] file.c [-o out]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path
-- Reading a global that was never set is a mistake here, and a local
-- named later in a file is a global to the code above it.
require("strict").on()

local cpp   = require "cpp"
local parse = require "parse"
local widert = require "widert"
local sys = require "sys"

local target, input, output = "amd64", nil, nil
local ppath, defs, ponly = {}, {}, false
local timing = false
local regparm = nil
local pic = false
local retclean, cet, retpoline, rethunk = false, false, false, false
local nosse = false
local ssp = nil
local opt = 0

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
	elseif a == "-time" then
		timing = true
	elseif a == "-fpic" or a == "-fPIC" then
		pic = true
	elseif a == "-fret-clean" then
		retclean = true
	elseif a:sub(1, 15) == "-fcf-protection" then
		cet = true
	elseif a == "-mretpoline" or a == "-mretpoline-external-thunk" or
	       a:sub(1, 18) == "-mindirect-branch=" and
	       a ~= "-mindirect-branch=keep" then
		retpoline = true
	elseif a:sub(1, 18) == "-mfunction-return=" and
	       a ~= "-mfunction-return=keep" then
		rethunk = true
	elseif a:sub(1, 10) == "-mregparm=" then
		regparm = tonumber(a:sub(11))
	elseif a == "-mno-sse" then
		nosse = true
	elseif a == "-msse" then
		nosse = false
	elseif a:sub(1, 17) == "-fstack-protector" then
		ssp = a:match("^-fstack%-protector%-(%a+)$") or true
	elseif a:sub(1, 2) == "-O" then
		local n = a:sub(3)

		opt = n == "" and 1 or (tonumber(n) or 1)
	elseif a:sub(1, 2) == "-I" then
		ppath[#ppath + 1] = value(a)
	elseif a:sub(1, 2) == "-D" then
		local d = value(a)
		local k, v = d:match("^([^=]+)=(.*)$")
		defs[k or d] = v or true
	elseif a:sub(1, 2) == "-U" then
		defs[value(a)] = nil
	elseif a:sub(1, 1) == "-" and a ~= "-" then
		-- Not a flag this knows.  It is refused rather than
		-- taken for a file name: `-m16` once went in as the
		-- input, the real input overwrote it, and a sweep meant
		-- to compare 16-bit code quietly compared 32-bit code
		-- instead and said everything was well.
		io.stderr:write("cc.lua: no option " .. a .. "\n")
		sys.exit(2)
	else
		input = a
	end
	i = i + 1
end

if not input then
	io.stderr:write("usage: cc.lua [-t target] [-Idir] [-DNAME] file.c\n")
	sys.exit(2)
end

local t = require("target." .. target)

if regparm then
	if not t.regparm then
		error("-mregparm is not a choice on " .. target)
	end
	t.regparm(regparm)
end

-- The machine facts a header may ask about.  A -D on the command line wins,
-- so a build can still say something different.
for k, v in pairs(t.predef or {}) do
	if defs[k] == nil then defs[k] = v end
end

local w = output and assert(io.open(output, "w")) or io.stdout
local src = cpp.new{file = input, path = ppath, define = defs,
	charsigned = t.charsigned ~= false}

local function run()
	if ponly then
		-- One token a line.  The parser is the real consumer, so there
		-- is no text layout to reproduce.
		while true do
			local tk = src:next()
			if tk.kind == "eof" then return end
			if tk.kind == "str" then
				w:write(tk.pfx or "", '"',
					(tk.text:gsub('[\\"]', "\\%0")), '"\n')
			else
				w:write(tk.text or tostring(tk.val or tk.kind), "\n")
			end
		end
	end
	local p = parse.new(src, t, function(s) w:write(s) end,
		{wide = sys.getenv("WIDE") ~= nil, pic = pic, opt = opt,
		 retclean = retclean, cet = cet, retpoline = retpoline,
		 rethunk = rethunk, nosse = nosse,
		 ssp = ssp})
	p:program()
	widert.emit(p, function(s) w:write(s) end, t, here,
		{pic = pic, opt = opt, retclean = retclean, cet = cet,
		 retpoline = retpoline, rethunk = rethunk, nosse = nosse})
	if t.trailer then w:write(t.trailer) end
end

-- MEM=1 samples the Lua heap while compiling: what is allocated, and what
-- survives a full collection, which is the working set a small machine would
-- have to hold.
if sys.getenv("MEM") then
	local peak, live, n = 0, 0, 0
	debug.sethook(function()
		local k = collectgarbage("count")
		if k > peak then peak = k end
		n = n + 1
		if n % 200 == 0 then
			collectgarbage("collect")
			k = collectgarbage("count")
			if k > live then live = k end
		end
	end, "", 5000)
	rawset(_G, "__memreport", function()
		debug.sethook()
		collectgarbage("collect")
		local final = collectgarbage("count")
		if final > live then live = final end
		-- Collect first: a count taken over uncollected garbage
		-- charges that garbage to whatever is dropped next.
		local function share(t, k)
			if not t or not t[k] then return 0, 0 end
			local n = 0
			for _ in pairs(t[k]) do n = n + 1 end
			collectgarbage("collect")
			local a = collectgarbage("count")
			t[k] = nil
			collectgarbage("collect")
			return a - collectgarbage("count"), n
		end
		local files = share(rawget(_G, "__cpp"), "files")
		local scopes = share(rawget(_G, "__parser"), "scopes")
		local mkb, mn = share(rawget(_G, "__cpp"), "macros")
		local gkb, gn = share(rawget(_G, "__parser"), "globals")
		local tkb, tn = share(rawget(_G, "__parser"), "tags")
		io.stderr:write(("      cpp files %.0f KB, scopes %.0f KB\n")
			:format(files, scopes))
		io.stderr:write(("      macros %.0f KB (%d, %.0f B each)," ..
			" globals %.0f KB (%d, %.0f B each), tags %.0f KB\n")
			:format(mkb, mn, mkb * 1024 / math.max(mn, 1),
				gkb, gn, gkb * 1024 / math.max(gn, 1), tkb))
		io.stderr:write(("mem: %.1f KB allocated, %.1f KB live, " ..
			"%.1f KB at exit, biggest body %.1f KB (%s)\n")
			:format(peak, live, final,
				(rawget(_G, "__bodymax") or 0) / 1024,
				rawget(_G, "__bodyname") or "-"))
	end)
end

local t0 = sys.clock()
local ok, err = xpcall(run, function(e)
	return sys.getenv("TRACE") and debug.traceback(e, 2) or e
end)
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	sys.exit(1)
end

if sys.getenv("ARENA") then
	local tree = require "tree"
	local live, peak, pool = tree.arena()
	io.stderr:write(("arena: %d live, %d peak, %d pooled\n")
		:format(live, peak, pool))
end

-- A host may make an unset global an error, so ask without reading it.
local report = rawget(_G, "__memreport")

if report then report() end

if timing then
	io.stderr:write(("time: %.2f s\n"):format(sys.clock() - t0))
end

if output then w:close() end
