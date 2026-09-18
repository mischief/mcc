-- One file of the upstream Lua test suite, on an interpreter this compiler
-- built.
--
-- `all.lua` runs its files in one process and in one order, which is why it
-- takes as long as it does.  Nothing in its preamble depends on a file
-- having run before, though, so a file can have that preamble to itself and
-- the lot of them can run side by side.  What each file needs beyond the
-- preamble -- a value it must answer with, a wrapper it must be called
-- through -- is copied from all.lua below, and a name that turns up in one
-- and not the other is a failed assertion rather than a file quietly not
-- run.
--
--   lua5.4 test/testes.lua <interpreter> <file.lua> [runner]
--   lua5.4 test/testes.lua -list

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

-- the build system hands over a path relative to its own directory, and
-- this runs the interpreter from the suite's
local function absolute(path)
	if not path or path:sub(1, 1) == "/" then return path end
	local p = io.popen("pwd")
	local cwd = p:read("l")
	p:close()
	return cwd .. "/" .. path
end

local lua, file, run = arg[1], arg[2], arg[3] or ""
local listing = lua == "-list"
if not listing then lua = absolute(lua) end
local src = os.getenv("LUA_SRC") or (os.getenv("HOME") .. "/src/lua")
local testes = src .. "/testes"

-- How all.lua calls each one.  `dofile` is its own, which dumps and loads
-- the chunk again; `olddofile` is Lua's.
local RUN = {
	["main.lua"] = "dofile('main.lua')",
	["gc.lua"] = "local f = assert(loadfile('gc.lua')) f()",
	["db.lua"] = "dofile('db.lua')",
	["calls.lua"] = "assert(dofile('calls.lua') == deep and deep)",
	["strings.lua"] = "olddofile('strings.lua')",
	["literals.lua"] = "olddofile('literals.lua')",
	["tpack.lua"] = "dofile('tpack.lua')",
	["attrib.lua"] = "assert(dofile('attrib.lua') == 27)",
	["gengc.lua"] = "dofile('gengc.lua')",
	["locals.lua"] = "assert(dofile('locals.lua') == 5)",
	["constructs.lua"] = "dofile('constructs.lua')",
	["code.lua"] = "dofile('code.lua', true)",
	["big.lua"] = "local f = coroutine.wrap(assert(loadfile('big.lua')))" ..
		" assert(f() == 'b') assert(f() == 'a')",
	["cstack.lua"] = "dofile('cstack.lua')",
	["nextvar.lua"] = "dofile('nextvar.lua')",
	["pm.lua"] = "dofile('pm.lua')",
	["utf8.lua"] = "dofile('utf8.lua')",
	["api.lua"] = "dofile('api.lua')",
	["memerr.lua"] = "dofile('memerr.lua')",
	["events.lua"] = "assert(dofile('events.lua') == 12)",
	["vararg.lua"] = "dofile('vararg.lua')",
	["closure.lua"] = "dofile('closure.lua')",
	["coroutine.lua"] = "dofile('coroutine.lua')",
	["goto.lua"] = "dofile('goto.lua', true)",
	["errors.lua"] = "dofile('errors.lua')",
	["math.lua"] = "dofile('math.lua')",
	["sort.lua"] = "dofile('sort.lua', true)",
	["bitwise.lua"] = "dofile('bitwise.lua')",
	["verybig.lua"] = "assert(dofile('verybig.lua', true) == 10)",
	["files.lua"] = "dofile('files.lua')",
}

-- not files of their own: all.lua is the driver, tracegc a module it loads,
-- and heavy and bwcoercion are only reached from other files
local NOTATEST = {["all.lua"] = true, ["tracegc.lua"] = true,
		  ["heavy.lua"] = true, ["bwcoercion.lua"] = true}

local function slurp(path)
	local f = io.open(path)
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

local all = slurp(testes .. "/all.lua")
if not all then tap.skipall("no " .. testes .. "/all.lua") end

-- `-list` names the files, and says so loudly if all.lua has a name this
-- does not know
if listing then
	local missing = {}
	for name in all:gmatch("'([%w_]+%.lua)'") do
		if not RUN[name] and not NOTATEST[name] then
			missing[#missing + 1] = name
		end
	end
	if #missing > 0 then
		io.stderr:write("testes.lua does not know: " ..
			table.concat(missing, " ") .. "\n")
		os.exit(1)
	end
	for name in pairs(RUN) do io.write(name, "\n") end
	os.exit(0)
end

local what = RUN[file]
if not what then tap.skipall(file .. " is not one of the suite's files") end

-- all.lua's own setup, verbatim, up to the first file it runs
local head = all:match("^(.-)\ndofile%('main%.lua'%)")
if not head then
	tap.ok(false, "all.lua still starts the way this expects")
	tap.done()
end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-testes"
os.execute("mkdir -p " .. dir)
local out = ("%s/%s-%s"):format(dir, file:gsub("%.lua$", ""),
	lua:gsub(".*/", ""))

-- The chunk goes in the suite's own directory, because the files there
-- open one another by name.  Two interpreters run the same file at the
-- same time, so the name carries which one this is.
local one = (".one-%s-%s"):format(lua:gsub(".*/", ""), file)
local w = assert(io.open(testes .. "/" .. one, "w"))

-- the preamble opens a block that the tail of all.lua closes
w:write(head, "\n", 'require"tracegc".start()\n', what,
	'\nprint("final OK !!!")\nend\n')
w:close()

local cmd = ("cd %s && ulimit -S -s 2000; %s%s -e '_port=true' -W %s")
	:format(testes, run, lua, one)
local p = io.popen(cmd .. " > " .. out .. " 2>&1")
p:close()
os.remove(testes .. "/" .. one)

local said = slurp(out) or ""
if not tap.ok(said:find("final OK", 1, true) ~= nil, file .. " passes") then
	tap.diag(said:sub(-1200))
end
tap.done()
