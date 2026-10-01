#!/bin/sh
# SPDX-License-Identifier: ISC
# Run abi.lua over a range of seeds, then shrink each failure.  A failed
# seed is kept in $WORK/TARGET/fail/SEED and its reduced form in
# .../reduced there; exit 3 when there is something to fix.
#   tools/fuzz/abi.sh [-t TARGET] [-n SEEDS] [-s FIRST] [-j JOBS]

set -u
here=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/.cache/mcc-abifuzz}
TARGET=amd64 SEEDS=100 FIRST=1 JOBS=4
export WORK

while getopts t:n:s:j: o; do
	case $o in
	t) TARGET=$OPTARG;;
	n) SEEDS=$OPTARG;;
	s) FIRST=$OPTARG;;
	j) JOBS=$OPTARG;;
	*) echo "usage: $0 [-t TARGET] [-n SEEDS] [-s FIRST] [-j JOBS]" >&2
	   exit 2;;
	esac
done

mkdir -p "$WORK/$TARGET/fail" || exit 2
last=$((FIRST + SEEDS - 1))
log=$WORK/$TARGET/log.$FIRST-$last
seq "$FIRST" "$last" |
    xargs -P"$JOBS" -I{} lua5.4 "$here/abi.lua" one "$TARGET" {} |
    sort -n > "$log"
echo "$TARGET seeds $FIRST-$last:" \
    $(awk '{ $1 = ""; print }' "$log" | sort | uniq -c | sort -rn)

failed=$(awk '$2 != "ok" && $2 != "skip" { print $1 }' "$log")
for s in $failed; do
	echo "$s"
done | xargs -r -P"$JOBS" -I{} sh -c \
    'lua5.4 "$0/abi.lua" reduce "$1" "$2/{}" > "$2/{}/reduce.log" 2>&1' \
    "$here" "$TARGET" "$WORK/$TARGET/fail"
for s in $failed; do
	echo "== $s"
	cat "$WORK/$TARGET/fail/$s/reduced/verdict" 2>/dev/null ||
	    tail -3 "$WORK/$TARGET/fail/$s/reduce.log"
done
[ -z "$failed" ] || exit 3
