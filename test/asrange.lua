-- SPDX-License-Identifier: ISC
-- Operands at the edge of their fields.  A value just inside must come
-- out as gas writes it.  A value just outside must be an error that
-- names the field, and gas must refuse it too.
--
--   lua5.4 test/asrange.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local as = require "mcc.as"

local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-asrange",
	true)

local function has(p)
	local f = io.popen("command -v '" .. p .. "' 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

local function look(glob)
	local p = io.popen("ls -d " .. glob .. " 2>/dev/null | head -1")
	local d = p:read("l")

	p:close()
	return d
end

local xt = look((os.getenv("ESPTOOLS") or
	(os.getenv("HOME") or "") .. "/.espressif/tools/xtensa-esp-elf") ..
	"/*/xtensa-esp-elf/bin")

-- How each target's gas is run, and the objcopy that takes its code out.
local GAS = {
	amd64 = {"as --64", "objcopy"},
	i386 = {"as --32", "objcopy"},
	riscv64 = {"riscv64-linux-gnu-as -mno-relax -march=rv64imafd",
		   "riscv64-linux-gnu-objcopy"},
	riscv32 = {"riscv64-linux-gnu-as -mno-relax -march=rv32imafd " ..
		   "-mabi=ilp32d", "riscv64-linux-gnu-objcopy"},
	arm64 = {"aarch64-linux-gnu-as", "aarch64-linux-gnu-objcopy"},
	xtensa = xt and {xt .. "/xtensa-esp32s3-elf-as --no-transform",
			 xt .. "/xtensa-esp32s3-elf-objcopy"},
}

local function gasok(t)
	local g = GAS[t]

	return g and has(g[1]:match("^%S+")) and has(g[2])
end

local function slurp(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("a")

	f:close()
	return s
end

-- gas's bytes for the text, or nil when it refuses it.
local function gas(t, text)
	local src, obj, bin = dir .. "/g.s", dir .. "/g.o", dir .. "/g.bin"
	local f = assert(io.open(src, "w"))

	f:write(text, "\n")
	f:close()
	os.remove(obj)
	if os.execute(("%s -o %s %s >/dev/null 2>&1"):format(GAS[t][1], obj,
	    src)) ~= true then
		return nil
	end
	os.execute(("%s -O binary --only-section=.text %s %s"):format(
		GAS[t][2], obj, bin))
	return slurp(bin) or ""
end

local function hex(s)
	return (s:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

-- mas's bytes for the text, or nil and the error.
local function mas(t, text)
	local opt = {arch = t, srcname = "t.s"}

	if t == "riscv32" then opt.xlen = 32 end
	local ok, a = pcall(as.assemble, text .. "\n", opt)

	if not ok then return nil, tostring(a) end
	return a.sec[".text"] and a.sec[".text"].bytes or ""
end

-- {target, line, want}: want is "ok", or a piece of the error, which
-- names the field.  `mas` marks a line gas leaves to the linker, so gas
-- is not asked.
local C = {
	-- the I and S forms: twelve signed bits
	{"riscv64", "addi a0, a1, 2047", "ok"},
	{"riscv64", "addi a0, a1, -2048", "ok"},
	{"riscv64", "addi a0, a1, 2048", "addi immediate 2048 out of range"},
	{"riscv64", "addi a0, a1, -2049", "addi immediate -2049 out of range"},
	{"riscv64", "andi a0, a1, 0xfff", "andi immediate 4095 out of range"},
	{"riscv64", "ld a2, 2047(a1)", "ok"},
	{"riscv64", "ld a2, 2048(a1)", "ld offset 2048 out of range"},
	{"riscv64", "lw a2, -2048(a1)", "ok"},
	{"riscv64", "lw a2, -2049(a1)", "lw offset -2049 out of range"},
	{"riscv64", "sd a2, 2047(a1)", "ok"},
	{"riscv64", "sd a2, 2048(a1)", "sd offset 2048 out of range"},
	{"riscv64", "fsd fa0, -2049(a1)", "fsd offset -2049 out of range"},
	{"riscv64", ".equ K, 2047\nld a0, K(a1)", "ok"},
	{"riscv64", ".equ K, 2047\nld a0, (K+1)(a1)", "ld offset 2048"},
	{"riscv64", "jalr a0, 2047(a1)", "ok"},
	{"riscv64", "jalr a0, 2048(a1)", "jalr offset 2048 out of range"},
	{"riscv64", "jalr a0, a1, -2048", "ok"},
	{"riscv64", "jalr a0, a1, -2049", "jalr offset -2049 out of range"},
	-- shift amounts
	{"riscv64", "slli a0, a1, 63", "ok"},
	{"riscv64", "slli a0, a1, 64", "slli shift amount 64 out of range"},
	{"riscv64", "srai a0, a1, -1", "srai shift amount -1 out of range"},
	{"riscv64", "slliw a0, a1, 31", "ok"},
	{"riscv64", "sraiw a0, a1, 32", "sraiw shift amount 32 out of range"},
	{"riscv32", "slli a0, a1, 31", "ok"},
	{"riscv32", "slli a0, a1, 32", "slli shift amount 32 out of range"},
	-- the upper twenty bits
	{"riscv64", "lui a0, 0xfffff", "ok"},
	{"riscv64", "lui a0, 0x100000", "lui immediate 1048576 out of range"},
	{"riscv64", "auipc a0, -1", "auipc immediate -1 out of range"},
	-- control and status registers
	{"riscv64", "csrrw a0, 4095, a1", "ok"},
	{"riscv64", "csrrw a0, 4096, a1", "csrrw csr 4096 out of range"},
	{"riscv64", "csrrwi a0, fflags, 31", "ok"},
	{"riscv64", "csrrwi a0, fflags, 32", "csr immediate 32 out of range"},
	{"riscv64", "csrwi fflags, -1", "csr immediate -1 out of range"},
	-- branches and jumps, after the distance is known
	{"riscv64", "beq a0, a1, 1f\n.skip 4090\n1: nop\n.skip 2", "ok"},
	{"riscv64", "beq a0, a1, 1f\n.byte 0\n1: nop",
		"beq offset 5 is not a multiple of 2"},
	{"riscv64", "jal 1f\n.skip 1048570\n1: nop\n.skip 2", "ok"},
	{"riscv64", "jal 1f\n.skip 1048572\n1: nop",
		"jal offset 1048576 out of range"},
	{"riscv64", "1: nop\n.skip 1048572\nj 1b", "ok"},
	{"riscv64", "1: nop\n.skip 1048576\nj 1b",
		"j offset -1048580 out of range"},
	{"riscv64", "j 1f\n.skip 1048572\n1: nop",
		"j offset 1048576 out of range"},
	-- li takes any 64-bit value, signed or not
	{"riscv64", "li a0, 0xffffffffffffffff", "ok"},
	{"riscv64", "li a0, 18446744073709551615", "ok"},
	{"riscv64", "li a0, 0x10000000000000000", "wider than 64 bits"},

	-- arm64: an indexed or unscaled offset is nine signed bits
	{"arm64", "ldr x0, [x1, #-256]", "ok"},
	{"arm64", "ldr x0, [x1, #-257]", "ldr offset -257 out of range"},
	{"arm64", "str w0, [x1, #255]!", "ok"},
	{"arm64", "str w0, [x1, #256]!", "str offset 256 out of range"},
	{"arm64", "ldr x0, [x1], #-257", "ldr offset -257 out of range"},
	{"arm64", "ldr x0, [x1, #32760]", "ok"},
	{"arm64", "ldr x0, [x1, #32768]", "ldr offset 32768 out of range"},
	{"arm64", "ldrb w0, [x1, #4095]", "ok"},
	{"arm64", "ldrb w0, [x1, #4096]", "ldrb offset 4096 out of range"},
	{"arm64", "ldrh w0, [x1, #8191]", "ldrh offset 8191 out of range"},
	-- a pair is seven signed bits scaled by its size
	{"arm64", "ldp x0, x1, [sp, #504]", "ok"},
	{"arm64", "ldp x0, x1, [sp, #-512]!", "ok"},
	{"arm64", "ldp x0, x1, [sp, #512]", "ldp offset 512 out of range"},
	{"arm64", "stp x0, x1, [sp, #-520]", "stp offset -520 out of range"},
	{"arm64", "ldp x0, x1, [sp, #4]", "ldp offset 4 is not a multiple"},
	{"arm64", "ldp w0, w1, [sp, #252]", "ok"},
	{"arm64", "ldp w0, w1, [sp, #256]", "ldp offset 256 out of range"},
	-- the wide moves and the shifts by a constant
	{"arm64", "movz x0, #65535, lsl #48", "ok"},
	{"arm64", "movz x0, #65536", "movz immediate 65536 out of range"},
	{"arm64", "movk x0, #-1", "movk immediate -1 out of range"},
	{"arm64", "movz x0, #1, lsl #8", "movz shift amount 8 is not"},
	{"arm64", "movz w0, #1, lsl #16", "ok"},
	{"arm64", "movz w0, #1, lsl #32", "movz shift amount 32 out of range"},
	{"arm64", "lsl x0, x1, #63", "ok"},
	{"arm64", "lsl x0, x1, #64", "lsl shift amount 64 out of range"},
	{"arm64", "asr w0, w1, #31", "ok"},
	{"arm64", "asr w0, w1, #32", "asr shift amount 32 out of range"},
	{"arm64", "lsr x0, x1, #-1", "lsr shift amount -1 out of range"},
	{"arm64", "svc #65535", "ok"},
	{"arm64", "svc #65536", "svc immediate 65536 out of range"},
	-- register numbers
	{"arm64", "add x0, x1, x30", "ok"},
	{"arm64", "add x0, x1, x31", "no register x31"},
	{"arm64", "fadd d0, d1, d31", "ok"},
	{"arm64", "fadd d0, d1, d32", "no register d32"},
	-- branches
	{"arm64", "b.eq 1f\n.skip 1048568\n1: nop", "ok"},
	{"arm64", "b.eq 1f\n.skip 1048572\n1: nop",
		"b.eq offset 1048576 out of range"},
	{"arm64", "b.ne 1f\n.byte 0, 0\n1: nop",
		"b.ne offset 6 is not a multiple of 4"},

	-- amd64: four bytes that a 64-bit operation sign extends
	{"amd64", "addq $0x7fffffff, %rax", "ok"},
	{"amd64", "addq $-0x80000000, %rbx", "ok"},
	{"amd64", "addq $0x80000000, %rax", "immediate 2147483648 out of"},
	{"amd64", "andq $0xffffffff, %rcx", "immediate 4294967295 out of"},
	{"amd64", "cmpq $0x80000000, (%rax)", "immediate 2147483648 out of"},
	{"amd64", "movq $-1, (%rax)", "ok"},
	{"amd64", "movq $0xffffffff, (%rax)", "immediate 4294967295 out of"},
	{"amd64", "testq $0x80000000, %rax", "immediate 2147483648 out of"},
	{"amd64", "imulq $0x80000000, %rax, %rax", "immediate 2147483648"},
	{"amd64", "pushq $-0x80000000", "ok"},
	{"amd64", "pushq $0x80000000", "immediate 2147483648 out of"},
	{"amd64", "imulw $1000, %ax, %ax", "ok"},
	-- a byte that is not the operand's size
	{"amd64", "shl $255, %eax", "ok"},
	{"amd64", "shl $256, %eax", "immediate 256 out of range"},
	{"amd64", "shl $-129, %eax", "immediate -129 out of range"},
	{"amd64", "pshufd $-128, %xmm0, %xmm1", "ok"},
	{"amd64", "pshufd $256, %xmm0, %xmm1", "immediate 256 out of range"},
	{"amd64", "vpshufd $256, %xmm0, %xmm1", "immediate 256 out of range"},
	{"amd64", "btl $256, %eax", "immediate 256 out of range"},
	{"amd64", "int $255", "ok"},
	{"amd64", "int $256", "interrupt number 256 out of range"},
	{"amd64", "int $-1", "interrupt number -1 out of range"},
	{"amd64", "ret $65535", "ok"},
	{"amd64", "ret $65536", "immediate 65536 out of range"},
	{"amd64", "enter $65535, $255", "ok"},
	{"amd64", "enter $65536, $0", "frame size 65536 out of range"},
	{"amd64", "enter $0, $256", "nesting level 256 out of range"},
	-- displacements in a 64-bit address
	{"amd64", "mov 0x7fffffff(%rax), %eax", "ok"},
	{"amd64", "mov 0x80000000(%rax), %eax", "displacement 2147483648 out"},
	{"amd64", "mov -0x80000000(%rax,%rbx,4), %eax", "ok"},
	{"amd64", "mov -0x80000001(%rax,%rbx,4), %eax",
		"displacement -2147483649 out"},
	{"amd64", "lea 0x7fffffff(%rip), %rax", "ok"},
	{"amd64", "lea 0x80000000(%rip), %rax", "displacement 2147483648"},
	{"amd64", "mov 0x7fffffff, %ecx", "ok"},
	{"amd64", "mov 0x80000000, %ecx", "displacement 2147483648 out"},
	-- a fixed address four bytes do not hold, which only the
	-- accumulator can reach
	{"amd64", "mov 0xffffffff, %eax", "ok"},
	{"amd64", "mov %rax, 0x100000000", "ok"},
	{"amd64", "mov %gs:0x80000000, %eax", "ok"},
	-- the scale and the control and debug registers
	{"amd64", "mov (%rax,%rbx,8), %eax", "ok"},
	{"amd64", "mov (%rax,%rbx,3), %eax", "scale 3 is not 1, 2, 4 or 8"},
	{"amd64", "mov %cr15, %rax", "ok"},
	{"amd64", "mov %cr16, %rax", "no register %cr16"},
	{"amd64", "mov %dr16, %rax", "no register %dr16"},
	-- outside long mode gas only warns of a value cut down, and so
	-- these are not errors there
	{"i386", "pushl $0x80000000", "ok"},
	{"i386", "addl $0xffffffff, %eax", "ok"},
	{"i386", "mov 0x80000000(%eax), %eax", "ok"},
	{"i386", "shl $256, %eax", "immediate 256 out of range"},

	-- xtensa
	{"xtensa", "addmi a2, a3, 32512", "ok"},
	{"xtensa", "addmi a2, a3, -32768", "ok"},
	{"xtensa", "addmi a2, a3, 257", "addmi immediate 257 is not a"},
	{"xtensa", "addmi a2, a3, 32768", "addmi by 128"},
	{"xtensa", "ssai 31", "ok"},
	{"xtensa", "ssai 32", "ssai shift amount 32 out of range"},
	{"xtensa", "ssai -1", "ssai shift amount -1 out of range"},
	{"xtensa", "extui a2, a3, 16, 16", "ok"},
	{"xtensa", "extui a2, a3, 16, 17", "extui 16,17"},
	{"xtensa", "l32i a2, a3, 1020", "ok"},
	{"xtensa", "l32i a2, a3, 1024", "offset 1024 out of range"},
	{"xtensa", "l32i a2, a3, 2", "offset 2 out of range"},
	{"xtensa", "rsr a2, 3", "ok"},
	{"xtensa", "rsr a2, 256", "rsr special register 256 out of range",
		"mas"},
	{"xtensa", ".align 4\ncall8 1f\n.skip 524284\n.align 4\n1: retw", "ok",
		"mas"},
	{"xtensa", ".align 4\ncall8 1f\n.skip 524288\n.align 4\n1: retw",
		"call8 offset 131072 out of range", "mas"},
}

for _, c in ipairs(C) do
	local t, text, want, only = c[1], c[2], c[3], c[4]
	local name = t .. ": " .. text:gsub("\n", "; ")
	local got, err = mas(t, text)
	local ref = nil

	if only ~= "mas" and gasok(t) then ref = {gas(t, text)} end
	if want == "ok" then
		if not tap.ok(got ~= nil, name .. " assembles") then
			tap.diag(err)
		elseif ref and not ref[1] then
			tap.ok(false, name .. ": gas refuses it")
		elseif ref and not tap.ok(got == ref[1],
		    name .. " is what gas writes") then
			local i = 1

			while got:byte(i) == ref[1]:byte(i) do i = i + 1 end
			tap.diag(("at byte %d: ours %s, gas %s"):format(i - 1,
				hex(got:sub(i, i + 7)),
				hex(ref[1]:sub(i, i + 7))))
		end
	else
		-- the error names the line it came from
		local ok = got == nil and err:find(want, 1, true) ~= nil and
			err:find("^t%.s:%d+:") ~= nil

		if not tap.ok(ok, name .. " is refused") then
			tap.diag(err or "it assembled")
		end
		if ref then
			tap.ok(ref[1] == nil, name .. ": gas refuses it too")
		end
	end
end

-- Through the driver the error comes out as a compiler's does, and the
-- exit status says so.
local lua = os.getenv("LUA") or "lua5.4"
local src = dir .. "/bad.s"
local f = assert(io.open(src, "w"))

f:write("\tnop\n\tld a2, 2048(a1)\n")
f:close()
local p = io.popen(("%s %s/../drive.lua --target=riscv64 -c -o %s/bad.o " ..
	"%s 2>&1; echo status $?"):format(lua, here, dir, src))
local out = p:read("a")

p:close()
tap.ok(out:find("bad.s:2: error: ld offset 2048 out of range", 1, true) and
	out:find("status 1", 1, true), "the driver names the line and fails")
tap.diag(out)
tap.done()
