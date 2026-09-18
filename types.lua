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

	local function base(name, size, kind)
		T[name] = {kind = kind, size = size, align = size, name = name}
	end
	base("i8", 1, "int")   base("u8", 1, "uint")
	base("i16", 2, "int")  base("u16", 2, "uint")
	base("i32", 4, "int")  base("u32", 4, "uint")
	base("i64", 8, "int")  base("u64", 8, "uint")
	-- _Bool is one byte, unsigned, and holds only 0 or 1: anything
	-- converted to it is compared against zero first.
	base("bool", 1, "uint")
	T.bool.name = "_Bool"
	T.bool.isbool = true
	base("f32", 4, "float")
	base("f64", 8, "float")
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

	function T.complete(st, members)
		local off, align = 0, 1
		st.members = members
		st.byname = {}
		for _, m in ipairs(members) do
			if m.ty.align > align then align = m.ty.align end
			if st.kind == "union" then
				m.off = 0
				if m.ty.size > off then off = m.ty.size end
			else
				off = round(off, m.ty.align)
				m.off = off
				off = off + m.ty.size
			end
			if m.name then
				st.byname[m.name] = m
			else
				-- An unnamed struct or union member has no
				-- name of its own, so what is inside it is
				-- named directly by the record around it,
				-- at the offset the two together give.
				-- byname, not members: the inner record has
				-- already flattened its own unnamed members.
				for name, im in pairs(m.ty.byname or {}) do
					st.byname[name] = {
						name = name, ty = im.ty,
						off = m.off + im.off,
					}
				end
			end
		end
		st.align = align
		st.size = round(off, align)
		st.incomplete = nil
		return st
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
