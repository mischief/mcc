-- SPDX-License-Identifier: ISC
-- A wasm module is made whole from the text of every unit, so the
-- driver keeps each unit's text here until the module is written.

local M = {}

-- each unit's text, renamed, in the order the units came
local wasmtext = {}
M.text = wasmtext
-- the first line of a wasm object, which is otherwise assembly text
M.OBJ = "\t.wasmobj\n"

-- A module is one namespace, and every unit names its own strings and
-- jump targets .L1. Give each unit its own set before they are joined.
-- Renaming touches names, not the text of a string: a unit that has a
-- static called `match` also has the word "match" in a table of names,
-- and only the first of those may change.
local function outsidestrings(text, f)
	local out = {}

	for line in text:gmatch("[^\n]*") do
		local at = line:find('"', 1, true)

		if at then
			out[#out + 1] = f(line:sub(1, at - 1)) ..
			    line:sub(at)
		else
			out[#out + 1] = f(line)
		end
	end
	return table.concat(out, "\n")
end

function M.scope(text)
	local n = #wasmtext + 1

	text = outsidestrings(text, function(s)
		return (s:gsub("%.L([%w_.]*)", function(rest)
			return ("%%L%d_%s"):format(n, rest)
		end):gsub("%%L", ".L"))
	end)

	-- A module is one namespace and C is not: `static` gives a
	-- function file scope, so two units may each define `getS` and
	-- mean different code. Give this unit's own names to itself.
	local mine = {}

	for name in ("\n" .. text):gmatch("\n%s*%.func%s+(%S+)%s+static") do
		mine[name] = ("%s$%d"):format(name, n)
	end
	-- and its static objects: a name typed as an object that the
	-- unit never made global
	local global = {}

	for name in ("\n" .. text):gmatch("\n%s*%.globl%s+([%w_$.]+)") do
		global[name] = true
	end
	for name in ("\n" .. text):gmatch("\n%s*%.weak%s+([%w_$.]+)") do
		global[name] = true
	end
	for name in ("\n" .. text):gmatch("\n%s*%.type%s+([%w_$.]+),@object") do
		if not global[name] and not name:match("^%.L") then
			mine[name] = ("%s$%d"):format(name, n)
		end
	end
	if not next(mine) then return text end

	return outsidestrings(text, function(s)
		return (s:gsub("([%w_$.]+)", function(w)
			return mine[w]
		end))
	end)
end

return M
