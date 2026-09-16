Headers for programs that link against the host's glibc.

They declare only what the C library really exports, with the layouts glibc
really uses, and nothing else: no inline functions, no type-generic macros,
no builtins beyond the ones this compiler knows.  That is why they exist.
glibc's own headers are written for gcc and reach for extensions this
compiler does not have.

Anything whose layout a program can see is spelled out here: `struct tm`
carries the two glibc fields past the standard nine, because mktime writes
them, and `jmp_buf` is the full two hundred bytes, because a program keeps
one in a structure of its own.  A type the program only ever holds a pointer
to, `FILE` above all, stays incomplete.
