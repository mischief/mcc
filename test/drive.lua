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

-- A literal in an assembly file means what it says.  `\\@` is the
-- assembler's count of macro expansions, and cooking it as a C escape
-- would drop the backslash and leave a name nothing defines.
do
	local f = assert(io.open(dir .. "/esc.S", "w"))

	f:write([[
	ALT "jmp .Lskip_rsb_\@", 1
	.ascii "a\nb"
]])
	f:close()
	ok, out = cc("-E esc.S")
	if not tap.ok(ok and (out or ""):find([[.Lskip_rsb_\@]], 1, true)
	    ~= nil and (out or ""):find([[a\nb]], 1, true) ~= nil,
	    "a literal keeps its spelling through the preprocessor") then
		tap.diag(out or "")
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

/* An attribute after a tag with no body belongs to what is being
   declared, not to the type.  A kernel writes exactly this. */
static struct q __attribute__((__section__(".ref.text")))
*late(int n) { (void)n; return head; }

struct q *reach(int n) { return late(n); }
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
		tap.ok(text:find(".ref.text", 1, true) ~= nil,
			"an attribute after a bare tag belongs to the " ..
			"declaration")
	end
end

-- A narrow object, the bytes of another file, and a sysroot that is
-- still a hosted world.  A kernel links its real mode code as
-- elf32-i386 and wraps the result in an object with .incbin; a cross
-- build hands the compiler a --sysroot and expects a dynamic link.
do
	write("narrow.s", "\t.code16\nf:\n\tmovl\t%cr0, %eax\n" ..
		"\tmovw\ttbl, %ax\ntbl:\n\t.long\t0\n")
	ok, out = cc("--target=amd64 -m16 -c -o narrow.o narrow.s")
	if not tap.ok(ok and true or false, "-m16 assembles") then
		tap.diag(out)
	else
		local e = slurp(dir .. "/narrow.o") or ""

		tap.is(e:byte(5), 1, "the object is ELFCLASS32")
		tap.is(e:byte(19), 3, "and says it is a 386")
		-- That ABI has no addend in a relocation entry, and
		-- `arch/x86/tools/relocs` reads a 32-bit object looking
		-- for SHT_REL.  A `.word` that names a symbol takes a
		-- two-byte relocation, not a four-byte one over it.
		local p2 = io.popen(("readelf -SrW %s/narrow.o")
			:format(dir))
		local t = p2:read("a") or ""

		p2:close()
		if not tap.ok(t:find(".rel.text", 1, true) ~= nil and
		    t:find(".rela", 1, true) == nil and
		    t:find("R_386_16", 1, true) ~= nil,
		    "with the relocations that machine says") then
			tap.diag(t)
		end
	end

	write("blob.bin", "hello world")
	write("inc.s", '\t.data\nd:\n\t.incbin "blob.bin"\n' ..
		'\t.incbin "blob.bin", 6\n\t.incbin "blob.bin", 0, 5\n')
	ok, out = cc("--target=amd64 -c -o inc.o inc.s")
	if not tap.ok(ok and true or false, ".incbin reads a file") then
		tap.diag(out)
	else
		local e = slurp(dir .. "/inc.o") or ""

		tap.ok(e:find("hello worldworldhello", 1, true) ~= nil,
			"and takes the part it was asked for")
	end

	-- `/` is a sysroot like any other: naming one is not a reason to
	-- stop linking against a system.
	write("hosted.c", [[
#include <stdio.h>
int main(void) { printf("sysrooted\n"); return 0; }
]])
	ok, out = cc("--sysroot=/ -o hosted hosted.c")
	if not tap.ok(ok and true or false, "a sysroot still links " ..
	    "against a system") then
		tap.diag(out)
	else
		local _r, said = shell("./hosted")

		tap.is(said, "sysrooted\n", "and what it builds runs")
	end
end

-- an unknown flag is a flag, not a file
ok, out = cc("-fno-semantic-interposition -Wno-unused -o prog3 add.c main.c")
tap.ok(ok and true or false, "an unknown flag is not taken for a file")

-- the stack protector needs the value and the handler from somewhere
ok, out = cc("-fstack-protector-all -o prog4 add.c main.c " ..
	here .. "/../rt/ssp.c")
tap.ok(ok and true or false, "-fstack-protector links against its runtime")

-- `-mno-sse` says the float registers are out of bounds.  A kernel
-- builds with it so that it never has to save them, and the save area a
-- variadic function keeps must hold none.
do
	write("va.c", [[
typedef __builtin_va_list va_list;
int sum(int n, ...)
{
	va_list ap;
	int t = 0, i;

	__builtin_va_start(ap, n);
	for (i = 0; i < n; i++)
		t += __builtin_va_arg(ap, int);
	__builtin_va_end(ap);
	return t;
}
]])
	ok, out = cc("--target=amd64 -mno-sse -S -o va.s va.c")
	local text = ok and slurp(dir .. "/va.s") or ""

	if not tap.ok(ok and not text:find("xmm", 1, true),
	    "-mno-sse keeps no float save area") then
		tap.diag(out or text)
	end
	ok, out = cc("--target=amd64 -S -o vasse.s va.c")
	text = ok and slurp(dir .. "/vasse.s") or ""
	tap.ok(ok and text:find("xmm", 1, true) ~= nil,
		"and without it the float registers are saved")
end

-- An asm operand that has to be a constant may sit in a slot whose
-- contents are known.  The kernel writes the flags of a bug table entry
-- that way.  gcc only folds it once its optimiser runs, so there is no
-- reference build to compare against: read what comes out instead.
do
	write("bug.c", [[
struct bug_entry { int addr, file; short line, flags; };
#define BUGFLAG_WARNING 1
int warned(int x)
{
	if (x) {
		__auto_type f = BUGFLAG_WARNING | 4;

		__asm__ __volatile__ ("ud2\n"
			".pushsection __bug_table,\"aw\"\n"
			"\t.word %c0\n\t.word %c1\n"
			".popsection\n"
			: : "i" (f), "i" (sizeof(struct bug_entry)));
	}
	return x;
}
]])
	ok, out = cc("--target=amd64 -S -o bug.s bug.c")
	local text = ok and slurp(dir .. "/bug.s") or ""

	if not tap.ok(ok and text:find(".word 5", 1, true) ~= nil and
	    text:find(".word 12", 1, true) ~= nil,
	    "an asm constant held in a slot") then
		tap.diag(out or text)
	end
end

-- `do { ... } while (0)` runs once, so a slot written before it still
-- holds what it held inside.  A kernel wraps nearly every statement
-- macro in one and reads a constant through two of them.  And an arm
-- ruled out before the constant is worked out is never written, so it
-- does not have to be one.
do
	write("once.c", [[
#define INNER(f) do {							\
	__asm__ __volatile__ ("nop\n\t.word %c0\n" : : "i" (f));	\
} while (0)
#define OUTER(v) do {							\
	__auto_type f = 1 | (v);					\
	INNER(f);							\
} while (0)
int warn(int x)
{
	OUTER(6);
	if (x) {
		switch (x) {
		case 1:
			if (0)
				OUTER(8);
			break;
		}
	}
	return x;
}
]])
	ok, out = cc("--target=amd64 -S -o once.s once.c")
	local text = ok and slurp(dir .. "/once.s") or ""

	if not tap.ok(ok and text:find(".word 7", 1, true) ~= nil,
	    "a constant read through do while zero") then
		tap.diag(out or text)
	end
end

-- The `__has_*` operators answer wherever they stand, not only in a
-- directive.  A kernel asks `__has_attribute` inside an ordinary
-- expression, where a name that is not a macro is a name.
do
	write("has.c", [[
#if __has_attribute(noreturn)
#error this compiler claims none of them
#endif
int has(void)
{
	return __has_attribute(btf_type_tag) +
		__has_builtin(__builtin_expect) * 2 +
		__has_feature(address_sanitizer) * 4;
}
]])
	ok, out = cc("--target=amd64 -S -o has.s has.c")
	tap.ok(ok and true or false, "the has_ operators answer anywhere")
	if not ok then tap.diag(out) end
end

-- A suffix this compiler does not know is for the linker, whatever the
-- build system calls it.  musl names its shared objects `.lo`, and
-- dropping them quietly builds a library with nothing in it.
do
	write("helper.c", "int helper(void) { return 42; }\n")
	write("usehelper.c",
	      "extern int helper(void);\nint main(void) " ..
	      "{ return helper() == 42 ? 0 : 1; }\n")
	ok, out = cc("-c -o helper.lo helper.c")
	if ok then ok, out = cc("-o usehelper usehelper.c helper.lo") end
	if not tap.ok(ok and true or false,
	    "an unknown suffix goes to the linker") then
		tap.diag(out)
	else
		local r = shell("./usehelper")

		tap.ok(r and true or false, "and what it builds runs")
	end
end

-- An archive with nothing in it is still an archive.  musl makes one
-- for each library that is really part of libc, and a build that links
-- against it has to find a file there.
do
	local mar = ("MCC_PROG=mar %s %s/../archive.lua"):format(lua, here)

	ok = shell(("%s rc empty.a"):format(mar))
	local text = ok and slurp(dir .. "/empty.a") or ""

	if not tap.ok(ok and text == "!<arch>\n",
	    "an archive with no members") then
		tap.diag(("wrote %d bytes"):format(#text))
	else
		ok, out = cc("-o withempty usehelper.c helper.lo empty.a")
		tap.ok(ok and true or false, "and it links against one")
	end
end

-- A shared object has to say how big each name it offers is.  With a
-- size of zero GNU ld warns that the type and size are not defined and
-- then falls over in its string table, which is what a libc built here
-- did to every program linked against it.
do
	write("shlib.c", "int shvar = 7;\n" ..
	      "int shfunc(int x) { return x + shvar; }\n")
	ok, out = cc("-fpic -shared -o libsh.so shlib.c")
	if not tap.ok(ok and true or false, "a shared object builds") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -W --dyn-syms %s/libsh.so")
			:format(dir))
		local t = p:read("a") or ""

		p:close()
		local fsz = t:match("%s(%d+)%s+FUNC%s+GLOBAL%s+%S+%s+%S+%s+shfunc")
		local vsz = t:match("%s(%d+)%s+OBJECT%s+GLOBAL%s+%S+%s+%S+%s+shvar")

		if not tap.ok(tonumber(fsz or "0") > 0 and vsz == "4",
		    "and says how big each name it offers is") then
			tap.diag(("shfunc %s, shvar %s")
				:format(tostring(fsz), tostring(vsz)))
		end
	end
end

-- A program has to have every name it reaches.  Without the check the
-- name goes out as one for the loader to find, the link says nothing,
-- and the program dies at start-up instead.
do
	write("nodef.c",
	      "extern int nowhere(void);\nint main(void) " ..
	      "{ return nowhere(); }\n")
	ok, out = cc("-o nodef nodef.c")
	if not tap.ok(not ok and (out or ""):find("undefined symbol nowhere",
	    1, true) ~= nil, "a name nothing defines stops the link") then
		tap.diag(out or "")
	end
	tap.ok(slurp(dir .. "/nodef") == nil,
		"and no half-written program is left behind")
	-- A shared object may leave a name to whatever loads it.
	write("leaves.c",
	      "extern int nowhere(void);\nint reach(void) " ..
	      "{ return nowhere(); }\n")
	ok, out = cc("-fpic -shared -o leaves.so leaves.c")
	if not tap.ok(ok and true or false,
	    "but a shared object may leave one open") then
		tap.diag(out)
	end
end

-- An alias stands for the same thing, so it is the same kind and the
-- same size.  musl`s `environ` is a weak alias, and GNU ld falls over
-- reading a library whose dynamic symbols have neither.
do
	write("alias.c", [[
char **__environ = 0;
extern __typeof(__environ) environ __attribute__((weak, alias("__environ")));
int __afn(int x) { return x + 1; }
extern __typeof(__afn) afn __attribute__((weak, alias("__afn")));
extern int __wide(int);
extern __typeof(__wide) wide __attribute__((weak, alias("__wide")));
int __wide(int x)
{
	if (x == 1) {
		x += 1;
		x += 4;
		x += 7;
		x += 10;
		x += 13;
		x += 16;
		x += 19;
		x += 22;
		x += 25;
		x += 28;
		x += 31;
		x += 34;
		x += 37;
		x += 40;
		x += 43;
		x += 46;
		x += 49;
		x += 52;
		x += 55;
		x += 58;
		x += 61;
		x += 64;
		x += 67;
		x += 70;
		x += 73;
		x += 76;
		x += 79;
		x += 82;
		x += 85;
		x += 88;
		x += 91;
		x += 94;
		x += 97;
		x += 100;
		x += 103;
		x += 106;
		x += 109;
		x += 112;
		x += 115;
		x += 118;
		x += 121;
		x += 124;
		x += 127;
		x += 130;
		x += 133;
		x += 136;
		x += 139;
		x += 142;
		x += 145;
		x += 148;
		x += 151;
		x += 154;
		x += 157;
		x += 160;
		x += 163;
		x += 166;
		x += 169;
		x += 172;
		x += 175;
		x += 178;
	}
	return x;
}
]])
	ok, out = cc("--target=amd64 -c -o alias.o alias.c")
	if not tap.ok(ok and true or false, "an alias builds") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -sW %s/alias.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		local o = t:match("(%d+)%s+OBJECT%s+WEAK%s+%S+%s+%S+%s+environ")
		local f = t:match("(%d+)%s+FUNC%s+WEAK%s+%S+%s+%S+%s+afn")

		if not tap.ok(o == "8" and tonumber(f or "0") > 0,
		    "and keeps the kind and the size of what it names") then
			tap.diag(("environ %s, afn %s")
				:format(tostring(o), tostring(f)))
		end
		-- A branch that widens on a later pass makes the body
		-- longer, so the size is taken again and not kept from
		-- the first answer.
		local w = t:match("(%d+)%s+FUNC%s+WEAK%s+%S+%s+%S+%s+wide")
		local r = t:match("(%d+)%s+FUNC%s+GLOBAL%s+%S+%s+%S+%s+__wide")

		if not tap.ok(w ~= nil and w == r,
		    "and the size it ends up with") then
			tap.diag(("wide %s, __wide %s")
				:format(tostring(w), tostring(r)))
		end
	end
end

-- Most of what is done to a scalar twice the register width is written
-- out here, so a shift asks for no runtime at all.  What is left -- the
-- multiply, the divide -- reaches one by name, and a freestanding
-- program has none to link, so the compiler puts the bodies it asked
-- for inside the object as names of its own.
do
	write("w128.c", [[
/* The runtime is read through a preprocessor of its own, so what the
   program gives these names cannot reach it. */
#define lo 999
#define mask 7
#define w_u int
typedef unsigned __int128 u128;
unsigned long long shifty(unsigned long long a, int n)
{
	u128 b = a;

	b <<= n;
	return (unsigned long long)(b >> 3);
}

unsigned long long timesy(unsigned long long a, unsigned long long b)
{
	return (unsigned long long)(((u128)a * (u128)b) >> 64);
}
]])
	ok, out = cc("--target=amd64 -c -o w128.o w128.c")
	if not tap.ok(ok and true or false, "a wide scalar builds") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -sW %s/w128.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		local undef = t:match("UND%s+(__w_%w+)")
		local mul = t:match("FUNC%s+LOCAL%s+%S+%s+%S+%s+(__w_mul)")

		if not tap.ok(undef == nil and mul == "__w_mul",
		    "and takes the runtime it needs with it") then
			tap.diag(("undefined %s, local %s")
				:format(tostring(undef), tostring(mul)))
		end
		-- Only what the code calls: a shift is written out and
		-- the divide was never asked for.
		if not tap.ok(t:match("__w_divu") == nil and
		    t:match("__w_shl") == nil,
		    "and leaves out what it does not call") then
			tap.diag(t)
		end
	end
end

-- A kernel leans on the compiler to delete an arm it can prove dead:
-- it calls a function nobody defines there, so if the arm survives
-- the link fails and says which one.  Two shapes of that, and both
-- have cost a kernel build: a comparison of two literals, and an
-- inline body whose reachable return is a constant.
do
	write("dead.c", [[
extern void __must_not_link(void);
#define ENABLED 0
static inline int mixed(void)
{
	if (!ENABLED)
		return 0;
	return __must_not_link != 0;
}
#define BYNAME(op) (__builtin_strcmp(op, "go") == 0)
void f(void) { if (mixed()) __must_not_link(); }
void g(void) { if (!BYNAME("go")) __must_not_link(); }
]])
	ok, out = cc("-c -o dead.o dead.c")
	if not tap.ok(ok and true or false, "an arm nothing reaches builds") then
		tap.diag(out)
	else
		local p = io.popen(("nm %s/dead.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("__must_not_link", 1, true) == nil,
		    "and the call in it is gone") then
			tap.diag(t)
		end
	end
end

-- A relocation against a name of this unit's own reaches it through
-- the section, as gas writes it and as the kernel's own checker
-- expects.  A distance into a section the linker folds is the
-- exception: there the addend says which of the folded pieces is
-- meant, and a distance is four short of it.
do
	write("rel.s", "\t.section .rodata.str1.1,\"aMS\",@progbits,1\n" ..
		".Lstr:\n\t.asciz \"hi\"\n" ..
		"\t.section .rodata\n.Lnum:\n\t.quad 7\n" ..
		"\t.text\n\tleaq\t.Lstr(%rip),%rdi\n" ..
		"\tmovq\t$.Lnum,%rsi\n\tleaq\t.Lnum(%rip),%rdx\n")
	ok, out = cc("-c -o rel.o rel.s")
	if not tap.ok(ok and true or false, "a local relocation assembles") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -rW %s/rel.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("%.rodata %+", 1) ~= nil and
		    t:find("%.Lstr", 1) ~= nil,
		    "through the section, but not into a folded one") then
			tap.diag(t)
		end
	end
end

-- gcc's -m16 is the 32-bit code generator with `.code16gcc` in front,
-- and so is this one: the same i386 code, in a mode where every one of
-- those instructions needs a prefix.  That is what a kernel's real
-- mode trampoline is built with.
do
	write("m16.c", "int m16f(int a, int b) { return a + b; }\n")
	ok, out = cc("-m16 -S -o m16.s m16.c")
	if not tap.ok(ok and slurp(dir .. "/m16.s"):find(".code16gcc", 1, true)
	    ~= nil, "-m16 puts .code16gcc in front of 32-bit code") then
		tap.diag(out .. slurp(dir .. "/m16.s"))
	end
	ok, out = cc("-m16 -c -o m16c.o m16.c")
	if not tap.ok(ok and true or false, "-m16 assembles what it made") then
		tap.diag(out)
	else
		local p = io.popen(("objdump -d -m i8086 %s/m16c.o")
			:format(dir))
		local t = p:read("a") or ""

		p:close()
		-- Every wide move in 16-bit code wears both prefixes: 66
		-- for the operand and 67 for the address.
		if not tap.ok(t:find("67 66 8b", 1, true) ~= nil and
		    t:find("66 c3", 1, true) ~= nil,
		    "with the operand and address prefixes on it") then
			tap.diag(t)
		end
	end
	write("m16.s", "\t.code16\n\t.text\n\tmovw %ax,%bx\n")
	ok, out = cc("--target=amd64 -m16 -c -o m16o.o m16.s")
	if not tap.ok(ok and true or false,
	    "and a narrow object still assembles") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -h %s/m16o.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("ELF32", 1, true) ~= nil and
		    t:find("80386", 1, true) ~= nil,
		    "as a 32-bit x86 object") then
			tap.diag(t)
		end
	end
end

-- The canary a kernel with more than one cpu reads is one of its
-- per-cpu words, named through the segment the machine keeps them in.
do
	write("ssp.c", "int sspf(int n) { char b[64]; b[n] = 1; return b[0]; }\n")
	ok, out = cc("--target=amd64 -fstack-protector-strong " ..
		"-mstack-protector-guard-reg=gs " ..
		"-mstack-protector-guard-symbol=__ref_stack_chk_guard " ..
		"-S -o ssp.s ssp.c")
	if not tap.ok(ok and true or false, "a per-cpu canary builds") then
		tap.diag(out)
	else
		local f = io.open(dir .. "/ssp.s")
		local t = f and f:read("a") or ""

		if f then f:close() end
		local n = 0

		for _ in t:gmatch("%%gs:__ref_stack_chk_guard") do
			n = n + 1
		end
		if not tap.ok(n == 2, "and is read through the segment") then
			tap.diag(t)
		end
	end
end

-- A system that versions the file name of a library rather than
-- keeping a plain one: the newest is the newest by number, not by
-- spelling.  openbsd ships libc.so.9.0 beside libc.so.104.0.
do
	write("vq.c", "int quux = 42;\nint getquux(void) { return quux; }\n")
	write("vm.c", "int getquux(void);\nint qmain(void) " ..
	      "{ return getquux(); }\n")
	ok, out = cc("--target=amd64 -fPIC -shared -Wl,-soname," ..
		"libvq.so.104.0 -o libvq.so.104.0 vq.c")
	if ok then
		ok, out = cc("--target=amd64 -fPIC -shared -Wl,-soname," ..
			"libvq.so.9.0 -o libvq.so.9.0 vq.c")
	end
	if ok then ok, out = cc("--target=amd64 -c -o vm.o vm.c") end
	if ok then
		ok, out = cc(("--target=amd64 -pie -nostdlib -e qmain " ..
			"-o vm -L%s -lvq vm.o"):format(dir))
	end
	if not tap.ok(ok and true or false, "a versioned library links") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -dW %s/vm"):format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("libvq.so.104.0", 1, true) ~= nil,
		    "and the newest is the one with the larger number") then
			tap.diag(t)
		end
	end
end

-- What is inside a typeof, an _Atomic or a record body is a
-- declaration of its own with attributes of its own.  What the
-- declaration around it has gathered must survive: linux writes the
-- section a per-cpu object goes in before the typeof that names its
-- type, and without the section there is no per-cpu area at all.
do
	write("sects.c", [[
struct rq { long a, b; };
__attribute__((section(".data..percpu" "..shared_aligned")))
__typeof__(struct rq) runqueues __attribute__((__aligned__(64)));
__attribute__((section(".data..percpu" ""))) __typeof__(int) kstat;
__attribute__((section(".t1"))) struct { int x; } t1;
__attribute__((section(".t3"))) _Atomic(int) t3;
]])
	ok, out = cc("--target=amd64 -c -o sects.o sects.c")
	if not tap.ok(ok and true or false, "a section before a typeof builds") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -SW %s/sects.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		local want = {".data..percpu..shared_aligned",
			      ".data..percpu", ".t1", ".t3"}
		local miss = nil

		for _, nm in ipairs(want) do
			if not t:find(nm, 1, true) then miss = nm end
		end
		if not tap.ok(miss == nil,
		    "and the object lands in the section it named") then
			tap.diag(("missing %s\n%s"):format(tostring(miss), t))
		end
		-- An alignment written after the declarator belongs to
		-- the name, and it was read before the declarator was.
		local al = t:match("%.data%.%.percpu%.%.shared_aligned[^\n]*")

		if not tap.ok(al ~= nil and al:match("(%d+)%s*$") == "64",
		    "and takes the alignment written after its name") then
			tap.diag(tostring(al))
		end
	end
end

-- A piece of a shared object is named for the section it came from and
-- the object it came out of.  What goes in the section table is the
-- section: a library built from a thousand objects would otherwise
-- have a thousand headers, and a linker reading one falls over.
do
	write("sa.c", "extern int sbee(void);\nint say(void) " ..
	      "{ return sbee() + 1; }\n")
	write("sb.c", "int sbee(void) { return 41; }\n")
	ok, out = cc("--target=amd64 -fpic -c sa.c -o sa.o")
	if ok then ok, out = cc("--target=amd64 -fpic -c sb.c -o sb.o") end
	if ok then
		ok, out = cc("--target=amd64 -shared -o libsab.so sa.o sb.o")
	end
	if not tap.ok(ok and true or false, "a library of two objects") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -SW %s/libsab.so"):format(dir))
		local t = p:read("a") or ""

		p:close()
		local n = 0

		for _ in t:gmatch("%[%s*%d+%]") do n = n + 1 end
		tap.ok(n < 20 and t:find("] .text ", 1, true) ~= nil and
			t:find("/sa.o", 1, true) == nil,
			"has one header per section, not one per object")
	end
end

-- The names the linker itself provides are not a library's to offer.
-- A program has its own linker script, which defines them and hides
-- them, and GNU ld hands one it found in a library to the code that
-- hides a symbol -- which then walks off the end of its string table
-- and dies.
do
	write("own.c", "extern char __init_array_start[];\n" ..
	      "extern char _DYNAMIC[];\n" ..
	      "char *owned(void) { return __init_array_start + " ..
	      "(_DYNAMIC - _DYNAMIC); }\n")
	ok, out = cc("--target=amd64 -fpic -shared -o libown.so own.c")
	if not tap.ok(ok and true or false,
	    "a library that names what the linker provides") then
		tap.diag(out)
	else
		local p = io.popen(("nm -D --defined-only %s/libown.so")
			:format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("_DYNAMIC", 1, true) == nil and
		    t:find("__init_array_start", 1, true) == nil,
		    "does not offer them") then
			tap.diag(t)
		end
	end
end

-- A temporary dies with its statement, so the slot it used goes to the
-- next one.  Without that a long function pays a slot for every
-- temporary it ever made, and a frame runs to thousands of bytes.
do
	local function frame(n)
		local body = {}

		for i = 1, n do
			body[#body + 1] = ("\ttotal += pick(&a, &b, %d) + " ..
				"pick(&b, &a, %d);\n"):format(i, i + 1)
		end
		write("frame.c", "struct pair { long x, y; };\n" ..
			"long pick(struct pair *, struct pair *, long);\n" ..
			"long run(void)\n{\n" ..
			"\tstruct pair a = {1, 2}, b = {3, 4};\n" ..
			"\tlong total = 0;\n\n" ..
			table.concat(body) ..
			"\treturn total;\n}\n")
		ok, out = cc("--target=amd64 -S -o frame.s frame.c")
		local text = ok and slurp(dir .. "/frame.s") or ""

		return tonumber(text:match("subq%s+%$(%d+),%%rsp")), text
	end
	local one = frame(1)
	local ten, t10 = frame(10)

	if not tap.ok(one ~= nil and ten ~= nil and ten <= one + 64,
	    "a statement hands its slots back") then
		tap.diag(("one statement %s, ten %s"):format(
			tostring(one), tostring(ten)))
		tap.diag(t10 or "")
	end
end

-- A build system puts linker flags in LDFLAGS and the compiler driver
-- passes them on with -Wl.  musl names the entry point of its own
-- loader and the soname of its library that way.
do
	write("dl.c", "int _dlstart(void) { return 7; }\n" ..
	      "int other(void) { return _dlstart(); }\n")
	ok, out = cc("--target=amd64 -fpic -shared -Wl,-e,_dlstart " ..
		"-Wl,-soname=libdl.so.9 -o libdl.so dl.c")
	if not tap.ok(ok and true or false, "a -Wl entry point and soname") then
		tap.diag(out)
	else
		local p = io.popen(("readelf -hdW %s/libdl.so"):format(dir))
		local t = p:read("a") or ""
		local e = t:match("Entry point address:%s+0x(%x+)")

		p:close()
		if not tap.ok(e ~= nil and tonumber(e, 16) ~= 0 and
		    t:find("libdl.so.9", 1, true) ~= nil,
		    "reach the linker") then
			tap.diag(t)
		end
	end
end

-- A label in hand-written assembly is in the symbol table even when
-- nothing refers to it, which is what makes a disassembly readable.
-- A name of the assembler`s own, which begins `.L`, stays out.
do
	write("labels.s", "\t.text\n" ..
	      "\t.globl\tstart\nstart:\n\tnop\n" ..
	      "inner:\n\tnop\n" ..
	      ".Lhidden:\n\tnop\n\tjmp\t.Lhidden\n")
	ok, out = cc("--target=amd64 -c -o labels.o labels.s")
	if not tap.ok(ok and true or false, "a file of bare labels") then
		tap.diag(out)
	else
		local p = io.popen(("nm %s/labels.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("t inner", 1, true) ~= nil and
		    t:find("T start", 1, true) ~= nil and
		    t:find(".Lhidden", 1, true) == nil,
		    "keeps its own labels and not the assembler`s") then
			tap.diag(t)
		end
	end
end

-- -fshort-wchar: `L"..."` holds two bytes an element and `wchar_t` is
-- as wide.  UEFI is built that way, and so is the linux EFI stub.
do
	write("wch.c", "#include <stdio.h>\n#include <stddef.h>\n" ..
	      "typedef unsigned short u16;\n" ..
	      "static const u16 cmd[] = L\"hi\";\n" ..
	      "static const wchar_t w[] = L\"abc\";\n" ..
	      "int main(void)\n{\n" ..
	      "\tprintf(\"%d %d %d %d\\n\", (int)sizeof cmd,\n" ..
	      "\t    (int)sizeof w, (int)sizeof(wchar_t), (int)cmd[0]);\n" ..
	      "\treturn 0;\n}\n")
	ok, out = cc("-fshort-wchar -o wch wch.c")
	if not tap.ok(ok and true or false, "-fshort-wchar compiles") then
		tap.diag(out)
	else
		local p = io.popen(dir .. "/wch")
		local t = (p:read("a") or ""):gsub("%s+$", "")

		p:close()
		tap.is(t, "6 8 2 104", "with two byte elements throughout")
	end
end

-- A kernel keeps the stack protector value in a global of its own and
-- has a handler of its own, and says so with the flags gcc takes.
do
	write("guard.c", "void use(char *);\n" ..
	      "int f(int n)\n{\n\tchar b[64];\n\n\tuse(b);\n" ..
	      "\treturn n;\n}\n")
	ok, out = cc("--target=amd64 -fstack-protector-strong " ..
		"-mstack-protector-guard=global -S -o guard.s guard.c")
	local t = ok and slurp(dir .. "/guard.s") or ""

	if not tap.ok(ok and t:find("__stack_chk_guard", 1, true) ~= nil and
	    t:find("__stack_chk_fail", 1, true) ~= nil and
	    t:find("__guard_local", 1, true) == nil,
	    "-mstack-protector-guard=global takes the platform names") then
		tap.diag(out or t)
	end
	ok, out = cc("--target=amd64 -fstack-protector-strong " ..
		"-mstack-protector-guard-symbol=__ref_stack_chk_guard " ..
		"-S -o guard2.s guard.c")
	t = ok and slurp(dir .. "/guard2.s") or ""
	if not tap.ok(ok and
	    t:find("__ref_stack_chk_guard", 1, true) ~= nil,
	    "and a name of its own when one is given") then
		tap.diag(out or t)
	end
	ok, out = cc("--target=amd64 -fstack-protector-strong " ..
		"-S -o guard3.s guard.c")
	t = ok and slurp(dir .. "/guard3.s") or ""
	tap.ok(ok and t:find("__guard_local", 1, true) ~= nil,
		"without them the compiler's own names stand")
end

-- An object nothing names is not written down, and neither is what
-- only it named.  A kernel builds a table of operations for a feature
-- the configuration left out, and that table names functions that call
-- what the configuration left out too.
do
	write("dead.c", "extern int missing(int);\n" ..
	      "struct ops { int (*f)(int); };\n" ..
	      "static int deadfn(int x) { return missing(x); }\n" ..
	      "static const struct ops deadops = { deadfn };\n" ..
	      "static int livefn(int x) { return x + 1; }\n" ..
	      "static const struct ops liveops = { livefn };\n" ..
	      "int use(void) { return liveops.f(41); }\n")
	ok, out = cc("--target=amd64 -c -o dead.o dead.c")
	if not tap.ok(ok and true or false, "a table nothing names") then
		tap.diag(out)
	else
		local p = io.popen(("nm %s/dead.o"):format(dir))
		local t = p:read("a") or ""

		p:close()
		if not tap.ok(t:find("liveops", 1, true) ~= nil and
		    t:find("livefn", 1, true) ~= nil and
		    t:find("deadops", 1, true) == nil and
		    t:find("deadfn", 1, true) == nil and
		    t:find("missing", 1, true) == nil,
		    "goes, and the function only it named goes with it") then
			tap.diag(t)
		end
	end
end

-- Only a system that pins system calls asks where they are.  A linker
-- script that places every section by name refuses an extra one.
do
	write("sys.s", "\t.text\n\tmovl\t$60,%eax\n\tsyscall\n")
	ok, out = cc("--target=amd64 -c -o sys.o sys.s")
	local e = ok and slurp(dir .. "/sys.o") or ""

	tap.ok(ok and e:find(".mcc.syscalls", 1, true) == nil,
		"no note of a system call where none is pinned")
	ok, out = cc("--target=amd64-openbsd -c -o syso.o sys.s")
	e = ok and slurp(dir .. "/syso.o") or ""
	tap.ok(ok and e:find(".mcc.syscalls", 1, true) ~= nil,
		"and one where they are")
end

-- A memory operand naming a member of an object at file scope is
-- `name + n`, which the machine names as it stands.  Working the
-- address out into a register first makes the instruction a different
-- length, and linux patches over `call *pv_ops+N(%rip)` by measuring
-- it: six bytes, `ff 15`, and nothing else will do.
do
	write("mop.c", "struct ops { void (*a)(void); void (*b)(void); };\n" ..
	      "extern struct ops pv;\n" ..
	      "extern void (*fp)(void);\n" ..
	      "void f(void) { __asm__ volatile(\"call *%[p];\"" ..
	      " : : [p] \"m\" (fp)); }\n" ..
	      "void g(void) { __asm__ volatile(\"call *%[p];\"" ..
	      " : : [p] \"m\" (pv.b)); }\n")
	ok, out = cc("--target=amd64 -fno-pic -S -o mop.s mop.c")
	local t = ok and slurp(dir .. "/mop.s") or ""

	if not tap.ok(ok and t:find("call *fp(%rip)", 1, true) ~= nil and
	    t:find("call *pv+8(%rip)", 1, true) ~= nil,
	    "a memory operand names a member where it stands") then
		tap.diag(out or t)
	end
end

-- A function may open with a test the configuration has already
-- answered, and return on it.  Everything behind that test is dead,
-- and with it the only uses of two names nothing defines.  The call
-- has to fold to the constant for those names to go, which means
-- building the body where it was called however long the rest of the
-- body is.  linux does this in btf.c: `__start_BTF` and `__stop_BTF`
-- are bracketed by the linker script only when BTF is on, and with it
-- off the only two references to them sit behind such a test.
do
	write("gfold.c",
	      "extern void nowhere(void);\n" ..
	      "extern char gstart[], gstop[];\n" ..
	      "static long parse(const char *n, void *a, long s)\n{\n" ..
	      "\tif (!0)\n\t\treturn 7;\n" ..
	      "\tnowhere();\n\t{\n\t\tvolatile long v[32];\n" ..
	      "\t\tint i;\n\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] = (long)n + s + i;\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] += v[(i + 1) & 31] * 3;\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] ^= v[(i + 5) & 31] - (long)a;\n" ..
	      "\t\treturn v[0] + v[31];\n\t}\n}\n" ..
	      "long go(void)\n{\n" ..
	      "\treturn parse(\"x\", gstart, gstop - gstart);\n}\n")
	ok, out = cc("--target=amd64 -S -o gfold.s gfold.c")
	local t = ok and slurp(dir .. "/gfold.s") or ""

	if not tap.ok(ok and t:find("nowhere", 1, true) == nil and
	    t:find("gstart", 1, true) == nil and
	    t:find("gstop", 1, true) == nil and
	    t:find("$7", 1, true) ~= nil,
	    "a constant guard folds the call and its arguments die") then
		tap.diag(out or t)
	end

	-- A guard that does not hold leaves the body alone, and a guard
	-- the compiler cannot settle leaves it alone too.
	write("gfold2.c",
	      "extern void nowhere(void);\n" ..
	      "extern int cfg;\n" ..
	      "static long parse(long s)\n{\n" ..
	      "\tif (cfg)\n\t\treturn 7;\n" ..
	      "\tnowhere();\n\t{\n\t\tvolatile long v[32];\n" ..
	      "\t\tint i;\n\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] = s + i;\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] += v[(i + 1) & 31] * 3;\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] ^= v[(i + 5) & 31];\n" ..
	      "\t\treturn v[0] + v[31];\n\t}\n}\n" ..
	      "long go(void)\n{\n\treturn parse(3);\n}\n")
	ok, out = cc("--target=amd64 -S -o gfold2.s gfold2.c")
	t = ok and slurp(dir .. "/gfold2.s") or ""
	if not tap.ok(ok and t:find("nowhere", 1, true) ~= nil,
	    "a guard the compiler cannot settle leaves the body alone") then
		tap.diag(out or t)
	end

	-- A guard that settles the other way returns nothing: the body
	-- behind it is the whole function.
	write("gfold3.c",
	      "extern void nowhere(void);\n" ..
	      "static long parse(long s)\n{\n" ..
	      "\tif (0)\n\t\treturn 7;\n" ..
	      "\tnowhere();\n\t{\n\t\tvolatile long v[32];\n" ..
	      "\t\tint i;\n\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] = s + i;\n" ..
	      "\t\tfor (i = 0; i < 32; i++)\n" ..
	      "\t\t\tv[i] += v[(i + 1) & 31] * 3;\n" ..
	      "\t\treturn v[0] + v[31];\n\t}\n}\n" ..
	      "long go(void)\n{\n\treturn parse(3);\n}\n")
	ok, out = cc("--target=amd64 -S -o gfold3.s gfold3.c")
	t = ok and slurp(dir .. "/gfold3.s") or ""
	if not tap.ok(ok and t:find("nowhere", 1, true) ~= nil,
	    "a guard that does not hold leaves the body alone") then
		tap.diag(out or t)
	end
end

-- -M and -MM ask for the list of files read and nothing else: no
-- object, no program, the rule on standard output.  A configure
-- script asks this way.  -MF sends it to a file and -MT names the
-- target.  The list holds every file the preprocessor opened, system
-- headers with the rest, which is more than -MM asks for and never
-- less.
do
	write("dep.c", "#include \"dephdr.h\"\nint f(void) { return X; }\n")
	write("dephdr.h", "#define X 3\n")
	ok, out = cc("-M dep.c > dep.mk")
	local t = ok and slurp(dir .. "/dep.mk") or ""

	if not tap.ok(ok and t:find("dep.o:", 1, true) == 1 and
	    t:find("dep.c", 1, true) ~= nil and
	    t:find("dephdr.h", 1, true) ~= nil and
	    slurp(dir .. "/dep.o") == nil and
	    slurp(dir .. "/a.out") == nil,
	    "-M writes the rule and builds nothing") then
		tap.diag(out or t)
	end
	ok, out = cc("-MM -MT built/dep.o -MF dep2.mk dep.c")
	t = ok and slurp(dir .. "/dep2.mk") or ""
	if not tap.ok(ok and t:find("built/dep.o:", 1, true) == 1 and
	    t:find("dephdr.h", 1, true) ~= nil,
	    "-MT names the target and -MF the file") then
		tap.diag(out or t)
	end
end

-- `.set a, b` where b is a name this file does not define makes a a
-- reference to b, not a symbol of its own.  gas resolves it away
-- entirely: no a in the table, and every relocation against a names b
-- with the offset folded into the addend.  linux's boot header
-- aliases setup_size, which the linker script defines, and writes it
-- into the PE header.
do
	write("alias.s",
	      "\t.text\n\t.globl\tstart\nstart:\n" ..
	      "\t.long\tfstart\n" ..
	      "\t.long\tfstart - salign\n" ..
	      "\t.set\tfstart, setup_size\n" ..
	      "\t.globl\tfstart\n" ..
	      "salign = 512\n")
	ok, out = cc("--target=amd64 -c -o alias.o alias.s")
	local _, rel = shell("readelf -rW alias.o")
	local _, sym = shell("readelf -sW alias.o")

	if not tap.ok(ok and rel:find("setup_size + 0", 1, true) ~= nil and
	    rel:find("setup_size - 200", 1, true) ~= nil and
	    rel:find("fstart", 1, true) == nil and
	    sym:find("fstart", 1, true) == nil,
	    "an alias of a name this file lacks is a reference to it") then
		tap.diag(out .. rel .. sym)
	end
end

tap.done()
