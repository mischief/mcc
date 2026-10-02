#!/bin/sh
# SPDX-License-Identifier: ISC
# Build csmith programs with gcc and mcc, shrink each disagreement with
# cvise into $WORK/found, and exit 3 when there is something to fix.
# Findings the installed mcc now passes are dropped first.  Give each
# target (-t) and csmith flag set (-f) its own WORK.
#   tools/fuzz/csmith.sh [-n SEEDS] [-j JOBS] [-t TARGET] [-f 'FLAGS']

set -u
CSMITH=${CSMITH:-$HOME/src/csmith/install}
WORK=${WORK:-$HOME/.cache/mcc-fuzz}
MCC=${MCC:-mcc}
FLAGS=${FLAGS:-}
TARGET=${TARGET:-amd64}
RTSRC=${RTSRC:-$HOME/.local/share/mcc/rt}
MCCSRC=${MCCSRC:-$HOME/code/lua/mcc}
SEEDS=200
JOBS=${JOBS:-8}

# A run reads its own copy, so the script can change under it.
if [ -z "${FUZZCOPY:-}" ]; then
	mkdir -p "$WORK" && cp "$0" "$WORK/csmith.sh" || exit 1
	FUZZCOPY=1 exec sh "$WORK/csmith.sh" "$@"
fi
export FUZZCOPY
I=$CSMITH/include
# Flags that turn undefined behavior gcc can see into an error.
W="-Wall -Werror=uninitialized -Werror=return-type -Werror=implicit-int"
W="$W -Werror=implicit-function-declaration -Werror=int-conversion"
W="$W -Werror=return-mismatch -Werror=incompatible-pointer-types -Wno-unused"
export CSMITH WORK MCC FLAGS TARGET RTSRC MCCSRC I W

# The window manager's preload breaks AddressSanitizer.
unset LD_PRELOAD

# The reference compiler and how a program for the target runs.  Off
# the host, mcc writes assembly and the target's gcc links it with
# mcc's runtime, as the test suite does.  SAN looks for undefined
# behavior on the host with the target's type sizes.
settarget()
{
	RTCC= GREF= GRUN=unset
	case $TARGET in
	amd64)	CC=gcc RUN= SAN=gcc;;
	i386)	CC="gcc -m32 -msse2 -mfpmath=sse" RUN= SAN="gcc -m32";;
	arm64)	CC="aarch64-linux-gnu-gcc -static" RUN=qemu-aarch64 SAN=gcc;;
	riscv64) CC="riscv64-linux-gnu-gcc -static" RUN=qemu-riscv64 SAN=gcc;;
	# A bare machine under qemu, with the test suite's start-up code.
	xtensa)	X=$(ls "$HOME"/.espressif/tools/xtensa-esp*-elf/*/xtensa-esp*-elf/bin/xtensa-esp32-elf-gcc |
		    tail -1)
		RTCC="$X -mlongcalls -mtext-section-literals"
		CC="$RTCC -nostartfiles -T $MCCSRC/test/xtensa/ld.script"
		CC="$CC $MCCSRC/test/xtensa/crt.S $MCCSRC/test/xtensa/sys.c"
		RUN="qemu-system-xtensa -M sim -cpu dc233c -nographic"
		RUN="$RUN -monitor none -semihosting -kernel"
		SAN="gcc -m32 -funsigned-char"
		# The simulated core has no high multiply, which libgcc's
		# 64-bit and float routines use, so a gcc build for it
		# traps.  The reference runs here instead: the same sizes,
		# alignments and char signedness.
		GREF="gcc -m32 -funsigned-char -malign-double" GRUN=;;
	*)	echo "no target $TARGET" >&2; exit 2;;
	esac
	RTCC=${RTCC:-$CC} GREF=${GREF:-$CC}
	[ "$GRUN" = unset ] && GRUN=$RUN
	RTLIB=$WORK/rt.a
	# csmith's --float programs mix pointer types, which gcc refuses
	# unless told otherwise.
	REFBUILD='$GREF -w -fpermissive -O0 -I$I t.c -o g'
	# MCCS is mcc's part; MCCL assembles and links what it wrote.
	if [ "$TARGET" = amd64 ]; then
		MCCS='$MCC -w -I$I -c t.c -o m.o'
		MCCL='$MCC m.o -lm -o m'
	else
		MCCS='$MCC --target=$TARGET -w -I$I -S t.c -o m.s'
		MCCL='$CC -w m.s $RTLIB -lm -o m'
	fi
	export CC RTCC RUN SAN RTLIB REFBUILD MCCS MCCL GREF GRUN
}

# The runtime, built once by the target's gcc.
buildrt()
{
	[ "$TARGET" = amd64 ] && return
	[ -s "$RTLIB" ] && return
	d=$(mktemp -d)
	for f in softfp varargs bits atomic half wide widefp; do
		$RTCC -w -O2 -c "$RTSRC/$f.c" -o "$d/$f.o" || exit 2
	done
	ar rcs "$RTLIB" "$d"/*.o && rm -rf "$d"
}

# What the checksum of t.c is, built by gcc; empty when it does not run.
gccsum()
{
	eval "$REFBUILD" 2>/dev/null || return
	timeout 30 $GRUN ./g 2>/dev/null | tail -1
}

# How mcc does on t.c in this directory: "ok", "mismatch", "crash SIG"
# where SIG is the first mcc source line in the error, or "asm SIG"
# when the assembler or linker refuses what mcc wrote.
verdict()
{
	want=$1
	if ! eval "timeout 300 $MCCS" 2>err; then
		# The mcc source line, or the message without its numbers.
		sig=$(grep -o 'mcc/[a-z/]*\.lua:[0-9]*' err | head -1)
		[ -n "$sig" ] || sig=$(sed -n 's/^.*error: //p' err | head -1 |
		    cut -d'(' -f1 | sed 's/ *$//')
		echo "crash ${sig:-unknown}"
		return
	fi
	if ! eval "$MCCL" 2>err; then
		sig=$(grep -o 'Error: [^`(]*' err | head -1 | sed 's/ *$//')
		[ -n "$sig" ] || sig=$(grep -m1 -o 'error: [^`(]*' err)
		[ -n "$sig" ] || sig=$(head -1 err | sed 's/^[^:]*: //')
		echo "asm $sig"
		return
	fi
	got=$(timeout 60 $RUN ./m 2>/dev/null | tail -1)
	if [ "$got" = "$want" ]; then echo ok; else echo mismatch; fi
}

# The interestingness test cvise runs in a case's directory.  It sets
# the same variables, then runs the same build commands.
writetest()
{
	kind=$1 sig=$2
	{
		echo '#!/bin/sh'
		echo 'unset LD_PRELOAD'
		echo "I='$I' MCC='$MCC' TARGET='$TARGET' RTLIB='$RTLIB'"
		echo "CC='$CC' RUN='$RUN' SAN='$SAN' W='$W'"
		echo "GREF='$GREF' GRUN='$GRUN'"
		# The message is in a file: it may hold any quote.
		printf '%s\n' "$sig" > sig
		if [ "$kind" = crash ]; then
			echo 'gcc -O0 -w -I$I -c t.c -o /dev/null >/dev/null 2>&1 || exit 1'
			echo 'timeout 60 $MCC --target=$TARGET -w -I$I -S t.c \'
			echo "    -o /dev/null 2>&1 | grep -qF -f '$PWD/sig'"
		elif [ "$kind" = asm ]; then
			echo 'gcc -O0 -w -I$I -c t.c -o /dev/null >/dev/null 2>&1 || exit 1'
			echo "timeout 60 $MCCS >/dev/null 2>&1 || exit 1"
			echo "$MCCL 2>&1 | grep -qF -f '$PWD/sig'"
		else
			echo '$SAN -O0 $W -fpermissive -I$I t.c -o s -fsanitize=undefined \'
			echo '    -fno-sanitize-recover=all >/dev/null 2>&1 || exit 1'
			echo 'timeout 10 ./s >/dev/null 2>&1 || exit 1'
			echo "$REFBUILD >/dev/null 2>&1 || exit 1"
			echo 'g=$(timeout 10 $GRUN ./g 2>&1) || exit 1'
			echo "( $MCCS && $MCCL ) >/dev/null 2>&1 || exit 1"
			echo 'm=$(timeout 10 $RUN ./m 2>&1)'
			echo '[ "$m" != "$g" ]'
		fi
	} > test.sh
	chmod +x test.sh
}

# One seed: keep it in queue/ when mcc fails it.
one()
{
	s=$1 d=$(mktemp -d)
	cd "$d" || return
	"$CSMITH/bin/csmith" $FLAGS --seed "$s" > t.c 2>/dev/null
	want=$(gccsum)
	case $want in
	"checksum = "*) ;;
	*)	echo "$s skip"; rm -rf "$d"; return;;
	esac
	v=$(verdict "$want")
	echo "$s $v"
	if [ "$v" != ok ]; then
		mkdir -p "$WORK/queue/$s"
		cp t.c "$WORK/queue/$s/orig.c"
		echo "$v" > "$WORK/queue/$s/kind"
	fi
	rm -rf "$d"
}

# Shrink one queued case to about 1200 bytes and move it to found/.
reduce()
{
	s=$1 q=$WORK/queue/$1
	cd "$q" || return
	cp orig.c t.c
	kind=$(cut -d' ' -f1 kind)
	writetest "$kind" "$(cut -d' ' -f2- kind)"
	if ! ./test.sh; then
		echo "$s not reproducible"; mv "$q" "$WORK/flaky/$s"; return
	fi
	size=$(wc -c < t.c)
	th=$(awk -v s="$size" 'BEGIN { t = 1 - 1200 / s;
	    if (t < 0.5) t = 0.5; printf "%.3f", t }')
	cvise -n 2 --tidy --timeout 120 --stopping-threshold "$th" \
	    test.sh t.c > cvise.log 2>&1
	echo "$s $(cat kind): $(wc -l < t.c) lines"
	mv "$q" "$WORK/found/$s"
}

# A finding the installed mcc now gets right goes to fixed/.
recheck()
{
	f=$WORK/found/$1 d=$(mktemp -d)
	cp "$f/orig.c" "$d/t.c"
	cd "$d" || return
	want=$(gccsum)
	if [ "$(verdict "$want")" = ok ]; then
		mv "$f" "$WORK/fixed/$1"; echo "$1 fixed"
	fi
	rm -rf "$d"
}

settarget
case ${1:-} in
one|reduce|recheck) "$@"; exit;;
esac

while getopts n:j:f:t: o; do
	case $o in
	n) SEEDS=$OPTARG;;
	j) JOBS=$OPTARG;;
	f) FLAGS=$OPTARG; export FLAGS;;
	t) TARGET=$OPTARG; export TARGET; settarget;;
	*) echo "usage: $0 [-n SEEDS] [-j JOBS] [-t TARGET] [-f FLAGS]" >&2
	   exit 2;;
	esac
done

mkdir -p "$WORK/queue" "$WORK/found" "$WORK/fixed" "$WORK/flaky" \
    "$WORK/log" || exit 1
command -v cvise >/dev/null || { echo "cvise is not installed" >&2; exit 2; }
# A work directory belongs to one target and one set of flags.
if [ -s "$WORK/flags" ] &&
   [ "$(cat "$WORK/flags")" != "$TARGET $FLAGS" ]; then
	echo "$WORK was made for '$(cat "$WORK/flags")'" >&2; exit 2
fi
echo "$TARGET $FLAGS" > "$WORK/flags"
buildrt
"$MCC" --version | head -1

ls "$WORK/found" | xargs -r -P"$JOBS" -n1 "$0" recheck

first=$(cat "$WORK/next" 2>/dev/null || echo 1)
last=$((first + SEEDS - 1))
log=$WORK/log/$first-$last
seq "$first" "$last" | xargs -P"$JOBS" -n1 "$0" one | sort -n > "$log"
echo $((last + 1)) > "$WORK/next"
echo "seeds $first-$last:" $(awk '{print $2}' "$log" | sort | uniq -c)

# Reductions get two jobs each from cvise.
ls "$WORK/queue" | xargs -r -P$(((JOBS + 1) / 2)) -n1 "$0" reduce

n=$(ls "$WORK/found" | wc -l)
for f in $(ls "$WORK/found" | sort -n); do
	echo "found/$f: $(cat "$WORK/found/$f/kind"), $(wc -l < \
	    "$WORK/found/$f/t.c") lines"
done
[ "$n" -eq 0 ] || exit 3
