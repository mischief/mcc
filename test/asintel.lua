-- SPDX-License-Identifier: ISC
-- `.intel_syntax noprefix` against gas: the same lines, the same bytes and
-- the same relocations.  OpenBSD's ptrace regress writes its AVX test this
-- way, and mas stopped at the directive.
--
--   lua5.4 test/asintel.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

if not has("as") or not has("objdump") then
	tap.skipall("no binutils for the Intel syntax differential")
	return
end

local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-asintel")
local src = dir .. "/i.s"
local f = assert(io.open(src, "w"))

f:write([[
	.intel_syntax noprefix
	vmovdqu	ymm0, [rip + .Lymm0]
	vmovdqu	ymm9, [rip + .Lymm0]
	vmovdqu	[rdi + 0x000], ymm0
	vmovdqu	[rdi + 0x1e0], ymm15
	mov	rax, [rbx + rcx*8 + 16]
	mov	eax, dword ptr [rsp]
	mov	dword ptr [rbp - 8], 42
	mov	qword ptr [rax], 0
	add	rax, 5
	sub	esp, 16
	lea	rdi, [rip + .Lymm0]
	movzx	eax, byte ptr [rsi]
	movsx	rcx, word ptr [rdx + 2]
	movsxd	rax, dword ptr [rdi]
	cdqe
	cqo
	xor	eax, eax
	push	rbp
	pop	rbx
	call	rax
	call	qword ptr [rax + 8]
	jmp	.Lymm0
	inc	byte ptr [rdi]
	mov	al, byte ptr fs:[rbx]
	rep	movsb
	lock	add dword ptr [rdi], 1
	fld	qword ptr [rsp]
	mul	QWORD PTR [rcx+8]
	add	r8, QWORD PTR [rcx+16]
	adcx	r8, rax
	adox	r9, rbx
	mulx	rbx, rax, [rsi+8]
	fstp	qword ptr [rsp + 8]
	imul	eax, ecx, 12
	shl	rax, 3
	test	byte ptr [rdi + 4], 1
	movq	xmm0, rax
	ret
	.att_syntax
	movq	%rax,%rbx
	.Lymm0:
	.quad 1
]])
f:close()

local g, m = dir .. "/g.o", dir .. "/m.o"

if not os.execute(("as --64 -o %s %s 2>/dev/null"):format(g, src)) then
	tap.skipall("gas does not take the sample")
	return
end
if not tap.ok(os.execute(("MCC_PROG=mcc %s %s -c -o %s %s >/dev/null 2>&1")
    :format(lua, drive, m, src)), "the sample assembles") then
	tap.done()
	return
end

-- Each instruction's bytes and text, and each relocation, with the
-- address column taken off.
local function lines(obj)
	local p = io.popen(("objdump -dr %s 2>/dev/null"):format(obj))
	local out = {}

	for l in p:lines() do
		local rest = l:match("^%s*[0-9a-f]+:%s+(.*)$")

		if rest then out[#out + 1] = (rest:gsub("%s+$", "")) end
	end
	p:close()
	return out
end

local a, c = lines(g), lines(m)

tap.ok(#a > 0 and #a == #c, ("gas wrote %d lines, ours %d"):format(#a, #c))
for i = 1, math.max(#a, #c) do
	if not tap.ok(a[i] == c[i], "intel: " .. (a[i] or c[i] or "?")) then
		tap.diag(("  gas  %s\n  ours %s"):format(a[i] or "-",
			c[i] or "-"))
	end
end
tap.done()
