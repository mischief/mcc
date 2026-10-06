-- the inline paths, and every way out of them to the runtime
local t = {1, 2, 3}
local s = 0
for i = 1, #t do s = s + t[i] end
print(s)
t[2] = "two"; t[4] = 4; t[1] = nil
print(t[1], t[2], t[3], t[4], #t >= 0)
local m = setmetatable({}, {__index = function(_, k) return k * 10 end,
                            __newindex = function(r, k, v) rawset(r, k, v + 1) end})
m[1] = 5
print(m[1], m[2])
local big = 2^53
print(1 + 2, 1 + 2.5, "3" + 4, big + 1, math.maxinteger + 1 == math.mininteger)
print(7 % 3, -7 % 3, 7 % -3, 7.5 % 2, 3 - 5, 6 * 7, 2 * 0.5)
for i = 3, 1, -1 do io.write(i, " ") end
for i = 1, 2, 0.5 do io.write(i, " ") end
for i = math.maxinteger - 2, math.maxinteger do io.write(i, " ") end
print()
local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
print(fs[1](), fs[3]())
local x, y = 1, "a"
print(x < 2, 2 < x, x == 1, x ~= 1, y == "a", 1 == 1.0, 1 < 1.5)
local function count(n) if n == 0 then return 0 end return 1 + count(n - 1) end
print(count(100))
local u = {}
for i = 1, 10 do u[i] = {i} end
local acc = 0
for i = 1, 10 do acc = acc + u[i][1] end
u[3] = u[4]
print(acc, u[3][1])
local q, z = 1, "s"
q = q == 1
z = not z
print(q, z, not nil, 1 < 2 == true)
local box = 0
local function bump() box = box + 1; return box end
bump(); bump()
local str = "keep"
local function getstr() return str end
str = str .. "!"
print(box, getstr(), bump() + bump())
