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

-- The state a staged compile carries across a pass boundary, as lines
-- of the preprocessed text.  -E proper drops the pragmas that only the
-- parser reads, so the preprocessing pass puts them back.
local function pragmas(src, have)
	local out = {}

	if src:pragmapack() ~= have.pack then
		have.pack = src:pragmapack()
		out[#out + 1] = ("#pragma pack(%s)"):format(have.pack or "")
	end
	local vs, k = src.visstack, 0

	while k < #have.vis and k < #vs and have.vis[k + 1] == vs[k + 1] do
		k = k + 1
	end
	for _ = k + 1, #have.vis do
		out[#out + 1] = "#pragma GCC visibility pop"
	end
	for j = k + 1, #vs do
		out[#out + 1] = "#pragma GCC visibility push(" .. vs[j] .. ")"
	end
	have.vis = table.move(vs, 1, #vs, 1, {})
	return out
end

-- The preprocessor reads no line markers, so a token read back from a
-- staged compile's text stands where the text has it.  Put it back
-- where the marker above it says it came from.
local function remap(src, path)
	local at, files, lines = {}, {}, {}
	local h = assert(io.open(path))
	local n = 0

	for l in h:lines() do
		n = n + 1
		local ln, f = l:match('^# (%d+) "(.*)"$')

		if ln then
			local k = #at + 1

			at[k], files[k], lines[k] = n + 1, f, tonumber(ln)
		end
	end
	h:close()
	local next = src.next

	src.next = function(self)
		local t = next(self)
		local line = t.line

		if line and at[1] and line >= at[1] then
			local lo, hi = 1, #at

			while lo < hi do
				local mid = (lo + hi + 1) // 2

				if at[mid] <= line then lo = mid else hi = mid - 1 end
			end
			t.file, t.line = files[lo], lines[lo] + line - at[lo]
		end
		return t
	end
end

-- .c -> .s
-- `pponly` stops after the preprocessor whatever -E says, which is what
-- an assembly source spelled with a capital S wants.
-- `pass` runs half of this for a staged compile.  Its kind "cpp" writes
-- the preprocessed text and the dependency list, with `name` the output
-- the rule names.  Its kind "cc" reads that text back, with `name` the
-- source it came from.
local function compile(drv, path, out, pponly, pass)
	local o, text = drv.o, drv.text
	local cpppass = pass and pass.kind == "cpp"
	local ccpass = pass and pass.kind == "cc"
	local pp = pponly or o.stop == "E" or cpppass
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
		preinclude = ccpass and {} or o.preinc, stdc = o.stdc,
		freestanding = o.freestanding, prefixmap = o.prefixmap,
		charsigned = drv.charsigned,
		nojoin = pp, asm = pponly, everything = pp}

	if ccpass then remap(src, path) end

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
		-- The text a staged compile reads back keeps its markers,
		-- a space between tokens so none can join, and pragmas.
		-- Assembly goes out as -E writes it either way.
		local faithful = cpppass and not pponly
		local nomarkers = o.nomarkers and not faithful
		local have = faithful and {vis = {}}

		-- A marker for the file itself, before any token.  A
		-- translation unit that is all comments still has to say
		-- which file it came from: autoconf greps for the name.
		if not nomarkers then
			file, line = path, 1
			w:write(('# 1 "%s"\n'):format(path))
		end
		while true do
			local tk = src:next()

			if tk.kind == "eof" then break end
			if have then
				local lines = pragmas(src, have)

				if #lines > 0 then
					w:write("\n", table.concat(lines, "\n"))
					file = nil
				end
			end
			if tk.file ~= file or tk.line < line then
				file, line = tk.file, tk.line
				if not nomarkers then
					w:write(('\n# %d "%s"\n')
						:format(line, file or "-"))
				else
					w:write("\n")
				end
				col = 0
			elseif tk.line > line then
				-- a run of blank lines, up to a point:
				-- past that a marker says where we are
				if tk.line - line > 8 and not nomarkers then
					w:write(('\n# %d "%s"\n')
						:format(tk.line, file or "-"))
				elseif tk.line - line > 8 then
					w:write("\n")
				else
					w:write(("\n"):rep(tk.line - line))
				end
				line, col = tk.line, 0
			elseif col > 0 and (tk.ws or faithful) then
				w:write(" ")
			end
			if tk.kind == "str" and tk.spell or
			   faithful and tk.kind == "num" and tk.spell then
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
		local name = ccpass and pass.name or path
		local dbg = o.debug and require("mcc.dwinfo").new(name,
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
					p.tok.file or name,
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
	if ccpass then return end
	local depfile = o.depfile
	local base = drv.base

	-- the output this pass stands in for, which the rule names
	if cpppass then out = pass.name ~= "" and pass.name or nil end
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
