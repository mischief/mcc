-- SPDX-License-Identifier: ISC
-- rv32 with the ilp32 ABI, which an ESP32-C series part uses: no float
-- registers, so a double travels as its bit pattern in an ordinary one.
return require("target.riscv").new{xlen = 32}
