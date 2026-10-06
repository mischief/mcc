-- control flow
local s = 0
for i = 1, 10 do s = s + i end
print(s)
for i = 10, 1, -3 do io.write(i, " ") end print()
for i = 1.0, 2.0, 0.25 do io.write(i, " ") end print()
for i = 1, 0 do print("never") end
local n = 0
repeat local m = n; n = n + 1 until m >= 4
print(n)
local i = 0
while true do i = i + 1; if i > 5 then break end end
print(i)
for i = 1, 3 do
  for j = 1, 3 do
    if j == 2 then goto continue end
    io.write(i, ",", j, " ")
    ::continue::
  end
end
print()
do
  local k = 0
  ::top::
  k = k + 1
  if k < 3 then goto top end
  print("k", k)
end
if nil then print("a") elseif false then print("b") elseif 0 then print("c") else print("d") end
print(1 and 2, nil and 1, false or "x", nil or false, 1 or error("no"))
print(not nil, not 0, 1 == 1.0, "1" == 1, 2 < 3, "a" < "b", 3 >= 3)
local t = {}
for k, v in pairs({10, 20, 30}) do t[#t+1] = k .. "=" .. v end
print(table.concat(t, " "))
for i, v in ipairs({"a", "b", nil, "d"}) do io.write(i, v, " ") end print()
local x = 5
local r = x > 3 and "big" or "small"
print(r)
