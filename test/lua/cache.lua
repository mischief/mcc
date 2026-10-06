-- cycles: classes that are their own __index
-- a lookup site's cache, and every way it has to miss
local t = {x = 1, y = 2}
local s = 0
for i = 1, 100 do s = s + t.x + t.y end
print(s)
-- the table grows and rehashes under the site
for i = 1, 200 do t["k" .. i] = i end
s = 0
for i = 1, 10 do s = s + t.x end
print(s, t.k150)
-- another table at the same site
local function getx(o) return o.x end
print(getx(t), getx({x = "other"}), getx({}), getx(setmetatable({}, {__index = {x = "meta"}})))
-- a key removed and put back
t.x = nil
print(getx(t))
t.x = 5
print(getx(t))
-- writes through the cache, and __newindex for an absent key
local log = {}
local w = setmetatable({}, {__newindex = function(r, k, v) log[#log + 1] = k; rawset(r, k, v) end})
local function setv(o, v) o.v = v end
for i = 1, 3 do setv(w, i) end
print(w.v, #log, log[1])
-- globals
G1 = 10
local function bump() G1 = G1 + 1 end
for i = 1, 5 do bump() end
print(G1)
G1 = nil
print(G1, type(print), math.floor(2.5))
-- a table freed and another made where it was
for i = 1, 50 do local u = {x = i}; s = getx(u) end
print(s)
-- method calls through a cached chain, and what breaks the chain
local A = {}; A.__index = A
function A:who() return "A" end
local B = setmetatable({}, {__index = A}); B.__index = B
function B:who() return "B" end
local objs = {setmetatable({}, A), setmetatable({}, B), setmetatable({}, A)}
local out = {}
for round = 1, 2 do
  for _, o in ipairs(objs) do out[#out + 1] = o:who() end
end
print(table.concat(out))
local o = setmetatable({}, A)
local function call(x) return x:who() end
print(call(o), call(o))
o.who = function() return "own" end
print(call(o))
o.who = nil
A.who = function() return "A2" end
print(call(o))
A.__index = B
print(call(o))
A.__index = function(t, k) return function() return "fn " .. k end end
print(call(o))
local s = "str"
print(s:upper(), s:len(), ("x"):rep(3))
