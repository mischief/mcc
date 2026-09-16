# comp

A small C compiler in Lua, in the shape of the 1972 one: a per-expression
tree, one code table per evaluation context, and a matcher that takes the
first alternative whose operand shapes the tree can satisfy.

It builds the whole of Lua, for amd64 and for riscv64, and the binary
answers exactly as one built by gcc from the same sources does. `TODO.md`
says what is left.

    lua5.4 cc.lua [-t amd64|riscv64|riscv32] [-Idir] [-DNAME] file.c [-o out.s]
    lua5.4 cc.lua -E file.c          # preprocess only, one token a line
    ./run                            # every test
    ./luabuild amd64                 # build Lua and check it against gcc's
    ./luacheck                       # compile a freestanding Lua tree
    SHOW=1 ./run                     # and print the generated assembly

Every test is differential: a file is compiled with this compiler and with
the system one, both are linked against the same driver, and the output is
compared. rv64 runs under `qemu-riscv64`; rv32 is assembled only, for want
of an rv32 libc here.

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
| `rt/softfp.c` | the floating point runtime, seventeen calls | no |
| `rt/varargs.c` | the variadic argument walker | no |
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
reuse, and nothing whole-function is ever built.

| input | lines | arena peak | resident | output |
| --- | --- | --- | --- | --- |
| `test/c/prog.c` | 105 | 17 nodes | 41.3 KB | 4.8 KB |
| the same, ten copies | 1059 | 17 nodes | 76.1 KB | 49 KB |

The arena does not move. What grows is the global symbol table, at roughly
300 bytes a symbol, which is the one thing a single pass cannot avoid
holding. Assembly is written out after each definition rather than
accumulated.

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
register class, because the target that matters has no FPU. The calling
convention is separate from that: a `double` goes in `xmm0` to `xmm7` on
amd64 and in `fa0` to `fa7` on riscv64, and the value crosses between the
files with one instruction, because a bit pattern is what both sides hold.
rv32 uses ilp32, where a `double` travels in an ordinary register, which is
what an ESP32-C series part wants.

Out: `long long` and `double` on a 32-bit target, which need register pairs;
bitfields; flat initializers for nested aggregates; `_Generic`.

Known limits inside what is in:

* A constant wider than the immediate field cannot go straight to memory.
* `switch` builds a compare chain, not a jump table.
* No debug information.

`TODO.md` lists what is missing, with the count of each construct in the Lua
source that puts it there.
