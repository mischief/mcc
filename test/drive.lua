-- SPDX-License-Identifier: ISC
-- The driver, in the shape a build system expects one.
--
-- The point is that `CC=mcc` works: the flags a makefile passes to
-- everything are taken or ignored, the stages stop where -c, -S and -E say
-- they stop, and what comes out runs.  Nothing but this compiler is
-- involved -- its own assembler and its own linker make the file.
--
--   lua5.4 test/drive.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local function full(p)
	if p:sub(1, 1) == "/" then return p end
	local h = io.popen("pwd")
	local cwd = h:read("l")
	h:close()
	return cwd .. "/" .. p
end

here = full(here)
local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-drive"

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))
	f:write(text)
	f:close()
end

local function slurp(path)
	local f = io.open(path)

	if not f then return nil end
	local text = f:read("a")

	f:close()
	return text
end

local function shell(cmd)
	local p = io.popen(("cd %s && %s 2>&1"):format(dir, cmd))
	local out = p:read("a")
	return p:close(), out
end

local function cc(args)
	return shell(("%s %s %s"):format(lua, drive, args))
end

write("add.c", [[
int add(int a, int b) { return a + b; }
]])
write("main.c", [[
#include <stdio.h>
int add(int a, int b);
int main(int argc, char **argv)
{
	printf("sum %d %s %d\n", add(20, 22), "ok", argc);
	return 0;
}
]])

-- the flags a makefile passes to everything, none of which mean anything
-- here and none of which may be mistaken for a file
local noise = "-O2 -Wall -Wextra -g -std=gnu11 -pipe -fno-common -MMD"

local ok, out = cc(noise .. " -c add.c main.c")
if not tap.ok(ok and true or false, "-c compiles each file on its own") then
	tap.diag(out)
	tap.done()
end
tap.ok(io.open(dir .. "/add.o") ~= nil and
	io.open(dir .. "/main.o") ~= nil,
	"each object takes its source's name")

ok, out = cc("-o prog add.o main.o")
if not tap.ok(ok and true or false, "objects link into a program") then
	tap.diag(out)
	tap.done()
end

local _, said = shell("./prog one two")
tap.is(said, "sum 42 ok 3\n", "the program runs and gets its arguments")

ok, out = cc(noise .. " -o prog2 add.c main.c")
tap.ok(ok and true or false, "sources compile and link in one step")
local _, s2 = shell("./prog2 one two")
tap.is(s2, "sum 42 ok 3\n", "and answer the same")

ok = cc("-S add.c")
tap.ok(ok and io.open(dir .. "/add.s") ~= nil, "-S stops at assembly")

ok, out = cc("-E add.c")
tap.ok(ok and out:find("int", 1, true) ~= nil, "-E stops at tokens")

-- An expansion stands on the line where the macro's name stood, even
-- when its arguments were spread over several.  Preprocessed assembly
-- rests on it: one line there is one statement.
do
	local f = assert(io.open(dir .. "/split.c", "w"))

	f:write([[
#define TWO(a, b) one a, b, three
TWO(x,
    y)
mark
]])
	f:close()
	ok, out = cc("-E split.c")
	local said = nil

	for l in (out or ""):gmatch("[^\n]+") do
		if l:find("one", 1, true) then said = l end
	end
	if not tap.ok(said == "one x, y, three",
	    "an expansion stays on one line") then
		tap.diag(tostring(said))
	end
end

-- `#` puts a backslash in front of a quote or a backslash that came
-- out of a string literal, and leaves a stray one alone.  Assembly
-- handed to the kernel's __stringify rests on the second half.
do
	local f = assert(io.open(dir .. "/hash.c", "w"))

	f:write([[
#define S(x) #x
S(mov $(\nr/2))
S("a\\b")
]])
	f:close()
	ok, out = cc("-E hash.c")
	local said = {}

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) == '"' then said[#said + 1] = l end
	end
	if not tap.ok(said[1] == [==["mov $(\nr/2)"]==] and
	    said[2] == [==["\"a\\\\b\""]==],
	    "# escapes only what it must") then
		tap.diag(tostring(said[1]) .. " / " .. tostring(said[2]))
	end
end

-- A backslash and a newline splice two lines into one.  Preprocessed
-- assembly has to come out as one line, because one line there is one
-- statement; C keeps the break, and so does gcc.
do
	local f = assert(io.open(dir .. "/cont.S", "w"))

	f:write("a b \\\n c, \\\n d\nmark\n")
	f:close()
	os.execute(("cp %s/cont.S %s/cont.c"):format(dir, dir))
	ok, out = cc("-E cont.S")
	local said = {}

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) ~= "#" and l:match("%S") then
			said[#said + 1] = l:match("^%s*(.-)%s*$")
		end
	end
	if not tap.ok(said[1] == "a b c, d",
	    "a spliced line of assembly comes out as one") then
		tap.diag(table.concat(said, " | "))
	end
	ok, out = cc("-E cont.c")
	local n = 0

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) ~= "#" and l:match("%S") then n = n + 1 end
	end
	if not tap.ok(n == 4, "a spliced line of C keeps its breaks") then
		tap.diag("lines " .. n)
	end
end

-- A macro that stands for nothing still separates what came before it
-- from what comes after, which is how the kernel writes a per-cpu
-- operand: `movq PER_CPU_VAR(x)` must not become `movq(x)`.
do
	local f = assert(io.open(dir .. "/empty.S", "w"))

	f:write([[
#define NOTHING
#define REL (%rip)
#define VAR(v) NOTHING(v)REL
	movq	VAR(top), %rsp
]])
	f:close()
	ok, out = cc("-E empty.S")
	local said = nil

	for l in (out or ""):gmatch("[^\n]+") do
		if l:find("movq", 1, true) then said = l end
	end
	if not tap.ok(said ~= nil and
	    said:find("movq (top)(%rip), %rsp", 1, true) ~= nil,
	    "a macro that expands to nothing leaves its space") then
		tap.diag(tostring(said))
	end
end

-- A body built where it is called.  The "i" constraint takes a
-- constant and nothing else, so only the caller has one: the parameter
-- still holds what was handed over when the input is read, and the
-- output writes it afterwards.  This is what linux's rip_rel_ptr needs,
-- and gcc only manages it with the optimizer on, so it is checked by
-- running rather than by comparing.
if (os.getenv("MCC_TARGET") or "amd64") == "amd64" then
	local f = assert(io.open(dir .. "/ripr.c", "w"))

	f:write([[
#include <stdio.h>
static __inline__ __attribute__((always_inline)) void *rip(void *p)
{
	__asm__("leaq %c1(%%rip), %0" : "=r"(p) : "i"(p));
	return p;
}
int v = 7;
int main(void)
{
	printf("%d %d
", *(int *)rip(&v), rip(&v) == (void *)&v);
	return 0;
}
]])
	f:close()
	ok, out = cc("-o ripr ripr.c")
	if not tap.ok(ok and true or false,
	    "a body with an immediate constraint builds where it is called")
	then
		tap.diag(out)
	else
		local _, said = shell("./ripr")

		if not tap.ok((said or ""):match("7 1") ~= nil,
		    "and the caller's address reaches the template") then
			tap.diag(tostring(said))
		end
	end
end

-- What the caller handed over may itself be a parameter of whatever
-- built the caller, so an operand that has to be a constant looks all
-- the way out.  linux's bit tests are written in two layers like this.
if (os.getenv("MCC_TARGET") or "amd64") == "amd64" then
	local f = assert(io.open(dir .. "/nest.c", "w"))

	f:write([[
#include <stdio.h>
static __inline__ __attribute__((always_inline))
int inner(long nr, const unsigned char *a)
{
	int r;
	__asm__ volatile("testb %2,%1
	setnz %b0"
		: "=q"(r) : "m"(a[nr >> 3]), "i"(1 << (nr & 7)));
	return r & 1;
}
static __inline__ __attribute__((always_inline))
int outer(long nr, const unsigned char *a) { return inner(nr, a); }
static const unsigned char t[2] = {0x05, 0x80};
int main(void)
{
	printf("%d%d%d%d
", outer(0, t), outer(1, t), outer(2, t),
	       outer(15, t));
	return 0;
}
]])
	f:close()
	ok, out = cc("-o nest nest.c")
	if not tap.ok(ok and true or false,
	    "a constant operand looks through more than one expansion")
	then
		tap.diag(out)
	else
		local _, said = shell("./nest")

		if not tap.ok((said or ""):match("1011") ~= nil,
		    "and every bit comes out where gcc puts it") then
			tap.diag(tostring(said))
		end
	end
end

-- A parameter that still holds what the caller wrote is as constant as
-- what the caller wrote.  A kernel picks between two ways of testing a
-- bit on the answer, so a `0` there costs it the good one.  gcc says
-- nothing is constant until the optimizer runs, so this is checked by
-- running rather than by comparing.
do
	local f = assert(io.open(dir .. "/cprop.c", "w"))

	f:write([[
#include <stdio.h>
static __inline__ __attribute__((always_inline)) int isconst(int x)
{ return __builtin_constant_p(x); }
static __inline__ __attribute__((always_inline)) int viaconst(int x)
{ return isconst(x); }
int main(void)
{
	printf("%d %d
", isconst(7), viaconst(7));
	return 0;
}
]])
	f:close()
	ok, out = cc("-o cprop cprop.c")
	if not tap.ok(ok and true or false, "constant_p builds") then
		tap.diag(out)
	else
		local _, said = shell("./cprop")

		if not tap.ok((said or ""):match("1 1") ~= nil,
		    "what the caller wrote is constant in the body") then
			tap.diag(tostring(said))
		end
	end
end

-- The operand of _Pragma may be a macro call of its own, so the
-- parentheses are counted rather than stopping at the first one that
-- closes.  linux turns its diagnostic pushes into one.
do
	local f = assert(io.open(dir .. "/prag.c", "w"))

	f:write([[
#define str1(s) #s
#define str(s) str1(s)
#define diag(s) _Pragma(str(GCC diagnostic s))
#define push() diag(push)
int a;
push();
int b;
]])
	f:close()
	ok, out = cc("-E prag.c")
	local said = {}

	for l in (out or ""):gmatch("[^\n]+") do
		if l:sub(1, 1) ~= "#" and l:match("%S") then
			said[#said + 1] = l:match("^%s*(.-)%s*$")
		end
	end
	if not tap.ok(said[1] == "int a;" and said[2] == ";" and
	    said[3] == "int b;", "a _Pragma takes its whole operand") then
		tap.diag(table.concat(said, " | "))
	end
end

-- On a system whose programs are position independent, an object built
-- for it is too: a name another unit owns is reached through the table,
-- the way gcc writes it.  `-fno-pic` says otherwise, and so does a
-- static link, which has no loader to fill a table in.
do
	local f = assert(io.open(dir .. "/nopic.c", "w"))

	f:write("extern int plain;\nint f(void) { return plain; }\n")
	f:close()
	local want = {["-c"] = "gotpcrel", ["-fno-pic -c"] = "pc32",
		      ["-static -c"] = "pc32", ["-fpic -c"] = "gotpcrel"}

	for flags, kind in pairs(want) do
		ok, out = cc(flags .. " -o nopic.o nopic.c")
		local said = nil

		if ok then _, said = shell("objdump -r nopic.o") end
		local got = said and said:lower():match("r_x86_64_([%w_]+)")

		if not tap.ok(got ~= nil and got:find(kind, 1, true) ~= nil,
		    ("%s gives a %s relocation"):format(flags, kind)) then
			tap.diag(tostring(got))
		end
	end
end

-- Compiling and linking in two steps reaches a data symbol the loader
-- owns.  It is the pc-relative reach that cannot be fixed up, so the
-- object has to have been built to go through the table.
do
	local f = assert(io.open(dir .. "/twostep.c", "w"))

	f:write("#include <stdio.h>\n" ..
		"int main(void){ fprintf(stderr, \"ok\\n\"); return 0; }\n")
	f:close()
	ok, out = cc("-c -o twostep.o twostep.c")
	if tap.ok(ok, "an object compiles") then
		ok, out = cc("-o twostep twostep.o")
		if not tap.ok(ok, "and links against the system library") then
			tap.diag(out)
		end
	end
end

-- A build system hands the linker script over with -Wl, because it
-- does not know whether the driver or the linker owns the flag.  This
-- driver is the linker, so it has to read it either way.
do
	local f = assert(io.open(dir .. "/wls.ld", "w"))

	f:write("ENTRY(_start)\nSECTIONS\n{\n\t. = 0x400000;\n" ..
		"\t__image_base = .;\n" ..
		"\t.text : { *(.text) *(.text.*) }\n" ..
		"\t__image_end = .;\n}\n")
	f:close()
	f = assert(io.open(dir .. "/wls.c", "w"))
	f:write("extern char __image_base[], __image_end[];\n" ..
		"long size(void){ return __image_end - __image_base; }\n" ..
		"void _start(void){ }\n")
	f:close()
	for _, how in ipairs{"-Wl,-T,wls.ld", "-Wl,-T -Wl,wls.ld",
			     "-T wls.ld"} do
		ok, out = cc("-nostdlib " .. how .. " -o wls wls.c")
		if not tap.ok(ok, how .. " names the linker script") then
			tap.diag(out)
		end
	end
end

-- A script that measures across its own sections, and an image the
-- kernel will load: a segment's file offset has to agree with its
-- address to the page, which back-dating over the headers breaks
-- unless the script left room for them.
do
	local f = assert(io.open(dir .. "/span.ld", "w"))

	f:write([[
ENTRY(_start)
SECTIONS
{
	. = 0x400000;
	__image_base = .;
	.text : { *(.text) *(.text.*) }
	. = ALIGN(0x1000);
	__data_start = .;
	.data : { *(.data) *(.data.*) }
	. = ALIGN(0x1000);
	__reloc_start = .;
	.reloc : { *(.reloc) }
	__image_end = .;
}
__data_size = __reloc_start - __data_start;
]])
	f:close()
	f = assert(io.open(dir .. "/span.c", "w"))
	f:write([[
extern char __data_size[], __image_base[], __image_end[];
long d = 5;
static long out(long v)
{
	long r;

	__asm__ volatile("syscall" : "=a"(r) : "a"(60L), "D"(v)
			 : "rcx", "r11");
	return r;
}
void _start(void) { out((long)__data_size == 0x1000 ? 7 : 1); }
]])
	f:close()
	ok, out = cc("-nostdlib -Wl,-T,span.ld -o span span.c")
	if tap.ok(ok, "a symbol the sections gave a value to") then
		local _, _, code = os.execute(dir .. "/span")

		if not tap.ok(code == 7, "and the image runs") then
			tap.diag("exit " .. tostring(code))
		end
	else
		tap.diag(out)
	end
end

-- A builtin this compiler does not know is the library function of
-- that name, and takes its declaration where the program made one.
do
	local f = assert(io.open(dir .. "/bi.c", "w"))

	f:write([[
double fmod(double, double);
unsigned long strlen(const char *);
double g(double a, double b) { return __builtin_fmod(a, b); }
unsigned long n(const char *s) { return __builtin_strlen(s); }
]])
	f:close()
	ok, out = cc("-c -o bi.o bi.c")
	if tap.ok(ok, "an unknown builtin compiles") then
		local _, said = shell("nm bi.o")

		if not tap.ok(said and not said:find("__builtin_", 1, true),
		    "and calls the library name") then
			tap.diag(said)
		end
	else
		tap.diag(out)
	end
end

-- A script that collects the relocations gets them made: a
-- self-relocating image walks them at startup, and the linker is the
-- only thing that knows which words hold an address.
do
	local f = assert(io.open(dir .. "/rel.ld", "w"))

	f:write([[
ENTRY(_start)
SECTIONS
{
	. = 0;
	.text : { *(.text) *(.text.*) }
	. = ALIGN(0x1000);
	.data : { *(.data) *(.data.*) }
	.bss : { *(.bss) *(.bss.*) *(COMMON) }
	.rela : { __rela_start = .; *(.rela.dyn) *(.rela*) __rela_end = .; }
	. = ALIGN(0x1000);
}
]])
	f:close()
	f = assert(io.open(dir .. "/rel.c", "w"))
	f:write([[
extern char __rela_start[], __rela_end[];
static long a = 1, b = 2;
long *p[] = { &a, &b, &a, &b };
long count(void) { return (__rela_end - __rela_start) / 24; }
void _start(void) { }
]])
	f:close()
	ok, out = cc("-fpic -nostdlib -Wl,-T,rel.ld -o rel rel.c")
	if tap.ok(ok, "a script that collects the relocations") then
		-- the names the link answered for, so the result can be
		-- read from outside, and so that a symbol written after
		-- the input rules can be checked against them
		local _, nms = shell("nm " .. dir .. "/rel")
		local a = (nms or ""):match("(%x+) %a __rela_start")
		local b = (nms or ""):match("(%x+) %a __rela_end")

		if not tap.ok(a and b and
		    tonumber(b, 16) - tonumber(a, 16) == 4 * 24,
		    "and a symbol after them sees them") then
			tap.diag(nms)
		end
		local _, said = shell("readelf -x .rela " .. dir .. "/rel")
		-- four pointers, and every entry says RELATIVE, which
		-- on this machine is eight
		local n = 0

		for _ in (said or ""):gmatch("08000000 00000000") do
			n = n + 1
		end
		if not tap.ok(n == 4, "one for each word that holds one") then
			tap.diag(said)
		end
	else
		tap.diag(out)
	end
end

-- A macro given on the command line may take arguments, and the name
-- it answers to is the one before the parentheses.
do
	local f = assert(io.open(dir .. "/dmac.c", "w"))

	f:write([[
int printf(const char *, ...);
int main(void)
{
	printf("%d %d %d %s\n", FOO(3), ADD(2, 5), PLAIN, STR(hi));
	return 0;
}
]])
	f:close()
	-- every one quoted: parentheses are the shell's too
	local args = "'-DFOO(x)=42' '-DADD(a,b)=((a)+(b))' -DPLAIN=7 " ..
		"'-DSTR(s)=#s'"

	ok, out = cc(args .. " -o dmac dmac.c")
	if not tap.ok(ok and true or false, "-D defines a macro with " ..
	    "arguments") then
		tap.diag(out)
	else
		local _, said = shell("./dmac")

		tap.is(said, "42 7 7 hi\n", "and it expands")
	end
end

-- A constraint letter that takes only part of the range: N is the port
-- of an in or an out and stops at 255, so a wider one has to reach the
-- template in a register instead.  What the letter chooses is invisible
-- at run time -- both forms name the same port -- so the text is what
-- says which was written.
do
	write("nd.c", [[
static inline void outw(unsigned short p, unsigned short v)
{ __asm__ volatile ("outw %0, %1" : : "a" (v), "Nd" (p)); }
static inline unsigned char inb(unsigned short p)
{ unsigned char v;
  __asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (p));
  return v; }
void wide(void) { outw(0x510, 0x19); }
void narrow(void) { outw(0x70, 0x19); }
unsigned char rwide(void) { return inb(0x511); }
unsigned char rnarrow(void) { return inb(0x71); }
]])
	ok, out = cc("--target=amd64 -S -o nd.s nd.c")
	if not tap.ok(ok and true or false, "an asm operand takes the " ..
	    "letter whose range it is in") then
		tap.diag(out)
	else
		local text = slurp(dir .. "/nd.s") or ""

		tap.ok(text:find("outw %ax, %dx", 1, true) ~= nil,
			"a port past 255 goes to dx")
		tap.ok(text:find("outw %ax, $112", 1, true) ~= nil,
			"one inside 255 is written in the instruction")
		tap.ok(text:find("inb %dx, %al", 1, true) ~= nil,
			"and the same for a read")
		tap.ok(text:find("inb $113, %al", 1, true) ~= nil,
			"both ways")
	end
end

-- Where an object belongs, and whether a body is built where it was
-- called.  A kernel checks both after it links: a reference from an
-- ordinary section into an init one is an error there, and both of
-- these put one in.
do
	write("sec.c", [[
#define __init __attribute__((__section__(".init.text")))
#define __initdata __attribute__((__section__(".init.data")))
static const int table[32] __attribute__((__section__(".init.rodata")))
	= { 1 };
struct q { struct q *next; void (*func)(void); };
static void __init thing(void) { }
struct q *head;

/* Long enough that the size limit would refuse it, and it reads a
   table that only exists while the kernel starts. */
static inline __attribute__((always_inline)) int wide(int i)
{
	int s = 0, k;

	for (k = 0; k < 32; k++)
		s += table[k] * i + k * k * k + (k & 7) + (k | 3) +
		     (k ^ 5) + (k % 7) + (k << 2) + (k >> 1);
	return s;
}

int __init setup(int i)
{
	/* A static in a block belongs where the declaration says. */
	static struct q qk __initdata = { .func = thing };

	qk.next = head;
	head = &qk;
	return wide(i);
}
]])
	ok, out = cc("--target=amd64 -S -o sec.s sec.c")
	if not tap.ok(ok and true or false, "a section attribute and " ..
	    "always_inline are read") then
		tap.diag(out)
	else
		local text = slurp(dir .. "/sec.s") or ""

		tap.ok(text:find(".init.data", 1, true) ~= nil,
			"a static in a block goes where it was told")
		tap.ok(text:find("call\twide") == nil,
			"always_inline beats the length this one would " ..
			"otherwise be refused for")
	end
end

-- an unknown flag is a flag, not a file
ok, out = cc("-fno-semantic-interposition -Wno-unused -o prog3 add.c main.c")
tap.ok(ok and true or false, "an unknown flag is not taken for a file")

-- the stack protector needs the value and the handler from somewhere
ok, out = cc("-fstack-protector-all -o prog4 add.c main.c " ..
	here .. "/../rt/ssp.c")
tap.ok(ok and true or false, "-fstack-protector links against its runtime")

tap.done()
