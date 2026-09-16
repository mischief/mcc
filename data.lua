-- Emitting initialized data, in gas syntax.
--
-- Both targets here speak gas, so this is shared; one that did not would
-- supply its own set through the target table.

local data = {}

local DIR = {[1] = "byte", [2] = "short", [4] = "long", [8] = "quad"}

-- Open an object: its linkage, its section, its alignment and its label.
function data.obj(g, name, align, static, bss)
	if not static then
		g:write("\t.globl\t" .. name .. "\n")
	end
	g:write(bss and "\t.bss\n" or "\t.data\n")
	g:write("\t.balign\t" .. align .. "\n" .. name .. ":\n")
end

function data.item(g, size, text)
	g:write("\t." .. (DIR[size] or "quad") .. "\t" .. text .. "\n")
end

function data.zero(g, n)
	if n > 0 then
		g:write("\t.zero\t" .. n .. "\n")
	end
end

local function escape(g, s)
	for i = 1, #s do
		local c = s:byte(i)
		if c == 34 or c == 92 then
			g:write("\\" .. s:sub(i, i))
		elseif c < 32 or c > 126 then
			g:write(("\\%03o"):format(c))
		else
			g:write(s:sub(i, i))
		end
	end
end

-- A string with its terminator.
function data.string(g, s)
	g:write("\t.ascii\t\"")
	escape(g, s)
	g:write("\\000\"\n")
end

-- A string literal, in read-only data.
function data.stringdef(g, label, s)
	g:write("\t.section\t.rodata\n\t.balign\t1\n" .. label .. ":\n")
	data.string(g, s)
end

function data.text(g)
	g:write("\t.text\n")
end

return data
