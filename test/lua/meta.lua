-- cycles: a metatable that is its own __index
local V = {}
V.__index = V
function V.new(x, y) return setmetatable({x = x, y = y}, V) end
function V.__add(a, b) return V.new(a.x + b.x, a.y + b.y) end
function V.__eq(a, b) return a.x == b.x and a.y == b.y end
function V.__lt(a, b) return a.x < b.x end
function V.__le(a, b) return a.x <= b.x end
function V.__tostring(v) return "(" .. v.x .. "," .. v.y .. ")" end
function V.__len(v) return 2 end
function V.__call(v, k) return v.x * k end
function V.__concat(a, b) return tostring(a) .. "|" .. tostring(b) end
function V:len2() return self.x * self.x + self.y * self.y end
local a, b = V.new(1, 2), V.new(3, 4)
print(tostring(a + b), a == V.new(1, 2), a < b, a <= b, #a, a(10))
print(a .. b, a:len2())
local d = setmetatable({}, {__index = function(t, k) return k .. "?" end})
print(d.foo, d[1])
local log = {}
local w = setmetatable({}, {__newindex = function(t, k, v) rawset(t, k, v * 2) end})
w.a = 5
print(w.a)
local base = {hello = function() return "hi" end}
local derived = setmetatable({}, {__index = base})
print(derived.hello())
print(getmetatable("x").__index == string)
local Animal = {}
Animal.__index = Animal
function Animal.new(name) local o = setmetatable({}, Animal); o.name = name; return o end
function Animal:speak() return self.name .. " makes a sound" end
local Dog = setmetatable({}, {__index = Animal})
Dog.__index = Dog
function Dog.new(name) local o = Animal.new(name); return setmetatable(o, Dog) end
function Dog:speak() return self.name .. " barks" end
print(Animal.new("cat"):speak(), Dog.new("rex"):speak())
