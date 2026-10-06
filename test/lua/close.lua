-- to-be-closed variables, on every way out of their scope but an error
local function closer(name)
  return setmetatable({}, {__close = function(_, err)
    print("close", name, err)
  end})
end
do
  local a <close> = closer("a")
  local b <close> = closer("b")
  local c <close> = nil
  print("in block")
end
for i = 1, 2 do
  local x <close> = closer("loop" .. i)
  if i == 2 then break end
  print("turn", i)
end
local function f()
  local y <close> = closer("f")
  return "ret"
end
print(f())
do
  local z <close> = closer("goto")
  goto out
end
::out::
local k <const> = 10
print(k + 1)
print(pcall(function() local bad <close> = {} end))
-- an error closes what it unwinds, with the error
local function closer2(name)
  return setmetatable({}, {__close = function(_, err) print("closing", name, err) end})
end
print(pcall(function()
  local a <close> = closer2("outer")
  do
    local b <close> = closer2("inner")
    error("oops", 0)
  end
end))
-- a __close that raises replaces the error
print(pcall(function()
  local a <close> = setmetatable({}, {__close = function() error("from close", 0) end})
  error("first", 0)
end))
