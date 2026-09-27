-- SPDX-License-Identifier: ISC
-- Emitting initialized data, in gas syntax.
--
-- Both targets here speak gas, so this is shared; one that did not would
-- supply its own set through the target table.

local data = {}

local DIR = {[1] = "byte", [2] = "short", [4] = "long", [8] = "quad"}

-- Open an object: its linkage, its section, its alignment and its label.
-- `sec` is what __attribute__((section("..."))) asked for, which a
-- kernel's link script places by name.
-- What a name is worth to another object: "hidden" keeps it out of the
-- dynamic table, so a shared object calls its own and nothing can stand
-- in front of it.
function data.visible(g, name, vis)
	if vis and vis ~= "default" then
		g:write(("\t.%s\t%s\n"):format(vis, name))
	end
end

-- A weak name loses to a strong one of the same spelling, which is how a
-- library offers a definition a program may replace.
function data.weaken(g, name)
	g:write("\t.weak\t" .. name .. "\n")
end

-- A second name for something defined elsewhere.  Nothing is emitted
-- beyond the symbol: the assembler resolves it to the same place.
function data.alias(g, name, target, weak, vis, func)
	g:write(("\t.%s\t%s\n"):format(weak and "weak" or "globl", name))
	data.visible(g, name, vis)
	if func then
		g:write(("\t.type\t%s,@function\n"):format(name))
	end
	g:write(("\t.set\t%s,%s\n"):format(name, target))
end

-- A common symbol: space the linker allocates once for every unit that
-- names it, as -fcommon asks for a tentative definition.
function data.comm(g, name, size, align, vis)
	data.visible(g, name, vis)
	g:write(("\t.comm\t%s,%d,%d\n"):format(name, size, align))
end

function data.obj(g, name, align, static, bss, sec, vis, tls)
	if not static then
		g:write("\t.globl\t" .. name .. "\n")
		data.visible(g, name, vis)
	end
	if tls then
		-- Each thread gets a copy of this section, which the T
		-- flag is what says.
		g:write(("\t.section\t%s,\"awT\",@%s\n")
			:format(bss and ".tbss" or ".tdata",
				bss and "nobits" or "progbits"))
	elseif sec then
		-- A section named by the program holds whatever else the
		-- program put there, so an object with nothing in it
		-- gets its zeros written rather than turning the whole
		-- section into one that holds no bytes.
		g:write(("\t.section\t%s,\"aw\",@progbits\n"):format(sec))
	else
		g:write(bss and "\t.bss\n" or "\t.data\n")
	end
	-- What the name is, which a tool that reads the symbol table
	-- back needs: the kernel's sorttable looks for an object by
	-- name and skips anything that does not say it is one.
	g:write("\t.type\t" .. name .. ",@object\n")
	g:write("\t.balign\t" .. align .. "\n" .. name .. ":\n")
end

-- And how much of it there is, once the bytes are down.
function data.endobj(g, name)
	g:write("\t.size\t" .. name .. ", .-" .. name .. "\n")
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

-- A string with its terminator.  `w` is the width of one character, so a
-- wide literal comes out as one item per character rather than as bytes.
-- `noterm` leaves the terminator off, for an array exactly as long as the
-- characters.
function data.string(g, s, w, noterm)
	if not w or w == 1 then
		g:write("\t.ascii\t\"")
		escape(g, s)
		g:write(noterm and "\"\n" or "\\000\"\n")
		return
	end
	-- A wide string comes as a list of code points; a narrow one as
	-- bytes.
	local list = type(s) == "table"

	for i = 1, #s do
		data.item(g, w, tostring(list and s[i] or s:byte(i)))
	end
	if not noterm then data.item(g, w, "0") end
end

-- A string literal, in read-only data.
function data.stringdef(g, label, s, w)
	g:write(("\t.section\t.rodata\n\t.balign\t%d\n%s:\n")
		:format(w or 1, label))
	data.string(g, s, w)
end

function data.text(g)
	g:write("\t.text\n")
end

return data
