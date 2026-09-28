-- SPDX-License-Identifier: ISC
-- The compiler proper as the driver runs it: C through the preprocessor
-- and then either written back out, for -E, or through the parser to
-- assembly.  The parser loads only for a unit that goes that far.

local cpp = require "mcc.cpp"
local sys = require "mcc.sys"

-- A string as C would write it: the lexer keeps what the escapes mean,
-- and -E has to put them back.
local ESC = {["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n",
	     ["\t"] = "\\t", ["\r"] = "\\r", ["\f"] = "\\f",
	     ["\v"] = "\\v", ["\a"] = "\\a", ["\b"] = "\\b",
	     ["\0"] = "\\0"}

local function escape(s)
	return (tostring(s or ""):gsub('[%z\1-\31\\"\127-\255]', function(c)
		return ESC[c] or ("\\%03o"):format(c:byte())
	end))
end

-- .c -> .s
-- `pponly` stops after the preprocessor whatever -E says, which is what
-- an assembly source spelled with a capital S wants.
local function compile(drv, path, out, pponly)
	local o, text = drv.o, drv.text
	local pp = pponly or o.stop == "E"
	local w = type(out) == "table" and out or assert(io.open(out, "w"))
	-- `-` is the standard input, which is how a build system asks the
	-- compiler what it defines.
	if path == "-" then
		text["-"] = io.read("a") or ""
	end
	local defs = o.defs

	if pponly then
		defs = {__ASSEMBLER__ = "1"}
		for k, v in pairs(o.defs) do defs[k] = v end
	end
	local src = cpp.new{file = path, path = o.incs, define = defs,
		text = text, keeptext = #o.files > 1 or not o.stop,
		preinclude = o.preinc, stdc = o.stdc,
		freestanding = o.freestanding, prefixmap = o.prefixmap,
		charsigned = drv.charsigned,
		nojoin = pp, asm = pponly, everything = pp}

	-- -dM lists what is defined at the end rather than what came out.
	if o.dumpmacros then
		while src:next().kind ~= "eof" do end
		local names = {}

		for k, m in pairs(src.macros) do
			if k ~= "__LINE__" and k ~= "__FILE__" and
			   k ~= "__COUNTER__" then
				names[#names + 1] = k
			end
		end
		table.sort(names)
		for _, k in ipairs(names) do
			local m = src.macros[k]
			local args = ""

			if m.params then
				local ps = {}
				for j, q in ipairs(m.params) do
					ps[j] = m.variadic and
						j == #m.params and
						(q == "__VA_ARGS__" and "..."
						 or q .. "...") or q
				end
				args = "(" .. table.concat(ps, ",") .. ")"
			end
			w:write("#define ", k, args, " ", m.body or "", "\n")
		end
	elseif o.deponly then
		-- Every file the preprocessor opened, in a make rule.
		-- The tokens go nowhere: reading them is only how the
		-- list is gathered.
		while src:next().kind ~= "eof" do end

		local d = o.depfile and assert(io.open(o.depfile, "w")) or w
		local seen = {}

		d:write(o.deptarget or
			(path:match("([^/]*)%.[^.]*$") or path) .. ".o", ":")
		for _, f in ipairs(src.read) do
			-- standard input is no file a rule can depend on
			if not seen[f] and f ~= "-" and f ~= "<stdin>" then
				seen[f] = true
				d:write(" ", (f:gsub("[ \\]", "\\%0")))
			end
		end
		d:write("\n")
		if d ~= w then d:close() end
	elseif pp then
		-- Preprocessed source as a program would write it: a
		-- token on the line it came from, with the spacing that
		-- separated it.  Tools read this.
		local file, line, col = nil, 0, 0

		-- A marker for the file itself, before any token.  A
		-- translation unit that is all comments still has to say
		-- which file it came from: autoconf greps for the name.
		if not o.nomarkers then
			file, line = path, 1
			w:write(('# 1 "%s"\n'):format(path))
		end
		while true do
			local tk = src:next()

			if tk.kind == "eof" then break end
			if tk.file ~= file or tk.line < line then
				file, line = tk.file, tk.line
				if not o.nomarkers then
					w:write(('\n# %d "%s"\n')
						:format(line, file or "-"))
				else
					w:write("\n")
				end
				col = 0
			elseif tk.line > line then
				-- a run of blank lines, up to a point:
				-- past that a marker says where we are
				if tk.line - line > 8 and not o.nomarkers then
					w:write(('\n# %d "%s"\n')
						:format(tk.line, file or "-"))
				elseif tk.line - line > 8 then
					w:write("\n")
				else
					w:write(("\n"):rep(tk.line - line))
				end
				line, col = tk.line, 0
			elseif col > 0 and tk.ws then
				w:write(" ")
			end
			if tk.kind == "str" and tk.spell then
				w:write(tk.spell)
			elseif tk.kind == "str" then
				w:write(tk.pfx or "", '"',
					tk.raw or escape(tk.text), '"')
			elseif tk.kind == "chr" then
				w:write("'", escape(tk.text or ""), "'")
			else
				w:write(tk.text or tostring(tk.val or
					tk.kind))
			end
			col = col + 1
		end
		w:write("\n")
	else
		-- -m16 is the 32-bit code generator in 16-bit mode, which
		-- is what gcc's own -m16 is and what a kernel's real mode
		-- trampoline is built with.
		if o.bits == 16 then w:write("\t.code16gcc\n") end
		local parse = require "mcc.parse"
		local widert = require "mcc.widert"
		local t = drv.target()
		local dbg = o.debug and require("mcc.dwinfo").new(path,
			sys.getenv("PWD") or ".", t.ptrsize, o.debugmap,
			o.canonmap) or nil

		if dbg then w:write(dbg:start()) end
		local p = parse.new(src, t, function(s) w:write(s) end,
			{wide = sys.getenv("WIDE") ~= nil, pic = o.pic,
			 cmodel = o.cmodel,
			 opt = o.opt, small = o.small,
			 retclean = o.retclean,
			 cet = o.cet, retpoline = o.retpoline,
			 rethunk = o.rethunk, nosse = o.nosse,
			 shortwchar = o.shortwchar,
			 common = o.common,
			 guardsym = o.guardsym, guardfail = o.guardfail,
			 guardreg = o.guardreg,
			 ssp = o.ssp, visibility = o.visibility, dbg = dbg})

		-- An error the parser did not raise itself says nothing
		-- about where it happened, so the token in hand is added.
		local ok, err = pcall(p.program, p)

		if not ok then
			if type(err) == "string" and
			   err:match("^[^\n]*%.lua:%d+: ") then
				err = ("%s:%d: %s"):format(
					p.tok.file or path,
					p.tok.line or 0, err)
			end
			error(err, 0)
		end
		widert.emit(p, function(x) w:write(x) end, t, drv.here,
			{pic = o.pic, cmodel = o.cmodel,
			 opt = o.opt, small = o.small,
			 retclean = o.retclean,
			 cet = o.cet, retpoline = o.retpoline,
			 rethunk = o.rethunk, nosse = o.nosse})
		if t.unitend then
			t.unitend(p.g, function(x) w:write(x) end)
		end
		if dbg then w:write(dbg:finish()) end
		if t.trailer then w:write(t.trailer) end
	end
	w:close()
	-- -MF names a file listing what was read, which a build system
	-- reads to know when to build again.  -MD alone names it after
	-- the object, the way gcc does: `-o x.o` writes x.d, and with no
	-- -o the source's own name ends in .d here.
	local depfile = o.depfile
	local base = drv.base

	if not depfile and o.mdauto then
		depfile = o.out and o.stop == "c" and
			o.out:gsub("%.[^./]*$", "") .. ".d" or base(path) .. ".d"
	end
	if depfile and not o.deponly then
		local d = assert(io.open(depfile, "w"))
		local seen = {}

		d:write(o.deptarget or o.out or
			(type(out) == "string" and out or base(path) .. ".o"),
			":")
		for _, f in ipairs(src.read) do
			-- standard input is no file a rule can depend on
			if not seen[f] and f ~= "-" and f ~= "<stdin>" then
				seen[f] = true
				d:write(" ", (f:gsub("[ \\]", "\\%0")))
			end
		end
		d:write("\n")
		-- -MP: every header is a target of its own with nothing to
		-- do, so deleting one does not stop the build.
		if o.mphony then
			for i, f in ipairs(src.read) do
				if i > 1 and seen[f] then
					seen[f] = nil
					d:write("\n", (f:gsub("[ \\]", "\\%0")),
						":\n")
				end
			end
		end
		d:close()
	end
end

return compile
