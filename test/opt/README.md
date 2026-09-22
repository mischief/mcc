# The optimizer corpus

Small C functions, one per file, each built to cost one thing.  gcc and
mcc compile every one under the same flags, and the bytes per cell say
where this compiler pays.  A run takes under a second, so the loop is:
look at a cell, change the compiler, run again.

    lua5.4 test/opt/run.lua                    # boot flags, the default
    lua5.4 test/opt/run.lua --target=m32       # plain i386
    lua5.4 test/opt/run.lua --target=amd64
    lua5.4 test/opt/run.lua --asm u64_add      # both assemblies, one cell
    lua5.4 test/opt/run.lua --family u64       # one family only
    lua5.4 test/opt/run.lua --target=amd64 --run   # build, run, compare
    lua5.4 test/opt/run.lua --save             # this run is the baseline

`boot` is the flag set a kernel's real mode setup is built with: `-m16
-Os -march=i386 -mregparm=3 -mpreferred-stack-boundary=2`.  The other
two say which costs are the machine's and which are the compiler's.

A run compares against `baseline-<target>.tsv` and fails when any cell
grew, so a change that buys bytes in one place and spends them in
another is seen.  `--save` moves the baseline; `--no-ratchet` looks
without judging.

`--run` links every cell that can run on the host into one program,
twice, and compares what the two print.  Cells that touch the machine
(ports, segment registers) are marked `norun`.  Only `m32` and `amd64`
can run.

## Reading a cell

A cell's size is code and initialized data, summed from the object's
sections by name.  `size` is not used: gcc writes a `.note.gnu.property`
it would count.

Every parameter and every local feeds the return value, so gcc cannot
drop any of it and a cell measures the same work twice.  No cell reads
a header; the prelude in `gen.lua` declares the types and the runtime a
cell calls.  A cell that calls `ext()` sees an opaque call in both
compilers.

A cell that uses eight-byte integers on i386 carries the runtime bodies
mcc emits for them, because mcc writes them into every object that
needs one.  That is what an image pays, so it is counted.

## Families

| family | what it costs |
| --- | --- |
| sig | the calling convention: argument count and type, return type |
| loc | locals: how many, used how often, live across a call or not |
| glob | a global reached by name: fields, constant and variable subscripts |
| cmp | comparisons and conditions, as branches and as values |
| rmw | read, modify, write, on locals, globals and through pointers |
| u64 | eight-byte integers on a four-byte machine |
| asm | inline assembly in the shapes a boot loader writes |
| inl | a static body called once or three times, at three sizes |
| va | variadic functions |
| ctl | control flow: if chains, switch, loops, break, goto |
| expr | expression depth and calls inside expressions |
| mem | records: zero, copy, pass and return by value, local arrays |
| type | widths and signs across loads, stores and conversions |
| konst | constants at the edges of the immediate forms |
| ptr | pointer arithmetic and walks |
| frame | what a frame costs when nothing needs one |
| call | calls: argument counts, indirect, tail, results used |
