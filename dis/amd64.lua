-- SPDX-License-Identifier: ISC
-- amd64, from bytes back to text.
--
-- The tables are the Intel maps read the other way: one entry per
-- opcode, naming the instruction and how its operands are spelled.
-- The output is what objdump prints, so the two can be compared.

local amd64 = {}

local R64 = {[0] = "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
	     "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}
local R32 = {[0] = "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi",
	     "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"}
local R16 = {[0] = "ax", "cx", "dx", "bx", "sp", "bp", "si", "di",
	     "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"}
local R8 = {[0] = "al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil",
	    "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"}
-- Without a REX byte the four high halves stand where spl and its
-- fellows otherwise do.
local R8L = {[0] = "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"}

local SEGREG = {[0] = "es", "cs", "ss", "ds", "fs", "gs", "?", "?"}
local SEGPFX = {[0x26] = "es", [0x2e] = "cs", [0x36] = "ss",
		[0x3e] = "ds", [0x64] = "fs", [0x65] = "gs"}

local CC = {[0] = "o", "no", "b", "ae", "e", "ne", "be", "a",
	    "s", "ns", "p", "np", "l", "ge", "le", "g"}

local SUF = {[1] = "b", [2] = "w", [4] = "l", [8] = "q"}

local function gpr(n, size, rex)
	if size == 8 then return R64[n] end
	if size == 4 then return R32[n] end
	if size == 2 then return R16[n] end
	return rex and R8[n] or R8L[n & 7]
end

-- tables ----------------------------------------------------------------

-- The eight arithmetic operations, in the order the opcode numbers them.
local G1 = {[0] = "add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"}
local G2 = {[0] = "rol", "ror", "rcl", "rcr", "shl", "shr", "shl", "sar"}
local G3b = {[0] = {"test", "Eb,Ib"}, {"test", "Eb,Ib"}, "not", "neg",
	     "mul", "imul", "div", "idiv"}
local G3v = {[0] = {"test", "Ev,Iz"}, {"test", "Ev,Iz"}, "not", "neg",
	     "mul", "imul", "div", "idiv"}
local G8 = {[0] = "?", "?", "?", "?", "bt", "bts", "btr", "btc"}

-- inc, dec and the indirect jumps.  A call or a jump through a place is
-- written with a star, and defaults to the whole register in long mode.
local G5 = {[0] = "inc", "dec",
	    {"call", "Ev", d64 = true, ind = true},
	    {"lcall", "Mp", ind = true, nosuf = true},
	    {"jmp", "Ev", d64 = true, ind = true},
	    {"ljmp", "Mp", ind = true, nosuf = true},
	    {"push", "Ev", d64 = true}, "?"}

local G6 = {[0] = {"sldt", "Ev", nosuf = true},
	    {"str", "Ev", nosuf = true}, {"lldt", "Ev", nosuf = true},
	    {"ltr", "Ev", nosuf = true}, {"verr", "Ev", nosuf = true},
	    {"verw", "Ev", nosuf = true}, "?", "?"}
local G6F2 = {[6] = {"lkgs", "Ev", nosuf = true}}

local G7 = {[0] = {"sgdt", "Ms", nosuf = true},
	    {"sidt", "Ms", nosuf = true},
	    {"lgdt", "Ms", nosuf = true},
	    {"lidt", "Ms", nosuf = true}, {"smsw", "Ev"},
	    {"rstorssp", "Mq", nosuf = true},
	    {"lmsw", "Ew"}, {"invlpg", "Mb", nosuf = true}}

-- The ones behind 0f 01 that name no place: the modrm byte is the whole
-- instruction.
local G7M3 = {
	[0xc1] = "vmcall", [0xc2] = "vmlaunch", [0xc3] = "vmresume",
	[0xc4] = "vmxoff", [0xc8] = "monitor", [0xc9] = "mwait",
	[0xca] = "clac", [0xcb] = "stac", [0xcf] = "encls",
	[0xd0] = "xgetbv", [0xd1] = "xsetbv", [0xd4] = "vmfunc",
	[0xd5] = "xend", [0xd6] = "xtest", [0xd8] = "vmrun",
	[0xda] = "vmload", [0xdb] = "vmsave", [0xdc] = "stgi",
	[0xdd] = "clgi", [0xde] = "skinit", [0xdf] = "invlpga",
	[0xe8] = "serialize", [0xee] = "rdpkru", [0xef] = "wrpkru",
	[0xf8] = "swapgs", [0xf9] = "rdtscp", [0xfa] = "monitorx",
	[0xfb] = "mwaitx", [0xea] = "saveprevssp",
	[0xfe] = "invlpgb", [0xff] = "tlbsync", [0xd9] = "vmmcall",
}
-- The two that name the registers they read, which no other member of
-- the group does.
local G7ARG = {[0xc8] = {"monitor", {"%rax", "%ecx", "%edx"}},
	       [0xc9] = {"mwait", {"%eax", "%ecx"}},
	       [0xfa] = {"monitorx", {"%rax", "%ecx", "%edx"}},
	       [0xfb] = {"mwaitx", {"%eax", "%ecx", "%ebx"}}}

local G9 = {[0] = "?", {"cmpxchg8b", "Mq", wide = "cmpxchg16b"}, "?",
	    {"xrstors", "M", w64 = true}, {"xsavec", "M", w64 = true},
	    {"xsaves", "M", w64 = true}, {"rdrand", "Rv"},
	    {"rdseed", "Rv"}}

local G15 = {[0] = {"fxsave", "M", w64 = true},
	     {"fxrstor", "M", w64 = true},
	     {"ldmxcsr", "Md", nosuf = true},
	     {"stmxcsr", "Md", nosuf = true},
	     {"xsave", "M", w64 = true}, {"xrstor", "M", w64 = true},
	     {"xsaveopt", "M", w64 = true},
	     {"clflush", "Mb", nosuf = true}}
local G15M3 = {[0xe8] = "lfence", [0xf0] = "mfence", [0xf8] = "sfence"}
-- Behind a 66 the same slots wait on a timer rather than on memory.
local G1566 = {[6] = {"tpause", "Ry", nosuf = true}}
-- With an f3 in front the same slots read and write the two bases a
-- thread's storage is found through.
local G15F3 = {[0] = {"rdfsbase", "Ry"}, {"rdgsbase", "Ry"},
	       {"wrfsbase", "Ry"}, {"wrgsbase", "Ry"}, "?",
	       {"incssp", "Rv", dq = true}, "?", "?"}

local G16 = {[0] = {"prefetchnta", "Mb", nosuf = true},
	     {"prefetcht0", "Mb", nosuf = true},
	     {"prefetcht1", "Mb", nosuf = true},
	     {"prefetcht2", "Mb", nosuf = true}, "?", "?", "?", "?"}

local G12 = {[0] = "?", "?", {"psrlw", "Nq,Ib", p66 = "Ux,Ib"}, "?",
	     {"psraw", "Nq,Ib", p66 = "Ux,Ib"}, "?",
	     {"psllw", "Nq,Ib", p66 = "Ux,Ib"}, "?"}
local G13 = {[0] = "?", "?", {"psrld", "Nq,Ib", p66 = "Ux,Ib"}, "?",
	     {"psrad", "Nq,Ib", p66 = "Ux,Ib"}, "?",
	     {"pslld", "Nq,Ib", p66 = "Ux,Ib"}, "?"}
local G14 = {[0] = "?", "?", {"psrlq", "Nq,Ib", p66 = "Ux,Ib"},
	     {"psrldq", "Ux,Ib"}, "?", "?",
	     {"psllq", "Nq,Ib", p66 = "Ux,Ib"}, {"pslldq", "Ux,Ib"}}

-- The one-byte map.  A slot with nothing in it is an opcode this
-- machine has no instruction for in long mode.
local M1 = {
	[0x00] = {"add", "Eb,Gb"}, {"add", "Ev,Gv"}, {"add", "Gb,Eb"},
	{"add", "Gv,Ev"}, {"add", "AL,Ib"}, {"add", "rAX,Iz"},
	nil, nil,
	{"or", "Eb,Gb"}, {"or", "Ev,Gv"}, {"or", "Gb,Eb"},
	{"or", "Gv,Ev"}, {"or", "AL,Ib"}, {"or", "rAX,Iz"},
	nil, nil,
}
local function fill(at, m)
	M1[at] = {m, "Eb,Gb"}
	M1[at + 1] = {m, "Ev,Gv"}
	M1[at + 2] = {m, "Gb,Eb"}
	M1[at + 3] = {m, "Gv,Ev"}
	M1[at + 4] = {m, "AL,Ib"}
	M1[at + 5] = {m, "rAX,Iz"}
end
for i, m in ipairs{"adc", "sbb", "and", "sub", "xor", "cmp"} do
	fill(0x10 + (i - 1) * 8, m)
end

for i = 0, 7 do
	M1[0x50 + i] = {"push", "Zv", d64 = true}
	M1[0x58 + i] = {"pop", "Zv", d64 = true}
end
for i = 0, 15 do
	M1[0x70 + i] = {"j" .. CC[i], "Jb", jcc = true}
end
for i = 0, 7 do
	M1[0xb0 + i] = {"mov", "Zb,Ib"}
	M1[0xb8 + i] = {"mov", "Zv,Iv", abs64 = true}
	if i > 0 then M1[0x90 + i] = {"xchg", "Zv,rAX"} end
	M1[0xd8 + i] = {"x87", ""}
end

M1[0x63] = {"movslq", "Gv,Ed", movsx = true}
M1[0x68] = {"push", "Iz", d64 = true}
M1[0x69] = {"imul", "Gv,Ev,Iz"}
M1[0x6a] = {"push", "Ibs", d64 = true}
M1[0x6b] = {"imul", "Gv,Ev,Ibs"}
M1[0x6c] = {"ins", "Yb,DXm", str = true}
M1[0x6d] = {"ins", "Yz,DXm", str = true}
M1[0x6e] = {"outs", "DXm,Xb", str = true}
M1[0x6f] = {"outs", "DXm,Xz", str = true}
M1[0x80] = {G1, "Eb,Ib"}
M1[0x81] = {G1, "Ev,Iz"}
M1[0x83] = {G1, "Ev,Ibs"}
M1[0x84] = {"test", "Eb,Gb"}
M1[0x85] = {"test", "Ev,Gv"}
M1[0x86] = {"xchg", "Eb,Gb"}
M1[0x87] = {"xchg", "Ev,Gv"}
M1[0x88] = {"mov", "Eb,Gb"}
M1[0x89] = {"mov", "Ev,Gv"}
M1[0x8a] = {"mov", "Gb,Eb"}
M1[0x8b] = {"mov", "Gv,Ev"}
M1[0x8c] = {"mov", "Ev,Sw", nosuf = true}
M1[0x8d] = {"lea", "Gv,M"}
M1[0x8e] = {"mov", "Sw,Ev", nosuf = true}
M1[0x8f] = {{[0] = {"pop", "Ev", d64 = true}}, "Ev"}
M1[0x90] = {"nop", "", nop90 = true}
M1[0x98] = {"cltq", "", sized = {[2] = "cbtw", [4] = "cwtl", [8] = "cltq"}}
M1[0x99] = {"cqto", "", sized = {[2] = "cwtd", [4] = "cltd", [8] = "cqto"}}
M1[0x9b] = {"fwait", ""}
M1[0x9c] = {"pushf", "", d64 = true, sized = {[2] = "pushfw",
	    [8] = "pushf"}}
M1[0x9d] = {"popf", "", d64 = true, sized = {[2] = "popfw", [8] = "popf"}}
M1[0x9e] = {"sahf", ""}
M1[0x9f] = {"lahf", ""}
M1[0xa0] = {"movabs", "AL,Ob", nosuf = true}
M1[0xa1] = {"movabs", "rAX,Ov", nosuf = true}
M1[0xa2] = {"movabs", "Ob,AL", nosuf = true}
M1[0xa3] = {"movabs", "Ov,rAX", nosuf = true}
M1[0xa4] = {"movs", "Yb,Xb", str = true}
M1[0xa5] = {"movs", "Yv,Xv", str = true}
M1[0xa6] = {"cmps", "Xb,Yb", str = true}
M1[0xa7] = {"cmps", "Xv,Yv", str = true}
M1[0xa8] = {"test", "AL,Ib"}
M1[0xa9] = {"test", "rAX,Iz"}
M1[0xaa] = {"stos", "Yb,AL", str = true}
M1[0xab] = {"stos", "Yv,rAX", str = true}
M1[0xac] = {"lods", "AL,Xb", str = true}
M1[0xad] = {"lods", "rAX,Xv", str = true}
M1[0xae] = {"scas", "AL,Yb", str = true}
M1[0xaf] = {"scas", "rAX,Yv", str = true}
M1[0xc0] = {G2, "Eb,Ib"}
M1[0xc1] = {G2, "Ev,Ib"}
M1[0xc2] = {"ret", "Iw", d64 = true, ret = true}
M1[0xc3] = {"ret", "", ret = true}
M1[0xc6] = {{[0] = {"mov", "Eb,Ib"}, [7] = {"xabort", "Ib"}}, "Eb,Ib"}
M1[0xc7] = {{[0] = {"mov", "Ev,Iz"}, [7] = {"xbegin", "Jz"}}, "Ev,Iz"}
M1[0xc8] = {"enter", "Iw,Ib"}
M1[0xc9] = {"leave", "", d64 = true}
M1[0xca] = {"lret", "Iw"}
M1[0xcb] = {"lret", "", ret = true}
M1[0xcc] = {"int3", ""}
M1[0xcd] = {"int", "Ib"}
M1[0xcf] = {"iret", "", ret = true, sized = {[2] = "iretw", [4] = "iret",
	    [8] = "iretq"}}
M1[0xd0] = {G2, "Eb,1"}
M1[0xd1] = {G2, "Ev,1"}
M1[0xd2] = {G2, "Eb,CL"}
M1[0xd3] = {G2, "Ev,CL"}
M1[0xd6] = {"udb", ""}
M1[0xd7] = {"xlat", ""}
M1[0xe0] = {"loopne", "Jb", jcc = true}
M1[0xe1] = {"loope", "Jb", jcc = true}
M1[0xe2] = {"loop", "Jb", jcc = true}
M1[0xe3] = {"jrcxz", "Jb", jcc = true}
M1[0xe4] = {"in", "AL,Ib"}
M1[0xe5] = {"in", "eAX,Ib"}
M1[0xe6] = {"out", "Ib,AL"}
M1[0xe7] = {"out", "Ib,eAX"}
M1[0xe8] = {"call", "Jz", call = true}
M1[0xe9] = {"jmp", "Jz", jmp = true}
M1[0xeb] = {"jmp", "Jb", jmp = true}
M1[0xec] = {"in", "AL,DXm"}
M1[0xed] = {"in", "eAX,DXm"}
M1[0xee] = {"out", "DXm,AL"}
M1[0xef] = {"out", "DXm,eAX"}
M1[0xf1] = {"int1", ""}
M1[0xf4] = {"hlt", ""}
M1[0xf5] = {"cmc", ""}
M1[0xf6] = {G3b, "Eb"}
M1[0xf7] = {G3v, "Ev"}
M1[0xf8] = {"clc", ""}
M1[0xf9] = {"stc", ""}
M1[0xfa] = {"cli", ""}
M1[0xfb] = {"sti", ""}
M1[0xfc] = {"cld", ""}
M1[0xfd] = {"std", ""}
M1[0xfe] = {{[0] = "inc", [1] = "dec"}, "Eb"}
M1[0xff] = {G5, "Ev"}

-- The two-byte map, behind 0f.  A slot that names four instructions is
-- one the mandatory prefix picks between: none, 66, f3, f2.
local M0F = {}

for i = 0, 15 do
	M0F[0x40 + i] = {"cmov" .. CC[i], "Gv,Ev"}
	M0F[0x80 + i] = {"j" .. CC[i], "Jz", jcc = true}
	M0F[0x90 + i] = {"set" .. CC[i], "Eb", nosuf = true}
end
for i = 0, 7 do M0F[0xc8 + i] = {"bswap", "Zv"} end

M0F[0x00] = {G6, "Ev", f2 = G6F2}
M0F[0x01] = {G7, "M", m3 = G7M3}
M0F[0x02] = {"lar", "Gv,Ew"}
M0F[0x03] = {"lsl", "Gv,Ew"}
M0F[0x05] = {"syscall", ""}
M0F[0x06] = {"clts", ""}
M0F[0x07] = {"sysret", "", sized = {[4] = "sysretl",
	     [8] = "sysretq"}}
M0F[0x08] = {"invd", ""}
M0F[0x09] = {"wbinvd", ""}
M0F[0x0b] = {"ud2", ""}
M0F[0x0d] = {{[0] = {"prefetch", "Mb"}, {"prefetchw", "Mb"}}, "Mb"}
M0F[0x18] = {G16, "Mb"}
for i = 0x19, 0x1f do M0F[i] = {"nop", "Ev", nopw = true} end
M0F[0x1e] = {"nop", "Ev", nopw = true,
	     pf3 = {"endbr", "", endbr = true}}
M0F[0x20] = {"mov", "Rq,Cd"}
M0F[0x21] = {"mov", "Rq,Dd"}
M0F[0x22] = {"mov", "Cd,Rq"}
M0F[0x23] = {"mov", "Dd,Rq"}
M0F[0x30] = {"wrmsr", ""}
M0F[0x31] = {"rdtsc", ""}
M0F[0x32] = {"rdmsr", ""}
M0F[0x33] = {"rdpmc", ""}
M0F[0x34] = {"sysenter", ""}
M0F[0x35] = {"sysexit", ""}
M0F[0xa0] = {"push", "FS", d64 = true}
M0F[0xa1] = {"pop", "FS", d64 = true}
M0F[0xa2] = {"cpuid", ""}
M0F[0xa3] = {"bt", "Ev,Gv"}
M0F[0xa4] = {"shld", "Ev,Gv,Ib"}
M0F[0xa5] = {"shld", "Ev,Gv,CL"}
M0F[0xa8] = {"push", "GS", d64 = true}
M0F[0xa9] = {"pop", "GS", d64 = true}
M0F[0xaa] = {"rsm", ""}
M0F[0xab] = {"bts", "Ev,Gv"}
M0F[0xac] = {"shrd", "Ev,Gv,Ib"}
M0F[0xad] = {"shrd", "Ev,Gv,CL"}
M0F[0xae] = {G15, "M", m3 = G15M3, f3 = G15F3, p66g = G1566}
M0F[0xaf] = {"imul", "Gv,Ev"}
M0F[0xb0] = {"cmpxchg", "Eb,Gb"}
M0F[0xb1] = {"cmpxchg", "Ev,Gv"}
M0F[0xb2] = {"lss", "Gv,Mp"}
M0F[0xb3] = {"btr", "Ev,Gv"}
M0F[0xb4] = {"lfs", "Gv,Mp"}
M0F[0xb5] = {"lgs", "Gv,Mp"}
M0F[0xb6] = {"movz", "Gv,Eb", movsx = true}
M0F[0xb7] = {"movz", "Gv,Ew", movsx = true}
M0F[0xb8] = {nil, nil, pf3 = {"popcnt", "Gv,Ev"}}
M0F[0xb9] = {"ud1", "Gv,Ev"}
M0F[0xba] = {G8, "Ev,Ib"}
M0F[0xbb] = {"btc", "Ev,Gv"}
M0F[0xbc] = {"bsf", "Gv,Ev", pf3 = {"tzcnt", "Gv,Ev"}}
M0F[0xbd] = {"bsr", "Gv,Ev", pf3 = {"lzcnt", "Gv,Ev"}}
M0F[0xbe] = {"movs", "Gv,Eb", movsx = true}
M0F[0xbf] = {"movs", "Gv,Ew", movsx = true}
M0F[0xc0] = {"xadd", "Eb,Gb"}
M0F[0xc1] = {"xadd", "Ev,Gv"}
M0F[0xc3] = {"movnti", "Md,Gy"}
M0F[0xc7] = {G9, "Mq"}

-- The floating point and vector part of the 0f map.  Each entry is the
-- four readings of the same opcode, by the prefix in front of it.
local function sse(op, np, p66, pf3, pf2)
	local e = {np and np[1], np and np[2]}

	-- Whatever else the no-prefix reading said about itself.
	for k, v in pairs(np or {}) do
		if type(k) == "string" then e[k] = v end
	end
	e.p66, e.pf3, e.pf2, e.sse = p66, pf3, pf2, true
	M0F[op] = e
end

sse(0x10, {"movups", "Vx,Wx"}, {"movupd", "Vx,Wx"},
    {"movss", "Vd,Wd", h = 3}, {"movsd", "Vq,Wq", h = 3})
sse(0x11, {"movups", "Wx,Vx"}, {"movupd", "Wx,Vx"},
    {"movss", "Wd,Vd", h = 3}, {"movsd", "Wq,Vq", h = 3})
sse(0x12, {"movlps", "Vq,Mq", h = 2, r3 = {"movhlps", "Vq,Ux"}},
    {"movlpd", "Vq,Mq", h = 2}, {"movsldup", "Vx,Wx"},
    {"movddup", "Vx,Wx"})
sse(0x13, {"movlps", "Mq,Vq"}, {"movlpd", "Mq,Vq"})
sse(0x14, {"unpcklps", "Vx,Wx"}, {"unpcklpd", "Vx,Wx"})
sse(0x15, {"unpckhps", "Vx,Wx"}, {"unpckhpd", "Vx,Wx"})
sse(0x16, {"movhps", "Vq,Mq", h = 2, r3 = {"movlhps", "Vq,Ux"}},
    {"movhpd", "Vq,Mq", h = 2}, {"movshdup", "Vx,Wx"})
sse(0x17, {"movhps", "Mq,Vq"}, {"movhpd", "Mq,Vq"})
sse(0x28, {"movaps", "Vx,Wx"}, {"movapd", "Vx,Wx"})
sse(0x29, {"movaps", "Wx,Vx"}, {"movapd", "Wx,Vx"})
sse(0x2a, {"cvtpi2ps", "Vq,Qq"}, {"cvtpi2pd", "Vx,Qq"},
    {"cvtsi2ss", "Vd,Ey"}, {"cvtsi2sd", "Vq,Ey"})
sse(0x2b, {"movntps", "Mx,Vx"}, {"movntpd", "Mx,Vx"})
sse(0x2c, {"cvttps2pi", "Pq,Wq"}, {"cvttpd2pi", "Pq,Wx"},
    {"cvttss2si", "Gy,Wd"}, {"cvttsd2si", "Gy,Wq"})
sse(0x2d, {"cvtps2pi", "Pq,Wq"}, {"cvtpd2pi", "Pq,Wx"},
    {"cvtss2si", "Gy,Wd"}, {"cvtsd2si", "Gy,Wq"})
sse(0x2e, {"ucomiss", "Vd,Wd"}, {"ucomisd", "Vq,Wq"})
sse(0x2f, {"comiss", "Vd,Wd"}, {"comisd", "Vq,Wq"})
sse(0x50, {"movmskps", "Gy,Ux"}, {"movmskpd", "Gy,Ux"})
sse(0x51, {"sqrtps", "Vx,Wx"}, {"sqrtpd", "Vx,Wx"},
    {"sqrtss", "Vd,Wd"}, {"sqrtsd", "Vq,Wq"})
sse(0x52, {"rsqrtps", "Vx,Wx"}, nil, {"rsqrtss", "Vd,Wd"})
sse(0x53, {"rcpps", "Vx,Wx"}, nil, {"rcpss", "Vd,Wd"})
sse(0x54, {"andps", "Vx,Wx"}, {"andpd", "Vx,Wx"})
sse(0x55, {"andnps", "Vx,Wx"}, {"andnpd", "Vx,Wx"})
sse(0x56, {"orps", "Vx,Wx"}, {"orpd", "Vx,Wx"})
sse(0x57, {"xorps", "Vx,Wx"}, {"xorpd", "Vx,Wx"})
sse(0x58, {"addps", "Vx,Wx"}, {"addpd", "Vx,Wx"},
    {"addss", "Vd,Wd"}, {"addsd", "Vq,Wq"})
sse(0x59, {"mulps", "Vx,Wx"}, {"mulpd", "Vx,Wx"},
    {"mulss", "Vd,Wd"}, {"mulsd", "Vq,Wq"})
sse(0x5a, {"cvtps2pd", "Vx,Wq"}, {"cvtpd2ps", "Vx,Wx"},
    {"cvtss2sd", "Vq,Wd"}, {"cvtsd2ss", "Vd,Wq"})
sse(0x5b, {"cvtdq2ps", "Vx,Wx"}, {"cvtps2dq", "Vx,Wx"},
    {"cvttps2dq", "Vx,Wx"})
sse(0x5c, {"subps", "Vx,Wx"}, {"subpd", "Vx,Wx"},
    {"subss", "Vd,Wd"}, {"subsd", "Vq,Wq"})
sse(0x5d, {"minps", "Vx,Wx"}, {"minpd", "Vx,Wx"},
    {"minss", "Vd,Wd"}, {"minsd", "Vq,Wq"})
sse(0x5e, {"divps", "Vx,Wx"}, {"divpd", "Vx,Wx"},
    {"divss", "Vd,Wd"}, {"divsd", "Vq,Wq"})
sse(0x5f, {"maxps", "Vx,Wx"}, {"maxpd", "Vx,Wx"},
    {"maxss", "Vd,Wd"}, {"maxsd", "Vq,Wq"})
sse(0x60, {"punpcklbw", "Pq,Qd"}, {"punpcklbw", "Vx,Wx"})
sse(0x61, {"punpcklwd", "Pq,Qd"}, {"punpcklwd", "Vx,Wx"})
sse(0x62, {"punpckldq", "Pq,Qd"}, {"punpckldq", "Vx,Wx"})
sse(0x63, {"packsswb", "Pq,Qq"}, {"packsswb", "Vx,Wx"})
sse(0x64, {"pcmpgtb", "Pq,Qq"}, {"pcmpgtb", "Vx,Wx"})
sse(0x65, {"pcmpgtw", "Pq,Qq"}, {"pcmpgtw", "Vx,Wx"})
sse(0x66, {"pcmpgtd", "Pq,Qq"}, {"pcmpgtd", "Vx,Wx"})
sse(0x67, {"packuswb", "Pq,Qq"}, {"packuswb", "Vx,Wx"})
sse(0x68, {"punpckhbw", "Pq,Qq"}, {"punpckhbw", "Vx,Wx"})
sse(0x69, {"punpckhwd", "Pq,Qq"}, {"punpckhwd", "Vx,Wx"})
sse(0x6a, {"punpckhdq", "Pq,Qq"}, {"punpckhdq", "Vx,Wx"})
sse(0x6b, {"packssdw", "Pq,Qq"}, {"packssdw", "Vx,Wx"})
sse(0x6c, nil, {"punpcklqdq", "Vx,Wx"})
sse(0x6d, nil, {"punpckhqdq", "Vx,Wx"})
sse(0x6e, {"movd", "Pq,Ey", wq = true}, {"movd", "Vy,Ey", wq = true})
sse(0x6f, {"movq", "Pq,Qq"}, {"movdqa", "Vx,Wx"},
    {"movdqu", "Vx,Wx"})
sse(0x70, {"pshufw", "Pq,Qq,Ib"}, {"pshufd", "Vx,Wx,Ib"},
    {"pshufhw", "Vx,Wx,Ib"}, {"pshuflw", "Vx,Wx,Ib"})
M0F[0x71] = {G12, "Nq,Ib", ndd = true}
M0F[0x72] = {G13, "Nq,Ib", ndd = true}
M0F[0x73] = {G14, "Nq,Ib", ndd = true}
sse(0x74, {"pcmpeqb", "Pq,Qq"}, {"pcmpeqb", "Vx,Wx"})
sse(0x75, {"pcmpeqw", "Pq,Qq"}, {"pcmpeqw", "Vx,Wx"})
sse(0x76, {"pcmpeqd", "Pq,Qq"}, {"pcmpeqd", "Vx,Wx"})
sse(0x77, {"emms", ""})
sse(0x7c, nil, {"haddpd", "Vx,Wx"}, nil, {"haddps", "Vx,Wx"})
sse(0x7d, nil, {"hsubpd", "Vx,Wx"}, nil, {"hsubps", "Vx,Wx"})
sse(0x7e, {"movd", "Ey,Pq", wq = true},
    {"movd", "Ey,Vy", wq = true}, {"movq", "Vq,Wq"})
sse(0x7f, {"movq", "Qq,Pq"}, {"movdqa", "Wx,Vx"},
    {"movdqu", "Wx,Vx"})
sse(0xc2, {"cmpps", "Vx,Wx,Ib"}, {"cmppd", "Vx,Wx,Ib"},
    {"cmpss", "Vd,Wd,Ib"}, {"cmpsd", "Vq,Wq,Ib"})
sse(0xc4, {"pinsrw", "Pq,Ew,Ib"}, {"pinsrw", "Vx,Ew,Ib"})
sse(0xc5, {"pextrw", "Gd,Nq,Ib"}, {"pextrw", "Gd,Ux,Ib"})
sse(0xc6, {"shufps", "Vx,Wx,Ib"}, {"shufpd", "Vx,Wx,Ib"})
sse(0xd0, nil, {"addsubpd", "Vx,Wx"}, nil, {"addsubps", "Vx,Wx"})
sse(0xd1, {"psrlw", "Pq,Qq"}, {"psrlw", "Vx,Wx"})
sse(0xd2, {"psrld", "Pq,Qq"}, {"psrld", "Vx,Wx"})
sse(0xd3, {"psrlq", "Pq,Qq"}, {"psrlq", "Vx,Wx"})
sse(0xd4, {"paddq", "Pq,Qq"}, {"paddq", "Vx,Wx"})
sse(0xd5, {"pmullw", "Pq,Qq"}, {"pmullw", "Vx,Wx"})
sse(0xd6, nil, {"movq", "Wq,Vq"})
sse(0xd7, {"pmovmskb", "Gd,Nq"}, {"pmovmskb", "Gd,Ux"})
sse(0xd8, {"psubusb", "Pq,Qq"}, {"psubusb", "Vx,Wx"})
sse(0xd9, {"psubusw", "Pq,Qq"}, {"psubusw", "Vx,Wx"})
sse(0xda, {"pminub", "Pq,Qq"}, {"pminub", "Vx,Wx"})
sse(0xdb, {"pand", "Pq,Qq"}, {"pand", "Vx,Wx"})
sse(0xdc, {"paddusb", "Pq,Qq"}, {"paddusb", "Vx,Wx"})
sse(0xdd, {"paddusw", "Pq,Qq"}, {"paddusw", "Vx,Wx"})
sse(0xde, {"pmaxub", "Pq,Qq"}, {"pmaxub", "Vx,Wx"})
sse(0xdf, {"pandn", "Pq,Qq"}, {"pandn", "Vx,Wx"})
sse(0xe0, {"pavgb", "Pq,Qq"}, {"pavgb", "Vx,Wx"})
sse(0xe1, {"psraw", "Pq,Qq"}, {"psraw", "Vx,Wx"})
sse(0xe2, {"psrad", "Pq,Qq"}, {"psrad", "Vx,Wx"})
sse(0xe3, {"pavgw", "Pq,Qq"}, {"pavgw", "Vx,Wx"})
sse(0xe4, {"pmulhuw", "Pq,Qq"}, {"pmulhuw", "Vx,Wx"})
sse(0xe5, {"pmulhw", "Pq,Qq"}, {"pmulhw", "Vx,Wx"})
sse(0xe6, nil, {"cvttpd2dq", "Vx,Wx"}, {"cvtdq2pd", "Vx,Wq"},
    {"cvtpd2dq", "Vx,Wx"})
sse(0xe7, {"movntq", "Mq,Pq"}, {"movntdq", "Mx,Vx"})
sse(0xe8, {"psubsb", "Pq,Qq"}, {"psubsb", "Vx,Wx"})
sse(0xe9, {"psubsw", "Pq,Qq"}, {"psubsw", "Vx,Wx"})
sse(0xea, {"pminsw", "Pq,Qq"}, {"pminsw", "Vx,Wx"})
sse(0xeb, {"por", "Pq,Qq"}, {"por", "Vx,Wx"})
sse(0xec, {"paddsb", "Pq,Qq"}, {"paddsb", "Vx,Wx"})
sse(0xed, {"paddsw", "Pq,Qq"}, {"paddsw", "Vx,Wx"})
sse(0xee, {"pmaxsw", "Pq,Qq"}, {"pmaxsw", "Vx,Wx"})
sse(0xef, {"pxor", "Pq,Qq"}, {"pxor", "Vx,Wx"})
sse(0xf1, {"psllw", "Pq,Qq"}, {"psllw", "Vx,Wx"})
sse(0xf2, {"pslld", "Pq,Qq"}, {"pslld", "Vx,Wx"})
sse(0xf3, {"psllq", "Pq,Qq"}, {"psllq", "Vx,Wx"})
sse(0xf4, {"pmuludq", "Pq,Qq"}, {"pmuludq", "Vx,Wx"})
sse(0xf5, {"pmaddwd", "Pq,Qq"}, {"pmaddwd", "Vx,Wx"})
sse(0xf6, {"psadbw", "Pq,Qq"}, {"psadbw", "Vx,Wx"})
sse(0xf7, {"maskmovq", "Pq,Nq"}, {"maskmovdqu", "Vx,Ux"})
sse(0xf8, {"psubb", "Pq,Qq"}, {"psubb", "Vx,Wx"})
sse(0xf9, {"psubw", "Pq,Qq"}, {"psubw", "Vx,Wx"})
sse(0xfa, {"psubd", "Pq,Qq"}, {"psubd", "Vx,Wx"})
sse(0xfb, {"psubq", "Pq,Qq"}, {"psubq", "Vx,Wx"})
sse(0xfc, {"paddb", "Pq,Qq"}, {"paddb", "Vx,Wx"})
sse(0xfd, {"paddw", "Pq,Qq"}, {"paddw", "Vx,Wx"})
sse(0xfe, {"paddd", "Pq,Qq"}, {"paddd", "Vx,Wx"})

-- The three-byte maps.  Almost everything here needs a 66 in front,
-- because that is how the vector forms are told from the old MMX ones.
local M38, M3A = {}, {}

local function v66(map, op, m, ops, np)
	map[op] = {np and m or nil, np and ops or nil,
		   p66 = {m, ops}, sse = true}
end

for op, m in pairs{[0x00] = "pshufb", [0x01] = "phaddw",
		   [0x02] = "phaddd", [0x03] = "phaddsw",
		   [0x04] = "pmaddubsw", [0x05] = "phsubw",
		   [0x06] = "phsubd", [0x07] = "phsubsw",
		   [0x08] = "psignb", [0x09] = "psignw",
		   [0x0a] = "psignd", [0x0b] = "pmulhrsw",
		   [0x1c] = "pabsb", [0x1d] = "pabsw",
		   [0x1e] = "pabsd"} do
	M38[op] = {m, "Pq,Qq", p66 = {m, "Vx,Wx"}, sse = true}
end
for op, m in pairs{[0x10] = "pblendvb", [0x14] = "blendvps",
		   [0x15] = "blendvpd", [0x17] = "ptest",
		   [0x1c] = nil, [0x28] = "pmuldq",
		   [0x29] = "pcmpeqq", [0x2b] = "packusdw",
		   [0x37] = "pcmpgtq", [0x38] = "pminsb",
		   [0x39] = "pminsd", [0x3a] = "pminuw",
		   [0x3b] = "pminud", [0x3c] = "pmaxsb",
		   [0x3d] = "pmaxsd", [0x3e] = "pmaxuw",
		   [0x3f] = "pmaxud", [0x40] = "pmulld",
		   [0x41] = "phminposuw"} do
	v66(M38, op, m, "Vx,Wx")
end
for op, m in pairs{[0x20] = "pmovsxbw", [0x21] = "pmovsxbd",
		   [0x22] = "pmovsxbq", [0x23] = "pmovsxwd",
		   [0x24] = "pmovsxwq", [0x25] = "pmovsxdq",
		   [0x30] = "pmovzxbw", [0x31] = "pmovzxbd",
		   [0x32] = "pmovzxbq", [0x33] = "pmovzxwd",
		   [0x34] = "pmovzxwq", [0x35] = "pmovzxdq"} do
	v66(M38, op, m, "Vx,Wq")
end
v66(M38, 0x2a, "movntdqa", "Vx,Mx")
v66(M38, 0x82, "invpcid", "Gq,Mx")
-- One element spread over the whole register.
for op, m in pairs{[0x18] = "broadcastss", [0x19] = "broadcastsd",
		   [0x1a] = "broadcastf128", [0x58] = "pbroadcastd",
		   [0x59] = "pbroadcastq", [0x78] = "pbroadcastb",
		   [0x79] = "pbroadcastw"} do
	v66(M38, op, m, "Vx,Wq")
end
-- A mask made by testing, which only an EVEX encodes.
v66(M38, 0x26, "ptestm", "Kr,Hx,Wx")
v66(M38, 0x27, "ptestm", "Kr,Hx,Wx")
M38[0xf0] = {"movbe", "Gv,Mv", p66 = {"movbe", "Gw,Mw"},
	     pf2 = {"crc32", "Gy,Eb"}, sse = true}
M38[0xf1] = {"movbe", "Mv,Gv", p66 = {"movbe", "Mw,Gw"},
	     pf2 = {"crc32", "Gy,Ev"}, sse = true}
-- The bit manipulation instructions, which carry no 66 and reach a
-- general register through VEX.
M38[0xf3] = {{[1] = {"blsr", "By,Ey"}, [2] = {"blsmsk", "By,Ey"},
	      [3] = {"blsi", "By,Ey"}}, "By,Ey", vexonly = true}
M38[0xf7] = {"bextr", "Gy,Ey,By", vexonly = true,
	     p66 = {"shlx", "Gy,Ey,By"}, pf3 = {"sarx", "Gy,Ey,By"},
	     pf2 = {"shrx", "Gy,Ey,By"}, sse = true}
M38[0xf2] = {"andn", "Gy,By,Ey", vexonly = true}
M38[0xf5] = {"bzhi", "Gy,Ey,By", vexonly = true,
	     pf3 = {"pext", "Gy,By,Ey"}, pf2 = {"pdep", "Gy,By,Ey"},
	     sse = true}
M38[0xf6] = {nil, nil, pf2 = {"mulx", "Gy,By,Ey"}, sse = true}

v66(M3A, 0x08, "roundps", "Vx,Wx,Ib")
v66(M3A, 0x09, "roundpd", "Vx,Wx,Ib")
v66(M3A, 0x0a, "roundss", "Vd,Wd,Ib")
v66(M3A, 0x0b, "roundsd", "Vq,Wq,Ib")
v66(M3A, 0x0c, "blendps", "Vx,Wx,Ib")
v66(M3A, 0x0d, "blendpd", "Vx,Wx,Ib")
v66(M3A, 0x0e, "pblendw", "Vx,Wx,Ib")
M3A[0x0f] = {"palignr", "Pq,Qq,Ib", p66 = {"palignr", "Vx,Wx,Ib"},
	     sse = true}
v66(M3A, 0x14, "pextrb", "Eb,Vx,Ib")
v66(M3A, 0x15, "pextrw", "Ew,Vx,Ib")
v66(M3A, 0x16, "pextr", "Ey,Vy,Ib")
v66(M3A, 0x17, "extractps", "Ed,Vd,Ib")
v66(M3A, 0x20, "pinsrb", "Vx,Eb,Ib")
v66(M3A, 0x21, "insertps", "Vx,Wd,Ib")
v66(M3A, 0x22, "pinsr", "Vy,Ey,Ib")
M3A[0x06] = {nil, nil, p66 = {"perm2f128", "Vx,Hx,Wx,Ib"}, sse = true}
for op, m in pairs{[0x18] = "insertf128", [0x38] = "inserti128"} do
	M3A[op] = {nil, nil, p66 = {m, "Vx,Hx,Wh,Ib"}, sse = true}
end
for op, m in pairs{[0x19] = "extractf128", [0x39] = "extracti128"} do
	M3A[op] = {nil, nil, p66 = {m, "Wh,Vx,Ib"}, sse = true}
end
M3A[0x46] = {nil, nil, p66 = {"perm2i128", "Vx,Hx,Wx,Ib"}, sse = true}
v66(M3A, 0x40, "dpps", "Vx,Wx,Ib")
v66(M3A, 0x41, "dppd", "Vx,Wx,Ib")
v66(M3A, 0x42, "mpsadbw", "Vx,Wx,Ib")
v66(M3A, 0x44, "pclmulqdq", "Vx,Wx,Ib")
v66(M3A, 0x60, "pcmpestrm", "Vx,Wx,Ib")
v66(M3A, 0x61, "pcmpestri", "Vx,Wx,Ib")
v66(M3A, 0x62, "pcmpistrm", "Vx,Wx,Ib")
v66(M3A, 0x63, "pcmpistri", "Vx,Wx,Ib")
M3A[0xf0] = {nil, nil, pf2 = {"rorx", "Gy,Ey,Ib"}, sse = true}

-- The AES and SHA instructions, which a kernel's crypto uses.
for op, m in pairs{[0xdb] = "aesimc", [0xdc] = "aesenc",
		   [0xdd] = "aesenclast", [0xde] = "aesdec",
		   [0xdf] = "aesdeclast"} do
	v66(M38, op, m, "Vx,Wx")
end
v66(M3A, 0xdf, "aeskeygenassist", "Vx,Wx,Ib")
for op, m in pairs{[0xc8] = "sha1nexte", [0xc9] = "sha1msg1",
		   [0xca] = "sha1msg2", [0xcb] = "sha256rnds2",
		   [0xcc] = "sha256msg1", [0xcd] = "sha256msg2"} do
	M38[op] = {m, "Vx,Wx", sse = true}
end
M38[0xcb] = {"sha256rnds2", "Vx,Wx,XMM0", sse = true}
M3A[0xcc] = {"sha1rnds4", "Vx,Wx,Ib", sse = true}

-- x87, whose opcode is the modrm byte as much as the d8..df in front.
-- A memory form names the width in the mnemonic; a register form is
-- one of the thirty-two in the second table.
local X87M = {
	[0xd8] = {[0] = "fadds", "fmuls", "fcoms", "fcomps", "fsubs",
		  "fsubrs", "fdivs", "fdivrs"},
	[0xd9] = {[0] = "flds", "?", "fsts", "fstps", "fldenv", "fldcw",
		  "fnstenv", "fnstcw"},
	[0xda] = {[0] = "fiaddl", "fimull", "ficoml", "ficompl", "fisubl",
		  "fisubrl", "fidivl", "fidivrl"},
	[0xdb] = {[0] = "fildl", "fisttpl", "fistl", "fistpl", "?",
		  "fldt", "?", "fstpt"},
	[0xdc] = {[0] = "faddl", "fmull", "fcoml", "fcompl", "fsubl",
		  "fsubrl", "fdivl", "fdivrl"},
	[0xdd] = {[0] = "fldl", "fisttpll", "fstl", "fstpl", "frstor",
		  "?", "fnsave", "fnstsw"},
	[0xde] = {[0] = "fiadds", "fimuls", "ficoms", "ficomps", "fisubs",
		  "fisubrs", "fidivs", "fidivrs"},
	[0xdf] = {[0] = "filds", "fisttps", "fists", "fistps", "fbld",
		  "fildll", "fbstp", "fistpll"},
}

local VEXH = {}
for _, m in ipairs{"addps", "addpd", "addss", "addsd", "subps", "subpd",
		   "subss", "subsd", "mulps", "mulpd", "mulss", "mulsd",
		   "divps", "divpd", "divss", "divsd", "minps", "minpd",
		   "minss", "minsd", "maxps", "maxpd", "maxss", "maxsd",
		   "andps", "andpd", "andnps", "andnpd", "orps", "orpd",
		   "xorps", "xorpd", "cmpps", "cmppd", "cmpss", "cmpsd",
		   "unpcklps", "unpcklpd", "unpckhps", "unpckhpd",
		   "shufps", "shufpd", "addsubps", "addsubpd", "haddps",
		   "haddpd", "hsubps", "hsubpd", "sqrtss", "sqrtsd",
		   "rcpss", "rsqrtss", "movhlps", "movlhps",
		   "cvtsi2ss", "cvtsi2sd", "cvtss2sd", "cvtsd2ss",
		   "roundss", "roundsd", "insertps", "blendps",
		   "blendpd", "pblendw", "pblendvb", "blendvps",
		   "blendvpd", "dpps", "dppd", "mpsadbw", "pclmulqdq",
		   "palignr", "pshufb", "pmaddubsw", "pmaddwd",
		   "psadbw", "pmulhrsw", "pinsrb", "pinsrw", "pinsr",
		   "packsswb", "packssdw", "packuswb", "packusdw",
		   "aesenc", "aesenclast", "aesdec", "aesdeclast"} do
	VEXH[m] = 2
end
for _, m in ipairs{"padd", "psub", "pmul", "pcmp", "pmin", "pmax",
		   "pavg", "punpck", "phadd", "phsub", "psign"} do
	VEXH[m] = 2
end
VEXH.pand, VEXH.pandn, VEXH.por, VEXH.pxor = 2, 2, 2, 2
for _, m in ipairs{"psllw", "pslld", "psllq", "psrlw", "psrld",
		   "psrlq", "psraw", "psrad", "pslldq", "psrldq"} do
	VEXH[m] = 2
end

-- Whether the vvvv field is this instruction's other source.  The
-- families are named by their start, because there are fifty of them
-- and they all behave the same way.
local function needsh(m)
	if VEXH[m] then return VEXH[m] end
	for pre, v in pairs(VEXH) do
		if #pre > 3 and m:sub(1, #pre) == pre then return v end
	end
	return nil
end

-- The element width an EVEX form spells out, which the same opcode
-- without one leaves unsaid.  A `d` here stands for d or q by the width
-- bit, and `b` for b or w.
local EVEXSUF = {
	[1] = {[0xef] = "d", [0xdb] = "d", [0xdf] = "d", [0xeb] = "d",
	       [0x6f] = "m", [0x7f] = "m"},
}

local function evexname(d, m)
	local t = EVEXSUF[d.map or 1]
	local k = t and t[d.op]

	if not k then return m end
	if k == "d" then return m .. (d.rexw and "q" or "d") end
	-- movdqa and movdqu, whose element width the prefix also picks.
	if d.mand == 0xf2 then return m .. (d.rexw and "16" or "8") end
	return m .. (d.rexw and "64" or "32")
end

-- Encoded with a VEX, but general register work: the name takes no v.
local BMI = {}
for _, m in ipairs{"andn", "bextr", "blsi", "blsmsk", "blsr", "bzhi",
		   "mulx", "pdep", "pext", "rorx", "sarx", "shlx",
		   "shrx"} do
	BMI[m] = true
end

-- What the 0f map means behind a VEX: the mask register operations,
-- which stand where the conditional sets do without one.
local MVEX = {
	[0x90] = {"kmov", "Kr,Km"}, [0x91] = {"kmov", "Km,Kr"},
	[0x92] = {"kmov", "Kr,Ey"}, [0x93] = {"kmov", "Gy,Kn"},
	[0x41] = {"kand", "Kr,Kv,Kn"}, [0x42] = {"kandn", "Kr,Kv,Kn"},
	[0x45] = {"kor", "Kr,Kv,Kn"}, [0x46] = {"kxnor", "Kr,Kv,Kn"},
	[0x47] = {"kxor", "Kr,Kv,Kn"}, [0x44] = {"knot", "Kr,Kn"},
	[0x4a] = {"kadd", "Kr,Kv,Kn"}, [0x4b] = {"kunpck", "Kr,Kv,Kn"},
	[0x98] = {"kortest", "Kr,Kn"}, [0x99] = {"ktest", "Kr,Kn"},
}

-- Which width a mask operation works in, by the prefix and the width
-- bit, since the mnemonic is the only place it is written.
local function kwidth(d)
	if d.mand == 0x66 then return d.rexw and "d" or "b" end
	return d.rexw and "q" or "w"
end

-- decoding ---------------------------------------------------------------

local dec = {}
dec.__index = dec

local function byte(d, at)
	local c = d.s:byte(at)

	if not c then error("short", 0) end
	return c
end

function dec:u8()
	local v = byte(self, self.p)

	self.p = self.p + 1
	return v
end

function dec:i8()
	local v = self:u8()

	return v >= 0x80 and v - 0x100 or v
end

function dec:u16()
	local v = string.unpack("<I2", self.s, self.p)

	self.p = self.p + 2
	return v
end

function dec:u32()
	local v = string.unpack("<I4", self.s, self.p)

	self.p = self.p + 4
	return v
end

function dec:i32()
	local v = string.unpack("<i4", self.s, self.p)

	self.p = self.p + 4
	return v
end

function dec:u64()
	local v = string.unpack("<I8", self.s, self.p)

	self.p = self.p + 8
	return v
end

-- The size an operand of each kind has, given the prefixes.
function dec:osize(t)
	if t == "b" then return 1 end
	if t == "w" then return 2 end
	if t == "d" then return 4 end
	if t == "q" then return 8 end
	if t == "y" then return self.rexw and 8 or 4 end
	if t == "z" then return self.o16 and 2 or 4 end
	-- v: the operand size, which a 66 halves and a REX.W widens
	if self.rexw then return 8 end
	if self.o16 then return 2 end
	return self.d64 and 8 or 4
end

-- The modrm byte, and the sib and displacement behind it.  What comes
-- out is either a register number or the pieces of a place.
function dec:modrm()
	if self.mrm then return self.mrm end
	local b = self:u8()
	local mod, reg, rm = b >> 6, (b >> 3) & 7, b & 7
	local m = {mod = mod,
		   reg = reg | (self.rexr and 8 or 0) | (self.hir or 0),
		   rm = rm, byte = b}

	if mod == 3 then
		m.regform = true
		m.rmnum = rm | (self.rexb and 8 or 0) |
			(self.evex and self.rexx and 16 or 0)
		self.mrm = m
		return m
	end
	if rm == 4 then
		local sib = self:u8()

		m.scale = 1 << (sib >> 6)
		local idx = ((sib >> 3) & 7) | (self.rexx and 8 or 0)
		local base = (sib & 7) | (self.rexb and 8 or 0)

		if idx ~= 4 then m.index = idx end
		if (sib & 7) == 5 and mod == 0 then
			m.disp = self:i32()
			m.dispn = 4
		else
			m.base = base
		end
	elseif rm == 5 and mod == 0 then
		-- Everything a place says in long mode is relative to
		-- the end of the instruction unless a sib says otherwise.
		m.disp = self:i32()
		m.dispn = 4
		m.rip = true
	else
		m.base = rm | (self.rexb and 8 or 0)
	end
	if mod == 1 then
		m.disp = self:i8()
		m.dispn = 1
	elseif mod == 2 then
		m.disp = self:i32()
		m.dispn = 4
	end
	self.mrm = m
	return m
end

local function hex(v)
	if v < 0 then return ("-0x%x"):format(-v) end
	return ("0x%x"):format(v)
end

-- A place, the way an assembler writes it.
function dec:mem(m, size)
	local out = {}

	self.hasmem = true
	self.memsize = size
	if self.seg then out[#out + 1] = "%" .. self.seg .. ":" end
	if m.rip then
		out[#out + 1] = hex(m.disp)
		out[#out + 1] = self.a32 and "(%eip)" or "(%rip)"
		self.riprel = m.disp
		return table.concat(out)
	end
	if not m.base and not m.index then
		-- Nothing to add to: the displacement is the address.
		out[#out + 1] = ("0x%x"):format((m.disp or 0) &
			0xffffffffffffffff)
	elseif m.dispn then
		out[#out + 1] = hex(m.disp)
	end
	local names = self.a32 and R32 or R64

	if m.base or m.index then
		local b = m.base and ("%" .. names[m.base]) or ""

		if m.index then
			out[#out + 1] = ("(%s,%%%s,%d)"):format(b,
				names[m.index], m.scale)
		else
			out[#out + 1] = "(" .. b .. ")"
		end
	end
	return table.concat(out)
end

local VN = {[16] = {}, [32] = {}, [64] = {}}
for i = 0, 31 do
	VN[16][i] = "xmm" .. i
	VN[32][i] = "ymm" .. i
	VN[64][i] = "zmm" .. i
end

function dec:xreg(n, half)
	return "%" .. VN[half and 16 or self.vl][n]
end

-- One operand of the spec, rendered.  `t` is the letter pair the tables
-- are written in: a method and a width.
function dec:operand(t)
	local meth = t:sub(1, 1)
	local kind = t:sub(2)

	if t == "1" then return "$1" end
	-- The port a string instruction reads is written as a place,
	-- and says nothing about how wide the transfer is.
	if t == "DXm" then return "(%dx)" end
	if t == "XMM0" then
		self.hasreg = true
		return "%xmm0"
	end
	if t == "AL" or t == "CL" or t == "DX" then
		self.hasreg = true
		return "%" .. t:lower()
	end
	if t == "FS" then return "%fs" end
	if t == "GS" then return "%gs" end
	if t == "eAX" then
		self.hasreg = true
		return self.o16 and "%ax" or "%eax"
	end
	if t == "rAX" then
		self.hasreg = true
		return "%" .. gpr(0, self:osize("v"), self.rex)
	end
	if meth == "E" or meth == "M" or meth == "R" then
		local size = self:osize(kind == "" and "v" or kind)
		local m = self:modrm()

		if m.regform then
			self.hasreg = true
			if meth == "M" then self.bad = true end
			return "%" .. gpr(m.rmnum, size, self.rex)
		end
		if meth == "R" then self.bad = true end
		return self:mem(m, size)
	end
	if meth == "G" then
		local m = self:modrm()

		self.hasreg = true
		return "%" .. gpr(m.reg, kind == "q" and 8 or
			self:osize(kind), self.rex)
	end
	if meth == "B" then
		self.hasreg = true
		return "%" .. gpr(self.vvvv or 0, self:osize(kind), true)
	end
	if meth == "S" then
		return "%" .. SEGREG[self:modrm().reg & 7]
	end
	if meth == "C" or meth == "D" then
		local m = self:modrm()

		self.hasreg = true
		return "%" .. (meth == "C" and "cr" or "db") .. m.reg
	end
	if meth == "V" then
		self.hasreg = true
		return self:xreg(self:modrm().reg, kind == "h")
	end
	if meth == "H" then
		self.hasreg = true
		return self:xreg(self.vvvv or 0)
	end
	if meth == "W" or meth == "U" then
		local m = self:modrm()

		if m.regform then
			self.hasreg = true
			return self:xreg(m.rmnum, kind == "h")
		end
		if meth == "U" then self.bad = true end
		-- A whole vector, or the half of one a lane operation
		-- moves, or a width the mnemonic already named.
		return self:mem(m, kind == "x" and self.vl or
			(kind == "h" and 16 or self:osize(kind)))
	end
	if meth == "K" then
		local m = self:modrm()

		if kind == "r" then return "%k" .. (m.reg & 7) end
		if kind == "v" then return "%k" .. ((self.vvvv or 0) & 7) end
		if kind == "n" then
			if not m.regform then self.bad = true end
			return "%k" .. (m.rm & 7)
		end
		if m.regform then return "%k" .. (m.rm & 7) end
		return self:mem(m, 0)
	end
	if meth == "K" then
		local m = self:modrm()

		if kind == "r" then return "%k" .. (m.reg & 7) end
		if kind == "v" then return "%k" .. ((self.vvvv or 0) & 7) end
		if kind == "n" then
			if not m.regform then self.bad = true end
			return "%k" .. (m.rm & 7)
		end
		if m.regform then return "%k" .. (m.rm & 7) end
		return self:mem(m, 0)
	end
	if meth == "P" then
		self.hasreg = true
		return "%mm" .. (self:modrm().reg & 7)
	end
	if meth == "Q" or meth == "N" then
		local m = self:modrm()

		if m.regform then
			self.hasreg = true
			return "%mm" .. (m.rm)
		end
		if meth == "N" then self.bad = true end
		return self:mem(m, self:osize(kind))
	end
	if meth == "I" then
		local size = self:osize(kind == "bs" and "b" or kind)
		local v

		if size == 1 then
			v = kind == "bs" and self:i8() or self:u8()
		elseif size == 2 then
			v = self:u16()
		elseif size == 8 then
			v = self:u64()
		else
			v = kind == "z" and self:i32() or self:u32()
		end
		-- An immediate narrower than the operand reaches its
		-- width by its sign, and is printed as the whole of it.
		local w = self:osize("v")

		if kind == "bs" or kind == "z" then
			if w == 8 then
				v = v & 0xffffffffffffffff
			elseif w == 4 then
				v = v & 0xffffffff
			else
				v = v & 0xffff
			end
		end
		return "$" .. ("0x%x"):format(v)
	end
	if meth == "J" then
		local off = kind == "b" and self:i8() or self:i32()

		self.reltarget = off
		return ""		-- filled in once the length is known
	end
	if meth == "O" then
		local v = self.a32 and self:u32() or self:u64()

		self.hasmem = true
		self.memsize = self:osize(kind)
		return (self.seg and ("%" .. self.seg .. ":") or "") ..
			("0x%x"):format(v)
	end
	if meth == "X" or meth == "Y" then
		local r = meth == "X" and "si" or "di"

		self.hasmem = true
		self.memsize = self:osize(kind)
		return (self.seg and ("%" .. self.seg .. ":") or "") ..
			("(%%%s%s)"):format(self.a32 and "e" or "r", r)
	end
	if meth == "Z" then
		self.hasreg = true
		return "%" .. gpr(self.zreg, self:osize(kind), self.rex)
	end
	self.bad = true
	return "?"
end

-- The suffix a mnemonic needs: one only when no operand says how wide
-- the instruction is, which is what an assembler would also require.
local function suffix(d, m)
	if d.hasreg or not d.hasmem then return m end
	return m .. (SUF[d.memsize] or "")
end

local PREFIX = {[0x26] = true, [0x2e] = true, [0x36] = true,
		[0x3e] = true, [0x64] = true, [0x65] = true,
		[0x66] = true, [0x67] = true, [0xf0] = true,
		[0xf2] = true, [0xf3] = true}

-- Read the prefixes, and the REX or VEX that ends them.
function dec:prefixes()
	while true do
		local c = byte(self, self.p)

		if not PREFIX[c] then break end
		self.p = self.p + 1
		if c == 0x66 then
			self.o16 = true
			self.n66 = (self.n66 or 0) + 1
			self.mand = self.mand or 0x66
		elseif c == 0x67 then
			self.a32 = true
		elseif c == 0xf0 then
			self.lock = true
		elseif c == 0xf2 then
			self.rep = 0xf2
			self.mand = 0xf2
		elseif c == 0xf3 then
			self.rep = 0xf3
			self.mand = 0xf3
		else
			self.seg = SEGPFX[c]
		end
	end
	local c = byte(self, self.p)

	if c >= 0x40 and c <= 0x4f then
		self.p = self.p + 1
		self.rex = true
		self.rexw = c & 8 ~= 0
		self.rexr = c & 4 ~= 0
		self.rexx = c & 2 ~= 0
		self.rexb = c & 1 ~= 0
		return
	end
	if c == 0x62 then
		self.p = self.p + 1
		local p0, p1, p2 = self:u8(), self:u8(), self:u8()

		self.vex, self.evex = true, true
		self.rexr = p0 & 0x80 == 0
		self.rexx = p0 & 0x40 == 0
		self.rexb = p0 & 0x20 == 0
		self.hir = p0 & 0x10 == 0 and 16 or 0
		self.map = p0 & 7
		self.rexw = p1 & 0x80 ~= 0
		self.vvvv = ((~(p1 >> 3)) & 15) |
			((p2 & 8) == 0 and 16 or 0)
		self.mand = ({[1] = 0x66, [2] = 0xf3,
			      [3] = 0xf2})[p1 & 3]
		if (p1 & 3) == 1 then self.o16 = true end
		self.vl = ({[0] = 16, 32, 64})[(p2 >> 5) & 3] or 16
		self.mask = p2 & 7
		self.zeroing = p2 & 0x80 ~= 0
		self.bcast = p2 & 0x10 ~= 0
		return
	end
	if c == 0xc4 or c == 0xc5 then
		self.p = self.p + 1
		local b1 = self:u8()

		self.vex = true
		self.rexr = b1 & 0x80 == 0
		if c == 0xc4 then
			self.rexx = b1 & 0x40 == 0
			self.rexb = b1 & 0x20 == 0
			self.map = b1 & 0x1f
			local b2 = self:u8()

			self.rexw = b2 & 0x80 ~= 0
			self.vvvv = (~(b2 >> 3)) & 15
			self.vl = (b2 & 4) ~= 0 and 32 or 16
			self.mand = ({[1] = 0x66, [2] = 0xf3,
				      [3] = 0xf2})[b2 & 3]
			if (b2 & 3) == 1 then self.o16 = true end
		else
			self.map = 1
			self.vvvv = (~(b1 >> 3)) & 15
			self.vl = (b1 & 4) ~= 0 and 32 or 16
			self.mand = ({[1] = 0x66, [2] = 0xf3,
				      [3] = 0xf2})[b1 & 3]
			if (b1 & 3) == 1 then self.o16 = true end
		end
	end
end

-- Which reading of an entry the mandatory prefix picks.
local function pick(e, mand)
	if not e then return nil end
	if mand == 0x66 and e.p66 then return e.p66 end
	if mand == 0xf3 and e.pf3 then return e.pf3 end
	if mand == 0xf2 and e.pf2 then return e.pf2 end
	if e.sse and mand and (e.p66 or e.pf3 or e.pf2) and not e[1] then
		return nil
	end
	return e
end

-- x87.  The modrm byte finishes the opcode: below c0 it names a place,
-- and the mnemonic says the width; above it the two operands are the
-- stack top and one other slot, in whichever order the form takes.
local X87R = {
	[0xd8] = {[0] = {"fadd", 1}, {"fmul", 1}, {"fcom", 3},
		  {"fcomp", 3}, {"fsub", 1}, {"fsubr", 1}, {"fdiv", 1},
		  {"fdivr", 1}},
	[0xd9] = {[0] = {"fld", 3}, {"fxch", 3}},
	[0xda] = {[0] = {"fcmovb", 1}, {"fcmove", 1}, {"fcmovbe", 1},
		  {"fcmovu", 1}},
	[0xdb] = {[0] = {"fcmovnb", 1}, {"fcmovne", 1}, {"fcmovnbe", 1},
		  {"fcmovnu", 1}, nil, {"fucomi", 1}, {"fcomi", 1}},
	[0xdc] = {[0] = {"fadd", 2}, {"fmul", 2}, nil, nil, {"fsub", 2},
		  {"fsubr", 2}, {"fdiv", 2}, {"fdivr", 2}},
	[0xdd] = {[0] = {"ffree", 3}, nil, {"fst", 3}, {"fstp", 3},
		  {"fucom", 3}, {"fucomp", 3}},
	[0xde] = {[0] = {"faddp", 2}, {"fmulp", 2}, nil, nil,
		  {"fsubp", 2}, {"fsubrp", 2}, {"fdivp", 2},
		  {"fdivrp", 2}},
	[0xdf] = {[0] = {"ffreep", 3}, nil, nil, nil, nil,
		  {"fucomip", 1}, {"fcomip", 1}},
}

-- The ones whose whole second byte is the instruction.
local X87ONE = {
	[0xd9] = {[0xd0] = "fnop", [0xe0] = "fchs", [0xe1] = "fabs",
		  [0xe4] = "ftst", [0xe5] = "fxam", [0xe8] = "fld1",
		  [0xe9] = "fldl2t", [0xea] = "fldl2e", [0xeb] = "fldpi",
		  [0xec] = "fldlg2", [0xed] = "fldln2", [0xee] = "fldz",
		  [0xf0] = "f2xm1", [0xf1] = "fyl2x", [0xf2] = "fptan",
		  [0xf3] = "fpatan", [0xf4] = "fxtract",
		  [0xf5] = "fprem1", [0xf6] = "fdecstp",
		  [0xf7] = "fincstp", [0xf8] = "fprem",
		  [0xf9] = "fyl2xp1", [0xfa] = "fsqrt",
		  [0xfb] = "fsincos", [0xfc] = "frndint",
		  [0xfd] = "fscale", [0xfe] = "fsin", [0xff] = "fcos"},
	[0xda] = {[0xe9] = "fucompp"},
	[0xdb] = {[0xe2] = "fnclex", [0xe3] = "fninit"},
	[0xde] = {[0xd9] = "fcompp"},
}

local function x87(d)
	local op = d.op
	local b = byte(d, d.p)

	if b < 0xc0 then
		local m = d:modrm()
		local nm = X87M[op][(m.byte >> 3) & 7]

		if nm == "?" then return nil end
		return nm, {d:mem(m, 0)}
	end
	d.p = d.p + 1
	local one = X87ONE[op] and X87ONE[op][b]

	if one then return one, {} end
	if op == 0xdf and b == 0xe0 then return "fnstsw", {"%ax"} end
	local f = X87R[op] and X87R[op][(b >> 3) & 7]

	if not f then return nil end
	local st = "%st(" .. (b & 7) .. ")"

	if f[2] == 1 then return f[1], {st, "%st"} end
	if f[2] == 2 then return f[1], {"%st", st} end
	return f[1], {st}
end

-- The opcodes of the 0f map that carry an immediate, for measuring an
-- EVEX form this decoder has no name for.
local IMM0F = {[0x70] = true, [0x71] = true, [0x72] = true,
	       [0x73] = true, [0xc2] = true, [0xc4] = true,
	       [0xc5] = true, [0xc6] = true}

-- How long an instruction is that nothing here can name.  A VEX or an
-- EVEX says its own length in its parts, and reading it keeps the
-- instructions after it in step; anything else is one byte, and the
-- next byte is tried as a fresh start.
function dec:unknown()
	if not self.vex or not self.op or not self.map then return 1 end
	local ok = pcall(function()
		if not self.mrm then self:modrm() end
		if self.map == 3 or (self.map == 1 and IMM0F[self.op]) then
			self:u8()
		end
	end)

	return ok and self.p - self.start or 1
end

-- One instruction at `at` in `s`, standing at address `addr`.
function amd64.decode(s, at, addr)
	local d = setmetatable({s = s, p = at, start = at, addr = addr or 0,
				vl = 16}, dec)
	local ok, err = pcall(function()
		d:prefixes()
		local e, map

		if d.vex then
			map = d.map
		else
			local c = d:u8()

			if c == 0x0f then
				local c2 = byte(d, d.p)

				if c2 == 0x38 then
					d.p = d.p + 1
					map = 2
				elseif c2 == 0x3a then
					d.p = d.p + 1
					map = 3
				else
					map = 1
				end
			else
				map = 0
				d.op = c
				d.zreg = (c & 7) | (d.rexb and 8 or 0)
				e = M1[c]
			end
		end
		if map > 0 then
			local maps = {M0F, M38, M3A}

			if not maps[map] then
				d.bad = true
				return
			end
			d.op = d:u8()
			d.zreg = (d.op & 7) | (d.rexb and 8 or 0)
			e = maps[map][d.op]
			if d.vex and map == 1 then
				if d.op == 0x77 then
					d.vzero = true
				elseif MVEX[d.op] then
					e, d.kmask = MVEX[d.op], true
				end
			end
		end
		if d.vzero then
			d.mnem = d.vl == 16 and "vzeroupper" or "vzeroall"
			d.list, d.nosuffix = {}, true
			return
		end
		d.sse = e and e.sse
		d.entry = d.kmask and e or pick(e, d.mand)
		-- Whether the prefix in front chose this reading rather
		-- than standing on its own as one more prefix.
		d.mandused = d.entry ~= nil and d.entry ~= e
		if not d.entry then
			d.bad = true
			return
		end
		d:build()
	end)

	if not ok then
		if err == "short" then return nil end
		error(err, 0)
	end
	local len = d.p - d.start

	if d.bad or not d.mnem then
		local n = d:unknown()

		return {len = n, mnem = "(bad)", ops = {},
			text = "(bad)", bad = true,
			bytes = s:sub(at, at + n - 1)}
	end
	return d:finish(len)
end

-- Work the entry into a mnemonic and a list of operands.
function dec:build()
	local e = self.entry
	local m, ops = e[1], e[2]

	self.d64 = e.d64
	if type(m) == "table" then
		-- A group: the middle field of the modrm byte picks.
		local mrm = self:modrm()
		local slot = m[(mrm.byte >> 3) & 7]

		if e.p66g and self.mand == 0x66 and mrm.mod == 3 then
			slot = e.p66g[(mrm.byte >> 3) & 7]
			self.mandused = true
		elseif e.f3 and self.rep == 0xf3 then
			slot = e.f3[(mrm.byte >> 3) & 7]
			self.mandused = true
		elseif e.f2 and self.rep == 0xf2 then
			slot = e.f2[(mrm.byte >> 3) & 7]
			self.mandused = true
		elseif e.m3 and mrm.mod == 3 then
			local arg = G7ARG[mrm.byte]
			local nm = e.m3[mrm.byte]

			if arg and e.m3 == G7M3 then
				self.mnem, self.list = arg[1], arg[2]
				self.nosuffix, self.noswap = true, true
				return
			end
			if nm then
				self.mnem, self.list = nm, {}
				return
			end
		end
		if type(slot) == "table" then
			m, ops = slot[1], slot[2]
			self.d64 = slot.d64 or self.d64
			self.ind = slot.ind
			if slot.nosuf then self.nosuffix = true end
			if slot.w64 then
				if self.rexw then m = m .. "64" end
				self.nosuffix = true
			end
			if slot.dq then
				m = m .. (self.rexw and "q" or "d")
				self.nosuffix = true
			end
			if slot.p66 and self.mand == 0x66 then
				ops = slot.p66
			end
			if slot.wide and self.rexw then m = slot.wide end
		elseif type(slot) == "string" and slot ~= "?" then
			m, ops = slot, e[2]
		else
			self.bad = true
			return
		end
	elseif e.m3 then
		local mrm = self:modrm()

		if mrm.mod == 3 then
			local nm = e.m3[mrm.byte]

			if nm then
				self.mnem, self.list = nm, {}
				return
			end
			self.bad = true
			return
		end
	end
	if m == "x87" then
		local nm, list = x87(self)

		if not nm then
			self.bad = true
			return
		end
		self.mnem, self.list = nm, list
		self.nosuffix = true
		self.noswap = true
		return
	end
	self.ind = self.ind or e.ind
	if e.r3 and self:modrm().mod == 3 then
		m, ops = e.r3[1], e.r3[2]
	end
	if e.wq and self.rexw then m = "movq" end
	if e.sized then
		m = e.sized[self:osize("v")] or m
	end
	-- 90 is a nop only as itself: a REX or a 66 makes it the
	-- exchange it always was.
	if e.nop90 then
		if self.rep == 0xf3 then
			self.mnem, self.list = "pause", {}
			self.mandused = true
			return
		end
		if self.rexb or self.o16 then
			m, ops = "xchg", "Zv,rAX"
		end
	end
	-- A whole address in the instruction is written wide.
	if e.abs64 and self.rexw then
		m = "movabs"
		self.nosuffix = true
	end
	-- movzx and movsx say both widths, because neither operand does.
	if e.movsx then
		local src = ops:match(",(%a%a?)$")
		local from = src == "Eb" and "b" or
			(src == "Ew" and "w" or "l")

		if m ~= "movslq" then
			m = m .. from .. (SUF[self:osize("v")] or "l")
		end
		self.nosuffix = true
	end
	if e.endbr then
		local b = self:u8()

		if b == 0xfa or b == 0xfb then
			self.mnem = b == 0xfa and "endbr64" or "endbr32"
			self.list = {}
			return
		end
		self.p = self.p - 1
		if (b >> 6) == 3 and ((b >> 3) & 7) == 1 then
			self.mnem = "rdssp" .. (self.rexw and "q" or "d")
			self.list = {self:operand("Rv")}
			self.nosuffix = true
			return
		end
		m, ops = "nop", "Ev"
		self.entry = {m, ops, nopw = true}
		e = self.entry
	end
	local words = {}

	if e.nopw then
		if self.seg then
			words[#words + 1] = self.seg
			self.seg = nil
		end
	elseif self.seg == "ds" then
		-- Nothing overrides the segment a place is read through
		-- anyway.  The same byte in front of an indirect branch
		-- says the target may be anywhere.
		words[#words + 1] = self.ind and "notrack" or "ds"
		self.seg = nil
	end
	self.words = words
	local list = {}

	for t in ops:gmatch("[^,]+") do
		list[#list + 1] = self:operand(t)
	end
	-- A multi-byte nop is one operand wide and prints no more.
	if e.nopw then
		self.mnem = self.o16 and "nopw" or
			(self.rexw and "nopq" or "nopl")
		self.list = list
		self.nosuffix = true
		return
	end
	if self.vex then
		if self.kmask then
			m = m .. kwidth(self)
		else
			local pos = e.h or (e.ndd and 1 or needsh(m))

			if pos == 3 then
				pos = self:modrm().regform and 2 or nil
			end

			if pos then
				table.insert(list, pos,
					self:xreg(self.vvvv or 0))
			end
			if self.evex then m = evexname(self, m) end
			if not BMI[m] then m = "v" .. m end
		end
		self.nosuffix = true
	end
	self.mnem, self.list = m, list
end

-- Put the pieces in the order an assembler reads them, which is the
-- reverse of the order the manual names them in.
function dec:finish(len)
	local m = self.mnem
	local list = self.list

	local e0 = self.entry

	if e0 and (e0.nosuf or self.d64) then self.nosuffix = true end
	if not self.nosuffix then m = suffix(self, m) end
	local ops = {}

	if self.noswap then
		ops = list
	else
		for i = #list, 1, -1 do ops[#ops + 1] = list[i] end
	end
	local ins = {len = len, mnem = m, ops = ops, bytes = self.s:sub(
		self.start, self.p - 1)}

	if self.reltarget then
		ins.target = (self.addr + len + self.reltarget) &
			0xffffffffffffffff
		for i, o in ipairs(ops) do
			if o == "" then ops[i] = ("0x%x"):format(ins.target) end
		end
	end
	if self.riprel then
		ins.riptarget = (self.addr + len + self.riprel) &
			0xffffffffffffffff
	end
	local e = self.entry

	if e then
		ins.kind = e.call and "call" or e.jmp and "jmp" or
			e.jcc and "jcc" or e.ret and "ret" or nil
	end
	if self.ind then
		ins.indirect = true
		if ops[1] then ops[1] = "*" .. ops[1] end
		ins.kind = m == "call" and "call" or
			(m == "jmp" and "jmp" or ins.kind)
	end
	if self.lock then m = "lock " .. m end
	if self.rep and not self.mandused then
		local name = self.rep == 0xf3 and "rep" or "repnz"

		if e and e.str then
			if self.rep == 0xf3 and (m:sub(1, 4) == "scas" or
			    m:sub(1, 4) == "cmps") then
				name = "repz"
			end
			m = name .. " " .. m
		elseif m == "nop" then
			m = "pause"
		elseif not self.vex then
			m = (self.rep == 0xf3 and "repz " or "repnz ") .. m
		end
	end
	if self.evex and self.mask and self.mask ~= 0 and ops[#ops] then
		ops[#ops] = ops[#ops] .. ("{%%k%d}"):format(self.mask) ..
			(self.zeroing and "{z}" or "")
	end
	local words = self.words or {}
	local used = 0

	if self.vex then
		used = self.n66 or 0
	elseif self.mand == 0x66 and self.mandused then
		used = 1
	elseif self.o16 and not self.rexw then
		used = 1
	end
	for _ = 1, (self.n66 or 0) - used do
		table.insert(words, 1, "data16")
	end
	if #words > 0 then m = table.concat(words, " ") .. " " .. m end
	ins.mnem = m
	ins.text = #ops > 0 and ("%-6s %s"):format(m, table.concat(ops, ","))
		or m
	return ins
end

amd64.wordbytes = 1

return amd64
