# State, and what is left

Target: compile Lua 5.4 (35 `.c` files, 31708 lines). The counts are
occurrences in that source, measured, and are why each item was on the list.

## Where Lua stands

    ./luabuild amd64
    ./luabuild riscv64

**Lua builds and runs, on both targets.** Every source compiles, the objects
link against the host's glibc, and the binary answers exactly as one built by
gcc from the same sources and the same headers.

    ./luatest amd64
    ./luatest riscv64

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

    ./luacheck

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
