-- SPDX-License-Identifier: ISC
-- A WebAssembly module, written as bytes.
--
-- This stands where as/<arch>.lua and ld.lua do for other targets, and
-- is smaller than either: no relaxation, no relocations, no link step.
-- Calls go by index and data is a segment.

local OP = require "wasmops"

local M = {}

local schar, srep = string.char, string.rep
local concat = table.concat

-- ---- numbers ----

local function uleb(v)
	local out = {}

	repeat
		local b = v & 0x7f

		v = v >> 7
		if v ~= 0 then b = b | 0x80 end
		out[#out + 1] = schar(b)
	until v == 0
	return concat(out)
end

local function sleb(v)
	local out = {}

	while true do
		local b = v & 0x7f
		local sign = b & 0x40

		v = v >> 7
		if v == -1 then v = -1 end	-- Lua's >> is logical
		if (v == 0 and sign == 0) or (v == -1 and sign ~= 0) then
			out[#out + 1] = schar(b)
			return concat(out)
		end
		out[#out + 1] = schar(b | 0x80)
	end
end

-- Lua shifts right logically, so a negative value has to be brought
-- down by arithmetic instead.
local function sleb64(v)
	local out = {}

	while true do
		local b = v & 0x7f
		local sign = b & 0x40

		v = (v < 0) and ~((~v) >> 7) or (v >> 7)
		if (v == 0 and sign == 0) or (v == -1 and sign ~= 0) then
			out[#out + 1] = schar(b)
			return concat(out)
		end
		out[#out + 1] = schar(b | 0x80)
	end
end

M.uleb, M.sleb = uleb, sleb64

local function name(s)
	return uleb(#s) .. s
end

local function vec(t)
	return uleb(#t) .. concat(t)
end

-- ---- types ----

local VT = { i32 = 0x7f, i64 = 0x7e, f32 = 0x7d, f64 = 0x7c,
	funcref = 0x70, externref = 0x6f }

M.VT = VT

local function valtype(t)
	return schar(VT[t] or error("no value type " .. tostring(t)))
end

-- ---- instructions ----

-- How each opcode's immediates are written. Anything absent takes
-- none, which is most of them.
local IMM = {
	["local.get"] = "u", ["local.set"] = "u", ["local.tee"] = "u",
	["global.get"] = "u", ["global.set"] = "u",
	["br"] = "u", ["br_if"] = "u", ["call"] = "u",
	["i32.const"] = "s", ["i64.const"] = "S",
	["f32.const"] = "f", ["f64.const"] = "d",
	["block"] = "b", ["loop"] = "b", ["if"] = "b",
	["br_table"] = "t", ["call_indirect"] = "c",
	["memory.size"] = "z", ["memory.grow"] = "z",
}

for k in pairs(OP) do
	if k:match("%.load") or k:match("%.store") then IMM[k] = "m" end
end

-- a block type: nothing, one value, or an index into the type section
local function blocktype(b)
	if b == nil or b == "void" then return "\x40" end
	if VT[b] then return valtype(b) end
	return sleb(b)
end

-- One instruction. `a` and `b` are its immediates, whose meaning the
-- opcode decides: an index, a constant, a block type, or the align and
-- offset pair a memory access takes.
function M.instr(op, a, b)
	local code = OP[op] or error("no opcode for " .. tostring(op))
	local k = IMM[op]

	if not k then return schar(code) end
	if k == "u" then return schar(code) .. uleb(a) end
	if k == "s" then return schar(code) .. sleb(a) end
	if k == "S" then return schar(code) .. sleb64(a) end
	if k == "b" then return schar(code) .. blocktype(a) end
	if k == "z" then return schar(code) .. "\0" end
	if k == "m" then
		-- align is a power of two and the natural one is right for
		-- everything here, so it is derived rather than passed
		return schar(code) .. uleb(a or 0) .. uleb(b or 0)
	end
	if k == "c" then
		return schar(code) .. uleb(a) .. uleb(b or 0)
	end
	if k == "t" then
		local labels = {}

		for _, l in ipairs(a) do labels[#labels + 1] = uleb(l) end
		return schar(code) .. vec(labels) .. uleb(b)
	end
	if k == "f" then
		return schar(code) .. string.pack("<f", a)
	end
	if k == "d" then
		return schar(code) .. string.pack("<d", a)
	end
	error("unhandled immediate " .. k)
end

-- ---- the module ----

local Mod = {}
Mod.__index = Mod

function M.new()
	return setmetatable({
		types = {}, typeidx = {},
		imports = {}, nimport = 0,
		funcs = {}, exports = {},
		data = {}, globals = {},
		elems = {}, tablesize = 0,
		mem = nil,
		start = nil,
	}, Mod)
end

-- Types are interned: a module holding one signature twice is a module
-- that says it twice, and nothing gains by that.
function Mod:type(params, results)
	local key = concat(params, ",") .. "->" .. concat(results, ",")
	local at = self.typeidx[key]

	if at then return at end
	local body = {}

	for _, p in ipairs(params) do body[#body + 1] = valtype(p) end
	local ps = vec(body)

	body = {}
	for _, r in ipairs(results) do body[#body + 1] = valtype(r) end

	self.types[#self.types + 1] = "\x60" .. ps .. vec(body)
	at = #self.types - 1
	self.typeidx[key] = at
	return at
end

-- An imported function takes the first indices, as the format wants,
-- so every import must be declared before any definition.
function Mod:import(module, field, typeidx)
	if #self.funcs > 0 then
		error("imports come before definitions")
	end
	self.imports[#self.imports + 1] =
	    name(module) .. name(field) .. "\x00" .. uleb(typeidx)
	self.nimport = self.nimport + 1
	return self.nimport - 1
end

-- `locals` is a list of {count, type}; `code` the instruction bytes,
-- without the end that closes the body.
function Mod:func(typeidx, locals, code)
	local decl = {}

	for _, l in ipairs(locals) do
		decl[#decl + 1] = uleb(l[1]) .. valtype(l[2])
	end
	self.funcs[#self.funcs + 1] = {
		type = typeidx,
		body = vec(decl) .. code .. schar(OP["end"]),
	}
	return self.nimport + #self.funcs - 1
end

function Mod:export(nm, kind, idx)
	local K = { func = 0, table = 1, memory = 2, global = 3 }

	self.exports[#self.exports + 1] =
	    name(nm) .. schar(K[kind]) .. uleb(idx)
end

function Mod:memory(min, max)
	self.mem = max and ("\x01" .. uleb(min) .. uleb(max))
	    or ("\x00" .. uleb(min))
end

function Mod:global(ty, mutable, init)
	self.globals[#self.globals + 1] =
	    valtype(ty) .. schar(mutable and 1 or 0) .. init ..
	    schar(OP["end"])
	return #self.globals - 1
end

function Mod:segment(offset, bytes)
	self.data[#self.data + 1] = "\x00" ..
	    M.instr("i32.const", offset) .. schar(OP["end"]) ..
	    uleb(#bytes) .. bytes
end

-- The function table, for a call through a pointer. Entries are
-- function indices and the index into this table is what a pointer
-- holds.
function Mod:table(entries)
	self.tablesize = #entries
	if #entries == 0 then return end
	local idx = {}

	for _, f in ipairs(entries) do idx[#idx + 1] = uleb(f) end
	self.elems[#self.elems + 1] = "\x00" ..
	    M.instr("i32.const", 0) .. schar(OP["end"]) .. vec(idx)
end

local function section(id, body)
	if body == nil or body == "" then return "" end
	return schar(id) .. uleb(#body) .. body
end

function Mod:emit()
	local out = { "\0asm", "\1\0\0\0" }

	out[#out + 1] = section(1, #self.types > 0 and vec(self.types) or nil)
	out[#out + 1] = section(2, #self.imports > 0 and vec(self.imports) or nil)

	if #self.funcs > 0 then
		local t = {}

		for _, f in ipairs(self.funcs) do t[#t + 1] = uleb(f.type) end
		out[#out + 1] = section(3, vec(t))
	end

	if self.tablesize > 0 then
		out[#out + 1] = section(4,
		    vec({ "\x70\x00" .. uleb(self.tablesize) }))
	end

	out[#out + 1] = section(5, self.mem and vec({ self.mem }) or nil)
	out[#out + 1] = section(6, #self.globals > 0 and vec(self.globals) or nil)
	out[#out + 1] = section(7, #self.exports > 0 and vec(self.exports) or nil)
	out[#out + 1] = section(9, #self.elems > 0 and vec(self.elems) or nil)

	if #self.funcs > 0 then
		local t = {}

		for _, f in ipairs(self.funcs) do
			t[#t + 1] = uleb(#f.body) .. f.body
		end
		out[#out + 1] = section(10, vec(t))
	end

	out[#out + 1] = section(11, #self.data > 0 and vec(self.data) or nil)
	return concat(out)
end

return M
