-- SPDX-License-Identifier: ISC
-- rv64gc with the lp64d ABI: a double is passed and returned in fa0-fa7.
return require("target.riscv").new{xlen = 64, fltreg = 8}
