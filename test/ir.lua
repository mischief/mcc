-- SPDX-License-Identifier: ISC
-- The blocks read off a recorded function.
--
-- A record is five slots a call, so one can be written by hand here
-- and the shape checked without compiling anything.  The cases are
-- the ones Braun's figure 3 draws: a straight run, an if with two
-- arms, and a loop whose back edge reaches a block already passed.
--
--   lua5.4 test/ir.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local ir = require "ir"

-- Build a record from a short description: each entry is a kind and
-- its payloads, the way gen.lua lays them out.
local function rec(list)
	local r = {n = 0}

	for _, e in ipairs(list) do
		local n = r.n

		r[n + 1], r[n + 2], r[n + 3] = e[1], e[2], e[3]
		r[n + 4], r[n + 5] = e[4], e[5]
		r.n = n + 5
	end
	return r
end

local function shape(blocks)
	local out = {}

	for i, b in ipairs(blocks) do
		local s = {}

		for _, x in ipairs(b.succ) do
			for j, y in ipairs(blocks) do
				if x == y then s[#s + 1] = j end
			end
		end
		out[i] = (b.label or "-") .. "->" .. table.concat(s, ",")
	end
	return table.concat(out, " ")
end

-- A straight run is one block that reaches nothing.
do
	local b = ir.blocks(rec{{"e"}, {"e"}, {"w", "x"}})

	tap.is(#b, 1, "a run with no branch is one block")
	tap.is(shape(b), "-->", "and it reaches nothing")
end

-- `if (c) then; else; end`: the test reaches the else block and
-- falls into the then block, which jumps past the else.
do
	local b, by = ir.blocks(rec{
		{"e"},                      -- before the if
		{"c", "tree", ".Lelse"},    -- branch when false
		{"e"},                      -- the then arm
		{"j", ".Lend"},
		{"l", ".Lelse"},
		{"e"},                      -- the else arm
		{"l", ".Lend"},
		{"e"},
	})

	tap.is(#b, 4, "an if with two arms is four blocks")
	-- The branch target comes before the fall through, which is
	-- the order every successor list here is in.
	tap.is(shape(b), "-->3,2 -->4 .Lelse->4 .Lend->",
		"the test reaches both arms and they meet")
	tap.ok(by[".Lend"] ~= nil and #by[".Lend"].pred == 2,
		"the block they meet in has two predecessors")
end

-- A loop: the body jumps back to a label already passed, so that
-- block has a predecessor that comes after it.
do
	local b, by = ir.blocks(rec{
		{"l", ".Ltop"},
		{"c", "tree", ".Lbrk"},
		{"e"},
		{"j", ".Ltop"},
		{"l", ".Lbrk"},
		{"e"},
	})

	tap.is(#b, 3, "a loop is three blocks")
	tap.is(shape(b), ".Ltop->3,2 -->1 .Lbrk->",
		"the body reaches the top again")
	local top = by[".Ltop"]

	tap.is(#top.pred, 1, "the head is reached from inside the loop")
	tap.ok(top.pred[1] == b[2], "by the block that ends the body")
end

-- A label straight after a branch opens the block that was waiting
-- rather than starting another empty one.
do
	local b = ir.blocks(rec{
		{"c", "tree", ".La"},
		{"l", ".La"},
		{"e"},
	})

	tap.is(#b, 2, "a label after a branch opens the waiting block")
	tap.is(shape(b), "-->2,2 .La->", "and the branch reaches it")
end

-- Liveness over frame slots.  A record can hold real trees, so these
-- are built with tree.lua rather than written as strings.
local tree = require "tree"
local ty = {size = 8, align = 8, kind = "int", name = "long"}
local function auto(off) return tree.auto(ty, off) end
local function set(off, v)
	return tree.node("ASGN", ty, auto(off), v)
end

do
	-- a = 1; if (a) { b = a; } use(b)
	local b, by = ir.blocks(rec{
		{"e", set(8, tree.const(ty, 1)), "eff"},
		{"c", auto(8), ".Lskip"},
		{"e", set(16, auto(8)), "eff"},
		{"l", ".Lskip"},
		{"e", auto(16), "eff"},
	})
	local info = ir.liveness(rec{}, b)

	tap.is(#b, 3, "three blocks")
	-- rebuilt with the same record so the analysis sees the trees
	local r2 = rec{
		{"e", set(8, tree.const(ty, 1)), "eff"},
		{"c", auto(8), ".Lskip"},
		{"e", set(16, auto(8)), "eff"},
		{"l", ".Lskip"},
		{"e", auto(16), "eff"},
	}
	local blocks2 = ir.blocks(r2)
	local i2, crosses, used = ir.liveness(r2, blocks2)

	tap.ok(used[8] and used[16], "both slots are seen")
	tap.ok(i2[blocks2[1]].write[8], "the first block writes slot 8")
	tap.ok(next(crosses) == nil, "with no call, nothing crosses one")
end

do
	-- x = 1; f(); use(x)   -- x is live across the call
	local callee = tree.name({size = 8, kind = "ptr", align = 8,
				  name = "f"}, "f")
	local call = tree.node("CALL", ty, callee, nil, {args = {}})
	local r3 = rec{
		{"e", set(8, tree.const(ty, 1)), "eff"},
		{"e", call, "eff"},
		{"e", auto(8), "eff"},
	}
	local b3 = ir.blocks(r3)
	local _, crosses3 = ir.liveness(r3, b3)

	tap.ok(crosses3[8], "a slot touched where a call runs crosses it")
end

tap.done()
