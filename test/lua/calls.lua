-- the call and return paths, inline and not
local function find(list, want)
  for i, v in ipairs(list) do
    local hold = {v}
    if v == want then return hold, i end
    if v == "stop" then return end
  end
  return nil
end
local h, i = find({"a", "b", "c"}, "b")
print(h[1], i, find({"stop"}, "x"), (find({"q"}, "z")))

local function deep(n)
  local t = {n}
  if n == 0 then return t end
  local r = deep(n - 1)
  return r
end
print(deep(50)[1])

local function counter()
  local c = 0
  local function inc() c = c + 1; return c end
  return inc
end
local inc = counter()
inc(); print(inc())

local callable = setmetatable({}, {__call = function(self, a, b) return a + b, "two" end})
print(callable(1, 2))
print((callable(3, 4)))
local function three() return 1, 2, 3 end
local a, b, c, d = three()
print(a, b, c, d)
local t = {three(), three()}
print(#t)
print(select("#", three()), math.max(three()))
local function none() end
print(none(), (none()), select("#", none()))
local function pass(...) return ... end
print(pass(), pass(nil), pass(1, nil, 3))
local function tostr(x) return tostring(x) end
print(tostr(12), tostr("s"), tostr(nil))
for k, v in pairs({x = 1}) do print(k, v) end
local function gen() local n = 0; return function() n = n + 1; if n <= 3 then return n, n * n end end end
for p, q in gen() do io.write(p, ":", q, " ") end print()
local function mixed(x)
  local s = "s" .. x
  do
    local u = {s}
    if x > 1 then return u[1] end
  end
  return s .. "!"
end
print(mixed(1), mixed(2))
local obj = {n = 5}
function obj:get(k) return self.n + k end
print(obj:get(1), obj.get(obj, 2))
print(pcall(function(x) return x * 2 end, 21))
