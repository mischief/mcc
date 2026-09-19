-- SPDX-License-Identifier: ISC
-- Shared test helpers: build a tree, generate, compare.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../?/init.lua;" ..
	package.path

local tree = require "tree"
local gen  = require "gen"
local tap  = require "test.tap"

local H = {tap = tap}

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
	if not tap.ok(got == want, name) then
		tap.diag("want\n" .. want)
		tap.diag("got\n" .. got)
	end
end

H.ok = tap.ok

function H.narrow(target)
	local small = {}
	for k, v in pairs(target or H.t) do small[k] = v end
	small.nreg = 2
	return small
end

H.done = tap.done

return H
