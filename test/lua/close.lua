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
