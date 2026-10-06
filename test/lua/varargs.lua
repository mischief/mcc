local function f(...) return select("#", ...), ... end
print(f())
print(f(1, nil, 3))
local function g(a, b, ...)
  local t = {...}
  return a, b, #t, ...
end
print(g(1))
print(g(1, 2, 3, 4, 5))
local function pass(...) return ... end
print(pass(1, 2, 3), pass(4, 5))
print((pass(1, 2, 3)))
local function sum(...)
  local s = 0
  for _, v in ipairs({...}) do s = s + v end
  return s
end
print(sum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
local t = {pass(1, 2), pass(3, 4)}
print(#t, t[1], t[2], t[3])
local a, b, c = pass(1)
print(a, b, c)
local x, y = 1
print(x, y)
local function multi() return 1, 2, 3 end
local p, q, r, s = 0, multi()
print(p, q, r, s)
print(string.format("%s %s", multi()))
print(math.max(multi()))
local function tail(n) if n == 0 then return "done" end return tail(n - 1) end
print(tail(1000))
print(pcall(function() error("boom") end))
print(select("#", pcall(function() error({code = 1}) end)))
print(pcall(function() return 1, 2 end))
print(select(-1, 1, 2, 3))
local ok, e = pcall(function() local z = nil; return z.x end)
print(ok)
print(xpcall(function() error("x", 0) end, function(m) return "handled " .. m end))
print(pcall(error))
