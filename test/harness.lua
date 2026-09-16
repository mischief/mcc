-- Shared test helpers: build a tree, generate, compare.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../?/init.lua;" .. package.path

local tree = require "tree"
local gen  = require "gen"

local H = {fail = 0}

function H.setup(name)
	H.t = require("target." .. name)
	H.ty = tree.types(H.t)
	return H.t, H.ty
end

function H.codegen(n, ctx, target)
	local sink = require("buf").new()
	gen.new(target or H.t, sink):expr(n, ctx or "eff", 0)
	return sink:text()
end

function H.branchgen(n, label, target)
	local sink = require("buf").new()
	gen.new(target or H.t, sink):cond(n, label, true, 0)
	return sink:text()
end

function H.check(name, got, want)
	got = got:gsub("%s+$", "")
	want = want:gsub("^\n", ""):gsub("%s+$", "")
	if got == want then
		print("ok   " .. name)
	else
		H.fail = H.fail + 1
		print("FAIL " .. name)
		print("--- want\n" .. want)
		print("--- got\n" .. got)
	end
end

function H.narrow(target)
	local small = {}
	for k, v in pairs(target or H.t) do small[k] = v end
	small.nreg = 2
	return small
end

function H.done()
	os.exit(H.fail == 0 and 0 or 1)
end

return H
