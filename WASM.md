# A WebAssembly target

Notes before any code. What this would take, what fits and what does
not, and where the hard part actually is.

## What fits better than expected

**A stack machine suits this compiler.** The brief against mcc's code
size is that every local, temporary, inlined parameter and inline
result is a frame slot, because nothing keeps a value in a register
across statements. WebAssembly has no register file to keep it in
either: it has a stack and an unbounded set of typed locals. What costs
bytes on amd64 is free here.

**Sethi-Ullman already produces the order a stack wants.** The matcher
evaluates the heavier subtree first and leaves its result where the
template can reach it. Written postfix, that is the operand order a
stack machine takes.

**The templates survive.** `md.lua` alternatives are text with `%R`
substitutions, three-address in shape. Map mcc's virtual registers to
wasm locals -- there is no limit and so no spilling -- and

    add %R1,%R        becomes    local.get $r1
                                 local.get $r0
                                 i32.add
                                 local.set $r0

Every target hook that names a register keeps working. `nreg` stops
being a real constraint.

**No linker.** A module is self-contained, calls go by index, and data
is a segment. `ld.lua` and `elf.lua` sit this one out.

## Where the hard part is

**Structured control flow.** wasm has no goto. It has `block`, `loop`,
`if`, `br`, `br_if` and `br_table`, and a branch may only leave a
construct it is inside. mcc emits labels and jumps to them.

The good news is that this funnels through very few places:

    gen:jump(label)          -> T.jump(g, label)
    gen:cond(n, l, s, reg)   -> T.branch(g, n, label, sense, reg)
    gen:newlabel()

so a target sees every edge. A wasm target records them per function
rather than writing text, and emits control flow once the body is
known.

Two ways to emit it:

*The dispatch loop*, which is mechanical and always correct:

    (local $state i32)
    (loop $top
      (block $case_n ... (block $case_0
        (br_table ... (local.get $state)))
        ;; label 0's code
        ...
      )
      (br $top))

Every label becomes a case, every jump becomes a `local.set $state`
and a `br $top`. No CFG analysis at all, perhaps 150 lines. The code
is bigger and slower than it needs to be and no engine will optimise
it well, but it runs, and it is a target you can test against.

*A relooper*, which recovers real `block`/`loop`/`if` from the CFG.
This is the right answer and it is the part that is genuinely hard --
irreducible flow needs node splitting or a dispatch fallback anyway.

Start with the dispatch loop. It makes every other piece testable, and
the relooper becomes an optimisation with a working baseline to diff
against rather than a prerequisite.

**Function pointers.** There are no code addresses. A pointer is an
index into a table and the call is `call_indirect` with a type index.
Anything in mcc that treats a function address as a number has to go
through that table instead.

**The container.** No ELF. A module is sections of LEB128: types,
imports, functions, table, memory, globals, exports, code, data. It
replaces `as/<arch>.lua`, and it is easier than one -- no instruction
encoding table, no relaxation, no relocations. `as/amd64.lua` is 2743
lines and almost all of it is encoding; this is a few hundred.

**The runtime.** Every other target has `rt/linux-<arch>.s` making
syscalls. There are none here: `write` and `exit` become imports the
embedder supplies. Smaller than what exists, but new.

## Size, against the targets that exist

    target/amd64.lua   1795     as/amd64.lua   2743
    target/riscv.lua   1286     as/riscv.lua    661
    target/arm64.lua   1258     as/arm64.lua    495
    target/xtensa.lua   760     as/xtensa.lua   377
    elf.lua            1026     ld.lua         1473

A target supplies 45 named hooks. So: `target/wasm.lua` of roughly the
usual size, a module writer smaller than any existing assembler, no
linker, and one piece -- control flow -- that has no equivalent in any
current backend.

One backend's work, not a rewrite. The earlier estimate of "weeks, and
a relooper first" was wrong on both counts.

## What it is worth, and what it costs

It would make compiled C run at engine speed in a browser instead of
through an interpreter, and it would let lua-os run mcc's output on the
machine it is already running on.

Against that: mcc's stated shape is ELF for real machines, with its own
assembler and linker and no host toolchain. wasm is a different
container with a different linking model and no addresses, and adding
it is a decision about what this compiler is, not only work. It also
competes with the inlining work, which has a measured 13090-byte prize;
this has none.

## Reference

`~/src/wasm-spec` is the WebAssembly spec repository. The binary format
is in `document/core/binary/`, and `test/core/*.wast` is the conformance
suite, which is the thing to run a module writer against.
