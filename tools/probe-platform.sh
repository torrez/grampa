#!/bin/sh
#
# grampa platform probe.
#
# Reports what the local toolchain does with the date shapes,
# commands, and awk features grampa depends on. Read-only: it
# writes nothing outside a temp directory it removes, and it
# never touches posts/ or build/.
#
# Run it on a machine you want to build grampa on, and send
# the output back:
#
#     sh tools/probe-platform.sh
#
# It exists because grampa is BSD/macOS-only today -- see the
# BSD-only gotcha in CLAUDE.md -- and porting it needs facts
# about the target platform rather than recollections about it.
#
set -u

echo "=== platform"
uname -srm
(. /etc/os-release 2>/dev/null && echo "distro: ${PRETTY_NAME:-unknown}") || echo "distro: n/a"

echo
echo "=== toolchain versions"
#
# Piping through head makes the pipeline's status head's, so
# `cmd --version | head -1 || echo fallback` never reaches the
# fallback -- head exits 0 on empty input. Capture first, then
# test the string.
#
ver() {
	# $1 = label, rest = command
	label=$1; shift
	out=$("$@" 2>/dev/null | head -1)
	if [ -n "$out" ]; then printf '%-6s %s\n' "$label:" "$out"
	else printf '%-6s no --version output (BSD, or absent)\n' "$label:"; fi
}
ver make make -v
ver date date --version
ver sed  sed --version
ver grep grep --version
out=$(awk --version 2>/dev/null | head -1)
[ -n "$out" ] || out=$(awk -W version 2>&1 | head -1)
printf '%-6s %s\n' "awk:" "${out:-unknown variant}"

echo
echo "=== which date dialect"
if date -v1d >/dev/null 2>&1; then echo "BSD: 'date -v' works"; else echo "not BSD: 'date -v' rejected"; fi
if date -d 2026-01-15 >/dev/null 2>&1; then echo "GNU: 'date -d' works"; else echo "not GNU: 'date -d' rejected"; fi

echo
echo "=== date shapes grampa must handle"
echo "    (CLAUDE.md documents every ACCEPT row below as building today,"
echo "     and every REJECT row as correctly refused)"
probe_gnu() {
	# $1 = y-m-d, $2 = expected verdict
	out=$(date -d "$1 00:00:00" "+%a, %d %b %Y %H:%M:%S %z" 2>&1)
	st=$?
	printf '  %-16s want=%-7s exit=%s  %s\n' "$1" "$2" "$st" "$out"
}
if date -d 2026-01-15 >/dev/null 2>&1; then
	echo "  -- via GNU 'date -d \"<y-m-d> 00:00:00\"' --"
	probe_gnu 2026-01-15 ACCEPT
	probe_gnu 2026-7-4    ACCEPT   # unpadded, documented as supported
	probe_gnu 26-7-4      ACCEPT   # two-digit year, documented as supported
	probe_gnu 99999-1-1   ACCEPT   # 5-digit year: make's prefilter CLEARS this
	probe_gnu 2026-01-31  ACCEPT   # month end
	probe_gnu 2028-02-29  ACCEPT   # leap year
	probe_gnu 2026-02-29  REJECT   # non-leap
	probe_gnu 2026-02-30  REJECT
	probe_gnu 2026-13-40  REJECT
	probe_gnu 20xx-ab-cd  REJECT
	echo
	echo "  the two that decide the design:"
	echo "    26-7-4     -> which year does GNU pick? (BSD -v26y gives year 26)"
	date -d "26-7-4 00:00:00" "+%Y" 2>&1 | sed 's/^/      year=/'
	echo "    99999-1-1  -> make's prefilter never asks date about this,"
	echo "                  so if GNU rejects it the RENDER fails while the CHECK passes"
	date -d "99999-1-1 00:00:00" "+%Y" 2>&1 | sed 's/^/      year=/'
else
	echo "  (not GNU; skipping the -d probes)"
fi

echo
echo "=== the long-form date grampa prints on each page"
if date -d 2026-01-15 >/dev/null 2>&1; then
	echo "  GNU: $(date -d '2026-01-15' '+%B %d, %Y' 2>&1)"
fi
if date -v1d >/dev/null 2>&1; then
	echo "  BSD: $(date -v2026y -v01m -v15d '+%B %d, %Y' 2>&1)"
fi

echo
echo "=== other commands grampa shells out to"
tmp=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/posts"
: > "$tmp/posts/2026-01-02-home_ok.txt"
printf 'x' > "$tmp/posts/$(printf '2026-01-02-home_a\001c.txt')"

printf 'cat -vt renders a control byte + tab: '
printf 'a\001b\tc\n' | cat -vt 2>&1 || echo "  cat -vt FAILED"

printf 'ls pipes raw bytes (want a^Ac):       '
(cd "$tmp" && ls posts | grep '\.txt$' | LC_ALL=C grep '[[:cntrl:]]' | cat -vt) 2>&1 || echo "  none matched"

printf 'sort -t- -k1,1n orders unpadded:      '
printf '2026-10-1\n2026-7-4\n' | sort -t- -k1,1n -k2,2n -k3,3n | tr '\n' ' '; echo "(want 2026-7-4 first)"

printf 'sed address-and-quit:                 '
printf 'title: A\n-----------------------------------\ntitle: B\n' | \
	sed -n '/^-----------------------------------/q; s/^title:[[:space:]]*//p' | head -1
echo "                                      (want A, not B)"

printf 'awk ENVIRON + getline from a file:    '
printf 'TPL\n' > "$tmp/tpl"
FOO=bar awk 'BEGIN{ if ((getline l < "'"$tmp"'/tpl") > 0) printf "%s/%s\n", ENVIRON["FOO"], l; else print "getline FAILED" }' 2>&1

echo
echo "=== make behaviour this repo depends on"
cat > "$tmp/Makefile" <<'MK'
all: sub/x.html
sub/%.html: ; @echo "  specific rule won (correct on make 3.81)"
%.html: ; @echo "  generic rule won (DIFFERENT from make 3.81)"
MK
(cd "$tmp" && make -s all 2>&1 | head -2)
echo "  (grampa requires the specific rule to win -- see the"
echo "   build/category/%.html ordering note in CLAUDE.md)"

echo
echo "=== done. send this whole output back."
