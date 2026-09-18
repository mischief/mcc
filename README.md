# mcc

Mischief's compiler collection: `mcc` compiles, `mas` assembles, `mld`
links. One program behind all three, and one binary for every target --
`--target=` rather than a prefix per machine, the way clang does it.

A small C compiler in Lua, in the shape of the 1972 one: a per-expression
tree, one code table per evaluation context, and a matcher that takes the
first alternative whose operand shapes the tree can satisfy.

It builds the whole of Lua, for amd64 and for riscv64, and the binary passes
the upstream Lua test suite: 28 test files, `final OK`. `TODO.md` says what
is left.

    lua5.4 drive.lua [-c|-S|-E|-shared] [-o out] [-Idir] [-DNAME] \
        [--target=amd64|riscv64|riscv32|xtensa] file...

`drive.lua` is the driver, in the shape a build system expects one: it
takes the flags a C compiler takes and ignores the ones that mean nothing
here, so `CC=mcc` works. It compiles, assembles and links with nothing but
this compiler -- no gas, no ld, no libc. `mas` is the same program with
`-c`, `mld` the same with `-nostdlib`, so a linker adds nothing that was
not named.

    mcc -O2 -Wall -c a.c b.c         # -O2 and -Wall mean nothing and are
    mld -o prog a.o b.o crt.o        # taken as flags, not as files
    mcc -o prog a.o b.o              # this one brings the runtime
    mcc -shared -fPIC -o m.so m.c
    mas b.s -o b.o

A build that sets `CC=mcc` gets the host target. There is no prefix per
machine to say otherwise, so a cross build has to say `--target=` itself.

Meson runs the tests, in parallel, and reads their TAP:

    meson setup build --prefix=$HOME/.local -Dlua_src=$HOME/src/lua
    meson test -C build                     # 261 tests, about 22 seconds
    meson test -C build --suite unit        # the code generator alone
    meson test -C build --suite amd64       # one target
    meson test -C build --suite lua         # a Lua tree, one source a test
    meson test -C build --suite testes      # the upstream suite, a file each
    meson install -C build                  # mcc, mas and mld

`lua_src` is an option rather than an environment variable on purpose:
meson re-runs its configuration whenever anything asks it to, and the
environment of that run is not the one you set up with. Tell it once with
`-Dlua_src=` and the whole-of-Lua tests keep running.

Only the programs this compiler produces are emulated; the compiler is Lua
and runs on the host. Nearly everything runs at once, so the wall clock is
the longest single test: the bootstrap, which is two interpreter builds one
after the other and cannot be anything else.

The system compiler is the oracle, not a dependency. Every test compiles a
file twice, once here and once with gcc, and compares what the two programs
say; each assembler is compared against gas byte for byte. Nothing in the
toolchain needs them: `test/self.lua` and `test/drive.lua` build and run
programs that gcc never touched.

Every test is differential: a file is compiled with this compiler and with
the system one, both are linked against the same driver, and the output is
compared. rv64 runs under `qemu-riscv64`, Xtensa under
`qemu-system-xtensa`; rv32 is assembled only, for want of an rv32 libc
here.

A target whose toolchain is not installed is left out at setup time rather
than failed, so `meson test` on a bare machine runs the unit tests and the
amd64 ones and says nothing about the rest.

## A module the interpreter loads

    meson test -C build module-abi

builds `test/c/mod.c` as a Lua module with this compiler, links it as a
shared object, and loads it into a Lua the compiler built and into one gcc
built. The same module built by gcc is loaded into both as well, and all
four have to answer the same. Nothing about a shared object is a private
arrangement: doubles in their own registers, eight of them so that the last
arrive on the stack, integers and floats interleaved so that both register
files fill, a variadic call that reads the register save area, one of our
own that writes it, a string through the library's buffer, and a callback
that reenters the interpreter.

Nothing in the file came from another toolchain: `cc.lua -fpic` compiles it,
`as/amd64.lua` assembles it and `so.lua` writes the shared object.

`-fpic` reaches a symbol another unit may replace through the table the
loader fills in. A global becomes an indirection through a `GOT` node, so
`&x` collapses back to the load by the rule that already handles `&*p`, and
a static stays a plain pc-relative reference. Direct calls stay direct.

`so.lua` writes the rest of what a loader reads: the symbols this object
offers and the ones it wants, their hash, the list of places to fix up, and
a six-byte stub for every function it calls and does not have. Nothing is
lazy -- every address is bound before the object runs, so there is no
resolver to call back into and each stub is one jump through the table.

The output also ends with `.note.GNU-stack`, without which the linker takes
the stack to be executable and refuses to load the result.

## Where the time goes

Sampling the compiler over the whole of Lua says the front end is most of
it: the tokenizer and the macro expander together, with the code generator
barely visible. Two things came of that.

The tokenizer now indexes the source rather than pulling a character at a
time through a closure, which was a call and a one-byte string for every
byte of every file. That alone took the biggest source from 0.44 to 0.35
seconds.

`c/scan.c` is the scan loop again in C, as a Lua module this compiler
builds with its own assembler and its own linker. It decides where a token
ends and nothing else -- which names are keywords and what a number is
worth stay in Lua -- so the two paths cannot drift apart on anything else,
and `test/scan.lua` runs both over every source it can find and compares
158,641 tokens. It takes the same file to 0.32.

Everything works without it. `require "scan"` is tried once and the Lua
scanner is used when it is not there, which is what a machine with no C
compiler of its own gets.

The macro expander was the other third, and none of it wanted C. A macro
body is kept as text, and it was tokenized again on every expansion, which
is most of what a preprocessor does when a header defines a macro that a
thousand lines use; the tokens are now kept and copied. Each expansion
frame carries its own length rather than being measured again on the way
past. Whether a macro is already expanding and whether a conditional is
switched off are counted rather than searched, because both were asked of
every token.

Those took the same file from 0.32 to 0.25 seconds.

A table for every token was what was left, and C did not help with that.
Five million copies of one token, taken apart:

    lua call, empty body         0.049 s
    c   call, empty body         0.038 s
    lua call, {}                 0.159 s
    c   call, table only         0.252 s
    lua constructor, 6 fields    0.541 s
    c   string keys, 6 fields    0.817 s
    c   cached keys, 6 fields    0.776 s

Crossing into C is not the problem -- an empty C function is called faster
than an empty Lua one. The problem is that everything after the crossing is
Lua-table work either way, and the VM does it better than the API can: a
constructor is one instruction with the hash sized once and the keys
already interned as constants, while `lua_getfield` and `lua_setfield` are
out-of-line calls that push and pop each value through the Lua stack.
Interning the keys once and keeping them in upvalues wins four hundredths
of a second, which says the string lookup was never the cost.

So C is worth it where the work is not Lua values -- the scanner is a byte
loop over a string, which the VM cannot walk without a call and a value per
byte, and there it won a tenth.

The token got a different shape instead. A table has an array part, which
is a vector, and a hash part, which is a hash; six named fields went in the
second and now six slots go in the first:

    hash, 6 fields   0.496 s
    array, 6 slots   0.236 s
    rewrite in place 0.126 s
    slot + copy      0.668 s

The last line was what the compiler did: the tokenizer wrote into one of
two tables in rotation, and whoever wanted to keep a token copied it, which
everyone did. A fresh token in array form is the second line. Only lex.lua
and cpp.lua see the slots -- `cpp:out` hands the parser a token by name,
because the parser holds one at a time and does not care -- so the two
hundred field reads in the parser did not have to move.

Together with the expander work that took the biggest source from 0.32 to
0.22 seconds and the whole tree from 3.41 to 2.43, which is what this
compiler does now:

    whole Lua tree, amd64    2.43 s with the module, 2.87 s without

## Its own assembler and linker

`as.lua` holds what every machine shares -- sections, labels, relocations,
directives and the passes -- and the encoding lives in `as/`. Not a general
assembler: it reads the subset the target files produce.

`as/riscv.lua` expands the pseudo-instructions the way the real one does,
and lengthens a branch that cannot reach, which takes a sizing pass that
repeats until nothing moves.

`as/amd64.lua` writes the sixty mnemonics target/amd64 emits: a REX byte,
an opcode, a ModRM byte, sometimes a SIB byte, a displacement and an
immediate. It picks the short form wherever the real one does -- the
accumulator opcodes, shifting by one, a jump that reaches in a byte -- and
`test/asdiff.lua amd64` holds it to that, 5,500 distinct instructions
against gas.

A jump's form comes from the decision made at the end of the last sizing
round and from nothing else. A round that widened as it measured would move
the ground under the next measurement, and a form once widened is never
narrowed: measuring against a label the round before placed made a jump
look further away than it was, and whole files came out three percent
larger than gas's.

`as/xtensa.lua` writes the wide, 24-bit forms only. A constant too big for
`movi` becomes an `l32r`, which reads a word near the code; `l32r` only
reaches backwards, so the pool sits in front of the function that uses it,
and its size is not known until the function has been read. A conditional
branch reaches 128 bytes and becomes the opposite branch over a jump past
that. The same repeated pass settles both.

    lua5.4 test/asdiff.lua riscv
    lua5.4 test/asdiff.lua xtensa

assembles everything this compiler makes twice, once with ours and once
with the real one, and compares the bytes: 261,882 RISC-V words, and 9,390
Xtensa instructions one at a time. A word the real one leaves a relocation
on is skipped, because it has not decided that word yet.

`ld.lua` lays the sections out, resolves the symbols, applies the
relocations and writes a static ELF. A gap wider than a page starts a
second loadable segment, `place` pins a section where the hardware looks
for it, and `detached` keeps the headers out of the image for a machine
that starts at the base address.

`obj.lua` is the object file between them, and it is why the linker does
not grow with the program: the header carries the sizes and the symbols
that matter, and one section at a time is read, relocated and written out.
Linking the whole of Lua for Xtensa holds 274 KB rather than the 4 MB it
would take to keep every unit.

    ./cclink -Iinclude -Iinclude/freestanding hello.c rt/miniio.c -o hello
    qemu-riscv64 hello

compiles, assembles and links with nothing else. `test/self.lua` builds five
of the differential programs that way and runs them against the same
programs built by gcc.

## Building Lua

    for f in lua/*.c; do
        lua5.4 cc.lua -t amd64 -Iinclude -Iinclude/hosted -Ilua "$f" -o "$f.s"
        gcc -c -o "${f%.c}.o" "$f.s"
    done
    gcc -no-pie -o lua lua/*.o rt/softfp.c rt/varargs.c -lm

`include/hosted/` holds headers for a program that links against the host's
glibc. They declare only what the library really exports, with the layouts
it really uses: glibc's own headers are written for gcc and reach for
extensions this compiler does not have. `-no-pie` is needed because taking
the address of a function in another object is a direct relocation here, not
a trip through the global offset table.

## Layout

| file | what | target aware |
| --- | --- | --- |
| `lex.lua` | tokenizer, two characters of lookahead | no |
| `cpp.lua` | the preprocessor, a token filter | no |
| `include/` | the freestanding headers a compiler must supply | no |
| `include/hosted/` | headers for a program that links against glibc | no |
| `as.lua` | the assembler, for what the RISC-V targets emit | yes |
| `ld.lua` | the linker and the ELF writer | yes |
| `rt/softfp.c` | the floating point runtime, in integers | no |
| `rt/varargs.c` | the variadic argument walker | no |
| `rt/wide.c` | eight-byte integers where a register is four | no |
| `rt/widefp.c` | and the floating point half of the same | no |
| `types.lua` | types and their layout | no |
| `data.lua` | emitting initialized data | no |
| `parse.lua` | declarations, statements, expressions | no |
| `tree.lua` | nodes, types, Sethi-Ullman numbering, the arena | no |
| `md.lua` | the table format and its compiler | no |
| `gen.lua` | the matcher and the driver | no |
| `cc.lua` | the command | no |
| `target/amd64.lua` | registers, address forms, code tables | yes |
| `target/riscv.lua` | the same, parameterised by width | yes |

## The preprocessor

A token filter between the lexer and the parser. Files nest on one stack and
macro expansions on another, with pushed-back tokens riding the expansion
stack so that a single order governs everything. Macro bodies are kept as
text and lexed again at each expansion, which costs time and saves the memory
a token list per macro would take.

All 35 Lua 5.4 source files preprocess to exactly what `gcc -E` produces,
585,434 tokens, with the same headers on both sides and `__GNUC__` off.

| input | tokens out | live |
| --- | --- | --- |
| `lctype.c` | 2,469 | 82 KB |
| `lvm.c` | 51,998 | 238 KB |
| `onelua.c`, the whole library in one unit | 217,366 | 354 KB |

The live set is the macro table and the interned names. What is not yet good
is the garbage: `lvm.c` allocates 83 MB, because a token is copied into a
fresh table at each of the five hops it makes on average. `TODO.md` carries
the fix and the measurement that rejected the obvious alternative.

## The arena

`tree.mark` and `tree.release` bracket every statement. Nodes come from a
pool and go back to it, so an expression costs nothing the next one does not
reuse, and nothing whole-function is ever built out of nodes.

    MEM=1 lua5.4 cc.lua ... file.c -o /dev/null

reports the Lua heap while compiling: what is allocated, and what survives a
full collection, which is the working set a small machine would have to hold.
Compiling the 35 Lua sources for rv32:

| | smallest (`lctype.c`) | largest (`lvm.c`) |
| --- | --- | --- |
| allocated | 681 KB | 1644 KB |
| live | 491 KB | 1264 KB |

The floor is 294 KB before a line is read: 21 KB of Lua, 260 KB of this
compiler's own code and tables, 14 KB of driver. Above that, for `lvm.c`:

| | KB | count | each |
| --- | --- | --- | --- |
| global symbols | 311 | 516 | 603 B |
| macros | 224 | 819 | 280 B |
| one function's assembly | 155 | `luaV_execute` | |

None of that is the arena, which stays at a few dozen nodes. It is what a
translation unit means: every name and every macro the headers declare has to
be held until the unit ends, and here each one is a Lua table. The 1972
compiler held a symbol in sixteen bytes, in a hash table of a hundred fixed
slots, and an expression in a five hundred byte arena. The shape is the same;
the representation is thirty-eight times heavier.

Assembly is written out after each external definition rather than
accumulated, and `buf.lua` merges the pieces as they arrive so that one
function's text costs its own size rather than five times it.

## Where a target plugs in

A target is one table. `md.target` checks it at load, so a malformed
description fails immediately rather than on the first tree that reaches it.

| field | what it supplies |
| --- | --- |
| `ptrsize`, `nreg` | pointer width, scratch registers |
| `regname(r, size)` | a register's name at a width |
| `suffix(ty)` | the size letter a mnemonic takes, if any |
| `addr(g, n)` | operand text for a node an instruction can name |
| `mnem(n, alt)` | the mnemonic behind `%I` |
| `branch`, `jump` | conditional and unconditional transfers |
| `adapt` | bridge a value in a register to another context |
| `save`, `restore` | spill one register around a fixed-register instruction |
| `call` | the argument sequence, whose length no table can express |
| `slot`, `frame`, `prologue`, `epilogue` | frame layout and the calling convention |
| `globaldef`, `stringdef` | data definitions |
| `dcalc` | optional, to override a difficulty the default gets wrong |
| `code` | the tables, one per context |

Four contexts, as in 1972: `reg`, `stack`, `eff`, `cc`. `md.lua` documents
the operand shapes, the evaluation list and the template escapes in full.

## Inline assembly

The subset a kernel writes: a literal template, operands tied to a register,
to memory or to an immediate, and a clobber list.

    __asm__ volatile ("rdtime %0" : "=r" (v));
    __asm__ ("shlq %%cl, %0" : "+r" (r) : "c" (n));
    __asm__ volatile ("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0));

An asm statement is a statement, and at a statement boundary this compiler
holds every value in its frame slot. No scratch register is live when one is
reached, so there is no allocation to reconcile: each operand takes the next
free register, skipping any the template names for itself. That is the part
of inline assembly that is usually hard, and this shape does not have it.

A constraint letter that names a register comes from the target: `a b c d S
D` on amd64, none on riscv, which has no fixed-register instructions. A
register the template destroys and the ABI wants back, `rbx` or `s1`, is
saved around the template. An output lands in a frame slot of its own first,
because storing it straight into its lvalue could need a second register and
destroy another output. `%0`, `%[name]`, `%%`, `%=` and the width modifiers
`%b %w %k %q %c` are understood; `asm goto` is not.

Not supported: `_Atomic` and `<stdatomic.h>`, which is what stands between
this and the rest of the lua-os kernel. Sixteen of its C files compile now,
`riscv64/machine.c` among them; the others ask for atomics.

## Fixed registers

Some instructions name their own registers. An alternative declares them:

    clob = {0}      -- allocation-order registers the template destroys

Anything in that set still holding a value, meaning an index below the
current register, is saved before the template and restored after. On amd64
a divide reads and writes rdx:rax and a variable shift reads cl, so rcx, rdx
and r11 are held out of the allocation order entirely and only rax has to be
saved. On riscv none of this applies: divide, remainder and variable shifts
are ordinary three-operand instructions, and no alternative there carries a
clobber list at all.

## What the second target changed

The matcher, the shape ladder, the evaluation list and the template mechanism
took riscv without a change. The interface below them moved, and each move is
a real difference between the machines:

* **`branch` takes the register.** riscv has no flags, so a comparison and a
  jump are one instruction. The `cc` table there only evaluates its operands
  into registers and emits nothing.
* **`mnem` takes the alternative.** `addi` and `add` are the same operator on
  different operand shapes.
* **Frame layout moved into the target.** amd64 locals start at -8(%rbp),
  riscv locals start below the saved `ra` and `s0` at -24(s0).
* **`%C` means an operand's literal number**, its value or its frame offset.

The operand classes carry the rest. On amd64, `i` (12) is what an instruction
can name, because an indirection is not an addressing mode there. On riscv
nothing but a small constant can appear in an arithmetic instruction, a global
sits at 16 because its address has to be built first, and a constant is 8 only
while it fits the twelve-bit field. The ladder is the same; where each
target's operands land on it is not.

One trap worth naming: an operand shape describes the **operand**, not the
node. `ADDR` shapes have to classify the thing being addressed, which is the
child. Getting that backwards produced assembly that looked plausible and
would not assemble.

## Measured

| | amd64 | riscv |
| --- | --- | --- |
| description | 369 lines | 370 lines, both widths |
| operators, alternatives | 28, 81 | 28, 59 |
| resident at load | 62.4 KB | 49.6 KB |

Target neutral code is 1392 lines: 137 for the lexer, 567 for the parser, 188
for the tree and its arena, 193 for the table format, 250 for the matcher and
the driver, 57 for the command. Roughly half of each figure above is the
compiled Lua of the description file and half is the table itself.

For comparison the whole PDP-11 table in the 1972 compiler is 12 KB of C. The
gap is Lua table overhead: pre-parsing every template cost 66.7 KB for 349
pieces, which is why `md.steps` and `md.parts` build the parsed form on first
use. Anything that has to fit a small machine should hold the table as a flat
array and a string pool.

## The language

In: `char`, `short`, `int`, `long` and their unsigned forms; pointers,
arrays, `struct`, `union`, `enum`, `typedef`, recursive declarators including
function pointers; aggregate initializers with inferred bounds and strings,
string literals, statics; functions with any number of arguments, variadic
definitions with `va_start`, `va_arg` and `va_end`; `if`/`else`, `while`,
`do`, `for`, `switch`, `goto` and labels, `return`, `break`, `continue`; the
full binary operator set with C precedence, `&&` and `||` with short
circuits, `?:`, compound assignment, prefix and postfix `++` and `--`,
address-of, indirection, subscripts, `.`, `->`, `sizeof`, casts,
whole-record assignment, the comma operator, and the preprocessor.

Arithmetic follows C: the integer promotions, the usual arithmetic
conversions, and the rule that gives an integer constant the first type that
holds it. Plain `char` is signed or unsigned as the platform has it.

Floating point is lowered to calls into `rt/softfp.c` rather than to a float
register class, because the target that matters has no FPU. That runtime
uses no C float or double itself: round to nearest with ties to even,
subnormals, infinities and NaNs, every product built from 16x16 pieces
because a 32-bit machine has no 64-bit multiply. It has to be that way
twice over -- a compiler reading a runtime written in doubles lowers its
`a * b` into a call to the function it is defining, and lua-os links no
libgcc. The calling
convention is separate from that: a `double` goes in `xmm0` to `xmm7` on
amd64 and in `fa0` to `fa7` on riscv64, and the value crosses between the
files with one instruction, because a bit pattern is what both sides hold.
rv32 uses ilp32, where a `double` travels in an ordinary register, which is
what an ESP32-C series part wants.

An eight-byte scalar on a four-byte machine does not fit a register, and
every tree node here gets one. So on a 32-bit target such a value lives in
memory, is named by its address, and every operation on it is a call into
`rt/wide.c` or `rt/widefp.c` -- the same trade the floating point runtime
makes, one step further along. Across a call it follows the platform: an
even-aligned register pair, and a pair coming back. `WIDE=1` forces the same
lowering on a 64-bit target, which is the only way to run it against a
compiler that has the type natively; `./run` does that for eight of the
differential tests.

Out: bitfields, flat initializers for nested aggregates, `_Generic`.

Known limits inside what is in:

* A constant wider than the immediate field cannot go straight to memory.
* `switch` builds a compare chain, not a jump table.
* No debug information.

`TODO.md` lists what is missing, with the count of each construct in the Lua
source that puts it there.
