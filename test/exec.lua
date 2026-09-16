-- Generate three functions for a target, assemble them, link against a C
-- driver and run.  The point is to prove the code, not to read it.
--
--   lua5.4 test/exec.lua [amd64|riscv64|riscv32]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../?/init.lua;" .. package.path

local tree = require "tree"
local gen  = require "gen"

local which = arg[1] or "amd64"
local t = require("target." .. which)

local TOOL = {
	amd64   = {cc = "gcc",                          run = ""},
	riscv64 = {cc = "riscv64-linux-gnu-gcc -static", run = "qemu-riscv64 "},
	-- no rv32 libc or emulator here, so that one only assembles
	riscv32 = {as = "riscv64-linux-gnu-as -march=rv32imac -mabi=ilp32"},
}
local tool = assert(TOOL[which], "no toolchain for " .. which)

local ty = tree.types(t)
local C = tree.const
local bin, un = tree.binary, tree.unary
local W = t.ptrsize == 8 and ty.i64 or ty.i32
local function A(typ, i) return tree.auto(typ, t.slot(i)) end

local sink = require("buf").new()
local g = gen.new(t, sink)
local function set(lv, rv) g:expr(bin("ASGN", lv.ty, lv, rv), "eff") end

-- long sum(long n) { long i, s; s = 0; i = 1;
--                    while (i <= n) { s += i; i++; } return s; }
do
	local n, i, s = A(W, 1), A(W, 2), A(W, 3)
	local frame = t.frame(3)
	t.prologue(g, "sum", frame, {{off = t.slot(1), reg = 0}})
	set(s, C(W, 0))
	set(i, C(W, 1))
	g:write("sum_loop:\n")
	g:cond(bin("GT", W, i, n), "sum_done", true)
	set(s, bin("ADD", W, s, i))
	set(i, bin("ADD", W, i, C(W, 1)))
	t.jump(g, "sum_loop")
	g:write("sum_done:\n")
	g:expr(A(W, 3), "reg", 0)
	t.epilogue(g, frame)
end

-- long slen(char *s) { long n = 0; while (*s) { n++; s++; } return n; }
do
	local cp = ty.ptr(ty.i8)
	local s, n = A(cp, 1), A(W, 2)
	local frame = t.frame(2)
	t.prologue(g, "slen", frame, {{off = t.slot(1), reg = 0}})
	set(n, C(W, 0))
	g:write("slen_loop:\n")
	g:cond(bin("EQ", W, un("INDIR", ty.i8, s), C(ty.i8, 0)), "slen_done", true)
	set(n, bin("ADD", W, n, C(W, 1)))
	set(s, bin("ADD", cp, s, C(cp, 1)))
	t.jump(g, "slen_loop")
	g:write("slen_done:\n")
	g:expr(A(W, 2), "reg", 0)
	t.epilogue(g, frame)
end

-- long poly(long a, long b) { return (a*b + a - a*b) * 7; }
do
	local a, b, r = A(W, 1), A(W, 2), A(W, 3)
	local frame = t.frame(3)
	local function mul() return bin("MUL", W, a, b) end
	t.prologue(g, "poly", frame, {{off = t.slot(1), reg = 0}, {off = t.slot(2), reg = 1}})
	set(r, bin("MUL", W,
		bin("SUB", W, bin("ADD", W, mul(), a), mul()),
		C(W, 7)))
	g:expr(A(W, 3), "reg", 0)
	t.epilogue(g, frame)
end

-- long arith(long a, long b) { return a/b + a%b + (a<<b) - (a>>b); }
do
	local a, b, r = A(W, 1), A(W, 2), A(W, 3)
	local frame = t.frame(3)
	t.prologue(g, "arith", frame, {{off = t.slot(1), reg = 0}, {off = t.slot(2), reg = 1}})
	set(r, bin("DIV", W, a, b))
	set(r, bin("ADD", W, r, bin("MOD", W, a, b)))
	set(r, bin("ADD", W, r, bin("SHL", W, a, b)))
	set(r, bin("SUB", W, r, bin("SHR", W, a, b)))
	g:expr(A(W, 3), "reg", 0)
	t.epilogue(g, frame)
end

local asm = sink:text()
if os.getenv("SHOW") then io.write(asm) end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-exec-" .. which
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local f = assert(io.open(dir .. "/out.s", "w"))
f:write(asm)
f:close()

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

if tool.as then
	local ok, out = shell(("%s -o %s/out.o %s/out.s"):format(tool.as, dir, dir))
	if not ok then
		io.write("FAIL " .. which .. " assemble\n" .. out)
		os.exit(1)
	end
	print("ok   " .. which .. " assembles")
	os.exit(0)
end

f = assert(io.open(dir .. "/main.c", "w"))
f:write[[
#include <stdio.h>
long sum(long), slen(const char *), poly(long, long), arith(long, long);
static long ref(long a, long b) { return a/b + a%b + (a<<b) - (a>>b); }
int main(void) {
	int bad = 0;
	long v;
	v = sum(10);        if (v != 55)  { printf("sum  %ld != 55\n", v);  bad = 1; }
	v = sum(1);         if (v != 1)   { printf("sum  %ld != 1\n", v);   bad = 1; }
	v = sum(0);         if (v != 0)   { printf("sum  %ld != 0\n", v);   bad = 1; }
	v = slen("hello");  if (v != 5)   { printf("slen %ld != 5\n", v);   bad = 1; }
	v = slen("");       if (v != 0)   { printf("slen %ld != 0\n", v);   bad = 1; }
	v = poly(3, 5);     if (v != 21)  { printf("poly %ld != 21\n", v);  bad = 1; }
	v = poly(-4, 9);    if (v != -28) { printf("poly %ld != -28\n", v); bad = 1; }
	{
		static const long cases[][2] = {{100,3},{-77,2},{7,1},{-1,3},{999,7}};
		int i;
		for (i = 0; i < 5; i++) {
			long a = cases[i][0], b = cases[i][1];
			long got = arith(a, b), want = ref(a, b);
			if (got != want) {
				printf("arith(%ld,%ld) %ld != %ld\n", a, b, got, want);
				bad = 1;
			}
		}
	}
	if (!bad) printf("ok   %s code runs\n", TARGET);
	return bad;
}
]]
f:close()

local ok, out = shell(("%s -DTARGET='\"%s\"' -o %s/t %s/main.c %s/out.s")
	:format(tool.cc, which, dir, dir, dir))
if not ok then
	io.write("FAIL " .. which .. " assemble/link\n" .. out)
	os.exit(1)
end
os.exit(os.execute(tool.run .. dir .. "/t") and 0 or 1)
