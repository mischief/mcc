-- cycles, closures, coroutines and strings, with collections between
local function mk(n)
  local a = {name = "a" .. n}
  local b = {peer = a}
  a.peer = b
  a.f = function() return a.name .. b.peer.name end
  return a
end
local keep = {}
for i = 1, 200000 do
  local x = mk(i)
  if i % 1000 == 0 then keep[#keep + 1] = x end
end
local s = 0
for _, x in ipairs(keep) do s = s + #x.f() end
print("keep", #keep, s)

local function gen(n)
  return coroutine.wrap(function()
    for i = 1, n do
      local t = {i, tostring(i), {i * 2}}
      coroutine.yield(t[1] + #t[2] + t[3][1])
    end
  end)
end
local total = 0
for j = 1, 50 do
  local g = gen(2000)
  for i = 1, 2000 do total = total + g() end
end
print("coro", total)

local parts = {}
for i = 1, 100000 do
  parts[#parts + 1] = string.format("%d:%s", i, ("x"):rep(i % 7))
end
print("str", #table.concat(parts, ","))

local t = setmetatable({}, {__index = function(t, k) return k * 2 end})
local acc = 0
for i = 1, 100000 do acc = acc + t[i] end
print("meta", acc)

local ok, err = pcall(function()
  local big = {}
  for i = 1, 100000 do big[i] = {i} end
  error({code = #big})
end)
print("pcall", ok, err.code)
collectgarbage()
print("count>0", collectgarbage("count") > 0)
