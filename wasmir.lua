-- SPDX-License-Identifier: ISC
-- Instructions, named rather than formatted.
--
-- Other machines format assembly a line at a time, because there the
-- assembly is the product. This says the same thing by name, so a
-- target reads as instructions rather than as tabs. Each answers a
-- string: a value that had to be made and then printed measured seven
-- times slower and a third heavier.

local M = {}

local function op(name, a, b)
	if b ~= nil then return "\t" .. name .. "\t" .. a .. "\t" .. b end
	if a ~= nil then return "\t" .. name .. "\t" .. a end
	return "\t" .. name
end

M.op = op

function M.label(name)
	return name .. ":"
end

-- Write instructions, in order, one to a line. A plain list stands for
-- the instructions in it, so a helper can answer several.
function M.emit(g, ...)
	for i = 1, select("#", ...) do
		local x = select(i, ...)

		if x == nil then
		elseif type(x) == "string" then
			g:write(x .. "\n")
		else
			for _, y in ipairs(x) do M.emit(g, y) end
		end
	end
end

-- ---- the ones a backend says most ----

function M.get(i) return "\tlocal.get\t" .. i end
function M.set(i) return "\tlocal.set\t" .. i end
function M.tee(i) return "\tlocal.tee\t" .. i end
function M.gget(i) return "\tglobal.get\t" .. i end
function M.gset(i) return "\tglobal.set\t" .. i end

function M.konst(ty, v) return "\t" .. ty .. ".const\t" .. v end
function M.load(ty) return "\t" .. ty .. ".load" end
function M.store(ty) return "\t" .. ty .. ".store" end
function M.binop(ty, name) return "\t" .. ty .. "." .. name end

function M.call(sym) return "\tcall\t@" .. sym end
function M.ret() return "\treturn" end

-- A jump, which as/wasm.lua turns into a case of its dispatch loop.
function M.jump(l) return "\tgoto\t" .. l end
function M.jumpif(l) return "\tgoto_if\t" .. l end

-- ---- what a function is wrapped in ----

function M.func(name, linkage)
	return "\t.func\t" .. name .. "\t" .. linkage
end

function M.endfunc() return "\t.endfunc" end

return M
