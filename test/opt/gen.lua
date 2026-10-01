-- SPDX-License-Identifier: ISC
-- The optimizer corpus: small C functions, one per file, each built to
-- cost one thing.  A cell is what gcc and mcc are both asked to compile;
-- the difference in bytes per cell says where this compiler pays.

-- Every parameter and every local feeds the return value, so gcc
-- cannot drop any of it and a cell measures the same work twice.
-- Nothing here reads a header: the types are declared in the prelude
-- and the runtime a cell calls is declared, not defined, so gcc sees
-- an opaque call where mcc does.

-- `G` in a cell is renamed per file, so a program made of every cell
-- links.  A cell marked `norun` touches the machine (ports, segment
-- registers) and is left out of that program.

local gen = {}

local PRELUDE = [==[
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef signed char s8;
typedef short s16;
typedef int s32;
typedef long long s64;
struct ss { int a; int b; };
struct bs {
	u16 ax, bx, cx, dx, si, di, bp, sp;
	u32 flags;
	u8 pad[20];
};
struct gs {
	u32 f;
	u8 b;
	u16 h;
	u32 a[8];
	struct { u32 x; u32 y; } s[4];
	u8 *p;
	int (*fp)(int);
};
int ext(int);
int ext2(int);
int ext3(int);
int ext3args(int, int, int);
int ext6(int, int, int, int, int, int);
u32 extp(void *);
void extv(void *);
u8 extc(int);
u64 extu64(int);
int extss(struct ss);
int extbs(struct bs);
struct ss extrss(int);
#ifndef __SIZE_TYPE__
#define __SIZE_TYPE__ unsigned long
#endif
void *memset(void *, int, __SIZE_TYPE__);
void *memcpy(void *, const void *, __SIZE_TYPE__);
]==]

local cells = {}

-- A cell: the family it belongs to, its name, the C source of one
-- function named after it, and how the driver calls it.
local function cell(family, name, src, call, opt)
	opt = opt or {}
	cells[#cells + 1] = {family = family, name = name, src = src,
			     call = call, norun = opt.norun,
			     show = opt.show, i386 = opt.i386}
end

-- Calling convention and frame --------------------------------------

local function ints(n, prefix)
	local a = {}
	for i = 1, n do a[i] = (prefix or "a") .. i end
	return a
end

local function sig(n)
	local params, sum, args = {}, {}, {}
	for i = 1, n do
		params[i] = "int a" .. i
		sum[i] = "a" .. i
		args[i] = tostring(i * 3)
	end
	cell("sig", "sig_int" .. n, ([==[
int sig_int%d(%s)
{
	return %s;
}
]==]):format(n, n == 0 and "void" or table.concat(params, ", "),
	n == 0 and "7" or table.concat(sum, " + ")),
	("sig_int%d(%s)"):format(n, table.concat(args, ", ")))
end

for _, n in ipairs{0, 1, 2, 3, 4, 6} do sig(n) end

cell("sig", "sig_char3", [==[
int sig_char3(s8 a, s8 b, s8 c)
{
	return a + b * c;
}
]==], "sig_char3(3, -5, 7)")

cell("sig", "sig_short3", [==[
int sig_short3(s16 a, u16 b, s16 c)
{
	return a + b * c;
}
]==], "sig_short3(3, 5, -7)")

cell("sig", "sig_ptr3", [==[
int sig_ptr3(int *a, int *b, int *c)
{
	return *a + *b * *c;
}
]==], "sig_ptr3(&V[0], &V[1], &V[2])")

cell("sig", "sig_u64_2", [==[
int sig_u64_2(u64 a, u64 b)
{
	return (int)(a + b);
}
]==], "sig_u64_2(5, 9)")

cell("sig", "sig_ss3", [==[
int sig_ss3(struct ss a, struct ss b, struct ss c)
{
	return a.a + b.b + c.a;
}
]==], "sig_ss3(SS, SS, SS)")

cell("sig", "sig_bs1", [==[
int sig_bs1(struct bs r)
{
	return r.ax + r.flags;
}
]==], "sig_bs1(BS)")

cell("sig", "sig_mix6", [==[
int sig_mix6(int a, s8 b, int *c, s16 d, u64 e, int f)
{
	return a + b + *c + d + (int)e + f;
}
]==], "sig_mix6(1, 2, &V[0], 4, 5, 6)")

cell("sig", "ret_char", [==[
s8 ret_char(int x)
{
	return (s8)x;
}
]==], "ret_char(300)")

cell("sig", "ret_short", [==[
s16 ret_short(int x, int y)
{
	return (s16)(x * y);
}
]==], "ret_short(300, 7)")

cell("sig", "ret_ptr", [==[
int *ret_ptr(int *p, int x)
{
	return p + x;
}
]==], "*ret_ptr(V, 2)")

cell("sig", "ret_u64", [==[
u64 ret_u64(u32 x, u32 y)
{
	return (u64)x * y;
}
]==], "ret_u64(70000, 70000)")

cell("sig", "ret_ss", [==[
struct ss ret_ss(int x, int y)
{
	struct ss r;

	r.a = x + 1;
	r.b = y * 2;
	return r;
}
]==], "ret_ss(3, 4)", {show = "struct ss r = %s; v = r.a + r.b;"})

cell("sig", "ret_bs", [==[
struct bs G;
struct bs ret_bs(int x)
{
	struct bs r = G;

	r.ax = x;
	return r;
}
]==], "ret_bs(9)", {show = "struct bs r = %s; v = r.ax + r.bx;"})

-- Locals: how many, used how often, and whether a call sits between
-- the writes and the reads --------------------------------------------

for _, k in ipairs{1, 2, 4} do
	for _, u in ipairs{1, 2, 4, 8} do
		for _, c in ipairs{0, 1} do
			local name = ("loc_k%d_u%d_c%d"):format(k, u, c)
			local b = {}

			b[#b + 1] = ("int %s(int x, int y)\n{\n"):format(name)
			for i = 0, k - 1 do
				local prev = i == 0 and "x" or ("l" .. (i - 1))

				b[#b + 1] = ("\tint l%d = %s %s %d;\n")
					:format(i, prev,
						i % 2 == 0 and "+" or "*",
						i * 5 + 1)
			end
			b[#b + 1] = "\tint r = y;\n"
			if c == 1 then b[#b + 1] = "\tr = ext(r);\n" end
			local forms = {"\tr += l%d;\n", "\tr ^= l%d << 1;\n",
				       "\tr += l%d * y;\n", "\tr |= l%d;\n"}

			for j = 1, u do
				for i = 0, k - 1 do
					b[#b + 1] = forms[(j - 1) % 4 + 1]
						:format(i)
				end
			end
			b[#b + 1] = "\treturn r;\n}\n"
			cell("loc", name, table.concat(b), name .. "(11, 5)")
		end
	end
end

-- Globals reached by name -----------------------------------------------

local function glob(name, body, call, opt)
	cell("glob", name, "struct gs G;\n" .. body, call, opt)
end

glob("glob_field", [==[
int glob_field(int x)
{
	return G.f + x;
}
]==], "glob_field(3)")

glob("glob_byte_cmp", [==[
int glob_byte_cmp(int x, int y)
{
	if (G.b == 5)
		return x;
	return y;
}
]==], "glob_byte_cmp(3, 4)")

glob("glob_arr_const", [==[
int glob_arr_const(int x)
{
	return G.a[3] + x;
}
]==], "glob_arr_const(3)")

glob("glob_arr_var", [==[
int glob_arr_var(int x)
{
	return G.a[x];
}
]==], "glob_arr_var(3)")

glob("glob_arr_const_store", [==[
int glob_arr_const_store(int x)
{
	G.a[3] = x;
	return 0;
}
]==], "glob_arr_const_store(3)")

glob("glob_struct_arr", [==[
int glob_struct_arr(int x)
{
	return G.s[2].y + x;
}
]==], "glob_struct_arr(3)")

glob("glob_struct_arr_var", [==[
int glob_struct_arr_var(int i)
{
	return G.s[i].y;
}
]==], "glob_struct_arr_var(3)")

glob("glob_addr_arg", [==[
int glob_addr_arg(int x)
{
	extv(&G.a[3]);
	return x;
}
]==], "glob_addr_arg(3)")

glob("glob_addr_field_call", [==[
int glob_addr_field_call(int x)
{
	return extp(&G.s[1]) + x;
}
]==], "glob_addr_field_call(3)")

glob("glob_rmw", [==[
int glob_rmw(int x)
{
	G.f += x;
	return 0;
}
]==], "glob_rmw(3)")

glob("glob_byte_store", [==[
int glob_byte_store(int x)
{
	G.b = 1;
	G.h = x;
	return 0;
}
]==], "glob_byte_store(3)")

glob("glob_ptr_field", [==[
int glob_ptr_field(int x)
{
	return G.p[x];
}
]==], "(G_glob_ptr_field.p = (u8 *)V, glob_ptr_field(1))")

glob("glob_two_fields", [==[
int glob_two_fields(int x)
{
	return G.f + G.h * x;
}
]==], "glob_two_fields(3)")

glob("glob_loop_store", [==[
int glob_loop_store(int n)
{
	int i;

	for (i = 0; i < n; i++)
		G.a[i] = i;
	return G.f;
}
]==], "glob_loop_store(3)")

glob("glob_flag_test", [==[
int glob_flag_test(int x)
{
	if (G.f & 0x80)
		G.f |= 1;
	return G.f + x;
}
]==], "glob_flag_test(3)")

-- Comparisons and conditions --------------------------------------------

local function cmp(name, body, call) cell("cmp", name, body, call) end

cmp("cmp_eq_const", [==[
int cmp_eq_const(int x, int y)
{
	if (x == 7)
		return y;
	return x + 1;
}
]==], "cmp_eq_const(7, 3)")

cmp("cmp_zero", [==[
int cmp_zero(int x, int y)
{
	if (x)
		return y;
	return 3;
}
]==], "cmp_zero(1, 3)")

cmp("cmp_not", [==[
int cmp_not(int x, int y)
{
	if (!x)
		return y;
	return 3;
}
]==], "cmp_not(0, 3)")

cmp("cmp_char_ptr", [==[
int cmp_char_ptr(const char *p, int y)
{
	if (p[0] == 'a')
		return y;
	return 3;
}
]==], "cmp_char_ptr(\"abc\", 3)")

cmp("cmp_short_glob", [==[
s16 G;
int cmp_short_glob(int y)
{
	if (G == 3)
		return y;
	return 4;
}
]==], "cmp_short_glob(3)")

cmp("cmp_lt_signed", [==[
int cmp_lt_signed(int a, int b)
{
	if (a < b)
		return a;
	return b;
}
]==], "cmp_lt_signed(-3, 3)")

cmp("cmp_lt_unsigned", [==[
int cmp_lt_unsigned(u32 a, u32 b)
{
	if (a < b)
		return a;
	return b;
}
]==], "cmp_lt_unsigned(3, 5)")

cmp("cmp_ret_lt", [==[
int cmp_ret_lt(int a, int b)
{
	return a < b;
}
]==], "cmp_ret_lt(3, 5)")

cmp("cmp_ret_not", [==[
int cmp_ret_not(int x)
{
	return !x;
}
]==], "cmp_ret_not(3)")

cmp("cmp_tern_const", [==[
int cmp_tern_const(int x)
{
	return x ? 1 : 0;
}
]==], "cmp_tern_const(3)")

cmp("cmp_tern_vals", [==[
int cmp_tern_vals(int c, int a, int b)
{
	return c ? a : b;
}
]==], "cmp_tern_vals(1, 3, 5)")

cmp("cmp_and_chain", [==[
int cmp_and_chain(int a, int b, int c)
{
	if (a && b && c)
		return 1;
	return a + b + c;
}
]==], "cmp_and_chain(1, 2, 3)")

cmp("cmp_or_chain", [==[
int cmp_or_chain(int a, int b, int c)
{
	if (a || b || c)
		return 1;
	return 5;
}
]==], "cmp_or_chain(0, 0, 3)")

cmp("cmp_range", [==[
int cmp_range(int x)
{
	if (x >= 'a' && x <= 'f')
		return x - 'a' + 10;
	return -1;
}
]==], "cmp_range('c')")

cmp("cmp_local_after_call", [==[
int cmp_local_after_call(int x)
{
	int l = ext(x);

	if (l == 3)
		return x;
	return l;
}
]==], "cmp_local_after_call(2)")

cmp("cmp_mask_bit", [==[
int cmp_mask_bit(u32 x, int y)
{
	if ((x & 0x80) == 0)
		return y;
	return 3;
}
]==], "cmp_mask_bit(0x80, 4)")

cmp("cmp_neg_const", [==[
int cmp_neg_const(int x)
{
	if (x == -1)
		return 5;
	return x;
}
]==], "cmp_neg_const(-1)")

-- Read, modify, write -----------------------------------------------------

local function rmw(name, body, call) cell("rmw", name, body, call) end

rmw("rmw_local_add", [==[
int rmw_local_add(int x, int y)
{
	int l = x;

	l += 5;
	extv(&l);
	l += y;
	return l;
}
]==], "rmw_local_add(3, 4)")

rmw("rmw_preinc_loop", [==[
int rmw_preinc_loop(int n)
{
	int i = 0, s = 0;

	while (i < n) {
		s += i;
		++i;
	}
	return s;
}
]==], "rmw_preinc_loop(5)")

rmw("rmw_postinc_stmt", [==[
int rmw_postinc_stmt(int n)
{
	int i = 0, s = 0;

	while (i < n) {
		s += i;
		i++;
	}
	return s;
}
]==], "rmw_postinc_stmt(5)")

rmw("rmw_ptr_field", [==[
int rmw_ptr_field(struct ss *p, int x)
{
	p->b += x;
	return 0;
}
]==], "rmw_ptr_field(&SSV, 3)")

rmw("rmw_glob", [==[
int G;
int rmw_glob(int x)
{
	G += x;
	G -= 3;
	return 0;
}
]==], "rmw_glob(3)")

rmw("rmw_arr_elem", [==[
int rmw_arr_elem(int *a, int i)
{
	a[i]++;
	return 0;
}
]==], "rmw_arr_elem(V, 1)")

rmw("rmw_shl", [==[
int rmw_shl(int x)
{
	int l = x;

	l <<= 1;
	extv(&l);
	l <<= 3;
	return l;
}
]==], "rmw_shl(3)")

rmw("rmw_or_mask", [==[
int rmw_or_mask(int x)
{
	int l = x;

	l |= 0x40;
	extv(&l);
	l &= ~0x40;
	return l;
}
]==], "rmw_or_mask(3)")

rmw("rmw_mul8", [==[
int rmw_mul8(int x)
{
	return x * 8;
}
]==], "rmw_mul8(3)")

rmw("rmw_udiv16", [==[
u32 rmw_udiv16(u32 x)
{
	return x / 16;
}
]==], "rmw_udiv16(300)")

rmw("rmw_umod8", [==[
u32 rmw_umod8(u32 x)
{
	return x % 8;
}
]==], "rmw_umod8(300)")

rmw("rmw_and_ff", [==[
u32 rmw_and_ff(u32 x)
{
	return x & 0xff;
}
]==], "rmw_and_ff(300)")

rmw("rmw_sdiv", [==[
int rmw_sdiv(int x, int y)
{
	return x / (y | 1);
}
]==], "rmw_sdiv(300, 7)")

rmw("rmw_shl_var", [==[
int rmw_shl_var(int x, int n)
{
	return x << (n & 31);
}
]==], "rmw_shl_var(3, 4)")

-- Eight-byte integers on a four-byte machine ---------------------------

local function u64c(name, body, call)
	cell("u64", name, body, call)
end

u64c("u64_add", [==[
u64 u64_add(u64 a, u64 b)
{
	return a + b;
}
]==], "u64_add(5000000000ULL, 7)")

u64c("u64_sub", [==[
u64 u64_sub(u64 a, u64 b)
{
	return a - b;
}
]==], "u64_sub(5000000000ULL, 7)")

u64c("u64_mul", [==[
u64 u64_mul(u64 a, u64 b)
{
	return a * b;
}
]==], "u64_mul(5000000000ULL, 7)")

u64c("u64_mul_u32", [==[
u64 u64_mul_u32(u64 a, u32 b)
{
	return a * b;
}
]==], "u64_mul_u32(5000000000ULL, 7)")

u64c("u64_div_u32", [==[
u64 u64_div_u32(u64 a, u32 b)
{
	return a / (b | 1);
}
]==], "u64_div_u32(5000000000ULL, 7)")

u64c("u64_mod_u32", [==[
u32 u64_mod_u32(u64 a, u32 b)
{
	return a % (b | 1);
}
]==], "u64_mod_u32(5000000000ULL, 7)")

u64c("u64_shl_const", [==[
u64 u64_shl_const(u64 a)
{
	return a << 4;
}
]==], "u64_shl_const(5000000000ULL)")

u64c("u64_shr_const", [==[
u64 u64_shr_const(u64 a)
{
	return a >> 4;
}
]==], "u64_shr_const(5000000000ULL)")

u64c("u64_shl_var", [==[
u64 u64_shl_var(u64 a, int n)
{
	return a << (n & 63);
}
]==], "u64_shl_var(5000000000ULL, 3)")

u64c("u64_cmp_lt", [==[
int u64_cmp_lt(u64 a, u64 b)
{
	return a < b;
}
]==], "u64_cmp_lt(5000000000ULL, 7)")

u64c("u64_cmp_eq", [==[
int u64_cmp_eq(u64 a, u64 b, int x)
{
	if (a == b)
		return x;
	return 0;
}
]==], "u64_cmp_eq(7, 7, 3)")

u64c("u64_ext_u32", [==[
u64 u64_ext_u32(u32 x, u32 y)
{
	return (u64)x * 3 + y;
}
]==], "u64_ext_u32(3000000000U, 5)")

u64c("u64_trunc", [==[
u32 u64_trunc(u64 a)
{
	return (u32)a + (u32)(a >> 32);
}
]==], "u64_trunc(5000000000ULL)")

u64c("u64_neg", [==[
u64 u64_neg(u64 a)
{
	return -a;
}
]==], "u64_neg(5)")

u64c("u64_and_or", [==[
u64 u64_and_or(u64 a, u64 b)
{
	return (a & b) | (a ^ 0xffULL);
}
]==], "u64_and_or(5000000000ULL, 7)")

u64c("u64_acc_loop", [==[
int u64_acc_loop(const char *s, int n)
{
	u64 acc = 0;
	int i;

	for (i = 0; i < n; i++)
		acc = acc * 10 + (s[i] - '0');
	return (int)acc;
}
]==], "u64_acc_loop(\"12345\", 5)")

u64c("u64_glob", [==[
u64 G;
int u64_glob(u32 x)
{
	G += x;
	return (int)G;
}
]==], "u64_glob(5)")

u64c("u64_local_pair", [==[
int u64_local_pair(u32 x, u32 y)
{
	u64 lo = x;
	u64 hi = y;

	return (int)((hi << 32 | lo) >> 16);
}
]==], "u64_local_pair(0x12345678, 0x9abc)")

-- Inline assembly, the shapes a boot loader writes -----------------------

local ASM = [==[
static inline void outb(u8 v, u16 port)
{
	asm volatile("outb %0,%1" : : "a"(v), "dN"(port));
}
static inline u8 inb(u16 port)
{
	u8 v;
	asm volatile("inb %1,%0" : "=a"(v) : "dN"(port));
	return v;
}
static inline u8 rdfs8(u32 addr)
{
	u8 v;
	asm volatile("movb %%fs:%1,%0" : "=q"(v) : "m"(*(u8 *)addr));
	return v;
}
static inline void wrfs32(u32 v, u32 addr)
{
	asm volatile("movl %1,%%fs:%0" : "+m"(*(u32 *)addr) : "ri"(v));
}
static inline void set_fs(u16 seg)
{
	asm volatile("movw %0,%%fs" : : "rm"(seg));
}
static inline void cpuid_count(u32 id, u32 count, u32 *a, u32 *b,
			       u32 *c, u32 *d)
{
	asm volatile("cpuid"
		     : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d)
		     : "a"(id), "c"(count));
}
]==]

-- Port I/O and the segment registers cannot run on the host; cpuid and
-- the rest can, and do.
local function asmc(name, body, call, opt)
	opt = opt or {}
	if not opt.run then opt.norun = true end
	cell("asm", name, ASM .. body, call, opt)
end

asmc("asm_outb1", [==[
int asm_outb1(int x)
{
	outb(x, 0x64);
	return 0;
}
]==], "asm_outb1(3)")

asmc("asm_outb3", [==[
int asm_outb3(int x)
{
	outb(0xd1, 0x64);
	outb(x, 0x60);
	outb(0xdf, 0x60);
	return 0;
}
]==], "asm_outb3(3)")

asmc("asm_inb2", [==[
int asm_inb2(void)
{
	return inb(0x64) + inb(0x60);
}
]==], "asm_inb2()")

asmc("asm_rdfs8", [==[
int asm_rdfs8(u32 x)
{
	return rdfs8(x) + rdfs8(x + 1);
}
]==], "asm_rdfs8(3)")

asmc("asm_wrfs32", [==[
int asm_wrfs32(u32 x, u32 v)
{
	wrfs32(v, x);
	return 0;
}
]==], "asm_wrfs32(3, 4)")

asmc("asm_setfs", [==[
int asm_setfs(u16 s)
{
	set_fs(s);
	return 0;
}
]==], "asm_setfs(3)")

asmc("asm_cpuid_glob", [==[
struct gs G;
int asm_cpuid_glob(void)
{
	cpuid_count(1, 0, &G.a[0], &G.a[1], &G.a[2], &G.a[3]);
	return G.a[0];
}
]==], "asm_cpuid_glob()", {run = true})

asmc("asm_cpuid_local", [==[
int asm_cpuid_local(u32 id)
{
	u32 a, b, c, d;

	cpuid_count(id, 0, &a, &b, &c, &d);
	return a + b + c + d;
}
]==], "asm_cpuid_local(0)", {run = true})

asmc("asm_inout", [==[
int asm_inout(int x, int y)
{
	asm("addl %1,%0" : "+r"(x) : "r"(y));
	return x;
}
]==], "asm_inout(3, 4)", {run = true})

asmc("asm_memclob", [==[
int G;
int asm_memclob(int x)
{
	G = x;
	asm volatile("" : : : "memory");
	return G + 1;
}
]==], "asm_memclob(3)", {run = true})

asmc("asm_bts", [==[
int asm_bts(u32 *addr, int nr)
{
	asm("btsl %1,%0" : "+m"(*addr) : "Ir"(nr));
	return 0;
}
]==], "asm_bts(V, 3)", {run = true})

asmc("asm_exported_outb", [==[
void asm_exported_outb(u8 v, u16 port)
{
	outb(v, port);
}
]==], "(asm_exported_outb(1, 2), 0)")

-- An "m" input fed a constant through an inlined parameter wants the
-- place and not the value: `ldmxcsr(MXCSR_DEFAULT)` in the kernel.
-- `divl` has no immediate form, so a constant put there is unbuilt
-- rather than silently wrong.
asmc("asm_memconst", [==[
static inline u32 divm(u32 lo, u32 d)
{
	u32 q;

	asm("xorl %%edx,%%edx\n\tdivl %1" : "=a"(q) : "m"(d), "a"(lo)
	    : "edx", "cc");
	return q;
}
int asm_memconst(int x)
{
	return (int)divm((u32)x, 7u);
}
]==], "asm_memconst(100)", {run = true})

-- Whether a static body is built where it is called ------------------

local H = {
	h8 = "static int h8(int x)\n{\n\treturn x + 1;\n}\n",
	h24 = "static int h24(int x)\n{\n\treturn ((x * 3 + 1) ^ (x >> 2)) - (x & 7);\n}\n",
	h64 = [==[
static int h64(int x)
{
	int i, s = 0;

	for (i = 0; i < x; i++)
		s += (i ^ x) & 5;
	return s - x;
}
]==],
}

local function inl(name, helper, sites, kind)
	local h = H[helper]

	if kind == "inline" then
		h = h:gsub("^static ", "static inline ")
	elseif kind == "always" then
		h = h:gsub("^static ", "static inline __attribute__((always_inline)) ")
	end
	local b = {}

	b[#b + 1] = ("int %s(int x)\n{\n\tint r = 0;\n"):format(name)
	for i = 1, sites do
		b[#b + 1] = ("\tr += %s(x + %d);\n"):format(helper, i)
	end
	b[#b + 1] = "\treturn r;\n}\n"
	cell("inl", name, h .. table.concat(b), name .. "(3)")
end

for _, hn in ipairs{"h8", "h24", "h64"} do
	for _, s in ipairs{1, 3} do
		inl(("inl_%s_%d"):format(hn, s), hn, s, "static")
		inl(("inl_%si_%d"):format(hn, s), hn, s, "inline")
	end
end
inl("inl_h8a_3", "h8", 3, "always")
inl("inl_h24a_3", "h24", 3, "always")

-- A record parameter handed down a chain of bodies, and a member at
-- its front stepped by a constant on the way: the kernel's sockptr_t
-- through copy_to_sockptr, copy_to_sockptr_offset and copy_to_user.
-- The member has the offset of the slot that holds the record, and
-- must not be read as the record.  The step is not zero, which would
-- fold away and take the case with it.
cell("inl", "inl_recmem", [==[
struct sp {
	void *user;
	int is_kernel;
};
static __attribute__((noinline)) int sp_leaf(void *to, const void *from,
					     unsigned long n)
{
	return (int)((char *)to - (const char *)from) + (int)n;
}
static inline __attribute__((always_inline)) int sp_is_kernel(struct sp p)
{
	return p.is_kernel;
}
static inline __attribute__((always_inline)) int sp_to_user(void *to,
	const void *from, unsigned long n)
{
	if (n > 64)
		return (int)n;
	return sp_leaf(to, from, n);
}
static inline __attribute__((always_inline)) int sp_copy_off(struct sp dst,
	unsigned long offset, const void *src, unsigned long size)
{
	if (!sp_is_kernel(dst))
		return sp_to_user(dst.user + offset, src, size);
	return -1;
}
static inline __attribute__((always_inline)) int sp_copy(struct sp dst,
	const void *src, unsigned long size)
{
	return sp_copy_off(dst, 4, src, size);
}
int inl_recmem(int x)
{
	char buf[16];
	struct sp p;

	p.user = buf;
	p.is_kernel = 0;
	return sp_copy(p, buf + (x & 7), 3);
}
]==], "inl_recmem(5)")

-- Variadic ----------------------------------------------------------------

cell("va", "va_wrap", [==[
int extva(const char *, __builtin_va_list);
int va_wrap(const char *f, ...)
{
	__builtin_va_list ap;
	int r;

	__builtin_va_start(ap, f);
	r = extva(f, ap);
	__builtin_va_end(ap);
	return r;
}
]==], "va_wrap(\"ab\", 3, 4)", {norun = true})
-- norun: on arm64 and riscv mcc's va_list is a record of its own, not
-- the platform's, so a list it builds cannot be read by a gcc callee.

cell("va", "va_sum", [==[
int va_sum(int n, ...)
{
	__builtin_va_list ap;
	int i, s = 0;

	__builtin_va_start(ap, n);
	for (i = 0; i < n; i++)
		s += __builtin_va_arg(ap, int);
	__builtin_va_end(ap);
	return s;
}
]==], "va_sum(3, 4, 5, 6)")

cell("va", "va_mixed", [==[
int va_mixed(int n, ...)
{
	__builtin_va_list ap;
	int s;
	const char *p;

	__builtin_va_start(ap, n);
	s = __builtin_va_arg(ap, int);
	p = __builtin_va_arg(ap, const char *);
	s += p[0] + (int)__builtin_va_arg(ap, unsigned long);
	__builtin_va_end(ap);
	return s + n;
}
]==], "va_mixed(1, 2, \"x\", 5UL)")

-- Control flow ------------------------------------------------------------

local function ctl(name, body, call) cell("ctl", name, body, call) end

ctl("ctl_if1", [==[
int ctl_if1(int x, int y)
{
	if (x > y)
		return x - y;
	return y - x;
}
]==], "ctl_if1(3, 5)")

ctl("ctl_if_nested", [==[
int ctl_if_nested(int x, int y)
{
	if (x > 0) {
		if (y > 0)
			return x + y;
		return x;
	}
	return y;
}
]==], "ctl_if_nested(3, 5)")

ctl("ctl_elif4_ret", [==[
int ctl_elif4_ret(int x, int y)
{
	if (x == 1)
		return y + 1;
	else if (x == 2)
		return y * 2;
	else if (x == 3)
		return y - 3;
	else if (x == 4)
		return y ^ 4;
	return 0;
}
]==], "ctl_elif4_ret(3, 5)")

ctl("ctl_elif4_assign", [==[
int ctl_elif4_assign(int x, int y)
{
	int r;

	if (x == 1)
		r = y + 1;
	else if (x == 2)
		r = y * 2;
	else if (x == 3)
		r = y - 3;
	else
		r = y ^ 4;
	return r + x;
}
]==], "ctl_elif4_assign(3, 5)")

local function switch(name, cases, sparse)
	local b = {}

	b[#b + 1] = ("int %s(int x, int y)\n{\n\tswitch (x) {\n"):format(name)
	for i = 1, cases do
		local v = sparse and (10 ^ (i - 1) // 1) or i

		b[#b + 1] = ("\tcase %d:\n\t\treturn y %s %d;\n")
			:format(math.tointeger(v) or v,
				({"+", "*", "-", "^", "|", "&"})[(i - 1) % 6 + 1],
				i * 7)
	end
	b[#b + 1] = "\t}\n\treturn 0;\n}\n"
	ctl(name, table.concat(b), name .. "(3, 5)")
end

switch("ctl_switch4", 4)
switch("ctl_switch8", 8)
switch("ctl_switch16", 16)
switch("ctl_switch_sparse6", 6, true)

ctl("ctl_switch_fall", [==[
int ctl_switch_fall(int x, int y)
{
	switch (x) {
	case 1:
		y += 1;
	case 2:
		y *= 3;
		break;
	case 3:
		y -= 7;
		break;
	default:
		y = 0;
	}
	return y;
}
]==], "ctl_switch_fall(1, 5)")

ctl("ctl_switch_loop", [==[
int ctl_switch_loop(const char *s, int n)
{
	int i, r = 0;

	for (i = 0; i < n; i++) {
		switch (s[i]) {
		case 'a':
			r += 1;
			break;
		case 'b':
			r *= 2;
			break;
		case 'c':
			r ^= 5;
			break;
		default:
			r--;
		}
	}
	return r;
}
]==], "ctl_switch_loop(\"abcd\", 4)")

ctl("ctl_for_n", [==[
int ctl_for_n(const int *a, int n)
{
	int i, s = 0;

	for (i = 0; i < n; i++)
		s += a[i];
	return s;
}
]==], "ctl_for_n(V, 3)")

ctl("ctl_for_call", [==[
int ctl_for_call(int n)
{
	int i, s = 0;

	for (i = 0; i < n; i++)
		s += ext(i);
	return s;
}
]==], "ctl_for_call(3)")

ctl("ctl_for_live", [==[
int ctl_for_live(int n, int x)
{
	int i, s = 0;

	for (i = 0; i < n; i++) {
		s += ext(i);
		s ^= x;
	}
	return s;
}
]==], "ctl_for_live(3, 9)")

ctl("ctl_while_ptr", [==[
int ctl_while_ptr(const char *s)
{
	const char *p = s;

	while (*p)
		p++;
	return p - s;
}
]==], "ctl_while_ptr(\"hello\")")

ctl("ctl_do", [==[
int ctl_do(int n)
{
	int s = 0;

	do {
		s += n;
		n--;
	} while (n > 0);
	return s;
}
]==], "ctl_do(4)")

ctl("ctl_nested2", [==[
int ctl_nested2(int n, int m)
{
	int i, j, s = 0;

	for (i = 0; i < n; i++)
		for (j = 0; j < m; j++)
			s += i * j;
	return s;
}
]==], "ctl_nested2(3, 4)")

ctl("ctl_break", [==[
int ctl_break(const int *a, int n, int k)
{
	int i;

	for (i = 0; i < n; i++)
		if (a[i] == k)
			break;
	return i;
}
]==], "ctl_break(V, 3, 2)")

ctl("ctl_continue", [==[
int ctl_continue(const int *a, int n)
{
	int i, s = 0;

	for (i = 0; i < n; i++) {
		if (a[i] & 1)
			continue;
		s += a[i];
	}
	return s;
}
]==], "ctl_continue(V, 3)")

ctl("ctl_early_ret", [==[
int ctl_early_ret(const int *a, int n, int k)
{
	int i;

	for (i = 0; i < n; i++)
		if (a[i] == k)
			return i;
	return -1;
}
]==], "ctl_early_ret(V, 3, 2)")

ctl("ctl_goto_fwd", [==[
int ctl_goto_fwd(int x, int y)
{
	int r = 0;

	if (x < 0)
		goto out;
	r = ext(x);
	if (r < y)
		goto out;
	r += y;
out:
	return r;
}
]==], "ctl_goto_fwd(3, 5)")

ctl("ctl_goto_back", [==[
int ctl_goto_back(int n)
{
	int s = 0;
again:
	s += n;
	if (--n > 0)
		goto again;
	return s;
}
]==], "ctl_goto_back(4)")

ctl("ctl_and_loop", [==[
int ctl_and_loop(const char *p, int n)
{
	int i = 0;

	while (i < n && p[i] != ' ')
		i++;
	return i;
}
]==], "ctl_and_loop(\"ab cd\", 5)")

ctl("ctl_two_iv", [==[
int ctl_two_iv(int *a, int n)
{
	int i, j;

	for (i = 0, j = n - 1; i < j; i++, j--) {
		int t = a[i];

		a[i] = a[j];
		a[j] = t;
	}
	return a[0];
}
]==], "ctl_two_iv(V, 3)")

ctl("ctl_ret_mid", [==[
int ctl_ret_mid(int x, int y)
{
	int r = ext(x);

	if (r == 0)
		return -1;
	r = ext2(r + y);
	if (r == 5)
		return -2;
	r = ext3(r);
	if (r < 0)
		return -3;
	return r;
}
]==], "ctl_ret_mid(3, 5)")

ctl("ctl_count_down", [==[
int ctl_count_down(int n)
{
	int s = 0;

	while (n--)
		s += ext(n);
	return s;
}
]==], "ctl_count_down(3)")

ctl("ctl_flag_loop", [==[
int ctl_flag_loop(const int *a, int n)
{
	int i, found = 0;

	for (i = 0; i < n; i++) {
		if (a[i] == 0)
			found = 1;
	}
	return found ? i : -i;
}
]==], "ctl_flag_loop(V, 3)")

-- Expression depth -----------------------------------------------------------

local function expr(name, body, call) cell("expr", name, body, call) end

expr("expr_n1", [==[
int expr_n1(int a, int b)
{
	return a + b;
}
]==], "expr_n1(3, 5)")

expr("expr_n2", [==[
int expr_n2(int a, int b, int c, int d)
{
	return (a + b) * (c + d);
}
]==], "expr_n2(3, 5, 7, 9)")

expr("expr_n3", [==[
int expr_n3(int a, int b, int c, int d, int e, int f)
{
	return ((a + b) * (c + d)) ^ ((e + f) * (a + c));
}
]==], "expr_n3(3, 5, 7, 9, 11, 13)")

expr("expr_n4", [==[
int expr_n4(int a, int b, int c, int d, int e, int f)
{
	return (((a + b) * (c + d)) ^ ((e + f) * (a + c))) -
	       (((a - b) * (c - d)) | ((e - f) * (a - c)));
}
]==], "expr_n4(3, 5, 7, 9, 11, 13)")

expr("expr_call_leaf", [==[
int expr_call_leaf(int a, int b)
{
	return a + ext(b);
}
]==], "expr_call_leaf(3, 5)")

expr("expr_call2", [==[
int expr_call2(int a, int b)
{
	return ext(a) + ext2(b);
}
]==], "expr_call2(3, 5)")

expr("expr_nested_call", [==[
int expr_nested_call(int x)
{
	return ext(ext2(x));
}
]==], "expr_nested_call(3)")

expr("expr_call_args", [==[
int expr_call_args(int a, int b)
{
	return ext3(ext(a) + ext2(b));
}
]==], "expr_call_args(3, 5)")

expr("expr_mem_ops", [==[
int expr_mem_ops(const int *p)
{
	return p[0] * p[1] + p[2] * p[3];
}
]==], "expr_mem_ops(V)")

expr("expr_mul_add_chain", [==[
int expr_mul_add_chain(int a, int b, int c)
{
	return a * b + b * c + c * a;
}
]==], "expr_mul_add_chain(3, 5, 7)")

-- Records and memory ---------------------------------------------------------

local function mem(name, body, call, opt) cell("mem", name, body, call, opt) end

mem("mem_zero_ss", [==[
int mem_zero_ss(int x)
{
	struct ss v = {0};

	v.a = x;
	extv(&v);
	return v.b;
}
]==], "mem_zero_ss(3)")

mem("mem_biosregs", [==[
int mem_biosregs(int x)
{
	struct bs ir, or;

	memset(&ir, 0, sizeof ir);
	memset(&or, 0, sizeof or);
	ir.ax = x;
	ir.dx = 3;
	extv(&ir);
	extv(&or);
	return or.ax + ir.dx;
}
]==], "mem_biosregs(3)")

mem("mem_copy_ss", [==[
int mem_copy_ss(const struct ss *p)
{
	struct ss v = *p;

	extv(&v);
	return v.a + v.b;
}
]==], "mem_copy_ss(&SSV)")

mem("mem_copy_bs", [==[
int mem_copy_bs(const struct bs *p)
{
	struct bs v = *p;

	extv(&v);
	return v.ax + v.flags;
}
]==], "mem_copy_bs(&BSV)")

mem("mem_pass_ss", [==[
int mem_pass_ss(int x)
{
	struct ss v;

	v.a = x;
	v.b = x + 1;
	return extss(v);
}
]==], "mem_pass_ss(3)")

mem("mem_pass_bs", [==[
struct bs G;
int mem_pass_bs(int x)
{
	G.ax = x;
	return extbs(G);
}
]==], "mem_pass_bs(3)")

mem("mem_ret_ss_use", [==[
int mem_ret_ss_use(int x)
{
	struct ss v = extrss(x);

	return v.a - v.b;
}
]==], "mem_ret_ss_use(3)")

mem("mem_arr_init", [==[
int mem_arr_init(int x)
{
	int a[4] = {1, 2, 3, 4};

	extv(a);
	return a[x & 3];
}
]==], "mem_arr_init(3)")

mem("mem_memset16", [==[
int mem_memset16(int x)
{
	u8 b[16];

	memset(b, 0, 16);
	b[x & 15] = 1;
	extv(b);
	return b[0];
}
]==], "mem_memset16(3)")

mem("mem_memcpy16", [==[
int mem_memcpy16(const void *p)
{
	u8 b[16];

	memcpy(b, p, 16);
	extv(b);
	return b[0];
}
]==], "mem_memcpy16(V)")

mem("mem_local_arr_var", [==[
int mem_local_arr_var(int i, int x)
{
	char buf[32];

	buf[0] = 0;
	buf[i & 31] = x;
	extv(buf);
	return buf[0];
}
]==], "mem_local_arr_var(3, 4)")

mem("mem_struct_ptr_write", [==[
int mem_struct_ptr_write(struct bs *r, int x)
{
	r->ax = x;
	r->bx = 0;
	r->flags = 1;
	return 0;
}
]==], "mem_struct_ptr_write(&BSV, 3)")

mem("mem_glob_struct_init", [==[
struct gs G;
int mem_glob_struct_init(int x)
{
	G.f = x;
	G.b = 1;
	G.h = 2;
	G.s[1].x = 3;
	return 0;
}
]==], "mem_glob_struct_init(3)")

-- Widths and signs --------------------------------------------------------

local function ty(name, body, call) cell("type", name, body, call) end

ty("ty_u8_load_add", [==[
int ty_u8_load_add(const u8 *p)
{
	u8 c = *p;

	return c + 1;
}
]==], "ty_u8_load_add((u8 *)V)")

ty("ty_s16_mul", [==[
int ty_s16_mul(const s16 *hp)
{
	s16 h = *hp;

	return h * 2;
}
]==], "ty_s16_mul((s16 *)V)")

ty("ty_u32_to_u8_store", [==[
int ty_u32_to_u8_store(u8 *bp, u32 x)
{
	*bp = x;
	return 0;
}
]==], "ty_u32_to_u8_store((u8 *)V, 3)")

ty("ty_char_cmp_signed", [==[
int ty_char_cmp_signed(s8 a, s8 b)
{
	return a < b;
}
]==], "ty_char_cmp_signed(-3, 3)")

ty("ty_u16_shift", [==[
int ty_u16_shift(const u16 *hp)
{
	u16 h = *hp;

	return h >> 3;
}
]==], "ty_u16_shift((u16 *)V)")

ty("ty_u8_loop", [==[
int ty_u8_loop(const u8 *p, u8 n)
{
	u8 i;
	int s = 0;

	for (i = 0; i < n; i++)
		s += p[i];
	return s;
}
]==], "ty_u8_loop((u8 *)V, 3)")

ty("ty_mixed_add", [==[
int ty_mixed_add(u8 a, s16 b, u32 c)
{
	return a + b + c;
}
]==], "ty_mixed_add(3, -5, 7)")

ty("ty_ptr_cast", [==[
int ty_ptr_cast(const void *p)
{
	return ((const u16 *)p)[1];
}
]==], "ty_ptr_cast(V)")

ty("ty_bool", [==[
int ty_bool(int x)
{
	_Bool b = x;

	return b;
}
]==], "ty_bool(3)")

ty("ty_u8_wrap", [==[
int ty_u8_wrap(int x, int y)
{
	u8 c = x;

	c += y;
	return c;
}
]==], "ty_u8_wrap(250, 10)")

ty("ty_s32_to_u16", [==[
u16 ty_s32_to_u16(int x)
{
	return (u16)x;
}
]==], "ty_s32_to_u16(70000)")

ty("ty_s8_glob_cmp", [==[
s8 G;
int ty_s8_glob_cmp(int x)
{
	if (G < 0)
		return x;
	return G;
}
]==], "ty_s8_glob_cmp(3)")

-- Constants at the edges of the immediate forms ------------------------

local function k(name, body, call) cell("konst", name, body, call) end

k("k_add1", "int k_add1(int x)\n{\n\treturn x + 1;\n}\n", "k_add1(3)")
k("k_sub1", "int k_sub1(int x)\n{\n\treturn x - 1;\n}\n", "k_sub1(3)")
k("k_add127", "int k_add127(int x)\n{\n\treturn x + 127;\n}\n", "k_add127(3)")
k("k_add128", "int k_add128(int x)\n{\n\treturn x + 128;\n}\n", "k_add128(3)")
k("k_and255", "int k_and255(int x)\n{\n\treturn x & 255;\n}\n", "k_and255(300)")
k("k_add256", "int k_add256(int x)\n{\n\treturn x + 256;\n}\n", "k_add256(3)")
k("k_mul2", "int k_mul2(int x)\n{\n\treturn x * 2;\n}\n", "k_mul2(3)")
k("k_shl1", "int k_shl1(int x)\n{\n\treturn x << 1;\n}\n", "k_shl1(3)")
k("k_big", "int k_big(int x)\n{\n\treturn x + 0x12345678;\n}\n", "k_big(3)")
k("k_retneg", "int k_retneg(int x)\n{\n\tif (x)\n\t\treturn -34;\n\treturn -22;\n}\n", "k_retneg(3)")
k("k_setm1", [==[
int k_setm1(int x)
{
	int l = -1;

	extv(&l);
	return l + x;
}
]==], "k_setm1(3)")
k("k_add0", "int k_add0(const int *p, int x)\n{\n\treturn p[0] + x;\n}\n", "k_add0(V, 3)")
k("k_cmp255", "int k_cmp255(u32 x)\n{\n\treturn x > 255;\n}\n", "k_cmp255(300)")
k("k_eq0_sel", "int k_eq0_sel(int x, int y, int z)\n{\n\treturn x == 0 ? y : z;\n}\n", "k_eq0_sel(0, 3, 5)")
k("k_zero_ret", "int k_zero_ret(int x)\n{\n\tif (x > 3)\n\t\treturn 0;\n\treturn 1;\n}\n", "k_zero_ret(5)")
k("k_u16_m1", [==[
int k_u16_m1(int x)
{
	u16 fcw = -1, fsw = -1;

	extv(&fcw);
	extv(&fsw);
	return fcw + fsw + x;
}
]==], "k_u16_m1(3)")

-- Pointers ----------------------------------------------------------------

local function ptr(name, body, call) cell("ptr", name, body, call) end

ptr("ptr_idx_var", "int ptr_idx_var(const int *p, int i)\n{\n\treturn p[i];\n}\n", "ptr_idx_var(V, 1)")
ptr("ptr_idx_const", "int ptr_idx_const(const int *p)\n{\n\treturn p[3];\n}\n", "ptr_idx_const(V)")
ptr("ptr_postinc_deref", [==[
int ptr_postinc_deref(const u8 *p, int n)
{
	int s = 0;

	while (n--)
		s += *p++;
	return s;
}
]==], "ptr_postinc_deref((u8 *)V, 3)")
ptr("ptr_add_const", [==[
int ptr_add_const(const int *p)
{
	p += 3;
	return *p;
}
]==], "ptr_add_const(V)")
ptr("ptr_diff", "int ptr_diff(const int *p, const int *q)\n{\n\treturn p - q;\n}\n", "ptr_diff(V + 3, V)")
ptr("ptr_cmp", "int ptr_cmp(const int *p, const int *q, int x)\n{\n\tif (p < q)\n\t\treturn x;\n\treturn 0;\n}\n", "ptr_cmp(V, V + 3, 5)")
ptr("ptr_deep", "int ptr_deep(struct gs *p)\n{\n\treturn p->s[2].y;\n}\n", "ptr_deep(&GSV)")
ptr("ptr_ptr", "int ptr_ptr(struct gs **pp)\n{\n\treturn (*pp)->f;\n}\n", "ptr_ptr(&GSP)")
ptr("ptr_arr_struct", "int ptr_arr_struct(const struct ss *p, int i)\n{\n\treturn p[i].b;\n}\n", "ptr_arr_struct(&SSV, 0)")
ptr("ptr_strlen_idx", [==[
int ptr_strlen_idx(const char *s)
{
	int i = 0;

	while (s[i])
		i++;
	return i;
}
]==], "ptr_strlen_idx(\"hello\")")
ptr("ptr_int_rmw", "int ptr_int_rmw(int *ip, int i)\n{\n\tip[i] += 1;\n\treturn 0;\n}\n", "ptr_int_rmw(V, 1)")
ptr("ptr_char_walk_cmp", [==[
const char *ptr_char_walk_cmp(const char *s, int c)
{
	while (*s != c) {
		if (!*s++)
			return 0;
	}
	return s;
}
]==], "*ptr_char_walk_cmp(\"hello\", 'l')")

-- Frames ----------------------------------------------------------------------

local function fr(name, body, call, opt) cell("frame", name, body, call, opt) end

fr("fr_leaf0", "int fr_leaf0(void)\n{\n\treturn 5;\n}\n", "fr_leaf0()")
fr("fr_leaf_arg", "int fr_leaf_arg(int x)\n{\n\treturn x + 3;\n}\n", "fr_leaf_arg(3)")
fr("fr_leaf_local", [==[
int fr_leaf_local(int x)
{
	int l = x * 3;

	return l + x;
}
]==], "fr_leaf_local(3)")
fr("fr_alloca", [==[
int fr_alloca(int n)
{
	char *b = __builtin_alloca(n);

	b[0] = 1;
	extv(b);
	return b[0];
}
]==], "fr_alloca(8)")
fr("fr_addr_local", [==[
int fr_addr_local(int x)
{
	int l = x;

	extv(&l);
	return l;
}
]==], "fr_addr_local(3)")
fr("fr_local_arr", [==[
int fr_local_arr(int x, int y)
{
	int a[8];

	a[0] = 0;
	a[x & 7] = y;
	return a[0];
}
]==], "fr_local_arr(3, 4)")
fr("fr_intcall_shape", [==[
void intcall(u8, const struct bs *, struct bs *);
int fr_intcall_shape(int x)
{
	struct bs ir, or;

	memset(&ir, 0, sizeof ir);
	ir.ax = 0x4f00 + x;
	intcall(0x10, &ir, &or);
	return or.ax == 0x4f ? or.bx : -1;
}
]==], "fr_intcall_shape(3)")
fr("fr_unused_arg", "int fr_unused_arg(int x, int y)\n{\n\treturn y;\n}\n", "fr_unused_arg(3, 4)")

-- The frame was covering these: a body that leaves the stack pointer
-- somewhere else on one path, and still has to return.
fr("fr_alloca_unstored", [==[
int fr_alloca_unstored(int n)
{
	void *b = __builtin_alloca(n);

	extv(b);
	extv(b);
	extv(b);
	extv(b);
	return n;
}
]==], "fr_alloca_unstored(8)")
fr("fr_stmtexpr_ret", [==[
int fr_stmtexpr_ret(int a, int b)
{
	return a - ({ if (b > 100) return 5; ext(b) * 2; });
}
]==], "fr_stmtexpr_ret(3, 4)")
fr("fr_stmtexpr_ret_taken", [==[
int fr_stmtexpr_ret_taken(int a, int b)
{
	return a - ({ if (b > 1) return a + 5; ext(b) * 2; });
}
]==], "fr_stmtexpr_ret_taken(3, 4)")
-- No parameter and no local, so nothing names the frame pointer; the
-- right operand is worked out first onto the stack, and the return
-- inside the statement expression leaves it there.
fr("fr_stmtexpr_pending", [==[
int G;
int fr_stmtexpr_pending(void)
{
	return ({ if (G > 1) return 5; ext(G) * 2; }) - ext(3);
}
]==], "(G_fr_stmtexpr_pending = 7, fr_stmtexpr_pending())")
fr("fr_asm_esp", [==[
int fr_asm_esp(int x)
{
	unsigned long sp;

	asm("mov %%esp,%0" : "=r"(sp));
	return (int)(sp & 3) + x;
}
]==], "fr_asm_esp(3)", {i386 = true})
fr("fr_asm_pushpop", [==[
int fr_asm_pushpop(int x)
{
	asm volatile("pushl %0\n\tpopl %0" : "+r"(x));
	return x + 1;
}
]==], "fr_asm_pushpop(3)", {i386 = true})
fr("fr_ret_in_loop_call", [==[
int fr_ret_in_loop_call(int n)
{
	int i;

	for (i = 0; i < n; i++)
		if (ext(i) > 10)
			return i;
	return -1;
}
]==], "fr_ret_in_loop_call(9)")

-- Calls ----------------------------------------------------------------------

local function call(name, body, c) cell("call", name, body, c) end

call("call_0", "int ext0(void);\nint call_0(void)\n{\n\treturn ext0() + 1;\n}\n", "call_0()")
call("call_3const", "int call_3const(void)\n{\n\treturn ext3args(1, 2, 3);\n}\n", "call_3const()")
call("call_3var", "int call_3var(int a, int b, int c)\n{\n\treturn ext3args(c, a, b);\n}\n", "call_3var(1, 2, 3)")
call("call_6const", "int call_6const(void)\n{\n\treturn ext6(1, 2, 3, 4, 5, 6);\n}\n", "call_6const()")
call("call_6var", "int call_6var(int a, int b, int c)\n{\n\treturn ext6(a, b, c, a + 1, b + 1, c + 1);\n}\n", "call_6var(1, 2, 3)")
call("call_indirect_glob", [==[
struct gs G;
int call_indirect_glob(int x)
{
	return G.fp(x) + G.fp(x + 1);
}
]==], "(G_call_indirect_glob.fp = ext, call_indirect_glob(3))")
call("call_tail", "int call_tail(int x)\n{\n\treturn ext(x + 1);\n}\n", "call_tail(3)")
call("call_res_twice", [==[
int call_res_twice(int x)
{
	int r = ext(x);

	return r * r + r;
}
]==], "call_res_twice(3)")
call("call_recursive", [==[
int call_recursive(int n)
{
	if (n <= 1)
		return 1;
	return n * call_recursive(n - 1);
}
]==], "call_recursive(5)")
call("call_ret_char", [==[
int call_ret_char(int x)
{
	u8 r = extc(x);

	return r + 1;
}
]==], "call_ret_char(3)")
call("call_ret_u64", [==[
int call_ret_u64(int x)
{
	u64 r = extu64(x);

	return (int)(r >> 3);
}
]==], "call_ret_u64(3)")
call("call_arg_from_call", "int call_arg_from_call(int x)\n{\n\treturn ext3args(ext(x), x, ext2(x));\n}\n", "call_arg_from_call(3)")
call("call_ptr_args", [==[
int call_ptr_args(int x)
{
	int a = x, b = x + 1;

	extv(&a);
	extv(&b);
	return a + b;
}
]==], "call_ptr_args(3)")

-- Writing it out --------------------------------------------------------------

function gen.cells()
	return cells
end

-- One file per cell under dir/src, and the driver that calls them all.
-- `only` narrows both to a list of cells.  A cell marked `i386` is
-- 32-bit assembly and is left out of the list for another machine.
function gen.write(dir, only)
	local cells = only or cells

	os.execute("mkdir -p " .. dir .. "/src")
	for _, c in ipairs(cells) do
		local f = assert(io.open(dir .. "/src/" .. c.name .. ".c", "w"))

		f:write("#define G G_", c.name, "\n", PRELUDE, "\n", c.src)
		f:close()
	end
	local d = assert(io.open(dir .. "/src/driver.c", "w"))

	d:write([==[
#include <stdio.h>
#ifdef OWN_MEM
/* A build whose convention libc does not share carries its own. */
void *memset(void *d, int c, __SIZE_TYPE__ n)
{
	unsigned char *p = d;

	while (n--)
		*p++ = c;
	return d;
}
void *memcpy(void *d, const void *s, __SIZE_TYPE__ n)
{
	unsigned char *p = d;
	const unsigned char *q = s;

	while (n--)
		*p++ = *q++;
	return d;
}
/* gcc lowers a 64-bit divide to these and calls them by the same
 * convention as everything else, which libgcc's were not built with. */
unsigned long long __udivdi3(unsigned long long n, unsigned long long d)
{
	unsigned long long q = 0, r = 0;
	int i;

	for (i = 63; i >= 0; i--) {
		r = (r << 1) | ((n >> i) & 1);
		if (r >= d) {
			r -= d;
			q |= 1ULL << i;
		}
	}
	return q;
}
unsigned long long __umoddi3(unsigned long long n, unsigned long long d)
{
	unsigned long long r = 0;
	int i;

	for (i = 63; i >= 0; i--) {
		r = (r << 1) | ((n >> i) & 1);
		if (r >= d)
			r -= d;
	}
	return r;
}
#else
#include <string.h>
#endif
]==], PRELUDE, [==[
int V[8] = {2, 3, 5, 7, 11, 13, 17, 19};
struct ss SS = {4, 6}, SSV = {8, 9};
struct bs BS = {1, 2, 3, 4, 5, 6, 7, 8, 9, {0}}, BSV = {11, 12, 13};
struct gs GSV = {1, 2, 3, {4, 5, 6, 7}, {{8, 9}, {10, 11}, {12, 13}}, 0, 0};
struct gs *GSP = &GSV;
int ext(int x) { return x * 3 + 1; }
int ext0(void) { return 17; }
int ext2(int x) { return x ^ 0x55; }
int ext3(int x) { return x - 7; }
int ext3args(int a, int b, int c) { return a * 100 + b * 10 + c; }
int ext6(int a, int b, int c, int d, int e, int f)
{
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6;
}
u32 extp(void *p) { return *(u32 *)p; }
void extv(void *p) { ((u8 *)p)[0] ^= 1; }
u8 extc(int x) { return x + 250; }
u64 extu64(int x) { return (u64)x << 33; }
int extss(struct ss s) { return s.a * 10 + s.b; }
int extbs(struct bs b) { return b.ax + b.dx; }
struct ss extrss(int x) { struct ss r = {x, x * 2}; return r; }
int extva(const char *f, __builtin_va_list ap)
{
	return f[0] + __builtin_va_arg(ap, int);
}
void intcall(u8 n, const struct bs *ir, struct bs *or)
{
	*or = *ir;
	or->ax = 0x4f;
	or->bx = n;
}
]==])
	-- The driver needs each cell's prototype, which is the line of
	-- its source that defines it.
	for _, c in ipairs(cells) do
		if not c.norun then
			for line in c.src:gmatch("[^\n]+") do
				if line:find(c.name .. "(", 1, true) and
				   not line:find(";", 1, true) then
					d:write(line, ";\n")
					break
				end
			end
			-- The cell's global, whatever its type, so a call
			-- may set it first.
			local gty = c.src:match("\n([%w_ ]+) G;\n") or
				c.src:match("^([%w_ ]+) G;\n")

			if gty then
				d:write(("extern %s G_%s;\n"):format(gty, c.name))
			end
		end
	end
	d:write("int main(void)\n{\n\tu64 v;\n")
	for _, c in ipairs(cells) do
		if not c.norun then
			local show = c.show and ("{ " .. c.show:format(c.call) ..
						 " }")
				or ("v = (u64)(%s);"):format(c.call)

			d:write(("\t%s\n\tprintf(\"%s %%llu\\n\", (unsigned long long)v);\n")
				:format(show, c.name))
		end
	end
	d:write("\treturn 0;\n}\n")
	d:close()
	local t = assert(io.open(dir .. "/cells.tsv", "w"))

	for _, c in ipairs(cells) do
		t:write(c.name, "\t", c.family, "\t", c.norun and "norun" or "run",
			"\n")
	end
	t:close()
	return cells
end

if arg and arg[0] and arg[0]:match("gen%.lua$") then
	gen.write(arg[1] or "build/opt")
	io.write(#cells, " cells\n")
end

return gen
