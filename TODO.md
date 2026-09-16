# State, and what is left

Target: compile Lua 5.4 (35 `.c` files, 31708 lines). The counts are
occurrences in that source, measured, and are why each item was on the list.

## Where Lua stands

    ./luacheck

**33 of the 35 sources compile and assemble, for amd64 and for riscv64**,
against lua-os's own headers. The two that do not are `loslib.c` and
`onelua.c`, which includes it: lua-os's `time.h` declares no `struct tm`, and
gcc refuses the same file with the same headers, so that is a gap in those
headers rather than in this compiler.

The 33 objects link into a Lua binary of 580 KB. It does not run yet, and the
reason is a deliberate ABI choice rather than a defect: a `double` travels in
an integer register here, which is what a machine with no FPU needs and not
what glibc expects. Built entirely with gcc against the same lua-os headers,
the same binary hangs in the same place, so the hang is those headers meeting
the host's libc, not the generated code.

To make it run, one of:

* compile lua-os's own libc with this compiler, which is the real target and
  makes both sides of every call agree; or
* classify floating point arguments the way SysV does, which means the
  targets learning about float registers after all, for calls only.

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
| 17 | 64-bit integers on rv32 | 9 `long long`, avoidable with `LUA_32BITS=1` | not needed yet |

Floating point needed no float register class. Every operation is a call into
`rt/softfp.c`, with the value carried as its bit pattern in an ordinary
register: `__dadd`, `__dcmp`, `__i2d` and the rest, seventeen of them. That is
what a machine without an FPU needs anyway, and the ESP32-C5 is one. A target
that has an FPU can override the lowering with table entries later, without
touching the front end.

## Still missing

* Calls into a foreign ABI that pass floating point. See above.
* `long long` on a 32-bit target: doubles need register pairs.
* Bitfields, multi-dimensional arrays, flat initializers for nested
  aggregates, `_Generic`, `_Static_assert` beyond skipping it.
* A compound assignment evaluates its left side twice, so `*p++ += 1` steps
  twice. Plain variables, members and `a[i]` with a simple index are correct.
* `switch` builds a compare chain, not a jump table.
* Debug information.

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
* Predefine the target's macros (`__x86_64__` and friends) so foreign headers
  take the right branches. With a crude command line of them, 17 of the 35
  Lua sources compile against glibc's headers rather than lua-os's.
