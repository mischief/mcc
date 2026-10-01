#!/bin/sh
# SPDX-License-Identifier: ISC
# Floating point differential fuzzer: tools/fuzz/fp.lua writes tests, mcc
# and gcc each build them, and every answer that differs is kept in
# $WORK/found as a one-test case.  Exit 3 when there is one.
#   [MCCFLAGS=-O1] tools/fuzz/fp.sh [-t T] [-n SEEDS] [-s FIRST] [-e EXPRS]

set -u
SRC=$(cd "$(dirname "$0")/../.." && pwd)
TARGET=${TARGET:-amd64}
SEEDS=100 FIRST=1 EXPRS=${EXPRS:-40} JOBS=${JOBS:-4}
MCCFLAGS=${MCCFLAGS:-}

while getopts t:n:s:e:j: o; do
	case $o in
	t) TARGET=$OPTARG;;
	n) SEEDS=$OPTARG;;
	s) FIRST=$OPTARG;;
	e) EXPRS=$OPTARG;;
	j) JOBS=$OPTARG;;
	*) echo "usage: $0 [-t TARGET] [-n SEEDS] [-s FIRST] [-e EXPRS]" \
	       "[-j JOBS]" >&2; exit 2;;
	esac
done
WORK=${WORK:-$HOME/.cache/mcc-fpfuzz/$TARGET$(echo "$MCCFLAGS" | tr -d ' ')}

case $TARGET in
amd64)	CC=gcc RUN=;;
i386)	CC="gcc -m32 -msse2 -mfpmath=sse" RUN=;;
arm64)	CC="aarch64-linux-gnu-gcc -static" RUN=qemu-aarch64;;
riscv64) CC="riscv64-linux-gnu-gcc -static" RUN=qemu-riscv64;;
*)	echo "no target $TARGET" >&2; exit 2;;
esac
# gcc must not fuse a multiply and an add, which mcc never does.
REF="-O0 -ffp-contract=off"
RTLIB=$WORK/rt.a
export SRC TARGET EXPRS CC RUN REF RTLIB WORK MCCFLAGS

# The runtime, built once by the target's gcc.
buildrt()
{
	[ -s "$RTLIB" ] && return
	d=$(mktemp -d)
	for f in softfp varargs bits atomic half wide widefp; do
		$CC -w -O2 -c "$SRC/rt/$f.c" -o "$d/$f.o" || exit 2
	done
	ar rcs "$RTLIB" "$d"/*.o && rm -rf "$d"
}

# Build and run one generated pair in the current directory.  Prints
# "ok", "mismatch NAMES", or what failed.
check()
{
	$CC $REF -w t.c m.c -lm -o g 2>err || { echo "refbuild"; return; }
	timeout 30 $RUN ./g > g.out 2>&1 || { echo "refrun"; return; }
	if ! timeout 300 lua5.4 "$SRC/cc.lua" -t "$TARGET" $MCCFLAGS \
	    -I"$SRC/include" t.c -o t.s 2>err; then
		echo "crash $(grep -o 'mcc/[a-z/]*\.lua:[0-9]*' err | head -1)"
		return
	fi
	$CC -w t.s m.c "$RTLIB" -lm -o m 2>err || { echo "asm"; return; }
	timeout 30 $RUN ./m > m.out 2>&1 || { echo "run"; return; }
	if cmp -s g.out m.out; then echo ok; return; fi
	echo "mismatch" $(diff g.out m.out | sed -n 's/^> \([^ ]*\) .*/\1/p')
}

# One seed: each failing test is written again on its own into found/.
one()
{
	s=$1 d=$(mktemp -d)
	cd "$d" || return
	lua5.4 "$SRC/tools/fuzz/fp.lua" -t "$TARGET" -s "$s" -n "$EXPRS" -o .
	v=$(check)
	echo "$s $v"
	case $v in
	ok)	;;
	mismatch*)
		for n in ${v#mismatch }; do
			f=$WORK/found/$s-$n
			mkdir -p "$f" && cd "$f" || continue
			lua5.4 "$SRC/tools/fuzz/fp.lua" -t "$TARGET" -s "$s" \
			    -n "$EXPRS" -k "$n" -o .
			check > verdict
			diff g.out m.out > diff
			cd "$d"
		done;;
	*)	mkdir -p "$WORK/found/$s" && cp t.c m.c err "$WORK/found/$s"
		echo "$v" > "$WORK/found/$s/verdict";;
	esac
	rm -rf "$d"
}

case ${1:-} in
one) shift; one "$@"; exit;;
esac

mkdir -p "$WORK/found" || exit 1
buildrt
log=$WORK/log.$FIRST
seq "$FIRST" $((FIRST + SEEDS - 1)) | xargs -P"$JOBS" -n1 "$0" one |
    sort -n > "$log"
echo "$TARGET seeds $FIRST-$((FIRST + SEEDS - 1)):" \
    $(awk '{print $2}' "$log" | sort | uniq -c)
grep -v ' ok$' "$log"
grep -q -v ' ok$' "$log" && exit 3
exit 0
