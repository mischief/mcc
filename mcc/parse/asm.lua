-- SPDX-License-Identifier: ISC
-- Inline assembly: reading the statement, its operands and clobbers, and
-- writing the template with the operands filled in.

local tree = require "mcc.tree"
local P = require "mcc.parse.base"
local cf = require "mcc.parse.fold"
local fold = cf.fold
local init = require "mcc.parse.init"
local addrtext = init.addrtext
local words = require "mcc.parse.words"
local IGNORE = words.IGNORE
local INLINEKW = words.INLINEKW

-- The subset a kernel actually writes: a literal template, operands tied to
-- a register, to memory or to an immediate, and a clobber list.  Nothing
-- here has to satisfy a register allocator, because an asm statement is a
-- statement, and at a statement boundary this compiler holds every value in
-- its frame slot: no scratch register is live when one is reached.
function P:asmstmt()
	self:adv()
	local isgoto = false

	-- `asm inline (...)` says the template is smaller than it looks,
	-- which is a hint to an inliner this compiler does not have.
	while self.tok.kind == "volatile" or self.tok.kind == "goto" or
	      self.tok.kind == "inline" or
	      (self.tok.kind == "name" and (IGNORE[self.tok.text] or
					    INLINEKW[self.tok.text])) do
		if self.tok.kind == "goto" then isgoto = true end
		self:adv()
	end
	self:expect("(")
	local text = self:expect("str").text
	local outs, ins, clob = {}, {}, {}

	local function operands(list)
		if self.tok.kind == ":" or self.tok.kind == ")" then return end
		repeat
			local nm
			if self:accept("[") then
				nm = self:expect("name").text
				self:expect("]")
			end
			local c = self:expect("str").text
			self:expect("(")
			local e = self:expression()

			-- An array named as a memory operand is the place
			-- it sits, not a pointer to its first element,
			-- which is what a kernel writes for a bitmap.
			if not (c:find("m", 1, true) and
				e.ty.kind == "array") then
				-- A memory operand wants the place, so
				-- it is read the way an output is: a
				-- value has no address to give the
				-- instruction.
				local ow = self.asmout

				self.asmout = ow or
					c:find("m", 1, true) ~= nil or nil
				e = self:rvalue(e)
				self.asmout = ow
			end
			self:expect(")")
			-- An immediate operand may be an address as well as
			-- a number: `"i" (func)` hands the template a
			-- symbol, which is what an alternative calls.
			-- An operand that has to be a constant may read
			-- what the caller handed a parameter, so long as
			-- nothing has written the parameter since.
			local k = fold(e) or addrtext(e)

			-- A value that has to be a constant may sit in a
			-- slot whose contents are known: a kernel writes
			-- `__auto_type f = A | B;` and then `"i" (f)` for
			-- the flags of a bug table entry.
			if not k and c:find("[inN]") then
				local sub = self:subkonst(e)

				k = fold(sub) or addrtext(sub)
			end
			if not k and c:find("[inN]") and self.inl then
				local a = self:inlsubst(e)

				k = a and (fold(a) or addrtext(a)) or nil
			end
			list[#list + 1] = {c = c, e = e, name = nm,
					   const = k}
		until not self:accept(",")
	end

	-- A template with any colon after it is the extended form, where
	-- `%%` spells a per cent sign even when no operand follows.
	local ext = self.tok.kind == ":"

	local labels = {}

	if self:accept(":") then
		-- An output is read here only to decay an array and to
		-- read out a bit-field; it stays the place it names.
		self.asmout = true
		operands(outs)
		self.asmout = nil
		if self:accept(":") then
			operands(ins)
			if self:accept(":") then
				while self.tok.kind == "str" do
					clob[#clob + 1] = self.tok.text
					self:adv()
					if not self:accept(",") then break end
				end
				-- `asm goto` names the labels the template
				-- may jump to in a fourth group.
				if self:accept(":") then
					repeat
						local nm =
							self:expect("name").text

						labels[#labels + 1] = {
							name = nm,
							sym = self:userlabel(nm)}
					until not self:accept(",")
				end
			end
		end
	end
	if isgoto and #labels == 0 then
		self:err("asm goto needs a label")
	end
	self:expect(")")

	-- An output needs somewhere safe to land: the template leaves it in a
	-- register, and storing it straight into its lvalue could need a
	-- second register and destroy another output.  A frame slot is
	-- the exception -- the machine names it with no register at
	-- all -- and it is most of what a kernel asm writes to.
	for _, o in ipairs(outs) do
		if o.e.op ~= "AUTO" and o.e.op ~= "NAME" and
		   o.e.op ~= "HARD" and o.e.op ~= "INDIR" then
			self:err("an asm output must be an lvalue")
		end
		-- An output the template writes to memory is already
		-- where it belongs and needs no landing place.
		if not o.c:find("m", 1, true) and o.e.op ~= "HARD" then
			if o.e.op == "AUTO" then
				o.direct = true
			elseif o.e.ty.vector then
				-- A vector lands in a slot as wide as it,
				-- and one read too starts from its value.
				o.tmp = self:temp(o.e.ty)
				if o.c:find("+", 1, true) then
					self.g:expr(self:assignto(
						tree.auto(o.e.ty, o.tmp), o.e),
						"eff")
				end
			else
				o.tmp = self:temp()
			end
		end
	end
	-- A vector input in a vector register is read from a frame slot,
	-- so one that is not in one is copied to one first.
	for _, o in ipairs(ins) do
		if o.e.ty.vector and o.c:find("[xv]") and o.e.op ~= "AUTO" then
			local tmp = self:temp(o.e.ty)

			self.g:expr(self:assignto(tree.auto(o.e.ty, tmp), o.e),
				"eff")
			o.e = tree.auto(o.e.ty, tmp)
		end
	end
	-- The outputs are written after the inputs are read, which is
	-- what lets `asm("..." : "=r"(p) : "i"(p))` see the caller's
	-- value on the way in.
	for _, o in ipairs(outs) do self:inlkill(o.e) end
	return tree.node("ASM", self.ty.void, nil, nil,
		{text = text, outs = outs, ins = ins, clob = clob,
		 ext = ext, labels = labels})
end

return {}
