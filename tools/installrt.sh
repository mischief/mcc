#!/bin/sh
# SPDX-License-Identifier: ISC
# Build mcc's runtime once, at install, for every target.  A link uses
# these rather than compiling the runtime again.
#
#   installrt.sh COMPDIR LUA
dir="${MESON_INSTALL_DESTDIR_PREFIX}/$1"
lua=$2
MCC_PROG=mcc
export MCC_PROG
for t in amd64 arm64 riscv64 riscv32 xtensa i386; do
	"$lua" "$dir/drive.lua" --target=$t --mcc-runtime-to="$dir/rtobj" \
	    2>/dev/null
done
exit 0
