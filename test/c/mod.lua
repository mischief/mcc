-- Exercise every function the module offers, and print what comes back.
local m = require "compmod"

local function p(...)
	local t = {}

	for i = 1, select("#", ...) do
		t[#t + 1] = tostring((select(i, ...)))
	end
	print(table.concat(t, "\t"))
end

p(m.mix(3, 2.5, -7, 0.125))
p(m.mix(-1, -0.5, 0, 1e18))
p(m.eight(1, 2, 3, 4, 5, 6, 7, 8))
p(m.eight(0.5, -0.25, 1e10, -1e-10, 7, 0, 3.5, -8.25))
p(m.straddle(1, 2.5, 3, 4.5, 5, 6.5, 7))
p(m.straddle(-2147483648, 0.0, 9007199254740993, -1.5, 42, 1e300, -1))
p(m.format("k", 42, 3.25, {}))
p(m.format("", -1, -0.0, nil))
p(m.sum(1, 2.75, 3, 4.5, 5, 6.25))
p(m.sum(-9, 1e9, 0, -0.75, 1 << 40, 2.5))
p(m.rot("Hello, World!"))
p(m.rot(string.rep("abcXYZ", 20)))
p(m.apply(function(x) return x * x end))
p(m.apply(function(x) return -x * 1000 end))
p(m.wide(123456789123, -1000003))
p(m.wide(-1, 3))
p(m.wide(math.maxinteger, 7))
