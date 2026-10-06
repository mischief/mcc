local t = {1, 2, 3, x = "a", ["y z"] = 5, [10] = 10}
print(#t, t.x, t["y z"], t[10], t[4])
t[#t + 1] = 4
print(#t, t[4])
local u = {}
for i = 1, 100 do u[i] = i * i end
print(#u, u[50], u[100])
u[100] = nil
print(#u)
local keys = {}
for k in pairs({a=1, b=2, c=3}) do keys[#keys+1] = k end
table.sort(keys)
print(table.concat(keys, ","))
local v = {5, 2, 8, 1, 9, 3}
table.sort(v)
print(table.concat(v, " "))
table.sort(v, function(a, b) return a > b end)
print(table.concat(v, " "))
table.insert(v, 7) table.insert(v, 1, 0)
print(table.concat(v, " "))
print(table.remove(v), table.remove(v, 1), table.concat(v, " "))
print(table.unpack({1, 2, 3}))
local p = table.pack(1, nil, 3)
print(p.n, p[1], p[2], p[3])
print(select("#", 1, nil, 3), select(2, "a", "b", "c"))
local nested = {a = {b = {c = "deep"}}}
print(nested.a.b.c)
local m = {}
m[1.0] = "one"; m[2] = "two"
print(m[1], m[2.0])
print(next({}))
local big = {}
for i = 1, 1000 do big["k" .. i] = i end
local sum = 0
for k, v in pairs(big) do sum = sum + v end
print(sum)
print(rawlen({1,2}), rawget({5}, 1), rawequal(t, t))
