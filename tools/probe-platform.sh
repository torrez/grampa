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
# It exists to gather facts about a host before building
# grampa on it -- see the portable-date gotcha in CLAUDE.md --
# rather than debugging from recollections about it.
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
printf 'make version:                         '
make --version 2>/dev/null | head -1

# The floor. This filter must stay identical to the guard at
# the top of the Makefile; the .0.%/.1.% patterns are what
# catch prereleases like 4.0.90.
printf 'meets the GNU make 4.2 floor:         '
cat > "$tmp/Makefile.floor" <<'MK'
ifeq ($(filter 3.% 4.0 4.0.% 4.1 4.1.%,$(MAKE_VERSION)),$(MAKE_VERSION))
$(error NO -- grampa needs GNU make 4.2 or newer, this is $(MAKE_VERSION))
endif
all: ; @echo "yes"
MK
(cd "$tmp" && make -s -f Makefile.floor all 2>&1 | head -1)
if ! (cd "$tmp" && make -s -f Makefile.floor all >/dev/null 2>&1); then
	echo "  (this probes whichever make is first on PATH. On a Mac that is"
	echo "   Apple's 3.81 -- brew install make, then re-run as: gmake test,"
	echo "   and probe gmake with  PATH=\"\$(brew --prefix make)/libexec/gnubin:\$PATH\")"
fi

# .DELETE_ON_ERROR on a .SECONDARY target: the 3.81 defect
# that set the floor. A "NO" here means a failed build can
# leave a half-written fragment that the next build ships.
printf 'DELETE_ON_ERROR vs .SECONDARY:        '
cat > "$tmp/Makefile.doe" <<'MK'
.DELETE_ON_ERROR:
.SECONDARY: c.tmp
all: c.out
%.tmp: %.src
	@printf 'half' > $@; exit 1
%.out: %.tmp
	@cp $< $@
MK
(cd "$tmp" && rm -f c.tmp c.out && : > c.src && \
	make -s -f Makefile.doe all >/dev/null 2>&1; \
	if [ -e "$tmp/c.tmp" ]; then \
		echo "NO -- half-written file survived the failed recipe"; \
	else echo "yes -- half-written file removed"; fi)

# Shortest-stem pattern selection, arrived in 3.82. The
# generic rule is deliberately first: with the specific one
# first every version picks it and the probe proves nothing.
printf 'shortest-stem pattern selection:      '
cat > "$tmp/Makefile.stem" <<'MK'
all: sub/x.html
%.html: ; @echo "NO -- generic rule won (pre-3.82 order-wins behaviour)"
sub/%.html: ; @echo "yes -- specific rule won on the shorter stem"
MK
(cd "$tmp" && make -s -f Makefile.stem all 2>&1 | head -1)
echo "  (see the build/category/%.html note in CLAUDE.md --"
echo "   grampa no longer depends on this, but it is what"
echo "   the rule order in the Makefile used to be for)"

echo
echo "=== done. send this whole output back."
