# comp

A small C compiler in Lua, in the shape of the 1972 one: a per-expression
tree, one code table per evaluation context, and a matcher that takes the
first alternative whose operand shapes the tree can satisfy.

It builds the whole of Lua, for amd64 and for riscv64, and the binary passes
the upstream Lua test suite: 28 test files, `final OK`. `TODO.md` says what
is left.

    lua5.4 cc.lua [-t amd64|riscv64|riscv32] [-Idir] [-DNAME] file.c [-o out.s]
    lua5.4 cc.lua -E file.c          # preprocess only, one token a line
    ./run                            # every test
    ./luabuild amd64                 # build Lua and check it against gcc's
    ./luatest amd64                  # and run the upstream test suite on it
    ./luacheck                       # compile a freestanding Lua tree
    SHOW=1 ./run                     # and print the generated assembly

Every test is differential: a file is compiled with this compiler and with
the system one, both are linked against the same driver, and the output is
compared. rv64 runs under `qemu-riscv64`; rv32 is assembled only, for want
of an rv32 libc here.

## Its own assembler and linker

`as.lua` reads the RISC-V assembly this compiler emits and answers with
bytes. Not a general assembler: sixty-three mnemonics and eleven directives,
which is what the target files produce. It expands the pseudo-instructions
the way the real one does, and lengthens a branch that cannot reach, which
takes a sizing pass that repeats until nothing moves.

    lua5.4 test/as.lua out/*.s

assembles every file twice, once with ours and once with `riscv64-linux-gnu-as`,
and compares the bytes: 139,832 words across the whole of Lua, byte for byte.
A word the real one leaves a relocation on is skipped, because it has not
decided that word yet.

`ld.lua` lays the sections out, resolves the symbols, applies the
relocations and writes a static ELF with one loadable segment. It also
answers with the list of words that hold an absolute address, which is what
a loader that places the program somewhere else has to add its base to.

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
