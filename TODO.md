# State, and what is left

Target: compile Lua 5.4 (35 `.c` files, 31708 lines). The counts are
occurrences in that source, measured, and are why each item was on the list.

## Where Lua stands

    meson test -C build --suite slow

**Lua builds and runs, on both targets.** Every source compiles, the objects
link against the host's glibc, and the binary answers exactly as one built by
gcc from the same sources and the same headers.

    meson test -C build --suite testes

It passes the upstream Lua test suite as well: 28 test files, `final OK`,
with `_port` set so that `main.lua` is skipped. That one drives the
interpreter as a subprocess and wants a readline POSIX build, which neither
of these is; the reference build stops at the same line.

| | amd64 | riscv64 under qemu |
| --- | --- | --- |
| gcc -O0 | 4.85s | 31.0s |
| this compiler | 6.00s | 34.3s |

Two corrections came out of the suite: a narrow integer argument to the float
runtime was not extended to a whole word, so `(double)INT_MIN` answered
`+2147483648.0`; and a local aggregate could not be initialized from values
that are not constants.

    meson test -C build --suite lua

The freestanding path, against lua-os's own headers, compiles and assembles
33 of the 35 sources for amd64 and riscv64. The two that do not are
`loslib.c` and `onelua.c`, which includes it: lua-os's `time.h` declares no
`struct tm`, and gcc refuses the same file with the same headers, so that is
a gap in those headers.

rv32 gets the same 33.

## Tier 1 — Lua cannot be built without these

| # | item | evidence in Lua | state |
| --- | --- | --- | --- |
| 1 | preprocessor | 514 includes, 874 macros (475 with arguments), 215 conditionals | done |
| 2 | struct, union, layout, `.` and `->` | 146 struct, 32 union, 3428 `->`, 1777 `.` | done |
| 3 | `switch` | 98 switches, 631 case labels | done |
| 4 | aggregate initializers | 51 | done |
| 5 | casts | 367 direct, 306 through `cast()` | done |
| 6 | `typedef` | 96 | done |
| 7 | function pointers, indirect calls | 15 typedefs, calls throughout | done |
| 8 | struct and union assignment | 11 `*a = *b`, plus every `setobj` | done |
| 9 | `enum` | 11 declarations, hundreds of constants | done |
| 10 | `?:` | 89 | done |
| 11 | `goto` and labels | 59 | done |
| 12 | storage classes and qualifiers | 990 `const`, 925 `static` | done |
| 13 | `sizeof` | 154 | done |
| 14 | comma operator, adjacent string literals | 7, 38 | done |

## Tier 2

| # | item | evidence | state |
| --- | --- | --- | --- |
| 15 | varargs: definitions, `va_list`, `va_start`, `va_arg` | 93 `...`, 34 `va_*` | done |
| 16 | floating point | 118 `float`/`double` | done, lowered to calls |
| 17 | 64-bit integers and doubles on rv32 | 9 `long long`, every `double` | done, in memory |

Floating point needed no float register class in the front end. Every
operation is a call into `rt/softfp.c`, with the value carried as its bit
pattern in an ordinary register: `__dadd`, `__dcmp`, `__i2d` and the rest,
seventeen of them. That is what a machine without an FPU needs, and the
ESP32-C5 is one. A target with an FPU can override the lowering with table
entries later, without touching the front end.

The calling convention is a separate question, and it is the platform's, not
this compiler's. `md.classify` holds the whole of it in three facts a target
states: how many floating point argument registers there are, whether a
variadic argument may use one, and whether a float that finds the float file
full falls back to the integer file. SysV on amd64 answers 8, yes, no; lp64d
on riscv64 answers 8, no, yes; ilp32 on rv32 answers 0, and a `double`
travels in an ordinary register.

## What Lua found

Ten corrections, each one a construct the language requires and the test
suite did not reach. They are in the history with their fixes; the pattern
worth keeping is that eight of the ten were found by building a real program
and comparing its output with the same program built by gcc, not by reading
the code.

| what was wrong | what it broke |
| --- | --- |
| the comma operator emitted its left side at parse time | `for (p = t; p->n; p++, m <<= 1)` stepped p before the body |
| a comma expression in a condition branched on the wrong node | `check_exp` in an `if`, so every table lookup missed |
| a conditional expression in a condition tested an arm against zero | `os.time` rejected every field |
| a compound assignment evaluated a side-effecting address twice | `*p++ += 1` stepped twice |
| `\f` and the octal and hex escapes were the letter after the backslash | the lexer read `for` as `or` |
| no integer promotion | `int >= lu_byte` compared unsigned, so a register was freed twice |
| an integer constant was always a word | `signed_char >= 0` compared 64 bits of a 32-bit value |
| widening a byte to eight bytes did nothing | a negative `shrlen` became four billion |
| a local array without a bound took its slot before its size | a ten-element array overwrote the return address |
| `sizeof` on a string literal answered for a pointer | every error message lost two characters |
| the stack pop after a compare clobbered the flags | `io.open` rejected every mode |
| a same size conversion retyped the node in place | unsigned remainder became signed remainder |
| a narrow integer argument to the float runtime was not extended | `(double)INT_MIN` answered `+2147483648.0` |

## Still missing

* Bitfields, flat initializers for nested aggregates, `_Generic`.
* `_Atomic` and `<stdatomic.h>`. Sixteen lua-os kernel files compile,
  `riscv64/machine.c` among them; the rest ask for atomics.
* The kernel's nolibc still cannot be used: it is header-only, and what it
  supplies is not what Lua wants -- no `FILE`, no `strtod`, no `%f`, no
  setjmp, no locale, no `mktime`. lua-os has its own C library instead, 1582
  lines in eight files, and all eight compile with this compiler; its
  `setjmp` is hand-written assembly in a `.S` file.
* `switch` builds a compare chain, not a jump table.
* Debug information.

## Still to do for lua-os

* A loader on the lua-os side: `ld.lua` already answers with the list of
  words holding an absolute address, which is the whole relocation table a
  loader needs. What is missing is the other side -- somewhere to put the
  program, and a table of the kernel symbols it may call.
* Passing a structure by value. Nothing in Lua does it and the runtime was
  rewritten to avoid it, but C allows it.
* `_Atomic` and `<stdatomic.h>`, which is what the rest of the lua-os
  kernel asks for.

## Worth doing, unrelated to Lua

* Peephole window: removes 7% of instructions (self-moves and jumps to the
  next address) for about 40 lines and no memory.
* Memory-operand alternatives for divide on amd64.
* Pool the preprocessor's token tables. Preprocessing `lvm.c` makes 268,190
  calls for 51,998 output tokens and allocates 319 bytes on each, 83 MB in
  all, because a token is copied into a fresh table at every hop. The live
  set is already bounded, at 238 KB for `lvm.c` and 354 KB for the whole
  library as one translation unit, so this is about garbage, not residency.
  Mark and release, as `tree` already does for nodes, should take most of it.
  A cache of lexed macro bodies was tried and dropped: 11% less garbage for
  87 KB more live memory, which is the wrong trade here.
* `stdint.h` is fixed at 64-bit widths and is wrong on rv32.
* Two assembler forms gas takes and these do not, found by assembling
  `test/c/asm.c` for every target rather than only its own: on RISC-V a
  load whose address is a symbol, `ld a0, cell`, which gas turns into an
  auipc and a load; on Xtensa the `ccount` special register. Inline
  assembly written for one target is only assembled by that target's
  gas today, so neither has bitten.
* Taking the address of a weak name nothing defines. A static link
  answers zero, which is what `_DYNAMIC` and its kind are written for.
  Handing the object to a linker that makes a position independent
  executable does not: the reference wants to go through the global
  offset table, and this compiler writes a PC-relative one.

## Inline assembly with an immediate-only constraint

`arch/x86/include/asm/asm.h` writes

    static __always_inline void *rip_rel_ptr(void *p)
    {
            asm("leaq %c1(%%rip), %0" : "=r"(p) : "i"(p));
            return p;
    }

`"i"` takes a constant and nothing else.  gcc satisfies it because it
always inlines the function and every call site passes the address of a
symbol, which folds.  This compiler does not inline, so `p` stays a
parameter and the constraint cannot be met.  It says so now rather than
writing a register where the template wants a number.

A `static inline` function nothing calls is no longer built, which is
what gcc does with one, so a file that only includes the header is
fine.  What is left is the file that really does call it, and for that
the only answer is to inline, carrying the argument's value into the
body.  That is a much larger piece of work: this compiler reads a unit
once and writes code as it goes, so there is nowhere for a caller's
value to meet a callee's body.

## A shared object on riscv64 or arm64

Neither target builds one, so a reference to a global another unit
owns is worked out where it stands rather than read from a table:
everything those two link ends up in one image.  A real shared object
needs the table, the sequences that read it -- `adrp :got:` with
`ldr :got_lo12:`, `auipc %got_pcrel_hi` with `ld %pcrel_lo` -- and a
linker that builds one.  The assemblers write all four now; the linker
does not.

## AVX-512 on amd64

The VEX forms are here.  EVEX, a second encoding on top of them, is
not: linux's blake2s wants `vprord` and `vpermi2d` and is the only
file left that needs it.

## 16 and 32 bit assembly

`.code16` and `.code32` change how every instruction is encoded, not
just a flag.  linux needs them for the processor trampoline, and
lua-os for its own.  Deliberately left out.

## Hardware floating point

Done on amd64, riscv64 and arm64.  A double is no longer a bit pattern
in an integer register going through rt/softfp.c: loads, stores, the
four arithmetic operations, negate, magnitude, square root, every
comparison and every conversion are instructions.

The float file is indexed by the Sethi-Ullman depth, the same one the
integer file uses, so no allocator changed: the value at depth k is in
float register k, and no two live values share a depth.  `%F` names it,
an `f` letter in a shape selects it, and an `m` letter keeps a constant
out of an operand that has to be a place.  gen tracks which depths hold
a float, because a target has to know that before it saves one.

    amd64     xmm8-15     the ABI keeps xmm0-7
    riscv64   ft0-7       the ABI keeps fa0-7
    arm64     d16-23      the ABI keeps d0-7 and the callee d8-15

On test/c/flt.c the text section went from 8368 to 5041 bytes on amd64,
7880 to 4928 on riscv64, and 5804 to 4364 on arm64.  A float-heavy loop
runs about a hundred times faster and matches gcc -O0 to the bit.

riscv32 and xtensa keep rt/softfp.c, and riscv64 follows its float ABI:
lp64d has the file, ilp32 has none.  The esp32 memory budget is
unchanged, because only the target in use is loaded.

## long double on amd64

The x87 extended type, as the x86-64 ABI asks: 16 bytes, 64 bits of
significand, passed on the caller's stack and returned in st(0).

x87 is a stack, and a stack does not answer to a depth, so a value of
this type lives in a frame slot indexed by the same depth a register
would be: eight slots, taken from the frame the first time one is
wanted.  Every operation loads its operands, works on the x87 stack and
puts the answer back.  That is slower than keeping values on the stack
between operations, and it means a call needs no saving at all, since
a frame slot is not something a call can touch.

A decimal literal is read in the type rather than through a double,
which a double could not do: the exponent reaches past ten to the four
thousandth.  The reader carries the digits and the power of ten in a
hundred and twenty-eight bits and rounds once at the end, which lands
on the same bits gcc does for every literal tried, subnormals and both
extremes included.

What is left:

  * a constant of this type only folds where a double holds the same
    value.  Past that the arithmetic is left to the machine, which is
    right but means `long double x = LDBL_MAX / 2;` at file scope says
    a constant is required.
  * `_Complex` parses and travels but has no arithmetic, so a library
    that implements the functions cannot be built with mcc.  musl's
    src/complex is the one that wants it.
  * a variable length array takes its room with alloca, so it lasts to
    the end of the function rather than the end of the block.  One
    written inside a loop takes more each time round.  Putting the
    stack back at the end of a block needs every way out of one to
    know, which is the work.
