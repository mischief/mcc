-- SPDX-License-Identifier: ISC
-- The spellings the parser knows by name: operators, keywords and their
-- GNU variants, and the ones it reads and ignores.

local BIN = {
	["||"] = {1, "OROR"},  ["&&"] = {2, "ANDAND"},
	["|"]  = {3, "OR"},    ["^"]  = {4, "XOR"},   ["&"] = {5, "AND"},
	["=="] = {6, "EQ"},    ["!="] = {6, "NE"},
	["<"]  = {7, "LT"},    ["<="] = {7, "LE"},
	[">"]  = {7, "GT"},    [">="] = {7, "GE"},
	["<<"] = {8, "SHL"},   [">>"] = {8, "SHR"},
	["+"]  = {9, "ADD"},   ["-"]  = {9, "SUB"},
	["*"]  = {10, "MUL"},  ["/"]  = {10, "DIV"}, ["%"] = {10, "MOD"},
}

local OPASSIGN = {
	["+="] = "ADD", ["-="] = "SUB", ["*="] = "MUL", ["/="] = "DIV",
	["%="] = "MOD", ["&="] = "AND", ["|="] = "OR",  ["^="] = "XOR",
	["<<="] = "SHL", [">>="] = "SHR",
}

-- Tokens that can begin a declaration.
local DECLKW = {}
for _, k in ipairs{"char", "short", "int", "long", "unsigned", "signed",
		   "_Bool",
		   "void", "float", "double",
		   "struct", "union", "enum", "const", "volatile",
		   "static", "extern", "register", "inline", "typedef"} do
	DECLKW[k] = true
end
local QUAL = {const = true, volatile = true, register = true}
-- `register` is a qualifier here, but at file scope beside an asm name
-- it binds the name to a machine register, so its presence is recorded.
-- C11 _Atomic, which is a qualifier on its own and a specifier with a
-- type in parentheses.  An atomic object has the layout of the type
-- under it here, and <stdatomic.h> does the work, so both forms only
-- have to be read and let through.
local ATOMICKW = {_Atomic = true, __Atomic = true}

-- Spellings that carry no meaning here.  They are ordinary identifiers to
-- the lexer, so the parser has to know them by name.
local IGNORE = {}
for _, k in ipairs{"_Noreturn", "restrict", "__restrict", "__restrict__",
		   "__signed__", "__const",
		   "__volatile", "__volatile__", "__extension__"} do
	IGNORE[k] = true
end

-- The other spellings of `inline`, which mean the same thing.
local INLINEKW = {__inline = true, __inline__ = true}
-- Builtins whose answer is a property of the program text, not a value
-- to work out.  The arm __builtin_choose_expr does not take is parsed
-- and thrown away, which is what its whole point is.
local SPECIAL = {__builtin_constant_p = true,
		 __builtin_choose_expr = true,
		 __builtin_types_compatible_p = true,
		 __builtin_offsetof = true,
		 __builtin_unreachable = true, __builtin_trap = true}
-- GNU C answers to `__attribute` as well as `__attribute__`.
local ATTRKW = {__attribute__ = true, __attribute = true}
-- C99 spells it one way and GNU C two others.
local COMPLEXKW = {_Complex = true, __complex__ = true,
		   __complex = true}
-- GNU C names the halves of a complex value with these.
local CPLXHALF = {__real__ = "re", __real = "re",
		  __imag__ = "im", __imag = "im"}
local PARENED = {__attribute__ = true, __attribute = true, __asm__ = true,
		 asm = true, __declspec = true}
-- _Alignas, which says what an object is aligned to, not what it is.
local ALIGNAS = {_Alignas = true, alignas = true}
-- The names a compiler answers to for the type a variadic walker is.
local VALIST = {__builtin_va_list = true, __gnuc_va_list = true}
-- The named floating point types of TS 18661-3.  The glibc headers take
-- these for keywords once the compiler says it is GCC 7 or later.
local FLOATN = {_Float32 = "f32", _Float32x = "f64", _Float64 = "f64",
		_Float64x = "f64", _Float128 = "f128",
		__float128 = "f128", __ieee128 = "f128"}
-- _Alignof, and the names a compiler that predates it answers to.
local ALIGNOF = {_Alignof = true, __alignof = true, __alignof__ = true}
-- A compile time assertion, in either spelling.
local STATICASSERT = {_Static_assert = true, static_assert = true}

-- The names GNU C answers to for a 128-bit integer.
local INT128 = {__int128 = true, __int128_t = true,
		__uint128_t = "unsigned"}

-- GNU __auto_type: a declaration whose type is its initializer's.  It
-- stands for a type until the initializer has been read.
local AUTOTYPE = {kind = "auto", size = 0, align = 1, name = "__auto_type"}

-- GNU typeof, which names the type of a type name or of an expression.
local TYPEOF = {typeof = true, __typeof = true, __typeof__ = true}
local STORAGE = {static = true, extern = true, typedef = true}
-- C11 and GNU spell thread storage two ways.  It stands beside static
-- or extern rather than in place of one.
local TLSKW = {_Thread_local = true, __thread = true}
local ASMKW = {asm = true, __asm = true, __asm__ = true}
-- What a string or character literal may be prefixed with.
local STRPREFIX = {u8 = true, u = true, U = true, L = true}
-- The keywords that begin a statement rather than an expression.
local STMTKW = {}
for _, k in ipairs{"if", "while", "for", "do", "switch", "case",
		   "default", "break", "continue", "return", "goto",
		   "{", ";"} do
	STMTKW[k] = true
end
-- The name of the function being compiled, which C99 says is a string
-- declared at the top of every body.
local FUNCNAME = {__func__ = true, __FUNCTION__ = true,
		  __PRETTY_FUNCTION__ = true}

return {
	ALIGNAS = ALIGNAS,
	ALIGNOF = ALIGNOF,
	ASMKW = ASMKW,
	ATOMICKW = ATOMICKW,
	ATTRKW = ATTRKW,
	AUTOTYPE = AUTOTYPE,
	BIN = BIN,
	COMPLEXKW = COMPLEXKW,
	CPLXHALF = CPLXHALF,
	DECLKW = DECLKW,
	FLOATN = FLOATN,
	FUNCNAME = FUNCNAME,
	IGNORE = IGNORE,
	INLINEKW = INLINEKW,
	INT128 = INT128,
	OPASSIGN = OPASSIGN,
	PARENED = PARENED,
	QUAL = QUAL,
	SPECIAL = SPECIAL,
	STATICASSERT = STATICASSERT,
	STMTKW = STMTKW,
	STORAGE = STORAGE,
	STRPREFIX = STRPREFIX,
	TLSKW = TLSKW,
	TYPEOF = TYPEOF,
	VALIST = VALIST,
}
