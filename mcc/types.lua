-- SPDX-License-Identifier: ISC
-- Types and their layout.
--
-- A type is a table: kind, size, align, and whatever the kind needs.  They
-- are made per target, because a pointer's width is the target's business.
--   int    kind int|uint, size
--   ptr    to
--   array  of, n
--   func   ret, params (a list of types), pnames
--   struct kind struct|union, tag, members, byname
--   void

local types = {}

local function round(n, a)
	return ((n + a - 1) // a) * a
end

function types.new(target)
	local ps = target.ptrsize
	local T = {}

	-- What the widest scalar is aligned to.  Most of these machines
	-- align one to its own width; the i386 ABI caps it at four, which
	-- is what makes `struct { int i; double d; }` twelve bytes there.
	local cap = target.maxalign
	-- Whether a zero-width bit-field raises the alignment of the
	-- record around it.  AAPCS64 says it does; the x86 and riscv
	-- ABIs say it names nothing and only moves to the next unit.
	local zerobit = target.zerobitalign
	local function base(name, size, kind)
		local al = (cap and size > cap) and cap or size

		T[name] = {kind = kind, size = size, align = al,
			   name = name}
	end
	base("i8", 1, "int")   base("u8", 1, "uint")
	base("i16", 2, "int")  base("u16", 2, "uint")
	base("i32", 4, "int")  base("u32", 4, "uint")
	base("i64", 8, "int")  base("u64", 8, "uint")
	-- GNU __int128, which on a 64-bit machine is two registers wide
	-- and so goes through the same runtime a 64-bit value does on a
	-- 32-bit one.
	base("i128", 16, "int") base("u128", 16, "uint")
	T.i128.name = "__int128"
	T.u128.name = "unsigned __int128"
	-- _Bool is one byte, unsigned, and holds only 0 or 1: anything
	-- converted to it is compared against zero first.
	base("bool", 1, "uint")
	T.bool.name = "_Bool"
	T.bool.isbool = true
	base("f32", 4, "float")
	base("f64", 8, "float")
	-- binary128, which the glibc headers declare on x86-64 whether or
	-- not anything calls those functions.  A declaration of one parses;
	-- arithmetic on one is refused.
	base("f128", 16, "float")
	T.f128.name = "_Float128"
	-- The two-byte floats.  Arithmetic on one is done in a float; a
	-- value of one is stored, loaded and passed as it is.  `half`
	-- says which: IEEE binary16, or bfloat16, the top of a float.
	base("f16", 2, "float")
	T.f16.name = "_Float16"
	T.f16.half = "hf"
	base("bf16", 2, "float")
	T.bf16.name = "__bf16"
	T.bf16.half = "bf"
	-- The x87 extended type: sixty-four bits of significand in ten
	-- bytes, laid out in sixteen so that an array of them stays
	-- aligned.  It is what the x86-64 ABI calls long double.
	base("f80", 16, "float")
	T.f80.name = "long double"
	T.f80.x87 = true
	-- Which of them `long double` names here.  A machine that has no
	-- wider format than a double says so by leaving it alone.
	T.ldouble = target.ldbl == "f80" and T.f80 or T.f64
	T.void = {kind = "void", size = 1, align = 1, name = "void"}

	local ptrs = setmetatable({}, {__mode = "k"})
	function T.ptr(to)
		local p = ptrs[to]
		if not p then
			p = {kind = "ptr", to = to, size = ps, align = ps,
			     name = "*" .. (to.name or "?")}
			ptrs[to] = p
		end
		return p
	end

	function T.array(of, n)
		return {kind = "array", of = of, n = n,
			size = of.size * (n or 0), align = of.align,
			name = (of.name or "?") .. "[]"}
	end

	-- params is a flat list of types; pnames carries the names, and only
	-- a definition ever reads them.  A table per parameter cost more than
	-- the type it named.
	function T.func(ret, params, variadic, pnames)
		return {kind = "func", ret = ret, params = params,
			variadic = variadic, pnames = pnames,
			size = ps, align = ps, name = "()"}
	end

	-- A tagged type starts incomplete; the members arrive later, which is
	-- what lets a struct hold a pointer to itself.
	function T.record(kind, tag)
		return {kind = kind, tag = tag, size = 0, align = 1,
			name = kind .. " " .. (tag or "?"), incomplete = true}
	end

	-- Layout, counted in bits so a bit-field and an ordinary member can
	-- share the arithmetic.  A bit-field sits inside a unit of its own
	-- declared type and never crosses one; a width of zero names no
	-- member and only moves to the next unit.  A union puts every
	-- member at zero and takes the widest.
	-- `attrs` is what __attribute__ said about the whole record:
	-- `packed` takes the padding out, `aligned` asks for more.
	-- C99 _Complex, as a pair of the base type.  Arithmetic on one is
	-- refused; this is enough for a header to declare a function that
	-- takes or answers with one, and for a program to pass it on.
	local cplx = setmetatable({}, {__mode = "k"})

	function T.complex(of)
		local c = cplx[of]

		if not c then
			c = {kind = "struct", tag = nil, complex = of,
			     size = of.size * 2, align = of.align,
			     name = "_Complex " .. (of.name or "?"),
			     members = {
				{name = "__real", ty = of, off = 0},
				{name = "__imag", ty = of, off = of.size},
			     }}
			c.byname = {__real = c.members[1],
				    __imag = c.members[2]}
			cplx[of] = c
		end
		return c
	end

	-- A GNU vector: `vector_size(n)` over an element type.  It is a
	-- value like a record, n bytes of one member `__v`, an array of
	-- the elements that a subscript reaches.  `vector` names the
	-- element type.  The alignment is the width, capped at 16 like
	-- every other frame slot, unless `aligned` said otherwise.
	local vecs = {}

	function T.vector(of, n, align)
		local key = tostring(of) .. ":" .. n .. ":" .. tostring(align)
		local v = vecs[key]

		if not v then
			local arr = T.array(of, n // of.size)

			v = {kind = "struct", tag = nil, vector = of,
			     size = n, align = align or (n < 16 and n or 16),
			     name = "__vector(" .. n .. ") " ..
				(of.name or "?"),
			     members = {{name = "__v", ty = arr, off = 0}}}
			v.byname = {__v = v.members[1]}
			vecs[key] = v
		end
		return v
	end

	function T.complete(st, members, attrs)
		local packed = attrs and attrs.packed
		-- `#pragma pack(n)`: no member is aligned past n bytes.
		local cap = attrs and attrs.maxalign
		local function capped(a)
			return cap and a > cap and cap or a
		end
		local bit, align = 0, 1
		local out = {}
		st.byname = {}
		for _, m in ipairs(members) do
			local unit = m.ty.size * 8
			-- `aligned` on a member of its own says where the
			-- member starts, and raises the record around it
			-- even when the record is packed.
			local nat = (packed or m.packed) and 1 or
				capped(m.ty.align)
			local ma = nat

			if m.align and m.align > nat then ma = m.align end

			if ma > align and (m.align or not packed) and
			   (m.bits ~= 0 or zerobit or m.align) then
				align = ma
			end
			if m.align and st.kind ~= "union" then
				bit = round(bit, ma * 8)
			end
			if st.kind == "union" then
				m.off, m.bit = 0, m.bits and 0 or nil
				local w = m.bits and
					round(m.bits, 8) // 8 or m.ty.size
				if w > bit then bit = w end
				out[#out + 1] = m
			elseif m.bits == 0 then
				if not packed then
					bit = round(bit, capped(m.ty.align) * 8)
				end
			elseif m.bits then
				-- The unit that holds a bit-field is as wide
				-- as its type's alignment, which is not the
				-- type's width everywhere: i386 aligns a
				-- long long to four.  A field may cover as
				-- many of those units as its type does and
				-- no more; one that would cover another
				-- starts at the next unit.  A field wider
				-- than the unit covers several by nature and
				-- is not moved for it.  packed makes the
				-- unit a byte, and then nothing moves.
				local flat = packed or m.packed or cap == 1
				local ua = flat and 8 or capped(m.ty.align) * 8
				local span = (bit % ua + m.bits + ua - 1)
					     // ua

				if not flat and span > unit // ua then
					bit = round(bit, ua)
				end
				m.off = (bit // ua) * (ua // 8)
				m.bit = bit - m.off * 8
				bit = bit + m.bits
				out[#out + 1] = m
			else
				bit = round(bit, ma * 8)
				m.off = bit // 8
				bit = bit + m.ty.size * 8
				out[#out + 1] = m
			end
			if m.bits == 0 then
				-- names nothing
			elseif m.name then
				st.byname[m.name] = m
			else
				-- An unnamed struct or union member has no
				-- name of its own, so what is inside it is
				-- named directly by the record around it,
				-- at the offset the two together give.
				-- byname, not members: the inner record has
				-- already flattened its own unnamed members.
				for name, im in pairs(m.ty.byname or {}) do
					-- A bit-field keeps where in the
					-- word it sits and how wide it is,
					-- or it lands at the bottom of the
					-- word and writes over its
					-- neighbours.
					st.byname[name] = {
						name = name, ty = im.ty,
						off = m.off + im.off,
						bits = im.bits,
						bit = im.bit,
					}
				end
			end
		end
		st.members = out
		if attrs and attrs.aligned and attrs.aligned ~= true and
		   attrs.aligned > align then
			align = attrs.aligned
		end
		st.align = align
		st.packed = packed or nil
		if st.kind == "union" then
			st.size = round(bit, align)
		else
			st.size = round(round(bit, 8) // 8, align)
		end
		st.incomplete = nil
		return st
	end

	-- Whether two types are the same one, for
	-- __builtin_types_compatible_p.  Names are unique per type here,
	-- so comparing them answers it.
	function T.same(a, b)
		if a == b then return true end
		if a.kind ~= b.kind then return false end
		if a.kind == "ptr" then return T.same(a.to, b.to) end
		if a.kind == "array" then
			return a.n == b.n and T.same(a.of, b.of)
		end
		return a.size == b.size and a.name == b.name
	end

	-- The type an expression of this type decays to when it is used.
	function T.decay(t)
		if t.kind == "array" then return T.ptr(t.of) end
		if t.kind == "func" then return T.ptr(t) end
		return t
	end

	function T.isint(t)
		return t.kind == "int" or t.kind == "uint"
	end

	function T.isfloat(t)
		return t.kind == "float"
	end

	function T.isscalar(t)
		return T.isint(t) or t.kind == "ptr" or t.kind == "float"
	end

	T.ptrsize = ps
	return T
end

return types
