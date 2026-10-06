-- coroutines: resume and yield, values both ways, errors, wrap, status
local co = coroutine.create(function(a, b)
  print("start", a, b)
  local c = coroutine.yield(a + b)
  print("got", c)
  local d, e = coroutine.yield(c * 2)
  print("got", d, e)
  return "done", 99
end)
print(coroutine.status(co))
print(coroutine.resume(co, 1, 2))
print(coroutine.status(co))
print(coroutine.resume(co, 10))
print(coroutine.resume(co, "x", "y"))
print(coroutine.status(co), coroutine.resume(co))

local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i) end end)
print(gen(), gen(), gen())

local function range(n)
  return coroutine.wrap(function() for i = 1, n do coroutine.yield(i, i * i) end end)
end
for i, sq in range(4) do io.write(i, "=", sq, " ") end print()

local bad = coroutine.create(function() error("boom") end)
print(coroutine.resume(bad))
print(coroutine.status(bad), coroutine.resume(bad))
local bad2 = coroutine.create(function() error({code = 7}) end)
local ok, e = coroutine.resume(bad2)
print(ok, type(e), e.code)
print(pcall(coroutine.wrap(function() error("wrapped", 0) end)))

print(coroutine.isyieldable(), type(coroutine.running()), select(2, coroutine.running()))
local inner = coroutine.create(function()
  local me, main = coroutine.running()
  print("inner running", main, coroutine.status(me), coroutine.isyieldable())
end)
coroutine.resume(inner)
print(pcall(coroutine.yield, 1))

-- a yield from inside a pcall, and across a nested resume
local nest = coroutine.create(function()
  local ok, v = pcall(function()
    local x = coroutine.yield("in pcall")
    error("after " .. x)
  end)
  print("pcall gave", ok, v)
  local sub = coroutine.wrap(function() coroutine.yield("sub") end)
  print(sub())
  coroutine.yield("outer")
  return "end"
end)
print(coroutine.resume(nest))
print(coroutine.resume(nest, "resume"))
print(coroutine.resume(nest))

-- producer and consumer
local function producer()
  return coroutine.create(function()
    for _, w in ipairs({"a", "b", "c"}) do coroutine.yield(w) end
  end)
end
local p = producer()
local got = {}
while true do
  local ok, v = coroutine.resume(p)
  if not v then break end
  got[#got + 1] = v
end
print(table.concat(got, ","), coroutine.status(p))
local c2 = coroutine.create(function() coroutine.yield() end)
coroutine.resume(c2)
print(coroutine.close(c2), coroutine.status(c2))
-- many coroutines, all let go
local total = 0
for i = 1, 2000 do
  local w = coroutine.wrap(function(x) local y = coroutine.yield(x + 1); return y * 2 end)
  total = total + w(i) + w(3)
end
print(total)
-- deep recursion inside a coroutine, and one that overflows
local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end
print(coroutine.wrap(function() return depth(5000) end)())
print(select(1, pcall(function() local function inf() return 1 + inf() end return inf() end)))
-- closing a suspended coroutine closes its variables
local function closer(name)
  return setmetatable({}, {__close = function(_, err) print("closed", name, err) end})
end
local c3 = coroutine.create(function()
  local v <close> = closer("in coroutine")
  coroutine.yield(1)
  print("never")
end)
print(coroutine.resume(c3))
print(coroutine.close(c3), coroutine.status(c3))
local c4 = coroutine.create(function()
  local v <close> = closer("errored")
  error("bad", 0)
end)
print(coroutine.resume(c4))
print(coroutine.close(c4))
local c5
c5 = coroutine.create(function()
  local x <close> = setmetatable({}, {__close = function() print(pcall(coroutine.close, c5)) end})
  coroutine.yield(20)
end)
print(coroutine.resume(c5))
print(coroutine.close(c5))
print(pcall(coroutine.wrap(function() local w <close> = closer("wrap") error("werr", 0) end)))
