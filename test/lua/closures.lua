-- closures, upvalues, and a fresh variable on each turn of a loop
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c1, c2 = counter(), counter()
print(c1(), c1(), c2(), c1())

local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
print(fs[1](), fs[2](), fs[3]())

local gs = {}
local j = 0
while j < 3 do
  j = j + 1
  local k = j * 10
  gs[j] = function() k = k + 1; return k end
end
print(gs[1](), gs[1](), gs[2](), gs[3]())

local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end
print(fib(20))

local function outer()
  local a = 1
  local function mid()
    local b = 2
    return function() a = a + b; return a end
  end
  return mid()
end
local f = outer()
print(f(), f())

-- a shared upvalue seen by two closures
local function pair()
  local v = 0
  return function(x) v = x end, function() return v end
end
local set, get = pair()
set(42); print(get())
for _, name in ipairs({"x", "y"}) do
  local s = name .. "!"
  fs[name] = function() return s end
end
print(fs.x(), fs.y())
