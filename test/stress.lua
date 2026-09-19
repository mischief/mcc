-- SPDX-License-Identifier: ISC
local out = {}
local function p(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  out[#out+1] = table.concat(t, "\t")
end

-- integers and floats
p(1//3, 1%3, -7//2, -7%2, 7/2, 2^10, math.maxinteger, math.mininteger)
p(math.type(1), math.type(1.0), math.tointeger(3.0), 3|5, 3~5, ~0, 1<<62)
p(string.format("%.14g %d %5.2f %x %o %s %q", 1/3, 42, 3.14159, 255, 8, "hi", "a\nb"))
p(math.floor(-3.5), math.ceil(-3.5), math.abs(-3), math.fmod(7,3))
p(math.sqrt(2), math.sin(0), math.exp(1), math.log(8,2))
p(tostring(0/0) == tostring(0/0), 1/0, -1/0)

-- strings
local s = "the quick brown fox jumps over the lazy dog"
p(#s, s:upper(), s:sub(5,9), s:find("brown"), s:byte(1,3))
p(s:gsub("%w+", function(w) return w:len() end))
p(s:rep(2, "-"):len(), ("x"):rep(5))
p(table.concat({s:match("(%a+) (%a+)")}, ","))
for w in s:gmatch("%a+") do out[#out+1] = w end
p(("%d-%s"):format(7, "z"), ("abc"):reverse())
p(string.pack and #string.pack("i4i8", 1, 2) or "nopack")
p(utf8 and utf8.char(65, 0x4e2d) or "noutf8")

-- tables
local t = {}
for i = 1, 200 do t[i] = (i * 37) % 101 end
table.sort(t)
p(t[1], t[100], t[200], #t)
table.sort(t, function(a,b) return a > b end)
p(t[1], t[200])
local u = {}
for i = 1, 50 do u["k"..i] = i end
local keys = {}
for k in pairs(u) do keys[#keys+1] = k end
table.sort(keys)
p(#keys, keys[1], keys[#keys])
p(table.unpack({1,2,3}))
table.insert(t, 1, 999) table.remove(t, 2)
p(t[1], #t)

-- closures, varargs, metatables
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local c = counter()
p(c(), c(), c())
local mt = {__index = function(_, k) return "d:"..k end,
            __add = function(a, b) return setmetatable({v = a.v + b.v}, getmetatable(a)) end,
            __tostring = function(a) return "V("..a.v..")" end,
            __len = function() return 42 end, __eq = function() return true end}
local A = setmetatable({v = 1}, mt)
local B = setmetatable({v = 2}, mt)
p(tostring(A + B), A.missing, #A, A == B)

-- errors and coroutines
p((pcall(function() error({code = 7}) end)))
p(select(2, pcall(function() error("msg", 0) end)))
local co = coroutine.create(function(a, b)
  local x = coroutine.yield(a + b)
  return x * 2
end)
p(coroutine.resume(co, 3, 4))
p(coroutine.resume(co, 10))
p(coroutine.status(co))
p(select(2, pcall(error)))

-- gc and weak tables
local w = setmetatable({}, {__mode = "v"})
for i = 1, 100 do w[i] = {i} end
collectgarbage()
p(type(collectgarbage("count")) )

-- load, string.dump
local f = load("local a, b = ... return a * b + 1")
p(f(6, 7))
p(pcall(load, "syntax ?? error"))
p(load("return 1 + ")) 

-- io
local fn = os.tmpname()
local h = io.open(fn, "w")
h:write("line1\n", 22, "\n", 3.5, "\n")
h:close()
h = io.open(fn, "r")
p(h:read("l"), h:read("n"), h:read("n"))
h:close()
os.remove(fn)
p(os.date("!%Y", 0), os.time({year=2000, month=1, day=1, hour=12}) > 0)
p(os.clock() >= 0, type(os.getenv("PATH")))

print(table.concat(out, "\n"))
