-- SPDX-License-Identifier: ISC
-- Variable arguments: va_start, va_arg, va_end and va_copy.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local isflt = cf.isflt
local isptr = cf.isptr
local isrec = cf.isrec

-- The address of the state a va_list names, and how big it is.  An
-- array of one gives its own address; one that has decayed to a
-- pointer, which is what a parameter is, gives its value.
function P:valistat(e)
	local t = e.ty

	if t.kind == "array" then
		return self:addrof(e), t.of.size
	end
	if isptr(t) and isrec(t.to) then
		return self:rvalue(e), t.to.size
	end
	self:err("va_copy needs a va_list")
end

-- Only the compiler knows where the argument save area is, so va_start is
-- built here rather than in a header.
function P:vastart()
	self:expect("(")
	local apl = self:assign()
	self:expect(",")
	self:assign()			-- the last named parameter, unused
	self:expect(")")
	if not self.vabase then
		self:err("va_start outside a variadic function")
	end
	-- A va_list that is the system's char * points at the first
	-- variadic argument on the caller's stack.
	if self.t.valistptr then
		local cp = self.ty.ptr(self.ty.i8)

		return tree.binary("ASGN", apl.ty, apl, self:conv(
			tree.unary("ADDR", cp, tree.auto(self.ty.i8,
				self.t.stackargs + self.vastk *
					self.t.ptrsize)), apl.ty))
	end
	local ap = self:rvalue(apl)
	if not isptr(ap.ty) or not isrec(ap.ty.to) then
		self:err("va_start needs a va_list")
	end

	local ps = self.t.ptrsize
	-- None of them, where a variadic function is handed everything
	-- on the stack whatever the convention does otherwise.
	local nreg = self.t.varstack and 0 or self.t.nargreg
	local nflt = self:vaflt()
	local cp = self.ty.ptr(self.ty.i8)

	local function set(field, value)
		local lv = self:member(ap, field, true)
		return tree.binary("ASGN", lv.ty, lv, self:conv(value, lv.ty))
	end
	local function area(off)
		return tree.unary("ADDR", cp, tree.auto(self.ty.i8, off))
	end
	-- The System V save area is one block: six integer registers, then
	-- eight floating point ones two words apart.  An offset into it
	-- says how much of each file the named parameters took.
	if self.t.vaabi == "sysv" then
		return tree.node("SEQ", self.word, nil, nil, {arms = {
			set("gp_offset",
				tree.const(self.word, self.vagp * 8)),
			set("fp_offset",
				tree.const(self.word,
					nreg * 8 + self.vafp * 16)),
			set("overflow_arg_area",
				area(self.t.stackargs + self.vastk * ps)),
			set("reg_save_area", area(self.vabase)),
		}})
	end
	-- The named parameters have already used up part of each file; the
	-- walker starts where they stopped.
	return tree.node("SEQ", self.word, nil, nil, {arms = {
		set("left", tree.const(self.word,
			math.max(0, nreg - self.vagp))),
		set("fleft", tree.const(self.word,
			math.max(0, nflt - self.vafp))),
		set("regs", tree.const(self.word, nreg)),
		set("reg", area(self.vabase + self.vagp * ps)),
		set("freg", area(self.vabase + (nreg + self.vafp) * ps)),
		set("stk", self.t.vastkslot
			and tree.binary("ADD", cp,
				tree.auto(cp, self.vabase + (nreg + nflt) * ps),
				tree.const(self.word, self.vastk * ps))
			or area(self.t.stackargs + self.vastk * ps)),
	}})
end

-- va_arg needs the type, so it is a builtin too: only the compiler can say
-- which register file the value arrived in.
function P:vaarg()
	self:expect("(")
	local apl = self:assign()
	local ap = self:rvalue(apl)
	self:expect(",")
	local ty = self:typename()
	if not ty then self:err("va_arg needs a type") end
	self:expect(")")
	-- 0 an ordinary word, 1 the float file, 2 the extended type,
	-- which is never in a register and is aligned on the stack.
	local flt = 0

	if ty.x87 then
		flt = 2
	elseif self:vaflt() > 0 and isflt(ty) then
		flt = 1
	end
	local p = self.t.vaabi == "sysv" and self:vasysv(ap, ty, flt)

	-- Everything on the caller's stack, each argument in whole words
	-- and none aligned beyond that: the next one is where the walker
	-- stands, and the walker steps over it.  No call, no test.
	if not p and self.t.valistptr then
		local ws = self.t.ptrsize
		local words = (ty.size + ws - 1) // ws

		p = tree.node("POSTADD", self.ty.ptr(self.ty.i8), apl, nil,
			{val = words * ws})
		p = self:conv(p, self.ty.ptr(ty))
	end
	if not p then
		p = self:rtcall("__va_next", self.ty.ptr(ty), {
			ap,
			tree.const(self.word, ty.size),
			tree.const(self.word, flt | self:vaflags(ty)),
		})
		p.soft = nil
	end
	return tree.unary("INDIR", ty, p)
end

-- What the runtime walker needs to know about a type besides its size,
-- as the VA_ flags of rt/varargs.c.  A target that says `vaexact`
-- aligns only what is aligned to two words, hands a big record over by
-- address, and may pass a float record in the float file.
function P:vaflags(ty)
	local ws = self.t.ptrsize
	if not self.t.vaexact then
		return (ty.size + ws - 1) // ws > 1 and 4 or 0
	end
	local f = ty.align >= 2 * ws and 4 or 0
	if isrec(ty) and self.t.eightbytes then
		local pcs = self.t.eightbytes(ty, false)

		if not pcs and self.t.recref then return 8 end
		if pcs and #pcs > 0 and pcs[1].flt and self:vaflt() > 0 then
			f = 1 | (pcs[1].size == 4 and 32 or 0)
		end
	end
	if self.t.vasplit then f = f | 16 end
	return f
end

-- Where the next argument sits, worked out here rather than in a call
-- to the runtime: the size and the register file are both known where
-- the walk is written, so what is left is one test and two additions.
--
-- The System V save area is six integer registers and then eight
-- floating point ones sixteen bytes apart.  An offset past the end of
-- a file means that file is used up and the rest comes off the
-- caller's stack.
local GPEND, FPEND = 48, 176

function P:vasysv(ap, ty, flt)
	local cp = self.ty.ptr(self.ty.i8)
	local pre = {}
	-- The list is named several times and must be worked out once.
	local slot, set = self:pin(self:conv(ap, self.ty.decay(ap.ty)))

	pre[#pre + 1] = set
	local function field(name)
		return self:member(slot(), name, true)
	end
	local words = (ty.size + 7) // 8
	local step = tree.const(self.word, words * 8)
	-- Where the answer goes, so that both arms hand back the same
	-- slot and the caller reads it once.
	local tmp = self:temp(cp)
	local function at() return tree.auto(cp, tmp) end
	local function setat(e)
		return tree.binary("ASGN", cp, at(), self:conv(e, cp))
	end
	local function bump(fld, by)
		local lv = field(fld)

		return tree.binary("ASGN", lv.ty, lv,
			self:conv(tree.binary("ADD", self.word,
				self:conv(field(fld), self.word), by),
				lv.ty))
	end
	-- Off the caller's stack, which is where anything too big for a
	-- register file goes and where the extended type always goes.
	local function stack(align, by)
		local a = field("overflow_arg_area")

		if align then
			a = tree.binary("AND", cp,
				tree.binary("ADD", cp, a,
					tree.const(self.word, 15)),
				tree.const(self.word, ~15))
		end
		return tree.node("SEQ", cp, nil, nil, {arms = {
			setat(a),
			tree.binary("ASGN", cp, field("overflow_arg_area"),
				tree.binary("ADD", cp, at(), by or step)),
			at()}})
	end
	-- A record too big for two registers is handed over in memory,
	-- and so is anything whose class the target cannot work out.
	local how = self.t.argpieces or self.t.eightbytes
	local pcs = isrec(ty) and how and how(ty)
	local mem = isrec(ty) and not pcs
	local nf = 0

	for _, pc in ipairs(pcs or {}) do
		if pc.flt then nf = nf + 1 end
	end
	if flt == 2 then
		pre[#pre + 1] = stack(true, tree.const(self.word, 16))
	elseif mem then
		pre[#pre + 1] = stack(ty.align >= 16, step)
	elseif nf > 0 then
		-- A record with a float piece: each piece is in its own
		-- file, so the pieces are gathered into a copy.
		local u64 = self.ty.u64
		local arr = self.ty.array(u64, #pcs)
		local obj = self:alloc(arr)
		local ni = #pcs - nf
		local arms = {}
		local fits = tree.binary("LE", self.ty.i32,
			self:conv(field("fp_offset"), self.word),
			tree.const(self.word, FPEND - nf * 16))

		if ni > 0 then
			fits = tree.binary("ANDAND", self.ty.i32, fits,
				tree.binary("LE", self.ty.i32,
					self:conv(field("gp_offset"), self.word),
					tree.const(self.word, GPEND - ni * 8)))
		end
		for _, pc in ipairs(pcs) do
			local off = pc.flt and "fp_offset" or "gp_offset"
			local src = tree.binary("ADD", cp, field("reg_save_area"),
				self:conv(field(off), self.word))

			arms[#arms + 1] = tree.binary("ASGN", u64,
				tree.auto(u64, obj + pc.off),
				tree.unary("INDIR", u64,
					self:conv(src, self.ty.ptr(u64))))
			arms[#arms + 1] = bump(off,
				tree.const(self.word, pc.flt and 16 or 8))
		end
		arms[#arms + 1] = setat(self:addrof(tree.auto(arr, obj)))
		arms[#arms + 1] = at()
		pre[#pre + 1] = tree.node("COND", cp, fits, nil,
			{arms = {tree.node("SEQ", cp, nil, nil, {arms = arms}),
				 stack(ty.align >= 16, step)}})
	else
		local off = flt == 1 and "fp_offset" or "gp_offset"
		local last = flt == 1 and FPEND - 16 or GPEND - words * 8
		local by = flt == 1 and tree.const(self.word, 16) or step
		-- A file is used up when the next value would run past
		-- the end of it.
		local fits = tree.binary("LE", self.ty.i32,
			self:conv(field(off), self.word),
			tree.const(self.word, last))
		local inreg = tree.node("SEQ", cp, nil, nil, {arms = {
			setat(tree.binary("ADD", cp,
				field("reg_save_area"),
				self:conv(field(off), self.word))),
			bump(off, by),
			at()}})

		pre[#pre + 1] = tree.node("COND", cp, fits, nil,
			{arms = {inreg, stack(ty.align >= 16, step)}})
	end
	return tree.node("SEQ", self.ty.ptr(ty), nil, nil,
		{arms = {tree.node("SEQ", cp, nil, nil, {arms = pre}),
			 self:conv(at(), self.ty.ptr(ty))}})
end

-- Nothing has to be taken down at the end of a walk over the arguments,
-- and copying one list to another is a copy of the object.  A libc that
-- spells these as builtins gets them here.
function P:vaend()
	self:expect("(")
	local e = self:assign()

	self:expect(")")
	return tree.node("SEQ", self.ty.void, nil, nil,
		{arms = {e, tree.const(self.ty.i32, 0)}})
end

function P:vacopy()
	self:expect("(")
	local d = self:assign()

	self:expect(",")
	local v = self:assign()

	self:expect(")")
	if self.t.valistptr then
		return tree.binary("ASGN", d.ty, d, self:conv(self:rvalue(v),
			d.ty))
	end
	-- A va_list is an array of one, so the copy is of the object
	-- rather than an assignment.  As a parameter it has already
	-- decayed, and then the pointer is the address to copy from
	-- rather than something to take the address of: this is what
	-- every vfprintf in a library does with the va_list it was
	-- handed.
	local da, n = self:valistat(d)
	local va = self:valistat(v)

	return tree.node("COPY", d.ty, da, va, {val = n})
end

return {}
