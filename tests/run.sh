#!/bin/bash
#
# grampa's test suite. Plain bash, no framework, no
# dependencies -- same spirit as the tool itself.
#
# Each test gets a throwaway sandbox containing the
# Makefile and .source/ from this checkout, so tests
# never touch your real posts/ or build/.
#
# Run with ./tests/run.sh or make test.
#
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$REPO/tests/tmp"
ORIGINAL_PATH="$PATH"
PASSED=0
FAILED=0
CURRENT=""

#
# make test runs this file as a recipe, and make exports
# MAKELEVEL, MAKEFLAGS and MFLAGS into that recipe's environment.
# Left alone, every sandbox `make` this suite shells out to
# inherits them, sees MAKELEVEL=1, concludes it is a sub-make, and
# auto-enables --print-directory -- so "make[1]: Entering
# directory ..." becomes the first line of a captured build,
# breaking test_build_announces_the_processor's assertion that the
# markdown notice is the first line. That assertion is
# load-bearing, not incidental: the notice's position is the whole
# reason it is a parse-time $(info) and not a line in build's
# recipe (see CLAUDE.md).
#
# The fix is not --no-print-directory on the test recipe or on the
# suite's own `make` calls -- that would silence the symptom while
# leaving MAKEFLAGS inherited, so `make -j4 test` or `make -s test`
# would still hand sandboxes flags nobody chose, and -s would
# silence the very output the assertions read. Unsetting all three
# up front makes every sandbox `make` a top-level make no matter
# how this file itself was invoked -- the same principle
# hide_markdown_tools serves below: the suite's result must not
# depend on the environment it inherits.
#
unset MAKELEVEL MAKEFLAGS MFLAGS
#
# An exported host TITLE or CATEGORY would otherwise satisfy
# make new's required-variable check on its own, making
# test_new_requires_a_title/_category fail depending on what
# the caller's shell happened to have set. DATE joins them for
# the same reason: every test that calls `new` today passes
# DATE= explicitly and so is unaffected, but new also reads a
# bare $$DATE straight from the environment, and an inherited
# host value would otherwise silently win for any future test
# that omits it.
#
unset TITLE CATEGORY DATE

#
# Which make the suite drives. Every call below goes through
# $MAKE rather than a bare `make`, and the Makefile's test recipe
# passes its own $(MAKE) in, so `gmake test` on a Mac exercises
# gmake. A bare `make` there would find Apple's /usr/bin/make
# 3.81, and since the floor became 4.2 that does not mean "the
# suite runs on 3.81" -- it means every single test dies at the
# version guard. Running ./tests/run.sh directly with nothing set
# still means plain `make`, which is the Linux case and unchanged.
#
MAKE="${MAKE:-make}"

#
# Fail once and clearly rather than several hundred times. If
# $MAKE is below the floor the guard fires inside every sandbox,
# and the real reason ends up buried in the first of a wall of
# identical failures. The probe runs the real Makefile so there is
# no second copy of the version test to drift: a good make fails
# this goal with "No rule to make target", which is not a match.
#
floor_out=$("$MAKE" -f "$REPO/Makefile" -n grampa-floor-probe 2>&1 || true)
if printf '%s\n' "$floor_out" | grep -q "GNU make 4.2 or newer required"; then
	printf '%s\n' "$floor_out" | grep "GNU make 4.2 or newer required" >&2
	echo "tests/run.sh: set MAKE to a GNU make 4.2+ (on macOS: brew install make, then gmake test)" >&2
	exit 1
fi

#
# Executable stubs that exit 1 for every PATH candidate in
# the Makefile's table, so `make setup` finds nothing and
# staging stays verbatim -- today's behaviour, and the same
# on every machine. An `exit 1` stub is what it takes: a
# non-executable placeholder does not shadow /usr/bin/x,
# because PATH lookup skips files it cannot execute, and a
# plain `exit` would be ACCEPTED by the probe.
#
# A test wanting a real processor overwrites one stub and
# re-runs `make setup`.
#
hide_markdown_tools() {
	mkdir -p "$SBOX/bin"
	for t in lowdown cmark cmark-gfm md2html comrak multimarkdown \
		markdown smu markdown_py markdown-it pandoc; do
		printf '#!/bin/sh\nexit 1\n' > "$SBOX/bin/$t"
		chmod +x "$SBOX/bin/$t"
	done
	PATH="$SBOX/bin:$PATH"
	export PATH
}

#
# path_stub <name> <shell-body>
#
# Writes an executable stub onto the sandbox PATH, with $f
# preset to the stub's LAST argument.
#
# $f, not $1: every candidate's argv puts flags before the
# filename -- `cmark --unsafe <file>`, `lowdown --out-no-smarty
# --html-no-skiphtml --html-no-escapehtml <file>` -- so a stub
# reading "$1" reads a flag and silently passes on the wrong
# input. The last argument is the file in every row of the
# table.
#
path_stub() {
	printf '#!/bin/sh\nfor f; do :; done\n%s\n' "$2" > "$SBOX/bin/$1"
	chmod +x "$SBOX/bin/$1"
}

#
# Fresh sandbox for the test named in $1. cds into it.
#
sandbox() {
	CURRENT="$1"
	SBOX="$TMPROOT/$1"
	PATH="$ORIGINAL_PATH"
	rm -rf "$SBOX"
	mkdir -p "$SBOX"
	cp "$REPO/Makefile" "$SBOX/"
	cp -R "$REPO/.source" "$SBOX/"
	cd "$SBOX" || exit 1
	hide_markdown_tools
	"$MAKE" setup >/dev/null 2>&1
}

#
# add_post <filename> <<'EOF' ... EOF
# Body comes from stdin.
#
add_post() {
	cat > "posts/$1"
}

#
# markdown_stub <<'EOF' ... EOF
# Writes an executable Markdown.pl into the sandbox from
# stdin. The real Markdown.pl is optional and gitignored,
# so a sandbox never has one and the Markdown staging branch
# would otherwise never be executed by this suite. The stub
# stands in for it: same calling convention (one filename
# argument, transformed body on stdout).
#
# Re-runs setup after chmod +x: staging is now driven by
# DETECTED_MARKDOWN, recorded in config.mk at setup time, not
# by a hardcoded `[ -x Markdown.pl ]` probe in the recipe.
# sandbox() already ran setup once, before this file existed,
# so without a second run here config.mk would still say
# there is no processor and every markdown_stub caller would
# silently stage verbatim.
#
markdown_stub() {
	cat > Markdown.pl
	chmod +x Markdown.pl
	local setup_out
	setup_out=$("$MAKE" setup 2>&1)
	if [ $? -ne 0 ]; then
		fail "markdown_stub's make setup failed" "$setup_out"
	fi
}

#
# Builds, capturing output. Fails the test if make
# fails. Stdin is closed so a hang shows up as an
# error rather than blocking the suite.
#
build() {
	BUILD_OUT=$("$MAKE" "$@" < /dev/null 2>&1)
	local status=$?
	if [ $status -ne 0 ]; then
		fail "make failed unexpectedly (exit $status)" "$BUILD_OUT"
		return 1
	fi
	return 0
}

#
# Builds expecting failure. Fails the test if make
# succeeds. Output lands in $BUILD_OUT either way.
#
build_expect_fail() {
	BUILD_OUT=$("$MAKE" "$@" < /dev/null 2>&1)
	local status=$?
	if [ $status -eq 0 ]; then
		fail "make succeeded but should have failed" "$BUILD_OUT"
		return 1
	fi
	return 0
}

#
# build_expect_fail_within <seconds> [make args]
#
# Same as build_expect_fail, but bounded by a wall clock.
# An unguarded `while (getline < "tpl")` loop spins forever
# rather than erroring, so a plain build_expect_fail against
# an unreadable template would block the whole suite -- and
# WRAP_IN_BASE's version eats memory while it spins. macOS
# has no timeout(1), so this backgrounds make under job
# control (set -m gives it its own process group) and kills
# the entire group, since it is awk and not make that hangs.
#
build_expect_fail_within() {
	local limit="$1"; shift
	local out="$SBOX/.timed-build.out"
	local pid waited=0 status

	set -m
	"$MAKE" "$@" < /dev/null > "$out" 2>&1 &
	pid=$!
	set +m

	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$limit" ]; then
			kill -9 -"$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			BUILD_OUT=$(cat "$out")
			fail "make did not finish within ${limit}s -- it hung" "$BUILD_OUT"
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done

	wait "$pid"
	status=$?
	BUILD_OUT=$(cat "$out")
	if [ "$status" -eq 0 ]; then
		fail "make succeeded but should have failed" "$BUILD_OUT"
		return 1
	fi
	return 0
}

ok() {
	PASSED=$((PASSED + 1))
}

fail() {
	FAILED=$((FAILED + 1))
	echo "FAIL: $CURRENT: $1"
	if [ -n "${2:-}" ]; then
		echo "$2" | sed 's/^/      /'
	fi
}

assert_file() {
	if [ -f "$1" ]; then ok; else fail "expected file to exist: $1"; fi
}

assert_no_file() {
	if [ -f "$1" ]; then fail "expected file NOT to exist: $1"; else ok; fi
}

#
# The -- in each grep below is load-bearing, not style.
# grampa's front-matter delimiter is 35 hyphens, so a test
# that greps for one hands grep something it reads as an
# unrecognized long option: exit 2, usage on stderr, and
# assert_not_grep's else-branch counts any nonzero exit as
# a pass. An assertion that can only pass is worse than no
# assertion, so do not drop these.
#
assert_grep() {
	if [ ! -f "$1" ]; then
		fail "cannot grep missing file: $1"
		return
	fi
	if grep -qF -- "$2" "$1"; then ok; else fail "expected '$2' in $1" "$(cat "$1")"; fi
}

assert_not_grep() {
	if [ ! -f "$1" ]; then
		fail "cannot grep missing file: $1"
		return
	fi
	if grep -qF -- "$2" "$1"; then fail "did NOT expect '$2' in $1" "$(cat "$1")"; else ok; fi
}

#
# Assertions against the captured make output. These
# exist because process substitution gives a /dev/fd
# path that is not a regular file on macOS, so the
# file-based helpers above cannot be used on it.
#
assert_out_grep() {
	if printf '%s\n' "$BUILD_OUT" | grep -qF -- "$1"; then ok; else fail "expected '$1' in make output" "$BUILD_OUT"; fi
}

assert_out_not_grep() {
	if printf '%s\n' "$BUILD_OUT" | grep -qF -- "$1"; then fail "did NOT expect '$1' in make output" "$BUILD_OUT"; else ok; fi
}

assert_eq() {
	if [ "$2" = "$3" ]; then ok; else fail "$1: expected [$2] got [$3]"; fi
}

pass_fail_summary() {
	echo
	echo "passed: $PASSED  failed: $FAILED"
	[ "$FAILED" -eq 0 ]
}

#
# ---------------------------------------------------
# Baseline: behaviour that must survive every change
# below.
# ---------------------------------------------------
#

test_builds_a_post_and_index() {
	sandbox builds_a_post_and_index
	add_post 2026-08-06-example_hello-world.txt <<'EOF'
title: Hello World
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/2026/08/06/hello-world.html
	assert_file build/index.html
	assert_grep build/2026/08/06/hello-world.html "<h4>Hello World</h4>"
	assert_grep build/2026/08/06/hello-world.html "posted on August 06, 2026"
}

test_index_is_reverse_chronological_and_capped_at_ten() {
	sandbox index_order
	local i
	for i in 1 2 3 4 5 6 7 8 9; do
		add_post "2026-01-0$i-n_post-0$i.txt" <<EOF
title: Post 0$i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	add_post 2026-01-10-n_post-10.txt <<'EOF'
title: Post 10
-----------------------------------
<p>Body 10.</p>
EOF
	add_post 2026-10-1-n_unpadded.txt <<'EOF'
title: Unpadded Oct
-----------------------------------
<p>Oct.</p>
EOF
	build || return
	assert_eq "index entry count" "10" "$(grep -c 'posted on' build/index.html)"
	assert_eq "newest first" "posted on October 01, 2026" "$(grep -o 'posted on [^<]*' build/index.html | head -1)"
	assert_not_grep build/index.html "Post 01"
}

test_build_contains_only_html() {
	sandbox only_html
	add_post 2026-08-06-example_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	# css: setup now seeds static/style.css, published as
	# build/style.css. It's designed output, not a leak -- what
	# this test protects is that no .tmp/.staged intermediate
	# escapes work/ into build/, which "css html" still catches.
	assert_eq "extensions under build/" "css html" "$(find build -type f | sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

test_zero_posts_does_not_hang() {
	sandbox zero_posts
	build || return
	assert_file build/index.html
}

test_blog_name_from_config() {
	sandbox blog_name
	add_post 2026-08-06-example_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=Andre Torrez\n' > config
	build || return
	assert_grep build/index.html "<title>Andre Torrez</title>"
	assert_grep build/2026/08/06/hello.html "<title>Hello - Andre Torrez</title>"
}

test_ampersands_are_not_mangled() {
	sandbox ampersands
	add_post 2026-08-06-cartoons_tom-and-jerry.txt <<'EOF'
title: Tom & Jerry
-----------------------------------
<p>Visit /search?a=1&b=2 for more.</p>
EOF
	build || return
	assert_grep build/2026/08/06/tom-and-jerry.html "<h4>Tom & Jerry</h4>"
	assert_grep build/2026/08/06/tom-and-jerry.html "/search?a=1&b=2"
	assert_not_grep build/2026/08/06/tom-and-jerry.html "{{title}}"
}

test_no_op_rebuild_is_quiet() {
	sandbox no_op
	add_post 2026-08-06-example_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	build || return
	assert_out_not_grep "Building"
}

test_parallel_build_is_clean() {
	sandbox parallel
	local i
	for i in 1 2 3 4 5 6; do
		add_post "2026-0$i-01-n_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	# url= is set so -j8 also exercises the .staged ->
	# .rssitem -> rss.tmp -> rss.xml chain, not just the
	# .staged -> .tmp -> html chain the default config runs.
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build -j8 || return
	# Counts dated post pages only, so category pages do
	# not change the expected number.
	assert_eq "post pages built" "6" "$(find build -type f -name '*.html' -path 'build/2*' | wc -l | tr -d ' ')"
	assert_eq "no stray intermediates" "" "$(ls work/ | grep -vE '\.(tmp|staged|rssitem)$' | tr '\n' ' ' | sed 's/ *$//')"
	assert_file build/rss.xml
	assert_eq "items in feed" "6" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
}

#
# .SECONDARY has to keep .staged files. Without it make
# reaps them as pattern-rule intermediates and Markdown
# re-runs on every build.
#
test_staged_files_persist() {
	sandbox staged_persist
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file work/2026-08-06-home_hello.staged
	assert_grep work/2026-08-06-home_hello.staged "title: Hello"
	assert_grep work/2026-08-06-home_hello.staged "<p>Hi.</p>"
}

#
# A detected processor is what stages the body now, not
# a hardcoded ./Markdown.pl.
#
test_detected_processor_stages_the_body() {
	sandbox detected_stages
	path_stub cmark 'sed "s/HELLO/RENDERED/" "$f"'
	"$MAKE" setup >/dev/null 2>&1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "RENDERED"
}

#
# With nothing detected the body is copied verbatim --
# today's behaviour when Markdown.pl is absent.
#
test_no_processor_stages_verbatim() {
	sandbox none_verbatim
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hello *world*
EOF
	build
	assert_grep build/2026/08/06/hello.html "Hello *world*"
}

#
# markdown= beats detection.
#
test_config_markdown_overrides_detection() {
	sandbox override_wins
	path_stub cmark 'sed "s/HELLO/DETECTED/" "$f"'
	path_stub mytool 'sed "s/HELLO/OVERRIDDEN/" "$f"'
	"$MAKE" setup >/dev/null 2>&1
	# There has to be something to beat: without this the
	# test silently degrades to "override beats nothing"
	# if the setup rerun above ever stops detecting.
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
	printf 'name=T\nmarkdown=mytool\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "OVERRIDDEN"
}

#
# Editing markdown= re-stages, or switching processors
# would appear to do nothing.
#
test_changing_markdown_restages_posts() {
	sandbox override_restage
	path_stub one 'sed "s/HELLO/FIRST/" "$f"'
	path_stub two 'sed "s/HELLO/SECOND/" "$f"'
	printf 'name=T\nmarkdown=one\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "FIRST"
	printf 'name=T\nmarkdown=two\n' > config
	build
	assert_grep build/2026/08/06/hello.html "SECOND"
}

#
# An override naming something absent fails loud rather
# than silently falling back to verbatim.
#
test_missing_override_tool_fails_the_build() {
	sandbox override_missing
	printf 'name=T\nmarkdown=no-such-tool-xyz\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build_expect_fail
	# Pin the reason, not just the exit status: a bare
	# build_expect_fail is satisfied by any failure, so an
	# unrelated future parse-time error would keep it green
	# while the 127 behaviour regressed. Make's own wording
	# is stabler than the shell's "command not found".
	assert_out_grep "Error 127"
}

#
# An override is a command LINE, not a command name. The
# flags have to survive to the tool -- and the commas in
# something like `-f +tables,-smarty` are the interesting
# part, since MARKDOWN_CMD is expanded inside $(or) and
# $(strip). They are safe because make splits a function's
# arguments on the literal commas in its source text,
# before any expansion, so commas arriving from a variable
# never become argument separators. Verified, and pinned
# here so a future re-quoting of the .staged recipe can't
# quietly break it.
#
test_multi_word_override_keeps_its_flags() {
	sandbox override_flags
	path_stub mytool 'case "$*" in *"-f +tables,-smarty"*) sed "s/HELLO/FLAGGED/" "$f";; *) exit 1;; esac'
	printf 'name=T\nmarkdown=mytool -f +tables,-smarty\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "FLAGGED"
}

#
# A # in a markdown= value comments out the rest of the
# staging recipe -- it is all ONE shell line -- taking the
# redirect and the && chain with it. The dangerous case is
# not the first build but the REBUILD: with a processor
# that succeeds given no file (cat, and every markdown CLI
# that reads stdin), the truncated line exits 0 without
# writing .staged, the previous .staged survives with its
# old mtime, and make calls the page up to date. That
# shipped the author's edit into the bin at exit 0 with
# "Build completed." on stdout. The parens around
# $(MARKDOWN_CMD) turn it into a shell syntax error.
#
test_hash_in_markdown_value_fails_the_rebuild() {
	sandbox hash_value_rebuild
	# Exits 0 when handed no file at all, which is what
	# every stdin-reading markdown CLI does and what makes
	# the truncated line silent rather than loud. A stub
	# that errored on no arguments would fail the build for
	# the wrong reason and pass this test even unfixed --
	# checked by mutation.
	path_stub mytool '[ $# -gt 0 ] || exit 0; cat "$f"'
	printf 'name=T\nmarkdown=mytool\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "HELLO"
	printf 'name=T\nmarkdown=mytool #note\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
EDITED
EOF
	build_expect_fail
	assert_not_grep build/2026/08/06/hello.html "EDITED"
}

#
# A processor detected at setup and uninstalled afterwards
# must fail loud, not fall back to verbatim -- otherwise a
# site quietly goes half-rendered. Markdown.pl is the
# candidate to test it with: it is probed by path rather
# than through PATH, so deleting it is host-independent in
# a way that removing a PATH stub is not.
#
test_uninstalled_detected_processor_fails_the_build() {
	sandbox detected_uninstalled
	markdown_stub <<'EOF'
#!/bin/sh
sed 's/HELLO/RENDERED/' "$1"
EOF
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "RENDERED"
	rm -f Markdown.pl
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
EDITED
EOF
	build_expect_fail
	assert_out_grep "Error 127"
}

#
# hide_markdown_tools' list is a hand-copy of the table's
# field 1. A thirteenth candidate added to the Makefile
# without updating it would silently restore the host
# dependence the helper exists to remove -- invisible on
# any machine that does not have the new tool. So derive
# the expected list from the Makefile and compare.
#
test_stub_list_matches_the_candidate_table() {
	sandbox stub_list_sync
	local expected actual
	expected=$(sed -n '/^define MARKDOWN_CANDIDATES/,/^endef/p' Makefile \
		| sed -n 's/|.*//p' | grep -v / | sort | tr '\n' ' ')
	actual=$(ls bin | sort | tr '\n' ' ')
	assert_eq "sandbox stubs cover every PATH candidate in the table" \
		"$expected" "$actual"
}

#
# A candidate whose smartypants flag is wrong renders the
# author's -- as an en dash. The probe used to check only
# exit status, the surviving <i>, and fragment-vs-document,
# so such a tool won detection and quietly rewrote every
# post's punctuation.
#
# The stub fails ONLY the punctuation check -- it exits 0,
# keeps the <i>, and emits no document -- so this test
# cannot pass for an unrelated reason.
#
test_probe_rejects_a_smartening_candidate() {
	sandbox probe_smarty
	path_stub lowdown 'sed "s/--/\&ndash;/g" "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
	assert_grep config.mk "DETECTED_MARKDOWN :="
}

#
# setup used to fall through a rejected candidate in
# silence, so the build notice named a processor the user
# did not expect and gave no hint why. The punctuation check
# makes that more likely, not less.
#
# The prefix is deliberately NOT "grampa: markdown:" --
# test_clean_and_setup_print_no_notice asserts that string
# is absent from setup's output, because it belongs to the
# build notice and setup must stay quiet about it.
#
test_setup_names_a_rejected_candidate() {
	sandbox setup_reject
	path_stub lowdown 'sed "s/--/\&ndash;/g" "$f"'
	BUILD_OUT=$("$MAKE" setup 2>&1)
	assert_out_grep "grampa: setup: lowdown: smartens punctuation"
	# BUILD_OUT merges stdout and stderr, so it cannot tell
	# the diagnostic line above apart from a winner written to
	# config.mk -- both start with "grampa:" and both contain
	# "DETECTED_MARKDOWN :=" as a substring. Pin the actual
	# file to an exactly-empty value so a diagnostic that
	# leaks onto stdout (and so into config.mk) is caught.
	assert_eq "no diagnostic leaked into the winner" "DETECTED_MARKDOWN :=" \
		"$(grep '^DETECTED_MARKDOWN' config.mk | sed 's/[[:space:]]*$//')"
}

#
# A TRIPWIRE, not a live guard, and it cannot fail today.
#
# cmark, cmark-gfm and md2html all HTML-escape a " in text
# content to &quot;. That is escaping, not smartening -- it
# renders identically -- but a literal " assertion cannot
# tell the two apart and would skip all three. The probe
# input therefore carries no quote at all, so this stub's
# escaping never fires and the test passes trivially.
#
# It exists to bite the next person who adds a quote to the
# probe input and a literal-" check alongside it. The stub
# escapes CONDITIONALLY for that reason: one that emitted
# &quot; unconditionally would test nothing in either world.
#
test_probe_accepts_escaped_quotes() {
	sandbox probe_escaped_quotes
	path_stub lowdown 'sed "s/\"/\&quot;/g" "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := lowdown"
}

#
# The notice says which processor a build is using, once,
# before any page is built.
#
test_build_announces_the_processor() {
	sandbox notice_detected
	path_stub cmark 'cat "$f"'
	"$MAKE" setup >/dev/null 2>&1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_out_grep "grampa: markdown: cmark --unsafe"
	# assert_out_grep is a substring match, so the line
	# above is equally happy with "cmark --unsafe (from
	# config)". Without this, dropping the $(if) that makes
	# the suffix conditional passes the whole suite while
	# every build falsely credits config for the choice.
	assert_out_not_grep "(from config)"
	# Nothing re-executes make today, but a rule that
	# remade config.mk or the Makefile would re-run the
	# parse and print the notice twice, silently.
	assert_eq "notice printed exactly once" 1 \
		"$(printf '%s\n' "$BUILD_OUT" | grep -c 'grampa: markdown:')"
	# Position is the whole reason it is a parse-time
	# $(info) and not a line in build's recipe.
	assert_eq "notice is the first line of the build" \
		"grampa: markdown: cmark --unsafe" \
		"$(printf '%s\n' "$BUILD_OUT" | head -1)"
}

test_build_announces_no_processor() {
	sandbox notice_none
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_out_grep "grampa: markdown: none -- post bodies stay HTML"
}

test_notice_marks_a_config_override() {
	sandbox notice_override
	path_stub mytool 'cat "$f"'
	printf 'name=T\nmarkdown=mytool\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_out_grep "grampa: markdown: mytool (from config)"
}

#
# Non-build goals stay quiet.
#
test_clean_and_setup_print_no_notice() {
	sandbox notice_quiet
	build clean
	assert_out_not_grep "grampa: markdown:"
	build setup
	assert_out_not_grep "grampa: markdown:"
}

#
# The staging branch runs Markdown.pl over the body and
# nothing else. A title is front matter, so asterisks in
# it must survive to the page untouched -- if the whole
# post went through the stub, the h4 would come back
# wrapped in <em>.
#
test_markdown_transforms_the_body_not_the_front_matter() {
	sandbox markdown_body_only
	markdown_stub <<'EOF'
#!/bin/sh
sed 's|\*\([^*]*\)\*|<em>\1</em>|g' "$1"
EOF
	add_post 2026-08-06-home_marked-up.txt <<'EOF'
title: A *starred* title
-----------------------------------
<p>Body with *emphasis* in it.</p>
EOF
	build || return
	assert_grep build/2026/08/06/marked-up.html "<em>emphasis</em>"
	assert_grep build/2026/08/06/marked-up.html "<h4>A *starred* title</h4>"
	# The branch's own scratch files are cleaned up after it.
	assert_eq "no stray intermediates" "" \
		"$(ls work/ | grep -vE '\.(tmp|staged|rssitem)$' | tr '\n' ' ' | sed 's/ *$//')"
}

#
# The Markdown branch reassembles head + splitter + body, so
# .source/splitter.txt's trailing blank line put an extra
# empty line at the top of every Markdown-staged body -- a
# one-byte disagreement with the verbatim branch, which cp's
# the post through untouched.
#
# It reached no output, which is why this is about the
# intermediate rather than about a page. PARSE_FRONT_MATTER
# accumulates with body = (body == "" ? $0 : body "\n" $0),
# so a leading empty line leaves body empty and the next
# line swallows it. Verified byte-identical over build/,
# rss.xml included, against a corpus built to break it.
#
# What closing it buys is that the two staging branches
# produce the same intermediate for the same input, so
# .staged files are diffable across branches. This test
# pins that agreement so a future edit to splitter.txt
# cannot quietly restore the blank line.
#
test_markdown_staged_file_has_no_blank_line_after_the_delimiter() {
	sandbox markdown_staged_no_blank_line
	markdown_stub <<'EOF'
#!/bin/sh
sed 's/^/MD:/' "$1"
EOF
	add_post 2026-01-02-home_s.txt <<'EOF'
title: Staged
-----------------------------------
<p>STAGED BODY</p>
EOF
	build || return
	# Delimiter-relative and not `sed -n 3p`, which was the
	# first form and had a silent-pass path: give this fixture
	# no title: line and the delimiter moves to line 1, so
	# line 3 is the body under the OLD splitter too and the
	# assertion passes against the regression it exists to
	# catch. Found by review. The label says "after the
	# delimiter", so the code should look for the delimiter.
	assert_eq "line after the delimiter" \
		'MD:<p>STAGED BODY</p>' \
		"$(awk 'f{print; exit} /^-----------------------------------$/{f=1}' work/2026-01-02-home_s.staged)"
}

#
# The staging branch used to chain its steps with `;`, so
# the recipe's exit status was `rm -f`'s and a failing
# Markdown.pl was invisible: make exited 0, .staged held
# front matter and nothing else, and a fully rendered
# page with an empty body went into build/ ready to
# deploy. This is the only path in the repo from a
# healthy source tree to silently wrong output.
#
test_failing_markdown_fails_the_build() {
	sandbox markdown_failure
	# Unconditional exit 1 would fail setup's own probe --
	# which runs this exact stub against a synthetic
	# "x <i>y</i> -- z" file -- so detection would reject the
	# candidate and DETECTED_MARKDOWN would come back empty,
	# and the build below would then stage verbatim and
	# succeed instead of failing. Passing the probe and only
	# then failing is what exercises a processor that was
	# detected and breaks for real, which is the case this
	# test is about.
	markdown_stub <<'EOF'
#!/bin/sh
case "$(cat "$1")" in
	*'<i>y</i>'*) cat "$1"; exit 0 ;;
esac
echo "Markdown.pl: broken" >&2
exit 1
EOF
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Real body content.</p>
EOF
	build_expect_fail || return
	# Pin the failure to the Markdown step rather than
	# accepting any nonzero make.
	assert_out_grep "Markdown.pl: broken"
	# The chain short-circuits before the cat that writes
	# $@, so the staging file is never created at all --
	# there is not even a half-written one to trust.
	assert_no_file work/2026-08-06-home_hello.staged
	# And nothing bodyless reached build/.
	assert_no_file build/2026/08/06/hello.html
}

#
# Recovering from a Markdown failure must not resurrect
# content: a failed staging run leaves scratch files in
# work/, and the next build must not fold any of them into
# the output.
#
# This test is now weaker than it was, and the honest
# version of its history is worth keeping. It was written
# against `split` and a glob: a failed run left chunks
# behind, the reassembly globbed up whatever it found, and a
# post that later split into fewer chunks than the failed
# run swept the stale ones back in and republished deleted
# text. Exact filenames cannot do that -- every scratch file
# is truncated before it is read -- so this passes even with
# the head rm -f removed, which was checked. What it covers
# now is the end-to-end property rather than the mechanism,
# and that is still worth a test: whatever the staging step
# is made of, deleted text must not come back.
#
test_failed_markdown_leaves_no_stale_chunks() {
	sandbox markdown_stale_chunks
	# Same reasoning as test_failing_markdown_fails_the_build:
	# an unconditional exit 1 fails setup's own probe, so
	# nothing would be detected and this build would succeed
	# verbatim instead of failing. Pass the probe, fail on the
	# real post.
	markdown_stub <<'EOF'
#!/bin/sh
case "$(cat "$1")" in
	*'<i>y</i>'*) cat "$1"; exit 0 ;;
esac
exit 1
EOF
	# The second delimiter gives the post a section the
	# author can then delete, which is what the rebuild
	# below must not bring back.
	add_post 2026-01-01-home_t.txt <<'EOF'
title: T
-----------------------------------
<p>Kept line.</p>
-----------------------------------
<p>Deleted secret.</p>
EOF
	build_expect_fail || return
	# Same whole-second mtime granularity as the other
	# rebuild tests.
	sleep 1
	# The author deletes the second half and fixes Markdown.pl.
	markdown_stub <<'EOF'
#!/bin/sh
cat "$1"
EOF
	add_post 2026-01-01-home_t.txt <<'EOF'
title: T
-----------------------------------
<p>Kept line.</p>
EOF
	build || return
	assert_not_grep work/2026-01-01-home_t.staged "Deleted secret."
	assert_not_grep build/2026/01/01/t.html "Deleted secret."
	assert_grep build/2026/01/01/t.html "<p>Kept line.</p>"
}

#
# test_parallel_build_is_clean runs -j8 but installs no
# stub, so the staging branch -- the fiddliest code in the
# Makefile, and the part that writes scratch files -- has
# never been exercised in parallel by this suite. Every
# intermediate the branch creates is named after the post
# ($(WORK_DIR)$*.head, .body, .mdbody) precisely so two posts
# cannot clobber each other; nothing checked that. Six
# posts is enough for -j8 to overlap them.
#
test_markdown_branch_is_parallel_safe() {
	sandbox markdown_parallel
	markdown_stub <<'EOF'
#!/bin/sh
sed 's|\*\([^*]*\)\*|<em>\1</em>|g' "$1"
EOF
	local i
	for i in 1 2 3 4 5 6; do
		add_post "2026-0$i-01-n_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body *$i* here.</p>
EOF
	done
	build -j8 || return
	# Every post's own body, transformed, in its own page --
	# a shared scratch namespace would cross them over.
	for i in 1 2 3 4 5 6; do
		assert_grep "build/2026/0$i/01/post-$i.html" "<em>$i</em>"
	done
	assert_eq "no stray intermediates" "" \
		"$(ls work/ | grep -vE '\.(tmp|staged|rssitem)$' | tr '\n' ' ' | sed 's/ *$//')"
}

#
# .staged exists so Markdown.pl runs once per post no
# matter how many consumers read the result. The three
# stub sandboxes all leave url= unset, so the second
# consumer -- %.rssitem -> rss.tmp -> rss.xml -- has never
# been shown to get the transformed body at all. Point the
# .rssitem rule at posts/%.txt instead of the .staged file
# and every assertion here still passes except this one.
#
test_markdown_body_reaches_the_feed() {
	sandbox markdown_feed
	markdown_stub <<'EOF'
#!/bin/sh
sed 's|\*\([^*]*\)\*|<em>\1</em>|g' "$1"
EOF
	add_post 2026-08-06-home_marked-up.txt <<'EOF'
title: A *starred* title
-----------------------------------
<p>Body with *emphasis* in it.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_file build/rss.xml
	# The feed escapes bodies, so the transformed markup
	# arrives entity-encoded rather than as raw tags.
	assert_grep build/rss.xml "&lt;em&gt;emphasis&lt;/em&gt;"
	# The title is front matter, so Markdown must not have
	# touched it -- same rule as on the HTML side.
	assert_grep build/rss.xml "<title>A *starred* title</title>"
}

#
# A Markdown.pl that was never chmod +x is invisible to
# setup's detection, so DETECTED_MARKDOWN stays empty and the
# body stays verbatim HTML. That is a silent fallback with no
# warning, which makes it worth pinning: README.md now tells
# people to check the execute bit precisely because nothing
# else will tell them.
#
# Two things independently reject the candidate, so this
# holds even if one of them is weakened: the case guard
# `[ -x "$probe" ] || continue` for a slash-bearing candidate,
# and, redundant with it, the probe's own attempt to run the
# candidate against its scratch file, whose nonzero exit
# (EACCES) is caught by `[ $rc -eq 0 ] || continue` either
# way. Verified directly -- relaxing the case guard alone to
# [ -f ] does not make this test fail, precisely because that
# second check still catches it.
#
# This does not use markdown_stub: that helper chmod +x's
# before re-running setup, so if it ran here setup would
# detect the (then executable) stub and record it in
# config.mk before the chmod 644 below ever ran -- and a
# later build would try to exec a now-unreadable
# ./Markdown.pl and fail loudly instead of falling back,
# which is a different bug from the one this test is
# guarding. Writing the file and chmodding it before setup
# runs is what actually exercises detection rejecting the
# candidate.
#
test_non_executable_markdown_falls_back_to_verbatim() {
	sandbox markdown_not_executable
	cat > Markdown.pl <<'EOF'
#!/bin/sh
sed 's|\*\([^*]*\)\*|<em>\1</em>|g' "$1"
EOF
	chmod 644 Markdown.pl
	"$MAKE" setup >/dev/null 2>&1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Body with *emphasis* in it.</p>
EOF
	build || return
	# Verbatim: the asterisks survive and no <em> appears.
	assert_grep build/2026/08/06/hello.html "<p>Body with *emphasis* in it.</p>"
	assert_not_grep build/2026/08/06/hello.html "<em>"
	# The verbatim branch is a plain cp, so it leaves none
	# of the Markdown branch's scratch files behind.
	assert_eq "no stray intermediates" "" \
		"$(ls work/ | grep -vE '\.(tmp|staged|rssitem)$' | tr '\n' ' ' | sed 's/ *$//')"
}

#
# split names its chunks .aa, .ab ... .az, .ba, and the old
# reassembly glob was $*.a[b-z]* -- so a body with more than
# 25 delimiter lines lost everything from .ba on, silently,
# at exit 0. Thirty delimiters puts five sections past that
# ceiling.
#
test_many_delimiter_lines_stage_completely() {
	sandbox many_delimiters
	markdown_stub <<'EOF'
#!/bin/sh
cat "$1"
EOF
	# printf -- because the format starts with a hyphen.
	# The first delimiter is the front-matter separator;
	# the other 29 are body text and stay put.
	{
		printf 'title: T\n'
		i=1
		while [ "$i" -le 30 ]; do
			printf -- '-----------------------------------\n<p>section %d</p>\n' "$i"
			i=$((i + 1))
		done
	} | add_post 2026-01-01-home_many.txt
	build || return
	assert_grep build/2026/01/01/many.html "<p>section 1</p>"
	assert_grep build/2026/01/01/many.html "<p>section 30</p>"
}

#
# Both rm -f's used $(WORK_DIR)$*.a[a-z]*, which reaches
# past its own post: for stem 2026-01-01-home_x that glob
# matches 2026-01-01-home_x.ab.staged and .tmp -- a same-date
# sibling's real outputs, deleted mid-build. Dotted slugs are
# degenerate, but eating another post's work is not an
# acceptable way to say so.
#
test_same_date_sibling_slug_does_not_collide() {
	sandbox sibling_slug
	markdown_stub <<'EOF'
#!/bin/sh
cat "$1"
EOF
	add_post 2026-01-01-home_x.txt <<'EOF'
title: X
-----------------------------------
<p>plain x</p>
EOF
	add_post 2026-01-01-home_x.ab.txt <<'EOF'
title: X dotted
-----------------------------------
<p>dotted sibling</p>
EOF
	# This has to assert on the FIRST build. A second make
	# exits 0 -- the survivor's files are up to date and its
	# rm never runs again -- so retrying here would make the
	# test incapable of failing.
	build || return
	assert_grep build/2026/01/01/x.html "<p>plain x</p>"
	assert_grep build/2026/01/01/x.ab.html "<p>dotted sibling</p>"
}

#
# A post with no delimiter left the body glob matching
# nothing, so cat failed -- into `cat ... | tail`, whose
# status is tail's. The && chain catches a failing step and
# never a failing stage of a pipe, so the build stayed at
# exit 0 with the error loose on stderr. The output
# assertion is the one that pins this: the exit status never
# told the truth here.
#
test_post_without_delimiter_stages_cleanly() {
	sandbox no_delimiter
	markdown_stub <<'EOF'
#!/bin/sh
cat "$1"
EOF
	add_post 2026-01-01-home_bare.txt <<'EOF'
title: Bare
EOF
	build || return
	assert_out_not_grep "No such file"
	# Same outcome as the verbatim branch: the whole file is
	# front matter, so the title renders and the body is empty.
	assert_grep build/2026/01/01/bare.html "Bare"
}

#
# A post opening with the delimiter: split -p left that line
# inside the front-matter chunk, the body glob then matched
# nothing, and the reassembly put a stray 35-hyphen line into
# the rendered body. awk drops the first delimiter wherever
# it is. Note this assertion only works because the grep
# helpers pass -- to grep; see the comment above them.
#
test_delimiter_on_first_line_leaves_no_stray_delimiter() {
	sandbox delimiter_first_line
	markdown_stub <<'EOF'
#!/bin/sh
cat "$1"
EOF
	add_post 2026-01-01-home_lead.txt <<'EOF'
-----------------------------------
<p>body only</p>
EOF
	build || return
	assert_grep build/2026/01/01/lead.html "<p>body only</p>"
	assert_not_grep build/2026/01/01/lead.html "-----------------------------------"
}

#
# fill() rescans the line it just composed, so whatever
# gets substituted first is itself searched for the
# placeholders substituted after it. A post body is the
# largest thing the author controls, so a post *about*
# grampa's own template syntax -- on a blog whose README
# invites people to read the Makefile -- came out with its
# examples replaced by real values.
#
# The fix is ordering, not a new engine: the author-supplied
# text goes in last, so there is nothing left to rescan it
# for. See the comment above RENDER_POST for what that does
# and does not close.
#
test_placeholders_in_a_body_are_not_expanded() {
	sandbox placeholder_body
	add_post 2026-08-06-home_syntax.txt <<'EOF'
title: Template syntax
-----------------------------------
<p>Use {{permalink}} for the URL, {{pub_date}} for the date,
{{category}} and {{category_url}} for the category, and
{{page_title}} in base.txt.</p>
EOF
	build || return
	local page=build/2026/08/06/syntax.html
	assert_grep "$page" "{{permalink}}"
	assert_grep "$page" "{{pub_date}}"
	assert_grep "$page" "{{category}}"
	assert_grep "$page" "{{category_url}}"
	assert_grep "$page" "{{page_title}}"
	# The real values still land where the template asks for
	# them -- this is an ordering change, not a disabling.
	assert_grep "$page" 'href="/2026/08/06/syntax.html"'
	assert_grep "$page" "posted on August 06, 2026"
	assert_grep "$page" "<title>Template syntax - My Weblog</title>"
	# The index wraps the same fragment through WRAP_IN_BASE.
	assert_grep build/index.html "{{page_title}}"
	# ...and the category page is the third consumer.
	assert_grep build/category/home.html "{{page_title}}"
}

#
# The title is author-supplied too, and is filled after the
# date/permalink/category values for the same reason.
#
test_placeholders_in_a_title_are_not_expanded() {
	sandbox placeholder_title
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: On {{permalink}} and {{category}}
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_grep build/2026/08/06/hello.html "<h4>On {{permalink}} and {{category}}</h4>"
	assert_grep build/2026/08/06/hello.html "<title>On {{permalink}} and {{category}} - My Weblog</title>"
}

#
# RENDER_ITEM has the same shape and the same problem: the
# title was filled before link, pub_date and category, so a
# title mentioning one of them picked up the real value.
# xml_escape does not touch braces, so escaping never hid
# this.
#
test_placeholders_in_the_feed_are_not_expanded() {
	sandbox placeholder_feed
	add_post 2026-08-06-home_syntax.txt <<'EOF'
title: On {{link}} and {{pub_date}}
-----------------------------------
<p>Use {{link}} and {{category}} in rss-item.txt.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_grep build/rss.xml "<title>On {{link}} and {{pub_date}}</title>"
	assert_grep build/rss.xml "{{link}}"
	assert_grep build/rss.xml "{{category}}"
	# The item's own link and date are still real.
	assert_grep build/rss.xml "<link>https://example.com/2026/08/06/syntax.html</link>"
	assert_grep build/rss.xml "<pubDate>Thu, 06 Aug 2026 00:00:00 "
}

#
# WRAP_IN_CHANNEL fills the blog name into <title> and
# <description> before it fills <link>, so a name= holding
# {{link}} took the site URL. config is author-supplied the
# same as a post is.
#
test_placeholders_in_the_blog_name_are_not_expanded() {
	sandbox placeholder_blog_name
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=A blog about {{link}}\nurl=https://example.com\n' > config
	build || return
	assert_grep build/rss.xml "<title>A blog about {{link}}</title>"
	assert_grep build/rss.xml "<description>A blog about {{link}}</description>"
	assert_grep build/rss.xml "<link>https://example.com</link>"
}

#
# Guards the pattern-rule trap: writing %.tmp's new
# prerequisites as a bare dependency line looks right and
# silently drops templates/post.txt, so editing the
# template would rebuild nothing.
#
test_editing_post_template_rebuilds_fragments() {
	sandbox post_template_rebuild
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	# Timestamp granularity, which is a property of the make
	# binary and the filesystem together rather than of the
	# make version: make compares whole seconds unless its
	# own build detected nanosecond stat(2). A touch landing
	# in the same wall-clock second as the first build then
	# looks "not newer" and gets skipped -- observed 3 of 3
	# with Apple's make 3.81 on APFS, and not reproducible
	# with a Linux source build of the same 3.81, which does
	# compare sub-second. Same reason
	# test_editing_one_category_does_not_rebuild_another sleeps.
	sleep 1
	touch templates/post.txt
	build || return
	assert_out_grep "Building work/2026-08-06-home_hello.tmp"
}

#
# The same bare-dependency-line trap as the test above,
# but for templates/base.txt, which has three consumers
# rather than one: the per-post %.html rule, the
# category/%.html rule, and the explicit index.html rule.
# Drop the prerequisite from any one of them and editing
# base.txt -- adding the feed's <link> tag, say, which
# README.md tells upgraders to do by hand -- leaves that
# page rendered from the old template with no error and
# no rebuild. Asserting all three in one test is
# deliberate: they are three copies of one dependency and
# the realistic mistake is fixing a rule and forgetting
# its siblings.
#
test_editing_base_template_rebuilds_every_page() {
	sandbox base_template_rebuild
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	# Whole-second mtime granularity, same as the test above.
	sleep 1
	touch templates/base.txt
	build || return
	assert_out_grep "Building build/2026/08/06/hello.html"
	assert_out_grep "Building build/category/home.html"
	assert_out_grep "Building index.html"
}

#
# The item's link must be absolute -- readers have no
# base to resolve against -- and must not contain the
# category, which is in the filename but never a URL.
#
test_rssitem_has_absolute_link_and_rfc822_date() {
	sandbox rssitem_link
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build work/2026-08-06-home_hello.rssitem || return
	assert_grep work/2026-08-06-home_hello.rssitem "<link>https://example.com/2026/08/06/hello.html</link>"
	assert_grep work/2026-08-06-home_hello.rssitem "<guid isPermaLink=\"true\">https://example.com/2026/08/06/hello.html</guid>"
	assert_grep work/2026-08-06-home_hello.rssitem "<pubDate>Thu, 06 Aug 2026 00:00:00 "
	assert_grep work/2026-08-06-home_hello.rssitem "<category>home</category>"
	assert_not_grep work/2026-08-06-home_hello.rssitem "/home/"
}

#
# A trailing slash on url= must not produce a double
# slash in the item link.
#
test_rssitem_link_survives_trailing_slash_in_url() {
	sandbox rssitem_slash
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com/\n' > config
	build work/2026-08-06-home_hello.rssitem || return
	assert_grep work/2026-08-06-home_hello.rssitem "<link>https://example.com/2026/08/06/hello.html</link>"
	assert_not_grep work/2026-08-06-home_hello.rssitem "example.com//"
}

#
# The mirror image of test_ampersands_are_not_mangled:
# HTML passes bodies through raw, XML must escape them.
#
test_rssitem_escapes_title_and_body() {
	sandbox rssitem_escape
	add_post 2026-08-06-cartoons_tom-and-jerry.txt <<'EOF'
title: Tom & Jerry
-----------------------------------
<p>Visit /search?a=1&b=2 for more.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build work/2026-08-06-cartoons_tom-and-jerry.rssitem || return
	assert_grep work/2026-08-06-cartoons_tom-and-jerry.rssitem "<title>Tom &amp; Jerry</title>"
	assert_grep work/2026-08-06-cartoons_tom-and-jerry.rssitem "&lt;p&gt;"
	assert_grep work/2026-08-06-cartoons_tom-and-jerry.rssitem "a=1&amp;b=2"
	assert_not_grep work/2026-08-06-cartoons_tom-and-jerry.rssitem "<p>"
	assert_not_grep work/2026-08-06-cartoons_tom-and-jerry.rssitem "&amp;lt;"
}

#
# A feed is opt-in. Without url= the build must succeed
# and produce nothing, not error and not emit a feed with
# relative links.
#
test_no_url_means_no_feed() {
	sandbox no_url
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_no_file build/rss.xml
	assert_no_file work/2026-08-06-home_hello.rssitem
	assert_file build/index.html
	assert_out_grep "skipping rss.xml"
}

test_feed_is_built_when_url_is_set() {
	sandbox feed_built
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_file build/rss.xml
	assert_grep build/rss.xml '<rss version="2.0">'
	assert_grep build/rss.xml "<title>My Weblog</title>"
	assert_grep build/rss.xml "<link>https://example.com</link>"
	assert_grep build/rss.xml "<link>https://example.com/2026/08/06/hello.html</link>"
	assert_eq "items in feed" "1" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
}

#
# The XML counterpart of test_ampersands_are_not_mangled,
# which asserts the opposite for HTML. Both on the same
# input, in the same file, is what pins escaping down as a
# per-consumer policy.
#
test_feed_escapes_titles_and_bodies() {
	sandbox feed_escape
	add_post 2026-08-06-cartoons_tom-and-jerry.txt <<'EOF'
title: Tom & Jerry
-----------------------------------
<p>Visit /search?a=1&b=2 for more.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_grep build/rss.xml "<title>Tom &amp; Jerry</title>"
	assert_grep build/rss.xml "&lt;p&gt;"
	assert_grep build/rss.xml "a=1&amp;b=2"
	assert_not_grep build/rss.xml "<p>"
	assert_grep build/2026/08/06/tom-and-jerry.html "/search?a=1&b=2"
}

test_feed_is_capped_at_ten_newest() {
	sandbox feed_ten
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
		add_post "2026-01-$(printf '%02d' $i)-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_eq "items in feed" "10" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
	assert_grep build/rss.xml "<title>Post 12</title>"
	assert_not_grep build/rss.xml "<title>Post 1</title>"
	assert_eq "newest item first" "Post 12" "$(grep '<title>' build/rss.xml | sed -n '2p' | sed 's/.*<title>//; s|</title>.*||')"
}

#
# Deleting a post used to leave it on the FRONT PAGE, which
# is worse than the feed case beside it and was undocumented.
#
# index.tmp is a cat of the newest-ten .tmp files, taken as
# prerequisites -- so make asks whether any is newer, never
# whether the set changed. Every post has a .tmp because
# every post has a page, so the incoming fragment is always
# already on disk and older, and index.tmp never re-cats.
# That is why the feed sometimes healed and the index never
# did.
#
test_deleting_a_post_heals_the_index() {
	sandbox delete_index
	local i
	for i in 1 2 3; do
		add_post "2026-01-0$i-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build || return
	assert_grep build/index.html "Post 3"
	# Whole-second mtime resolution: posts/ must come out
	# strictly newer than index.tmp or nothing re-cats.
	sleep 1
	rm posts/2026-01-03-home_post-3.txt
	build || return
	assert_not_grep build/index.html "Post 3"
	assert_grep build/index.html "Post 2"
}

#
# Same mechanism as the index, one target over. A category
# page is an awk pass over every fragment in its category,
# taken as prerequisites -- and it is not even windowed, so
# a deleted post stays on it forever.
#
test_deleting_a_post_heals_the_category_page() {
	sandbox delete_category
	local i
	for i in 1 2 3; do
		add_post "2026-01-0$i-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build || return
	assert_grep build/category/home.html "Post 3"
	sleep 1
	rm posts/2026-01-03-home_post-3.txt
	build || return
	assert_not_grep build/category/home.html "Post 3"
	assert_grep build/category/home.html "Post 2"
}

#
# test_deleting_a_post_heals_the_feed builds all twelve
# posts at once, which is the ONE corpus shape where the
# heal already worked -- the eleventh-newest post has no
# .rssitem, so deletion forces one to be built, which makes
# rss.tmp out of date. That test passes against the unfixed
# Makefile and covers none of the bug.
#
# A blog grown a post at a time is the normal shape, and
# there every out-of-window post already has its fragment.
# Nothing rebuilds and the deleted post's <item> survives.
#
test_deleting_a_post_heals_the_feed_after_incremental_growth() {
	sandbox feed_delete_incremental
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11; do
		add_post "2026-01-$(printf '%02d' $i)-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build || return
	sleep 1
	add_post "2026-01-12-home_post-12.txt" <<EOF
title: Post 12
-----------------------------------
<p>Body 12.</p>
EOF
	build || return
	assert_grep build/rss.xml "<title>Post 12</title>"
	sleep 1
	rm posts/2026-01-12-home_post-12.txt
	build || return
	assert_eq "items in feed after delete" "10" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
	assert_not_grep build/rss.xml "<title>Post 12</title>"
	assert_grep build/rss.xml "<title>Post 2</title>"
}

#
# A tree with no posts/ at all builds an empty site at exit
# 0, and must keep doing so. Adding posts as a prerequisite
# of index.tmp/rss.tmp/category pages would otherwise make
# make die on its own "No rule to make target 'posts'", so
# the posts: rule exists to recreate it.
#
test_build_works_without_a_posts_directory() {
	sandbox no_posts_dir
	rm -rf posts
	build || return
	assert_file build/index.html
	assert_eq "posts/ recreated" "yes" "$([ -d posts ] && echo yes || echo no)"
}

#
# The all-at-once companion to the two heal tests above and
# to test_deleting_a_post_heals_the_feed_after_incremental_growth
# below: same mechanism (posts as a directory-level
# prerequisite of rss.tmp), a different corpus shape, and the
# one that end-to-end exercises the feed's ten-item window
# actually dropping a title and pulling the next one in.
#
# It does NOT guard listing RSSITEM_FILES in .SECONDARY --
# see the comment above that line in the Makefile. That used
# to matter, back when rss.tmp's only prerequisites were the
# .rssitem files themselves: marking them .SECONDARY let make
# treat a missing one as tolerable, which suppressed exactly
# the rebuild this test checks for. Now that posts is a
# prerequisite of rss.tmp too, any change to the post set
# makes rss.tmp out of date outright, and a target that must
# be remade gets its missing secondary prerequisites built
# regardless of .SECONDARY -- verified by mutation, appending
# $(RSSITEM_FILES) to .SECONDARY passes this test and the full
# suite identically. This sandbox still builds all twelve
# posts at once, which is the one corpus shape where the heal
# already worked before posts became a prerequisite -- the
# incremental-growth test below is the one that covers the
# shape where it did not.
#
test_deleting_a_post_heals_the_feed() {
	sandbox feed_delete
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
		add_post "2026-01-$(printf '%02d' $i)-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_eq "items in feed" "10" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
	assert_not_grep build/rss.xml "<title>Post 2</title>"
	# Whole-second mtime resolution: the newly built
	# .rssitem must come out strictly newer than the
	# rss.tmp of the first build, or nothing re-cats.
	sleep 1
	rm posts/2026-01-12-home_post-12.txt
	build || return
	assert_eq "items in feed after delete" "10" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
	assert_grep build/rss.xml "<title>Post 2</title>"
	assert_not_grep build/rss.xml "<title>Post 12</title>"
}

#
# The feed path re-derives everything that made
# test_zero_posts_does_not_hang necessary: cat with no
# operands would read stdin, and an unguarded getline on a
# missing template would spin.
#
test_feed_with_zero_posts() {
	sandbox feed_empty
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_file build/rss.xml
	assert_grep build/rss.xml '<rss version="2.0">'
	assert_not_grep build/rss.xml "<item>"
}

#
# Guards the -v0H -v0M -v0S pinning and the decision to
# omit lastBuildDate. A feed that churns on every build
# looks perfectly correct in isolation.
#
test_feed_is_byte_stable_across_rebuilds() {
	sandbox feed_stable
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	cp build/rss.xml first-rss.xml
	# Whole-second mtime resolution again -- a one-post
	# sandbox builds in well under a second, so without
	# this the two builds can land in the same wall-clock
	# second and come out byte-identical even if a churning
	# timestamp (a reintroduced lastBuildDate, say) would
	# otherwise have caught it.
	sleep 1
	"$MAKE" clean >/dev/null 2>&1
	build || return
	if cmp -s first-rss.xml build/rss.xml; then ok; else fail "feed changed across rebuilds" "$(diff first-rss.xml build/rss.xml)"; fi
}

#
# config is a prerequisite of %.rssitem for exactly this
# reason. Drop it and every other test still passes while
# real installs get stale hostnames forever.
#
test_changing_url_rebuilds_the_feed() {
	sandbox feed_url_change
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://old.example.com\n' > config
	build || return
	assert_grep build/rss.xml "<link>https://old.example.com/2026/08/06/hello.html</link>"
	# Whole-second mtime resolution again -- a one-post
	# sandbox builds in well under a second, so without
	# this the rewritten config is "not newer" than the
	# .rssitem files and nothing rebuilds.
	sleep 1
	printf 'name=My Weblog\nurl=https://new.example.com\n' > config
	build || return
	assert_grep build/rss.xml "<link>https://new.example.com/2026/08/06/hello.html</link>"
	assert_not_grep build/rss.xml "old.example.com"
}

test_url_omits_the_category() {
	sandbox url_omits_category
	add_post 2026-08-06-home_installing-a-doorbell.txt <<'EOF'
title: Installing A Doorbell
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/2026/08/06/installing-a-doorbell.html
	assert_no_file build/2026/08/06/home/installing-a-doorbell.html
	assert_grep build/2026/08/06/installing-a-doorbell.html 'href="/2026/08/06/installing-a-doorbell.html"'
}

test_multi_hyphen_category_parses() {
	sandbox multi_hyphen
	add_post 2026-07-04-project-ideas_raspberry-pi-backup.txt <<'EOF'
title: Raspberry Pi Backup
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/2026/07/04/raspberry-pi-backup.html
	assert_grep build/2026/07/04/raspberry-pi-backup.html "posted on July 04, 2026"
}

test_filename_without_underscore_fails() {
	sandbox no_underscore
	add_post 2026-08-06-no-category-here.txt <<'EOF'
title: Oops
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail || return
	assert_out_grep "2026-08-06-no-category-here.txt"
	assert_no_file build/2026/08/06/no-category-here.html
}

test_filename_with_two_underscores_fails() {
	sandbox two_underscores
	add_post 2026-08-06-a_b_c.txt <<'EOF'
title: Oops
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail || return
	assert_out_grep "2026-08-06-a_b_c.txt"
}

test_filename_with_empty_category_fails() {
	sandbox empty_category
	add_post 2026-08-06-_orphan.txt <<'EOF'
title: Oops
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail || return
	assert_out_grep "2026-08-06-_orphan.txt"
}

#
# The category is not in the URL, so two posts sharing a date
# and title slug in different categories both want
# /2026/08/06/dup.html. One would win on filename sort order
# and the other would still be linked from the index and its
# own category page, pointing at the wrong post. Parse-time
# error naming both files instead.
#
test_duplicate_permalink_fails() {
	sandbox duplicate_permalink
	add_post 2026-08-06-home_dup.txt <<'EOF'
title: Home Dup
-----------------------------------
<p>Home body.</p>
EOF
	add_post 2026-08-06-work_dup.txt <<'EOF'
title: Work Dup
-----------------------------------
<p>Work body.</p>
EOF
	build_expect_fail || return
	assert_out_grep "posts/2026-08-06-home_dup.txt"
	assert_out_grep "posts/2026-08-06-work_dup.txt"
	assert_no_file build/2026/08/06/dup.html
	assert_no_file build/index.html
	assert_no_file build/category/work.html
}

#
# The same title slug on two different dates is a different
# page each time, so it must still build.
#
test_same_slug_on_different_dates_is_fine() {
	sandbox same_slug_other_date
	add_post 2026-08-06-home_dup.txt <<'EOF'
title: Home Dup
-----------------------------------
<p>Home body.</p>
EOF
	add_post 2026-08-07-work_dup.txt <<'EOF'
title: Work Dup
-----------------------------------
<p>Work body.</p>
EOF
	build || return
	assert_file build/2026/08/06/dup.html
	assert_file build/2026/08/07/dup.html
	assert_grep build/2026/08/06/dup.html "<h4>Home Dup</h4>"
	assert_grep build/2026/08/07/dup.html "<h4>Work Dup</h4>"
}

#
# A stem no post maps to leaves tmp_for_page empty, which
# makes the %.html rule's prerequisites satisfiable anyway --
# so it used to wrap templates/base.txt in itself and exit 0,
# or hang on stdin. It has to fail and say why.
#
test_unknown_page_target_fails_cleanly() {
	sandbox unknown_page
	add_post 2026-08-06-home_real.txt <<'EOF'
title: Real Post
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	build_expect_fail build/2026/08/06/typo.html || return
	assert_out_grep "no post"
	assert_out_grep "build/2026/08/06/typo.html"
	assert_no_file build/2026/08/06/typo.html
	assert_file build/2026/08/06/real.html
}

#
# The same guard for a category stem. This needs its own
# test because it is a different rule: build/category/%.html
# and %.html both match build/category/typo.html, and above
# the 4.2 floor the shortest stem wins, so the category rule
# always claims it and the %.html guard never sees a category
# path at all.
#
# Without a guard of its own, tmp_files_in_category is empty
# for an unknown category, the prerequisite list is trivially
# satisfiable, and awk runs with zero file operands -- which
# writes an empty base.txt-wrapped page at exit 0, or, if
# stdin happens to be a terminal rather than the /dev/null
# the helpers redirect, sits there reading it.
#
test_unknown_category_page_target_fails_cleanly() {
	sandbox unknown_category
	add_post 2026-08-06-home_real.txt <<'EOF'
title: Real Post
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	build_expect_fail build/category/typo.html || return
	assert_out_grep "no post"
	assert_out_grep "build/category/typo.html"
	assert_no_file build/category/typo.html
	assert_file build/category/home.html
}

test_category_link_on_post_page() {
	sandbox category_link_post
	add_post 2026-08-06-home_installing-a-doorbell.txt <<'EOF'
title: Installing A Doorbell
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_grep build/2026/08/06/installing-a-doorbell.html 'in <a href="/category/home.html">home</a>'
	assert_not_grep build/2026/08/06/installing-a-doorbell.html ".gif"
	assert_not_grep build/2026/08/06/installing-a-doorbell.html "{{category}}"
}

test_category_link_display_name_has_spaces() {
	sandbox category_display
	add_post 2026-07-04-project-ideas_raspberry-pi-backup.txt <<'EOF'
title: Raspberry Pi Backup
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_grep build/2026/07/04/raspberry-pi-backup.html 'href="/category/project-ideas.html">project ideas</a>'
}

test_category_link_on_index() {
	sandbox category_link_index
	add_post 2026-08-06-home_installing-a-doorbell.txt <<'EOF'
title: Installing A Doorbell
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_grep build/index.html 'href="/category/home.html">home</a>'
}

test_category_page_lists_its_posts_newest_first() {
	sandbox category_page
	add_post 2026-01-02-home_older-doorbell.txt <<'EOF'
title: Older Doorbell
-----------------------------------
<p>Older body.</p>
EOF
	add_post 2026-08-06-home_newer-doorbell.txt <<'EOF'
title: Newer Doorbell
-----------------------------------
<p>Newer body.</p>
EOF
	build || return
	assert_file build/category/home.html
	assert_grep build/category/home.html "<h4>Newer Doorbell</h4>"
	assert_grep build/category/home.html "<h4>Older Doorbell</h4>"
	assert_grep build/category/home.html "Newer body."
	assert_eq "newest first" "Newer Doorbell" "$(grep -o '<h4>[^<]*</h4>' build/category/home.html | head -1 | sed 's/<[^>]*>//g')"
}

test_category_pages_do_not_mix_categories() {
	sandbox category_separate
	add_post 2026-08-06-home_doorbell.txt <<'EOF'
title: Doorbell
-----------------------------------
<p>Home body.</p>
EOF
	add_post 2026-08-07-project-ideas_pi-backup.txt <<'EOF'
title: Pi Backup
-----------------------------------
<p>Project body.</p>
EOF
	build || return
	assert_file build/category/home.html
	assert_file build/category/project-ideas.html
	assert_not_grep build/category/home.html "Pi Backup"
	assert_not_grep build/category/project-ideas.html "Doorbell"
}

test_category_page_is_not_capped_at_ten() {
	sandbox category_uncapped
	local i
	for i in 1 2 3 4 5 6 7 8 9; do
		add_post "2026-01-0$i-n_post-0$i.txt" <<EOF
title: Post 0$i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	add_post 2026-01-10-n_post-10.txt <<'EOF'
title: Post 10
-----------------------------------
<p>Body 10.</p>
EOF
	add_post 2026-01-11-n_post-11.txt <<'EOF'
title: Post 11
-----------------------------------
<p>Body 11.</p>
EOF
	build || return
	assert_eq "index still capped" "10" "$(grep -c 'posted on' build/index.html)"
	assert_eq "category page has all 11" "11" "$(grep -c 'posted on' build/category/n.html)"
	assert_grep build/category/n.html "Post 01"
}

test_category_page_title_uses_display_name_and_blog_name() {
	sandbox category_title
	add_post 2026-07-04-project-ideas_pi-backup.txt <<'EOF'
title: Pi Backup
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=Andre Torrez\n' > config
	build || return
	assert_grep build/category/project-ideas.html "<title>project ideas - Andre Torrez</title>"
}

test_editing_one_category_does_not_rebuild_another() {
	sandbox category_scope
	add_post 2026-08-06-home_doorbell.txt <<'EOF'
title: Doorbell
-----------------------------------
<p>Home body.</p>
EOF
	add_post 2026-08-07-project-ideas_pi-backup.txt <<'EOF'
title: Pi Backup
-----------------------------------
<p>Project body.</p>
EOF
	build || return
	touch -t 202701010000 posts/2026-08-06-home_doorbell.txt
	# Timestamp granularity -- see the note on the sleep in
	# test_editing_base_template_rebuilds_every_page. Without
	# this, a rebuild that lands in the same wall-clock
	# second as the first build can look "not newer" than
	# files the first build produced, and get skipped --
	# flaky, not a real rebuild-scope bug.
	sleep 1
	build || return
	assert_out_grep "build/category/home.html"
	assert_out_not_grep "build/category/project-ideas.html"
}

test_category_pages_are_html_only_in_build() {
	sandbox category_html_only
	add_post 2026-08-06-home_doorbell.txt <<'EOF'
title: Doorbell
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	# css: setup now seeds static/style.css, published as
	# build/style.css. It's designed output, not a leak -- what
	# this test protects is that no .tmp/.staged intermediate
	# escapes work/ into build/, which "css html" still catches.
	assert_eq "extensions under build/" "css html" "$(find build -type f | sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

test_migration_converts_old_posts() {
	sandbox migration
	cp -R "$REPO/tools" .
	# Old-format posts, category in front matter.
	cat > posts/2026-08-06-installing-a-doorbell.txt <<'EOF'
title: Installing A Doorbell
category: Home
-----------------------------------
<p>Hi.</p>
EOF
	cat > posts/2026-07-04-raspberry-pi-backup.txt <<'EOF'
title: Raspberry Pi Backup
category: Project Ideas
-----------------------------------
<p>Hi.</p>
EOF
	# Dry run must change nothing: both original files
	# still exist with their original content, and neither
	# target name has been created yet.
	./tools/migrate-categories.sh >/dev/null 2>&1
	assert_file posts/2026-08-06-installing-a-doorbell.txt
	assert_file posts/2026-07-04-raspberry-pi-backup.txt
	assert_grep posts/2026-08-06-installing-a-doorbell.txt "category: Home"
	assert_grep posts/2026-07-04-raspberry-pi-backup.txt "category: Project Ideas"
	assert_no_file posts/2026-08-06-home_installing-a-doorbell.txt
	assert_no_file posts/2026-07-04-project-ideas_raspberry-pi-backup.txt
	# Apply.
	./tools/migrate-categories.sh --apply >/dev/null 2>&1
	assert_file posts/2026-08-06-home_installing-a-doorbell.txt
	assert_file posts/2026-07-04-project-ideas_raspberry-pi-backup.txt
	assert_no_file posts/2026-08-06-installing-a-doorbell.txt
	assert_not_grep posts/2026-08-06-home_installing-a-doorbell.txt "category:"
	assert_grep posts/2026-08-06-home_installing-a-doorbell.txt "title: Installing A Doorbell"
	# And the migrated tree builds to the original URLs.
	build || return
	assert_file build/2026/08/06/installing-a-doorbell.html
	assert_file build/2026/07/04/raspberry-pi-backup.html
	assert_file build/category/home.html
	assert_file build/category/project-ideas.html
}

#
# A migrated post's name has an underscore but its front
# matter no longer has a category: line -- that combination
# is what "already migrated" actually looks like. Detecting
# it from the underscore alone is ambiguous (see the test
# below), so this checks the front-matter half of the rule.
#
test_migration_skips_already_migrated_by_missing_category() {
	sandbox migration_skip_already_migrated
	cp -R "$REPO/tools" .
	cat > posts/2026-08-06-home_installing-a-doorbell.txt <<'EOF'
title: Installing A Doorbell
-----------------------------------
<p>Hi.</p>
EOF
	./tools/migrate-categories.sh --apply > migrate.out 2>&1
	assert_grep migrate.out "skip"
	assert_grep migrate.out "posts/2026-08-06-home_installing-a-doorbell.txt"
	assert_grep migrate.out "errors 0"
	assert_file posts/2026-08-06-home_installing-a-doorbell.txt
}

#
# A legacy title containing an underscore was never
# forbidden by the old format, so an underscore in the name
# is not by itself proof of "already migrated." When
# front matter still has a category: line too, the script
# cannot tell which case it is and must refuse rather than
# guess -- see the Makefile's own CHECKED_POST_NAMES, which
# would silently misparse this same file as category "weird",
# title "title".
#
test_migration_refuses_ambiguous_underscore_title() {
	sandbox migration_ambiguous_underscore
	cp -R "$REPO/tools" .
	local status
	cat > posts/2026-01-03-weird_title.txt <<'EOF'
title: Weird Title
category: Home
-----------------------------------
<p>Hi.</p>
EOF
	./tools/migrate-categories.sh --apply > migrate.out 2>&1
	status=$?
	assert_eq "apply exit code" "1" "$status"
	assert_grep migrate.out "ERROR"
	assert_grep migrate.out "posts/2026-01-03-weird_title.txt"
	assert_file posts/2026-01-03-weird_title.txt
	assert_grep posts/2026-01-03-weird_title.txt "category: Home"
}

#
# The Makefile allows a non-ASCII category, but the script's
# a-z0-9- slug filter cannot carry one -- it would rename
# "Café" to caf_ and lose a character with no diagnostic.
# Refusing matches what it already does for a category that
# slugifies to nothing. The check is wider than non-ASCII:
# it covers everything outside printable ASCII, because a
# tab survives the space-to-hyphen tr and would silently
# join two words.
#
test_migration_refuses_a_non_ascii_category() {
	sandbox migration_non_ascii
	cp -R "$REPO/tools" .
	local status
	cat > posts/2026-01-03-a-post.txt <<'EOF'
title: A Post
category: Café
-----------------------------------
<p>Hi.</p>
EOF
	./tools/migrate-categories.sh --apply > migrate.out 2>&1
	status=$?
	assert_eq "apply exit code" "1" "$status"
	assert_grep migrate.out "ERROR"
	assert_grep migrate.out "outside printable ASCII"
	assert_file posts/2026-01-03-a-post.txt
	assert_no_file posts/2026-01-03-caf_a-post.txt
}

#
# base.txt must advertise the feed on every page kind --
# the index and a post page -- not just the one recipe that
# happens to build rss.xml itself.
#
test_base_template_advertises_the_feed() {
	sandbox feed_autodiscovery
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_grep build/index.html 'type="application/rss+xml"'
	assert_grep build/index.html 'href="/rss.xml"'
	assert_grep build/2026/08/06/hello.html 'type="application/rss+xml"'
}

#
# The feed's <category> uses the display form -- hyphens
# become spaces -- same as the HTML pages. Nothing pinned
# that down for a multi-word category before this.
#
test_feed_category_uses_display_form() {
	sandbox feed_category_display
	add_post 2026-07-04-project-ideas_raspberry-pi-backup.txt <<'EOF'
title: Raspberry Pi Backup
-----------------------------------
<p>Hi.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	build || return
	assert_grep build/rss.xml "<category>project ideas</category>"
	assert_not_grep build/rss.xml "<category>project-ideas</category>"
}

#
# A source file that cannot be removed (read-only,
# permission-restricted, chflags uchg -- all realistic)
# must not be reported as a success while the migrated
# content sits under a second name and the original is
# still there under the first.
#
test_migration_reports_error_when_rm_fails() {
	sandbox migration_rm_fails
	# chflags uchg is the only realistic way to make a file
	# un-removable without root, and it is BSD/macOS-only. On
	# a host without it (GNU/Linux) there is nothing to test
	# -- rm would just succeed -- so skip rather than fail.
	if ! command -v chflags >/dev/null 2>&1; then
		echo "SKIP: $CURRENT (no chflags on this host)"
		return 0
	fi
	cp -R "$REPO/tools" .
	local status
	cat > posts/2026-02-02-rmtest.txt <<'EOF'
title: RM Test
category: Home
-----------------------------------
<p>Hi.</p>
EOF
	chflags uchg posts/2026-02-02-rmtest.txt
	./tools/migrate-categories.sh --apply > migrate.out 2>&1
	status=$?
	chflags nouchg posts/2026-02-02-rmtest.txt
	assert_eq "apply exit code signals failure" "1" "$status"
	assert_grep migrate.out "ERROR"
	assert_grep migrate.out "posts/2026-02-02-rmtest.txt"
	assert_grep migrate.out "posts/2026-02-02-home_rmtest.txt"
	assert_grep migrate.out "errors 1"
	# Both files exist -- that's the honest state, not a
	# silent duplicate reported as a clean success.
	assert_file posts/2026-02-02-rmtest.txt
	assert_file posts/2026-02-02-home_rmtest.txt
}

#
# make setup probes date(1) and writes the host's dialect to
# a generated config.mk. sandbox() already ran setup, so the
# file is there to inspect.
#
test_setup_writes_the_host_date_dialect() {
	sandbox setup_writes_dialect
	assert_file config.mk
	assert_grep config.mk "DATE_DIALECT := "
	local want
	if date -v1d >/dev/null 2>&1; then want=bsd
	elif date -d 2026-01-15 >/dev/null 2>&1; then want=gnu
	else want=none; fi
	assert_grep config.mk "DATE_DIALECT := $want"
}

# ---------------------------------------------------
# The make version floor. MAKE_VERSION is a built-in, and
# a command-line assignment overrides a built-in, so these
# exercise the real guard against a fake version without
# needing an old make binary on the host. The floor was
# established by building 3.81 through 4.3 from source and
# running the suite -- as it stood before these three tests
# existed -- against each: 3.81 fails because it voids
# .DELETE_ON_ERROR for .SECONDARY targets, 4.0 hangs or
# segfaults on an emoji in a post filename. That run is
# recorded, not repeatable: every binary below the floor now
# dies at the guard before a single test can run.
# ---------------------------------------------------

#
# 3.81 is the version that actually shipped broken, and
# the one macOS still has.
#
test_old_make_version_fails_the_build() {
	sandbox old_make_version
	add_post 2026-02-10-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail MAKE_VERSION=3.81
	assert_out_grep "4.2 or newer"
	assert_out_grep "3.81"
	assert_no_file build/2026/02/10/hello.html
}

#
# 4.1 rejected and 4.2 accepted, pinning the boundary
# itself. Without the 4.1 case, narrowing the guard to
# 3.% alone -- which looks like a tidy-up -- would pass
# every other test here.
#
test_make_version_floor_is_4_2() {
	sandbox make_version_floor
	add_post 2026-02-10-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail MAKE_VERSION=4.0
	assert_out_grep "4.2 or newer"
	build_expect_fail MAKE_VERSION=4.1
	assert_out_grep "4.2 or newer"
	# Prereleases: 4.0.90 predates the emoji fix, so a bare
	# 4.0/4.1 word match is not enough.
	build_expect_fail MAKE_VERSION=4.0.90
	assert_out_grep "4.2 or newer"
	# Above the floor, including versions that sort oddly as
	# strings. 4.10 must be accepted, not read as 4.1.
	build MAKE_VERSION=4.10 || return
	build MAKE_VERSION=4.2 || return
	assert_grep build/2026/02/10/hello.html "Hi."
}

#
# The guard is deliberately not gated on BUILD_GOAL, unlike
# the config.mk guards it sits above: the fix is a newer
# make, not a recipe in this file, so clean and setup have
# nothing to offer an old make either. Gating it would pass
# the two tests above and lose this.
#
test_old_make_version_fails_nonbuild_goals_too() {
	sandbox old_make_version_nonbuild
	build_expect_fail clean MAKE_VERSION=3.81
	assert_out_grep "4.2 or newer"
	build_expect_fail setup MAKE_VERSION=3.81
	assert_out_grep "4.2 or newer"
}

#
# With no config.mk, DATE_DIALECT is empty and any dated
# build must die with "run make setup first". An ordinary
# 1st-28th date keeps SUSPECT_POST_DATES empty, so the
# failure comes at recipe time -- the representative path.
# A month-end date would fail earlier at parse time on the
# same message; this pins the recipe-time path deliberately.
#
test_build_without_config_mk_fails() {
	sandbox build_without_config_mk
	rm -f config.mk
	add_post 2026-02-10-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail
	assert_out_grep "make setup"
	# The markdown notice is gated on DATE_DIALECT so an
	# unconfigured tree leads with the line that tells you
	# what to do. Dropping that half of the gate passes
	# every notice test, so this is where it is pinned.
	assert_out_not_grep "grampa: markdown:"
}

#
# B1 regression: BAD_POST_DATES is := and expands at parse
# time on EVERY invocation, make setup included. A month-end
# post (a suspect date) on an unconfigured tree must NOT make
# `make setup` itself die before it writes config.mk -- that
# was a deadlock (can't build without config.mk, can't setup
# to create it). The gate `$(if $(DATE_DIALECT),...)` on the
# check is what keeps setup bootstrappable here.
#
test_setup_bootstraps_with_a_month_end_post() {
	sandbox setup_bootstraps_month_end
	rm -f config.mk
	add_post 2026-01-31-home_endofmonth.txt <<'EOF'
title: End of month
-----------------------------------
<p>Hi.</p>
EOF
	# setup must succeed and write config.mk despite the suspect
	# date and the absent config.mk at parse time.
	if "$MAKE" setup < /dev/null > setup.out 2>&1; then ok; else
		fail "make setup deadlocked on a month-end post" "$(cat setup.out)"; fi
	assert_file config.mk
	# And once configured, the build works and the suspect date
	# renders -- proving the gate skipped the check, it did not
	# permanently disable it.
	build
	assert_file build/2026/01/31/endofmonth.html
}

#
# Detection records field 2 -- the whole command line --
# not the probe name. Recorded as field 1, cmark-gfm loses
# -e table and renders tables as paragraphs at exit 0.
#
test_setup_records_the_full_argv() {
	sandbox setup_full_argv
	path_stub cmark-gfm 'cat "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := cmark-gfm --unsafe -e table"
}

#
# Preference order: the table's first working candidate
# wins, not whichever happens to be installed.
#
test_setup_prefers_the_earlier_candidate() {
	sandbox setup_order
	path_stub cmark 'cat "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
	path_stub lowdown 'cat "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := lowdown --out-no-smarty"
}

#
# The probe tests the flags, not just the binary: a
# candidate that drops raw HTML is skipped, which is the
# real behaviour of cmark/cmark-gfm/lowdown without their
# --unsafe-family flags.
#
test_probe_skips_a_candidate_that_eats_raw_html() {
	sandbox probe_raw_html
	path_stub lowdown 'sed "s|<i>y</i>|RAWGONE|" "$f"'
	path_stub cmark 'cat "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
}

#
# A candidate emitting a whole document is skipped: base.txt
# would otherwise wrap it in a second <html> at exit 0.
#
test_probe_skips_a_whole_document_candidate() {
	sandbox probe_document
	path_stub lowdown 'echo "<html><body>x <i>y</i></body></html>"'
	"$MAKE" setup >/dev/null 2>&1
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
	# Every other candidate is stubbed to exit 1 by
	# hide_markdown_tools, so with lowdown rejected nothing
	# else can win. Pin the line to exactly empty, the same
	# shape as test_setup_names_a_rejected_candidate, so a
	# rejection reason that leaks onto stdout (an errant
	# missing >&2 on this branch) is caught here instead of
	# only proving the wrong name was not chosen.
	assert_eq "no diagnostic leaked into the winner" "DETECTED_MARKDOWN :=" \
		"$(grep '^DETECTED_MARKDOWN' config.mk | sed 's/[[:space:]]*$//')"
}

#
# One candidate truncating the probe file must not poison
# the candidates behind it. The file is rewritten per
# candidate for exactly this reason.
#
test_a_truncating_candidate_does_not_poison_the_walk() {
	sandbox probe_truncate
	path_stub lowdown ': > "$f"; exit 1'
	path_stub cmark 'cat "$f"'
	"$MAKE" setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
}

#
# Nothing installed is a legitimate state, not an error.
#
test_setup_with_no_processor_records_empty() {
	sandbox setup_none
	"$MAKE" setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN :="
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
}

#
# The cmp guard: a no-op setup must not bump the mtime, or
# every setup re-stages every post, config.mk being a
# prerequisite of %.staged. The
# scratch file setup writes and cmps against is named
# config.mk.$$ (the PID), so no fixed name is knowable
# statically -- a glob count is what stands in for
# assert_no_file here, and it is what actually catches a
# scratch file left behind, unlike a fixed name nothing
# writes any more.
#
test_noop_setup_leaves_config_mk_untouched() {
	sandbox setup_noop
	local before after
	before=$(stat -c %Y config.mk 2>/dev/null || stat -f %m config.mk)
	sleep 1
	"$MAKE" setup >/dev/null 2>&1
	after=$(stat -c %Y config.mk 2>/dev/null || stat -f %m config.mk)
	assert_eq "config.mk mtime unchanged by a no-op setup" "$before" "$after"
	assert_eq "no scratch file survives setup" "0" \
		"$(ls config.mk.* 2>/dev/null | wc -l | tr -d ' ')"
}

#
# ---------------------------------------------------
# The upgrade guard. An install set up before markdown
# detection existed has a config.mk holding only
# DATE_DIALECT. Left alone that install goes mixed --
# already-staged posts keep rendered bodies while the
# next edited post stages verbatim -- at exit 0.
# ---------------------------------------------------
#

#
# An install from before markdown detection must fail loud
# rather than silently staging verbatim.
#
test_config_mk_without_detected_markdown_fails_the_build() {
	sandbox old_config_mk
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build_expect_fail
	assert_out_grep "config.mk predates markdown detection"
}

#
# ...including for an explicit file goal. An allowlist of
# all/build/deploy leaves this ungated, which reopens the
# silent rot the guard exists to close.
#
test_old_config_mk_fails_for_an_explicit_page_goal() {
	sandbox old_config_mk_explicit
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build_expect_fail build/2026/08/06/hello.html
	assert_out_grep "config.mk predates markdown detection"
}

#
# The guard must not deadlock: it tells you to run setup,
# so setup has to parse and run.
#
test_setup_recovers_an_old_config_mk() {
	sandbox old_config_mk_setup
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build setup
	assert_grep config.mk "DETECTED_MARKDOWN :="
}

#
# A probed-empty config.mk is a legitimate state and must
# not trip the guard. $(origin) is what tells the two
# apart: undefined vs file, though both expand empty.
#
test_probed_empty_config_mk_builds_fine() {
	sandbox empty_detected
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_file build/2026/08/06/hello.html
}

#
# clean must stay usable on an unconverted tree.
#
test_clean_works_with_an_old_config_mk() {
	sandbox old_config_mk_clean
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build clean
}

#
# ---------------------------------------------------
# Unreadable templates. A template that is present but
# cannot be read -- one chmod 000, or a cp/rsync that
# dropped the mode -- satisfies make's prerequisite, so
# awk runs anyway. getline returns -1 on that file, which
# is truthy, so an unguarded loop never terminates.
#
# All four programs must instead say which template they
# could not read and exit non-zero, so .DELETE_ON_ERROR
# takes the half-written page away rather than leaving an
# empty one to be deployed.
#
# The 10s limits are slack for a failure that should be
# instantaneous; they only ever elapse if the guard is
# gone, and the helper kills the process group so a
# regression costs ten seconds, not the suite.
# ---------------------------------------------------
#

test_unreadable_post_template_fails_the_build() {
	sandbox unreadable_post_template
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Real body content.</p>
EOF
	chmod 000 templates/post.txt
	build_expect_fail_within 10
	local built=$?
	# Sandboxes are kept after the run, and a 000 file in
	# one of them breaks any later cp -R or rsync of the
	# checkout -- which is exactly what a reviewer does.
	chmod 644 templates/post.txt
	[ $built -eq 0 ] || return
	assert_out_grep "cannot read templates/post.txt"
	assert_no_file work/2026-08-06-home_hello.tmp
	assert_no_file build/2026/08/06/hello.html
}

test_unreadable_base_template_fails_the_build() {
	sandbox unreadable_base_template
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Real body content.</p>
EOF
	chmod 000 templates/base.txt
	build_expect_fail_within 10
	local built=$?
	chmod 644 templates/base.txt
	[ $built -eq 0 ] || return
	assert_out_grep "cannot read templates/base.txt"
	assert_no_file build/2026/08/06/hello.html
	assert_no_file build/index.html
}

test_unreadable_rss_item_template_fails_the_build() {
	sandbox unreadable_rss_item_template
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Real body content.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	chmod 000 templates/rss-item.txt
	build_expect_fail_within 10
	local built=$?
	chmod 644 templates/rss-item.txt
	[ $built -eq 0 ] || return
	assert_out_grep "cannot read templates/rss-item.txt"
	assert_no_file work/2026-08-06-home_hello.rssitem
}

test_unreadable_rss_template_fails_the_build() {
	sandbox unreadable_rss_template
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Real body content.</p>
EOF
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	chmod 000 templates/rss.txt
	build_expect_fail_within 10
	local built=$?
	chmod 644 templates/rss.txt
	[ $built -eq 0 ] || return
	assert_out_grep "cannot read templates/rss.txt"
	assert_no_file build/rss.xml
}

#
# ---------------------------------------------------
# Deleted templates. templates/post.txt and
# templates/rss-item.txt are named only in pattern rules,
# so under make's pattern search they are not files
# that "ought to exist": delete one and the %.tmp or
# %.rssitem rule simply becomes inapplicable, the stale
# fragment already in work/ is taken as-is with no
# dependency check, and the build exits 0 serving the old
# body. base.txt and rss.txt hard-error in the same state
# only because they are also prerequisites of the explicit
# build/index.html and build/rss.xml rules.
#
# Naming both in build's prerequisite list gives them that
# same standing. These two tests are the guard.
# ---------------------------------------------------
#

test_deleted_post_template_fails_the_build() {
	sandbox deleted_post_template
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>First body.</p>
EOF
	build || return
	assert_grep build/2026/08/06/hello.html "First body."

	sleep 1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Second body.</p>
EOF
	rm templates/post.txt
	build_expect_fail || return
	assert_out_grep "templates/post.txt"
	# build_expect_fail above is what detects the bug. These
	# two do not -- the stale body sits there either way, and
	# the old code reached them by reporting success. They are
	# here for a different failure: a build that fails *and*
	# leaves the already-published page damaged or gone.
	assert_grep build/2026/08/06/hello.html "First body."
	assert_not_grep build/2026/08/06/hello.html "Second body."
}

test_deleted_rss_item_template_fails_the_build() {
	sandbox deleted_rss_item_template
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>First body.</p>
EOF
	build || return
	assert_grep build/rss.xml "First body."

	sleep 1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Second body.</p>
EOF
	rm templates/rss-item.txt
	build_expect_fail || return
	assert_out_grep "templates/rss-item.txt"
	# Same as above: these two guard the damaged-page case,
	# not the silent-stale one build_expect_fail catches.
	assert_grep build/rss.xml "First body."
	assert_not_grep build/rss.xml "Second body."
}

#
# ---------------------------------------------------
# The page title comes from the front matter only.
#
# PARSE_FRONT_MATTER stops at the delimiter; the sed that
# composes PAGE_TITLE has to stop there too, or a body line
# beginning "title:" becomes the page's <title> while its
# <h4> renders empty -- which is exactly what a post about
# grampa's own post format contains.
# ---------------------------------------------------
#

test_body_title_line_is_not_the_page_title() {
	sandbox body_title_line
	add_post 2026-08-06-home_untitled.txt <<'EOF'
-----------------------------------
<p>Front matter looks like this:</p>
title: Sneaky
EOF
	build || return
	assert_grep build/2026/08/06/untitled.html "<title>My Weblog</title>"
	assert_not_grep build/2026/08/06/untitled.html "<title>Sneaky"
}

#
# ---------------------------------------------------
# A post filename is the only metadata store, so a
# degenerate one has nowhere to fail safely. These
# cover the character half; the date half is below.
# ---------------------------------------------------
#

#
# The bug this whole change exists for. posts/..._a[b]c.txt
# beside posts/..._abc.txt builds at exit 0 today and ships
# the SIBLING's body under the bracket name, because $< is
# unquoted in the %.staged recipe and the shell glob-expands
# it onto the neighbour before awk ever sees the file.
#
# The load-bearing assertion is the assert_no_file on the
# bracket page: a build that merely fails for some other
# reason would satisfy build_expect_fail on its own.
#
test_glob_character_slug_is_rejected() {
	sandbox glob_character_slug_is_rejected
	add_post '2026-01-02-home_abc.txt' <<'EOF'
title: Sibling ABC
-----------------------------------
<p>SIBLING BODY</p>
EOF
	add_post '2026-01-02-home_a[b]c.txt' <<'EOF'
title: Bracket
-----------------------------------
<p>BRACKET BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-01-02-home_a[b]c.txt'
	assert_no_file 'build/2026/01/02/a[b]c.html'
	assert_no_file 'build/2026/01/02/abc.html'
}

#
# Four representative metacharacters, each alone in its own
# sandbox. THREE OF THE FOUR ALREADY FAIL TODAY -- ' exits 2
# with "usage: cp", $ with "no post in posts/ builds this
# page", and ; with "No rule to make target" -- so an
# assertion on exit status alone would pass against the
# buggy code and guard nothing. Assert the new message.
# Only a*c alone builds at exit 0 today.
#
test_shell_metacharacter_slug_is_rejected() {
	local i=0
	for slug in "a'c" 'a*c' 'a$c' 'a;c'; do
		i=$((i + 1))
		sandbox "shell_metacharacter_slug_is_rejected_$i"
		add_post "2026-01-02-home_${slug}.txt" <<'EOF'
title: Meta
-----------------------------------
<p>META BODY</p>
EOF
		build_expect_fail || continue
		assert_out_grep "posts/2026-01-02-home_${slug}.txt"
		assert_out_grep 'illegal character'
	done
}

#
# CANNOT FAIL BEFORE THE CHANGE. This is the guard on
# BAD_CHARS itself: cafe-with-an-accent, an uppercase slug,
# and a dotted slug all build correctly today and must keep
# doing so. It is the test most likely to catch a later
# over-eager edit to the character list.
#
test_unusual_but_safe_slug_still_builds() {
	sandbox unusual_but_safe_slug_still_builds
	add_post '2026-01-02-home_café.txt' <<'EOF'
title: Accented
-----------------------------------
<p>ACCENT BODY</p>
EOF
	add_post '2026-01-03-home_Hello.txt' <<'EOF'
title: Capitalised
-----------------------------------
<p>CAPITAL BODY</p>
EOF
	add_post '2026-01-04-home_Hello.World.txt' <<'EOF'
title: Dotted
-----------------------------------
<p>DOTTED BODY</p>
EOF
	build || return
	assert_grep 'build/2026/01/02/café.html' 'ACCENT BODY'
	assert_grep 'build/2026/01/03/Hello.html' 'CAPITAL BODY'
	assert_grep 'build/2026/01/04/Hello.World.html' 'DOTTED BODY'
}

#
# posts/2026-01-02-home_.txt passes every shape clause --
# .txt satisfies the has-a-category-word test and home
# satisfies category_slug -- and publishes
# build/2026/01/02/.html, a dotfile no server will serve and
# no ls will show. Found by review. The sibling
# of the empty-category clause, and it wants the same
# treatment.
#
test_empty_title_slug_is_rejected() {
	sandbox empty_title_slug_is_rejected
	add_post '2026-01-02-home_.txt' <<'EOF'
title: Nameless
-----------------------------------
<p>NAMELESS BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-01-02-home_.txt'
	assert_out_grep 'empty title slug'
	assert_no_file 'build/2026/01/02/.html'
}

#
# ---------------------------------------------------
# Control characters. These fall outside BAD_CHARS' own
# taxonomy -- a control byte is neither a letter, a digit,
# ASCII punctuation, nor a non-ASCII byte -- and cannot be
# elements of a make list at all, so they are checked by a
# separate grep over the directory rather than by a clause
# of check_post_name.
# ---------------------------------------------------
#

#
# A control byte in a slug built today at exit 0 and landed
# in the URL: build/2026/01/02/a<0x01>c.html, control byte
# and all. Not shell-hazardous -- no globbing, no word
# splitting -- so the sibling-body bug that motivated
# BAD_CHARS stayed closed and this was a policy gap rather
# than a reopened hole.
#
# The load-bearing assertion is that no page was published
# under the byte's name, not merely that the build failed.
#
test_control_character_slug_is_rejected() {
	sandbox control_character_slug_is_rejected
	add_post "$(printf '2026-01-02-home_a\001c.txt')" <<'EOF'
title: Control
-----------------------------------
<p>CONTROL BODY</p>
EOF
	add_post '2026-01-03-home_ok.txt' <<'EOF'
title: Fine
-----------------------------------
<p>FINE BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'control character in filename'
	assert_out_grep 'posts/2026-01-02-home_a^Ac.txt'
	assert_no_file "build/2026/01/02/$(printf 'a\001c').html"
	assert_no_file 'build/2026/01/03/ok.html'
}

#
# A tab ALREADY failed before this check existed, so an
# assertion on exit status alone would pass against the
# behaviour being fixed and guard nothing. What was wrong
# was the message: POST_NAMES word-splits on the tab and
# check_post_name then judges the fragments, so the build
# said "posts/c.txt: no category in filename" -- naming a
# file that does not exist, for a reason that is not the
# reason. Assert the text, both halves.
#
# This also pins the check's POSITION, and pins it harder
# than first written. Moved below CHECKED_POST_NAMES, the
# fragment $(error) aborts the parse before the relocated
# check runs at all, so the control message never appears
# and BOTH assertions fail -- not just the second, as an
# earlier version of this comment predicted. Verified by
# making that exact move.
#
# The first assertion carries the posts/ prefix on purpose.
# Without it, dropping $(addprefix posts/,...) from
# CHECKED_CONTROL_CHARS is a mutant that survives the whole
# suite -- found by review, at 271 passing.
#
test_tab_in_filename_names_the_whole_file() {
	sandbox tab_in_filename_names_the_whole_file
	add_post "$(printf '2026-01-02-home_a\tc.txt')" <<'EOF'
title: Tabbed
-----------------------------------
<p>TAB BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-01-02-home_a^Ic.txt'
	assert_out_not_grep 'no category in filename'
}

#
# DEL is the one control character outside the 0x00-0x1F
# run, so a hand-written character class that stopped at
# 0x1F would pass the 0x01 test above and fail this one.
# That is the whole reason it is separate.
#
test_del_character_slug_is_rejected() {
	sandbox del_character_slug_is_rejected
	add_post "$(printf '2026-01-02-home_a\177c.txt')" <<'EOF'
title: Delete
-----------------------------------
<p>DEL BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'control character in filename'
	assert_out_grep 'posts/2026-01-02-home_a^?c.txt'
	assert_no_file "build/2026/01/02/$(printf 'a\177c').html"
}

#
# CANNOT FAIL BEFORE THE CHANGE. It guards the new check's
# false-positive surface: any edit that widens the grep
# pattern, or breaks the pipeline into matching everything,
# fails here.
#
# It does NOT guard the LC_ALL=C pin, and must not be read
# as doing so. The spec review swept all 288 locales
# installed on the development machine against a corpus of
# exactly these names plus 0x01, 0x7F, and tab: zero locales
# differ from the LC_ALL=C reference, en_US.ISO8859-1
# included. APFS also rejects invalid UTF-8 filenames
# outright, so the continuation-byte hazard cannot reach the
# grep here at all. LC_ALL=C stays as a pin by principle,
# the same standing rfc822_from_filename's has -- both are
# about environments this machine cannot reproduce.
#
# Multibyte names on purpose, rather than repeating
# test_unusual_but_safe_slug_still_builds' ASCII set: a
# byte-oriented grep is likeliest to trip on multibyte
# input, which is a different false-positive surface from
# the one BAD_CHARS has.
#
test_ordinary_filenames_survive_the_control_check() {
	sandbox ordinary_filenames_survive_the_control_check
	add_post '2026-01-02-home_café.txt' <<'EOF'
title: Accented
-----------------------------------
<p>ACCENT BODY</p>
EOF
	add_post '2026-01-03-home_日本語.txt' <<'EOF'
title: CJK
-----------------------------------
<p>CJK BODY</p>
EOF
	add_post '2026-01-04-home_🎉party.txt' <<'EOF'
title: Emoji
-----------------------------------
<p>EMOJI BODY</p>
EOF
	build || return
	assert_grep 'build/2026/01/02/café.html' 'ACCENT BODY'
	assert_grep 'build/2026/01/03/日本語.html' 'CJK BODY'
	assert_grep 'build/2026/01/04/🎉party.html' 'EMOJI BODY'
}

#
# The control check and POST_NAMES share one listing,
# POST_LS, and the whole argument for that sharing is that
# the two cannot drift about which files count as posts.
# Nothing tested it: severing the sharing -- giving the
# check its own `ls posts` without the .txt filter -- passed
# the entire suite at 274. Found by the whole-branch review,
# and the same class as the addprefix mutant closed at 271.
#
# posts/ is the author's directory, not grampa's, so an
# editor backup or a scratch file with an odd byte in its
# name is a thing that happens. It is not a post, POST_NAMES
# does not see it, and the check must not either.
#
# This guards the harmless direction of the drift. The
# dangerous direction -- a listing that MISSES posts -- is
# already covered by the three rejection tests above, which
# is why this one is a false-positive guard rather than a
# hole. Watched failing against the severed-listing mutant.
#
test_control_check_ignores_non_post_files() {
	sandbox control_check_ignores_non_post_files
	add_post '2026-01-02-home_ok.txt' <<'EOF'
title: Fine
-----------------------------------
<p>FINE BODY</p>
EOF
	: > "posts/$(printf 'notes\001.bak')"
	build || return
	assert_grep 'build/2026/01/02/ok.html' 'FINE BODY'
}

#
# static/ filenames are checked with a deliberately narrower
# set than posts use: only what breaks a make list, a make
# target name, or an unquoted shell word. logo@2x.png is a
# legal asset name and must keep building.
#
test_bad_character_in_a_static_name_fails() {
	sandbox static_bad_char
	mkdir -p static
	: > 'static/a:b.css'
	build_expect_fail || return
	assert_out_grep "bad character in static filename"
	assert_out_grep "static/a:b.css"
}

test_space_in_a_static_name_fails() {
	sandbox static_space
	mkdir -p static
	: > 'static/my photo.png'
	build_expect_fail || return
	assert_out_grep "bad character in static filename"
	assert_out_grep "static/my photo.png"
}

#
# Rendered through cat -vt, so the byte reaches the terminal
# as ^A rather than raw. Same trade CONTROL_CHAR_NAMES makes.
#
test_control_character_in_a_static_name_fails() {
	sandbox static_control
	mkdir -p static
	: > "$(printf 'static/ctrl\001x.css')"
	build_expect_fail || return
	assert_out_grep "bad character in static filename"
	assert_out_grep 'static/ctrl^Ax.css'
}

#
# The hole the posts checks still have. A newline is
# invisible to a line-based grep -- find prints the name as
# two lines and neither matches -- so the existence check is
# what catches it. Its message names a fragment, because a
# fragment is all there is to name.
#
test_newline_in_a_static_name_fails() {
	sandbox static_newline
	mkdir -p static
	: > "$(printf 'static/nl\nx.css')"
	build_expect_fail || return
	assert_out_grep "splits a make list"
	assert_out_grep "static/nl"
}

#
# The converse, and the reason the set is not BAD_CHARS:
# every one of these is legal and must not error.
#
test_legal_static_names_are_accepted() {
	sandbox static_legal_names
	mkdir -p static/img
	: > 'static/logo@2x.png'
	: > 'static/style,min.css'
	: > 'static/a+b.css'
	: > 'static/café.jpg'
	: > 'static/x~y.css'
	: > 'static/img/deep.svg'
	build || return
	assert_out_not_grep "bad character in static filename"
}

test_static_file_is_copied() {
	sandbox static_copy
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	mkdir -p static
	echo "body{color:red}" > static/style.css
	build || return
	assert_file build/style.css
	assert_grep build/style.css "body{color:red}"
	assert_file build/2026/08/06/hello.html
}

test_static_subdirectory_is_preserved() {
	sandbox static_subdir
	mkdir -p static/img/deep
	echo "svg" > static/img/deep/x.svg
	build || return
	assert_file build/img/deep/x.svg
	assert_grep build/img/deep/x.svg "svg"
}

#
# Doubles as the .SECONDARY / intermediate-reaping guard:
# a reaped copy would be re-made every build.
#
test_static_file_is_not_recopied_when_unchanged() {
	sandbox static_incremental
	mkdir -p static
	echo "a" > static/style.css
	build || return
	assert_out_grep "Copying build/style.css"
	build || return
	assert_out_not_grep "Copying build/style.css"
}

test_changed_static_file_is_recopied() {
	sandbox static_changed
	mkdir -p static
	echo "a" > static/style.css
	build || return
	sleep 1
	echo "b" > static/style.css
	build || return
	assert_out_grep "Copying build/style.css"
	assert_grep build/style.css "b"
}

#
# The bug a plain $(BUILD_DIR)% pattern rule had: %.html beat
# it for build/about.html -- its prerequisites all exist --
# and the unknown-page guard fired with a message about
# posts. /about.html and the /404.html GitHub Pages wants at
# the root both failed. The static pattern rule does not
# compete on stem length at all.
#
test_static_html_page_is_published() {
	sandbox static_html_page
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	mkdir -p static
	echo "<h1>About</h1>" > static/about.html
	build || return
	assert_file build/about.html
	assert_grep build/about.html "<h1>About</h1>"
	assert_out_not_grep "no post in posts/ builds this page"
}

test_static_html_page_in_category_dir_is_published() {
	sandbox static_html_category
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	mkdir -p static/category
	echo "<h1>Extra</h1>" > static/category/extra.html
	build || return
	assert_file build/category/extra.html
	assert_grep build/category/extra.html "<h1>Extra</h1>"
	assert_file build/category/home.html
}

test_static_collision_with_index_fails() {
	sandbox static_collide_index
	mkdir -p static
	echo "<h1>Mine</h1>" > static/index.html
	build_expect_fail || return
	assert_out_grep "both build build/index.html"
	assert_out_grep "rename or remove"
}

#
# rss.xml is a reserved path whether or not the feed is
# currently built. Gating this on FEED_PAGES would accept the
# file today and break the build on the day url= gets set --
# a failure whose cause was added weeks earlier. No url= here
# on purpose.
#
test_static_collision_with_the_feed_fails_without_url() {
	sandbox static_collide_feed
	mkdir -p static
	echo "nope" > static/rss.xml
	build_expect_fail || return
	assert_out_grep "both build build/rss.xml"
}

test_static_collision_with_a_post_page_fails() {
	sandbox static_collide_post
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	mkdir -p static/2026/08/06
	echo "<h1>Impostor</h1>" > static/2026/08/06/hello.html
	build_expect_fail || return
	assert_out_grep "both build build/2026/08/06/hello.html"
}

#
# The silent one. static/2026 beside a 2026-dated post: the
# first serial build exits 0 having never published the file
# -- build/2026/ exists as a directory newer than the source,
# so make judges the target up to date -- and after a touch,
# cp copies INTO the directory and lands at build/2026/2026.
# Exit 0 both times. Under -j4 it is a race-dependent mkdir
# failure instead.
#
test_static_file_shadowing_a_page_directory_fails() {
	sandbox static_shadow_dir
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	mkdir -p static
	echo "nope" > static/2026
	build_expect_fail || return
	assert_out_grep "same path as a directory generated pages live in"
	assert_out_grep "build/2026"
}

test_static_directory_named_for_a_page_fails() {
	sandbox static_under_page
	mkdir -p static/index.html
	echo "nope" > static/index.html/x.css
	build_expect_fail || return
	assert_out_grep "same path as a generated page"
	assert_out_grep "build/index.html"
}

#
# The near-misses that must NOT fire. filter's % is anchored
# by the /, so these are clean -- if either errors, the
# collision filters have lost their anchor.
#
test_static_names_near_a_generated_page_are_fine() {
	sandbox static_near_miss
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	mkdir -p static/2026/08/06
	echo "a" > static/2026/08/06/hello.htmlx
	echo "b" > static/categoryextra.css
	build || return
	assert_file build/2026/08/06/hello.htmlx
	assert_file build/categoryextra.css
	assert_file build/2026/08/06/hello.html
}

#
# The placement constraint, pinned rather than commented --
# the sibling of test_character_error_precedes_the_date_error.
# A name bad in BOTH ways must get the character message. The
# collision guards must sit below CHECKED_STATIC_CHARS: a
# space-bearing name word-splits STATIC_PAGES into a bogus
# extra word (false exact-collision match), and a % in a name
# would corrupt the $(s)/% and $(g)/% filter patterns the
# shadow/under-page guards use.
#
# The fixture is 'static/index.html x' and the space is the
# whole point. This test shipped with static/index:x.html,
# which is bad in ONE way only -- it collides with nothing,
# since build/index:x.html is not a page grampa builds -- so
# it passed under both orderings and pinned nothing. Moving
# the GENERATED_PAGES block above the character check left
# the suite at 419/0. With the space, the same mutation
# splits the listing into `static/index.html` and `x`,
# STATIC_PAGES gets build/index.html, and the mutated
# Makefile dies at CHECKED_STATIC_EXACT with "static file and
# a generated page both build build/index.html" while the
# real one dies at the character check. Proved by mutation in
# both directions.
#
# The second sandbox keeps the old : fixture for what it does
# pin: the OTHER placement constraint, character-check above
# the copy rule. Verified by moving the collision block below
# the copy rule -- the : still dies at the character check
# with the good message, since that check did not move; the
# "target pattern contains no '%'" failure a below-the-copy-
# rule placement was once thought to risk does not occur, and
# crediting it to this ordering was wrong.
#
test_static_character_error_precedes_the_collision_error() {
	sandbox static_check_order
	mkdir -p static
	: > 'static/index.html x'
	build_expect_fail || return
	assert_out_grep "bad character in static filename"
	assert_out_not_grep "static file and a generated page both build"

	sandbox static_check_order_colon
	mkdir -p static
	: > 'static/index:x.html'
	build_expect_fail || return
	assert_out_grep "bad character in static filename"
	assert_out_not_grep "target pattern contains no"
}

#
# find static (no slash) prints only the symlink, so
# STATIC_PAGES got the literal word `static`, which exists,
# and the build exited 0 having copied nothing.
#
test_symlinked_static_directory_is_published() {
	sandbox static_symlink
	mkdir -p assets
	echo "body{color:blue}" > assets/style.css
	# From Task 4 on, setup already created a real static/
	# directory; ln -s against it would nest a self-looping
	# static/assets -> assets inside it instead of replacing it.
	rm -rf static
	ln -s assets static
	build || return
	assert_file build/style.css
	assert_grep build/style.css "body{color:blue}"
}

#
# The listing was `find static/ ! -type d`, which admitted a
# FIFO, and cp on a FIFO blocks on a writer that never comes:
# `mkfifo static/pipe && make` hung forever, in serial and
# under -j8, killed at 20s both times. make -n was fine, so it
# was recipe-time. This is the failure class the getline
# guards and the two cats' /dev/null already close everywhere
# else.
#
# build_expect_fail_within for the same reason the unreadable-
# template tests use it: a plain build_expect_fail against an
# unguarded hang blocks the whole suite rather than failing
# one test.
#
# It asserts LOUD, not skipped-in-silence. Narrowing the
# listing alone would trade the hang for a static/ that does
# not publish in full and says so nowhere -- the silent wrong
# output this program refuses everywhere else -- so
# CHECKED_STATIC_TYPES names the entry and stops.
#
# The symlink half is a second case, not decoration: the
# listing deliberately keeps symlinks (a symlinked asset must
# still publish), so a link to a FIFO hangs cp identically,
# and only the find -L in the type check sees through it.
#
test_fifo_in_static_does_not_hang() {
	sandbox static_fifo
	mkfifo static/pipe
	build_expect_fail_within 10
	local built=$?
	# Sandboxes are kept after the run, and a leftover FIFO
	# is a trap for anything that later walks the tree
	# without special-file handling -- the same courtesy the
	# unreadable-template tests pay with their chmod 644.
	rm -f static/pipe
	[ $built -eq 0 ] || return
	assert_out_grep "cannot be published"
	assert_out_grep "static/pipe"
	assert_no_file build/pipe

	sandbox static_fifo_symlink
	mkfifo "$SBOX/realpipe"
	ln -s "$SBOX/realpipe" static/lpipe
	build_expect_fail_within 10
	built=$?
	rm -f static/lpipe "$SBOX/realpipe"
	[ $built -eq 0 ] || return
	assert_out_grep "cannot be published"
	assert_out_grep "static/lpipe"
	assert_no_file build/lpipe
}

#
# { } and , are legal under the minimal set, and brace-expand
# in an unquoted cp. This is UNIVERSAL coverage, not the
# host-conditional coverage this comment used to claim: make
# runs recipes with $(SHELL), and the Makefile sets
# SHELL := /bin/bash unconditionally, so the recipe shell is
# bash whatever /bin/sh happens to be. Verified with a probe
# recipe printing $0 and $BASH_VERSION, and by repointing
# SHELL and watching $0 follow it rather than staying
# /bin/sh. The old wording invited someone to discount a
# guard that is actually solid.
#
test_brace_in_a_static_name_builds() {
	sandbox static_brace
	mkdir -p static
	echo "b" > 'static/x{1,2}y.css'
	build || return
	assert_file 'build/x{1,2}y.css'
}

test_build_works_without_a_static_directory() {
	sandbox static_absent
	# From Task 4 on, sandbox() runs setup, which now seeds
	# static/ with the stock stylesheet -- remove it so this
	# test still exercises what its name says: a build with no
	# static/ at all.
	rm -rf static
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/2026/08/06/hello.html
	assert_no_file build/style.css
}

test_setup_creates_static_with_the_stylesheet() {
	sandbox static_setup
	assert_file static/style.css
	assert_grep static/style.css "font-family"
}

#
# setup is safe to re-run -- the yes n | cp -i guarantee that
# templates/ has. An edited stylesheet must survive.
#
test_setup_does_not_clobber_an_edited_stylesheet() {
	sandbox static_setup_noclobber
	echo "body{color:hotpink}" > static/style.css
	"$MAKE" setup >/dev/null 2>&1
	assert_grep static/style.css "hotpink"
}

test_stock_stylesheet_is_published_and_linked() {
	sandbox static_stylesheet_published
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/style.css
	assert_grep build/index.html '<link rel="stylesheet" href="/style.css">'
	assert_grep build/2026/08/06/hello.html '<link rel="stylesheet" href="/style.css">'
}

#
# ---------------------------------------------------
# The date half. date -v already rejects every bad date
# below and exits 1; nothing hears it, because
# date_from_filename is a $(shell) call, which keeps the
# output and throws the status away. So today these all
# publish a page with an empty posted-on line and an empty
# <pubDate>.
# ---------------------------------------------------
#

test_out_of_range_date_is_rejected() {
	sandbox out_of_range_date_is_rejected
	add_post '2026-13-40-home_bad.txt' <<'EOF'
title: Bad Date
-----------------------------------
<p>BAD DATE BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-13-40-home_bad.txt'
	assert_no_file 'build/2026/13/40/bad.html'
}

#
# Two names, and the second is the one that matters. In
# 20xx-ab-cd every field is malformed, so the month clause
# rejects it and the year clause is never isolated -- delete
# the year clause entirely and this name is still caught.
# 20xx-01-02 has a valid month and day, so only the year
# clause can reject it. Found by the whole-branch review.
#
test_non_numeric_date_is_rejected() {
	sandbox non_numeric_date_is_rejected
	add_post '20xx-ab-cd-home_x.txt' <<'EOF'
title: Not A Date
-----------------------------------
<p>NON NUMERIC BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/20xx-ab-cd-home_x.txt'
	assert_no_file 'build/20xx/ab/cd/x.html'

	sandbox non_numeric_year_only
	add_post '20xx-01-02-home_x.txt' <<'EOF'
title: Bad Year Only
-----------------------------------
<p>BAD YEAR BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/20xx-01-02-home_x.txt'
	assert_no_file 'build/20xx/01/02/x.html'
}

#
# Separate from the out-of-range test on purpose: this is
# the case stage one alone would miss, since 30 is inside
# any plausible day range. A future contributor who deletes
# stage two as a fork-saving tidy-up should be told so by a
# test rather than by the spec.
#
test_impossible_calendar_date_is_rejected() {
	sandbox impossible_calendar_date_is_rejected
	add_post '2026-02-30-home_feb.txt' <<'EOF'
title: No Such Day
-----------------------------------
<p>FEB THIRTY BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-02-30-home_feb.txt'
	assert_no_file 'build/2026/02/30/feb.html'
}

#
# Leap-year exactness, which is the sharpest thing
# distinguishing stage two from a day-range check. 2026 is
# not a leap year.
#
test_non_leap_february_29_is_rejected() {
	sandbox non_leap_february_29_is_rejected
	add_post '2026-02-29-home_feb.txt' <<'EOF'
title: Not A Leap Year
-----------------------------------
<p>FEB TWENTYNINE BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-02-29-home_feb.txt'
	assert_no_file 'build/2026/02/29/feb.html'
}

#
# date -v accepts enormous years and then stops, so a
# prefilter that checks "all digits" without bounding the
# length clears this name, never sends it to date, and
# publishes /999999999999/01/02/x.html with an empty
# posted-on line. Found at the plan review against exactly
# that prefilter. This is the guard on YEAR_SHAPES upper
# bound.
#
# Note the cliff is a bound on the year's VALUE, not its
# digit count -- 100000000000 is accepted and 999999999999
# is not, both twelve digits -- so this asserts on a name
# date really does reject rather than on a digit count.
#
test_absurdly_long_year_is_rejected() {
	sandbox absurdly_long_year_is_rejected
	add_post '999999999999-01-02-home_x.txt' <<'EOF'
title: Long Year
-----------------------------------
<p>LONG YEAR BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/999999999999-01-02-home_x.txt'
	assert_no_file 'build/999999999999/01/02/x.html'
}

#
# CANNOT FAIL BEFORE THE CHANGE. Unpadded dates are
# documented as supported and are the likeliest thing an
# over-strict date check would break. The five-digit year is
# here because YEAR_SHAPES stops at five, so it is the
# boundary case -- though note the assertion cannot see
# WHICH stage let it through, only that it built.
#
test_unpadded_date_still_builds() {
	sandbox unpadded_date_still_builds
	add_post '2026-7-4-home_unpadded.txt' <<'EOF'
title: Unpadded
-----------------------------------
<p>UNPADDED BODY</p>
EOF
	add_post '99999-1-1-home_faryear.txt' <<'EOF'
title: Far Year
-----------------------------------
<p>FAR YEAR BODY</p>
EOF
	build || return
	assert_grep 'build/2026/7/4/unpadded.html' 'UNPADDED BODY'
	assert_grep 'build/99999/1/1/faryear.html' 'FAR YEAR BODY'
}

#
# CANNOT FAIL BEFORE THE CHANGE. The guard on the prefilter
# boundary: all three of these are days stage one declines
# to clear, so this is the only test exercising stage two
# ACCEPT path. Without it, a stage two that rejected
# everything it was asked about would pass the whole suite.
# 2028 is a leap year.
#
test_month_end_dates_still_build() {
	sandbox month_end_dates_still_build
	add_post '2026-01-31-home_jan.txt' <<'EOF'
title: End Of January
-----------------------------------
<p>JAN THIRTYONE BODY</p>
EOF
	add_post '2026-04-30-home_apr.txt' <<'EOF'
title: End Of April
-----------------------------------
<p>APR THIRTY BODY</p>
EOF
	add_post '2028-02-29-home_leap.txt' <<'EOF'
title: Leap Day
-----------------------------------
<p>LEAP DAY BODY</p>
EOF
	build || return
	assert_grep 'build/2026/01/31/jan.html' 'JAN THIRTYONE BODY'
	assert_grep 'build/2026/04/30/apr.html' 'APR THIRTY BODY'
	assert_grep 'build/2028/02/29/leap.html' 'LEAP DAY BODY'
}

#
# The Makefile comment above the date check says it must
# stay below CHECKED_POST_NAMES, because its $(shell)
# interpolates filenames unquoted and a name carrying $( or
# a backtick executes during the parse. Nothing enforced
# that. Found by review: with the two checks
# swapped, all eleven other character and date tests still
# passed, because each of them uses a name that is bad in
# exactly one way and so never observes which check fires.
#
# This name is bad in both ways at once. Correct order says
# "illegal character"; swapped order says "no such calendar
# date". No live payload needed to pin it.
#
test_character_error_precedes_the_date_error() {
	sandbox character_error_precedes_the_date_error
	add_post '2026-02-30-ho!me_x.txt' <<'EOF'
title: Both Wrong
-----------------------------------
<p>BOTH WRONG BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'illegal character'
	assert_out_not_grep 'no such calendar date'
}

#
# ---------------------------------------------------
# all and clean must be phony. Both are named after
# nothing on disk, but make does not know that: create a
# file with either name -- a stray shell redirect, a
# `touch clean` -- and make finds the target up to date
# and runs no recipe at all.
#
# Only the clean case actually bites, and it bites hard,
# because it looks like it worked. The all case does not:
# all's prerequisite `build` is phony and so always out of
# date, which drags all along with it. That test therefore
# passes with and without .PHONY: all -- it is a guard
# against build ever losing its own declaration, not a
# reproduction of a live bug.
# ---------------------------------------------------
#

test_clean_works_with_a_file_named_clean() {
	sandbox file_named_clean
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/2026/08/06/hello.html

	touch clean
	build clean || return
	assert_no_file build/2026/08/06/hello.html
	assert_no_file work/2026-08-06-home_hello.tmp
}

#
# make clean && make deploy handed deploy.sh an empty
# build/ -- 0 entries, exit 0, no warning. deploy.sh is
# user-supplied and the example is an rsync; a --delete in
# it turns that sequence into "unpublish the site".
#
# The stub records what it was handed rather than asserting
# inside itself, so a failure shows the real listing. make's
# own output goes to files rather than /dev/null for the
# same reason: if the green path ever regresses before
# deploy.sh runs, an empty deployed.txt and nothing else is
# a FAIL nobody can diagnose.
#
test_deploy_builds_first() {
	sandbox deploy_builds_first
	add_post '2026-01-02-home_d.txt' <<'EOF'
title: Deployed
-----------------------------------
<p>DEPLOY BODY</p>
EOF
	cat > deploy.sh <<'EOF'
#!/bin/sh
ls "$1" > deployed.txt
EOF
	chmod +x deploy.sh
	build || return
	"$MAKE" clean > deploy-clean.out 2>&1
	"$MAKE" deploy > deploy-make.out 2>&1
	assert_file deployed.txt
	assert_grep deployed.txt 'index.html'
}

test_default_build_works_with_a_file_named_all() {
	sandbox file_named_all
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	touch all
	build || return
	assert_file build/2026/08/06/hello.html
	assert_file build/index.html
}

#
# sandbox() must pin detection off regardless of what the
# developer has installed, or the whole suite's output
# depends on their laptop. Non-executable placeholders do
# not shadow a real tool -- PATH lookup skips them -- so
# the stubs must be executable and exit non-zero.
#
test_sandbox_hides_host_markdown_tools() {
	sandbox sandbox_hides_tools
	for t in lowdown cmark cmark-gfm md2html comrak multimarkdown markdown smu markdown_py markdown-it pandoc; do
		if [ -x "bin/$t" ]; then ok; else fail "expected a stub for $t"; fi
		if "./bin/$t" /dev/null >/dev/null 2>&1; then fail "stub $t must exit non-zero"; else ok; fi
	done
	assert_eq "PATH is prefixed with the sandbox bin" "$SBOX/bin" "${PATH%%:*}"
}

#
# ---------------------------------------------------
# make new: the post generator.
#
# The feature's whole value is an invariant: it must be
# incapable of emitting a filename any of the five
# parse-time checks rejects. Most of these tests are that
# invariant from one side or another.
# ---------------------------------------------------
#

test_new_requires_a_title() {
	sandbox new_requires_a_title
	build_expect_fail new CATEGORY=home || return
	assert_out_grep "TITLE"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

test_new_requires_a_category() {
	sandbox new_requires_a_category
	build_expect_fail new TITLE="Hello there" || return
	assert_out_grep "CATEGORY"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

#
# new joins NONBUILD_GOALS, so BUILD_GOAL is empty for this
# invocation and the parse-time markdown $(info) stays
# quiet. Mutation-catchable: drop `new` from the list and
# this fails.
#
test_new_prints_no_markdown_notice() {
	sandbox new_no_notice
	build new TITLE="Hello there" CATEGORY=home || return
	assert_out_not_grep "grampa: markdown:"
	assert_out_grep "Created posts/"
}

#
# Same shape as test_clean_works_with_a_file_named_clean:
# `new` is named after nothing on disk, but make does not
# know that until .PHONY says so.
#
test_new_works_with_a_file_named_new() {
	sandbox new_file_named_new
	touch new
	build new TITLE="Hello there" CATEGORY=home || return
	assert_out_grep "Created posts/"
}

#
# The round trip. The one test that proves the invariant end
# to end rather than in pieces: whatever name new chose, the
# build accepts it and publishes the permalink it implies.
#
test_new_creates_a_post_that_builds() {
	sandbox new_round_trip
	build new TITLE="Installing a Doorbell" CATEGORY=home DATE=2026-08-06 || return
	assert_file posts/2026-08-06-home_installing-a-doorbell.txt
	assert_grep posts/2026-08-06-home_installing-a-doorbell.txt "title: Installing a Doorbell"
	assert_grep posts/2026-08-06-home_installing-a-doorbell.txt "-----------------------------------"
	build || return
	assert_file build/2026/08/06/installing-a-doorbell.html
	assert_grep build/2026/08/06/installing-a-doorbell.html "<h4>Installing a Doorbell</h4>"
	assert_file build/category/home.html
}

#
# The slug table from the spec, one assertion per class.
# Each title is run in its own sandbox because a failure
# that leaves a bad filename behind poisons every later
# make in the same directory.
#
test_new_slugifies_a_title() {
	sandbox new_slugify
	build new TITLE="Tom & Jerry: part 2" CATEGORY=home DATE=2026-01-02 || return
	assert_file posts/2026-01-02-home_tom-jerry-part-2.txt
	build new TITLE="Tom's doorbell" CATEGORY=home DATE=2026-01-03 || return
	assert_file posts/2026-01-03-home_toms-doorbell.txt
	build new TITLE="A/B testing" CATEGORY=home DATE=2026-01-04 || return
	assert_file posts/2026-01-04-home_a-b-testing.txt
	build new TITLE="Version 2.0 notes" CATEGORY=home DATE=2026-01-05 || return
	assert_file posts/2026-01-05-home_version-2.0-notes.txt
	build new TITLE="  spaced   out  " CATEGORY=home DATE=2026-01-06 || return
	assert_file posts/2026-01-06-home_spaced-out.txt
	build new TITLE="Under_scored" CATEGORY=home DATE=2026-01-07 || return
	assert_file posts/2026-01-07-home_under-scored.txt
	build || return
	assert_file build/2026/01/05/version-2.0-notes.html
}

#
# The category goes through the same pipeline, so a
# two-word category becomes the hyphenated slug the
# Makefile's category rules already understand.
#
test_new_slugifies_a_category() {
	sandbox new_slugify_category
	build new TITLE="Backup script" CATEGORY="Project Ideas" DATE=2026-01-02 || return
	assert_file posts/2026-01-02-project-ideas_backup-script.txt
	build || return
	assert_file build/category/project-ideas.html
}

#
# Non-ASCII is legal in a grampa filename, so the slugifier
# must not eat it. Every tr stage is LC_ALL=C and therefore
# bytewise, which is exactly what keeps a multi-byte
# character intact: its continuation bytes are all >= 0x80
# and cannot collide with the ASCII punctuation being
# stripped. ASCII is lowercased; É is not, because a
# bytewise tr cannot case-fold it.
#
test_new_keeps_non_ascii() {
	sandbox new_non_ascii
	build new TITLE="Café notes" CATEGORY=home DATE=2026-01-02 || return
	assert_file posts/2026-01-02-home_café-notes.txt
	build new TITLE="日記 #1" CATEGORY=home DATE=2026-01-03 || return
	assert_file posts/2026-01-03-home_日記-1.txt
	build || return
	assert_file build/2026/01/02/café-notes.html
}

#
# The hostile title. Nothing executes, and the value the
# SHELL receives lands in the front matter byte for byte --
# which is also a test of fill(), since & in a replacement is
# the bug fill() exists to avoid. "The shell receives" is
# deliberate and not "typed": $HOME below does not survive as
# typed, only as make hands it to the shell -- see the note
# further down.
#
#
# $HOME is deliberately in here too, and it does NOT survive
# as typed: TITLE is a command-line variable, so make expands
# it while building the recipe's environment -- before the
# shell that reads "$$TITLE" starts -- and $H is make's own
# reference to the (undefined) one-letter variable H, which
# vanishes and leaves OME behind. That is the same $ gotcha
# documented above the new rule (a bare $5 vanishes the same
# way), not a bug in the slugifier; verified with a two-line
# makefile that only echoes "$$TITLE", independent of this
# feature. The expected names below say "ome", not "home",
# for that reason.
#
test_new_survives_a_hostile_title() {
	sandbox new_hostile_title
	build new TITLE='Tom & "Jerry" '"'"'s $HOME `whoami` \z' CATEGORY=home DATE=2026-01-02 || return
	assert_file posts/2026-01-02-home_tom-jerry-s-ome-whoami-z.txt
	assert_grep posts/2026-01-02-home_tom-jerry-s-ome-whoami-z.txt 'Tom & "Jerry"'
	assert_grep posts/2026-01-02-home_tom-jerry-s-ome-whoami-z.txt '`whoami`'
	build || return
	assert_grep build/2026/01/02/tom-jerry-s-ome-whoami-z.html 'Tom &'
}

#
# The blocking finding of the spec review. Control bytes
# are not in BAD_CHARS and nothing else in the pipeline
# touches them, so before the [:cntrl:] stage a tab wrote a
# filename the build rejects -- and a newline wrote one that
# breaks every LATER make in the directory, which is why the
# second half of this test builds afterwards rather than
# only checking the filename.
#
test_new_strips_control_characters() {
	sandbox new_control_chars
	build new TITLE="$(printf 'Two\nlines')" CATEGORY=home DATE=2026-01-02 || return
	assert_file posts/2026-01-02-home_two-lines.txt
	build new TITLE="$(printf 'a\tb')" CATEGORY=home DATE=2026-01-03 || return
	assert_file posts/2026-01-03-home_a-b.txt
	build || return
	assert_file build/2026/01/02/two-lines.html
	assert_file build/2026/01/03/a-b.html
}

#
# The front matter is one line, so a newline in the title
# has to be flattened there too -- not only in the slug.
# Without it PARSE_FRONT_MATTER reads the tail of the title
# as something it is not.
#
test_new_keeps_the_front_matter_on_one_line() {
	sandbox new_one_line_front_matter
	build new TITLE="$(printf 'Two\nlines')" CATEGORY=home DATE=2026-01-02 || return
	assert_grep posts/2026-01-02-home_two-lines.txt "title: Two lines"
	assert_eq "front matter line count" "1" "$(grep -c '^title: ' posts/2026-01-02-home_two-lines.txt)"
	build || return
	assert_grep build/2026/01/02/two-lines.html "<h4>Two lines</h4>"
}

#
# An empty title slug never reaches the build: written
# directly it dies at PARSE time on check_post_name's
# empty-title-slug clause, before any recipe runs and before
# anything publishes -- verified against a hand-written
# posts/2026-01-02-home_.txt. An empty category dies the same
# way on the sibling clause. new refuses first instead, and
# refuses without writing, so neither of those parse-time
# deaths -- which would also poison every LATER make new in
# the same directory -- is ever reached.
#
test_new_refuses_a_title_with_no_usable_characters() {
	sandbox new_empty_title_slug
	build_expect_fail new TITLE="!!!" CATEGORY=home || return
	assert_out_grep "no usable characters"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

test_new_refuses_a_category_with_no_usable_characters() {
	sandbox new_empty_category_slug
	build_expect_fail new TITLE="Hello there" CATEGORY="???" || return
	assert_out_grep "no usable characters"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

#
# CATEGORY="-" slugifies to a non-empty "-", so the
# empty-string check above does not see it -- but the
# category is re-parsed by splitting the filename on
# hyphens, so it collapses back to empty and the build
# dies with "empty category in filename". Worse, so does
# every LATER make new, the parse failing before any recipe
# runs: the generator would have produced the one name its
# own successor cannot survive.
#
test_new_refuses_a_hyphen_only_category() {
	sandbox new_hyphen_only_category
	build_expect_fail new TITLE="Hello there" CATEGORY="-" || return
	assert_out_grep "no usable characters"
	build_expect_fail new TITLE="Hello there" CATEGORY="- -" || return
	assert_out_grep "no usable characters"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

#
# The mirror image of the hyphen-only CATEGORY refusal above:
# an all-hyphen TITLE is legitimate and must keep building.
# The category gets the stricter (post-strip) check because
# category_slug re-parses the filename on hyphens and an
# all-hyphen field collapses to zero words there; the title
# has no such re-parse -- post_slug is just "whatever survived
# after the category's _", hyphens included -- so nothing
# pins this without a test asserting the accept side too.
#
test_new_accepts_an_all_hyphen_title() {
	sandbox new_all_hyphen_title
	build new TITLE="- - -" CATEGORY=home DATE=2026-01-02 || return
	assert_file posts/2026-01-02-home_-----.txt
	build || return
	assert_file build/2026/01/02/-----.html
}

#
# Never clobber. Everything else in this Makefile copies
# with `yes n | cp -i`; this is that rule where cp is not
# what does the writing. The assertion is on the OLD
# CONTENT, not the exit status, so it fails against a
# recipe that writes first and complains after.
#
test_new_refuses_an_existing_post() {
	sandbox new_refuses_existing
	build new TITLE="Hello there" CATEGORY=home DATE=2026-01-02 || return
	printf 'title: Edited by hand\n-----------------------------------\n<p>MINE</p>\n' \
		> posts/2026-01-02-home_hello-there.txt
	build_expect_fail new TITLE="Hello there" CATEGORY=home DATE=2026-01-02 || return
	assert_out_grep "already exists"
	assert_grep posts/2026-01-02-home_hello-there.txt "MINE"
}

#
# The category is not in the URL, so two posts sharing a
# date and title slug in different categories both want
# /2026/01/02/dup.html. CHECKED_POST_PAGES errors naming
# both files; new refuses before the second one exists.
#
test_new_refuses_a_duplicate_permalink() {
	sandbox new_refuses_duplicate
	build new TITLE="Dup" CATEGORY=home DATE=2026-01-02 || return
	assert_file posts/2026-01-02-home_dup.txt
	build_expect_fail new TITLE="Dup" CATEGORY=work DATE=2026-01-02 || return
	assert_out_grep "2026-01-02-home_dup.txt"
	assert_no_file posts/2026-01-02-work_dup.txt
	build || return
	assert_file build/2026/01/02/dup.html
}

#
# category_slug re-parses the filename by splitting on
# hyphens, which drops a leading or trailing empty field the
# same way `a-`.split("-") drops its trailing "". Untrimmed,
# CATEGORY='-x' would write posts/<date>--x_t.txt -- a name
# that parses to category "x", not "-x": the filename and the
# category the post actually lands under would disagree. The
# recipe trims cslug's edge hyphens after the hyphen-only
# check runs (not before), so CATEGORY='-x', 'x-', and
# '- x -' all collapse to the same file and the same category
# page. An INTERIOR run is a different case and is left alone:
# CATEGORY='a--b' keeps "a--b" in both the filename and the
# page, matching category_slug's own handling of interior
# hyphen runs.
#
test_new_trims_edge_hyphens_from_category() {
	sandbox new_trims_edge_hyphens
	build new TITLE=T CATEGORY='-x' DATE=2026-01-02 || return
	assert_file posts/2026-01-02-x_t.txt
	build new TITLE=T2 CATEGORY='x-' DATE=2026-01-03 || return
	assert_file posts/2026-01-03-x_t2.txt
	build new TITLE=T3 CATEGORY='- x -' DATE=2026-01-04 || return
	assert_file posts/2026-01-04-x_t3.txt
	build new TITLE=T4 CATEGORY='a--b' DATE=2026-01-05 || return
	assert_file posts/2026-01-05-a--b_t4.txt
	build || return
	assert_file build/category/x.html
	assert_file build/category/a--b.html
}

#
# The dup glob can match a DIRECTORY sharing this date and
# title slug, not just another post file. Bare `ls` on a
# directory argument lists its CONTENTS, not its own name, so
# an EMPTY directory made the check see no output and new wrote
# a second, colliding file at exit 0 -- the exact duplicate
# permalink tree the check exists to refuse. `ls -d` is what
# closes it, by naming the directory itself instead of
# listing into it.
#
test_new_refuses_a_duplicate_permalink_that_is_a_directory() {
	sandbox new_refuses_duplicate_directory
	mkdir -p posts/2026-04-02-work_d.txt
	build_expect_fail new TITLE=D CATEGORY=home DATE=2026-04-02 || return
	assert_out_grep "2026-04-02-work_d.txt"
	assert_no_file posts/2026-04-02-home_d.txt
}

test_new_backdates_with_date() {
	sandbox new_backdates
	build new TITLE="Old news" CATEGORY=home DATE=2026-07-04 || return
	assert_file posts/2026-07-04-home_old-news.txt
	build || return
	assert_file build/2026/07/04/old-news.html
	assert_grep build/2026/07/04/old-news.html "July 04, 2026"
}

#
# The grammar accepts an unpadded date, so the shape check
# must too, or new would be unable to write a name the build
# accepts -- the invariant in the other direction.
#
test_new_accepts_an_unpadded_date() {
	sandbox new_unpadded_date
	build new TITLE="Fourth" CATEGORY=home DATE=2026-7-4 || return
	assert_file posts/2026-7-4-home_fourth.txt
	build || return
	assert_file build/2026/7/4/fourth.html
}

test_new_refuses_an_impossible_date() {
	sandbox new_impossible_date
	build_expect_fail new TITLE="Never" CATEGORY=home DATE=2026-02-30 || return
	assert_out_grep "2026-02-30"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

test_new_refuses_a_malformed_date() {
	sandbox new_malformed_date
	build_expect_fail new TITLE="Never" CATEGORY=home DATE=2026-02 || return
	assert_out_grep "YYYY-MM-DD"
	build_expect_fail new TITLE="Never" CATEGORY=home DATE=20xx-ab-cd || return
	assert_out_grep "YYYY-MM-DD"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

#
# date_select interpolates its argument into RECIPE TEXT,
# not into the environment, so unlike TITLE it is not
# protected by the export discipline. Under the gnu twin
# that text is -d "<date> 00:00:00" and one " escapes it.
# Verified before the fix, with the shape check removed: this
# payload created the file.
#
# The payload has no space in it on purpose. date_words/
# date_select word-split their argument and rejoin the pieces
# with a literal hyphen no matter what whitespace originally
# separated them, so a space-bearing payload like
# 'x";touch PWNED;"' becomes the single token "touch-PWNED" --
# a command that does not exist -- and never creates PWNED
# even with the shape check removed. That would make this
# test pass against genuinely vulnerable code. ">" needs no
# space to redirect, so it survives the rejoin and still
# proves the escape.
#
# The shape check is what closes it, and it has to be
# make-level: $(if) expands only the branch it takes, so a
# bad shape means date_select is never expanded with the
# payload at all.
#
test_new_does_not_execute_an_injected_date() {
	sandbox new_injected_date
	build_expect_fail new TITLE="Never" CATEGORY=home DATE='x";>PWNED;"' || return
	assert_no_file PWNED
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

#
# The default-date path expands no date helper, so it works
# on a tree that has never been set up. The DATE= path goes
# through date_select, whose else branch is the $(error), so
# it says what every other unconfigured dated thing says.
#
# The first half is the R2 test: it fails against a
# shell-guarded date_select, because make expands the whole
# recipe line before the shell sees any of it and the
# $(error) fires in a branch the shell would never have run.
#
test_new_works_without_config_mk() {
	sandbox new_no_config_mk
	rm -f config.mk
	build new TITLE="Unconfigured" CATEGORY=home || return
	assert_out_grep "Created posts/"
	if ls posts/*-home_unconfigured.txt >/dev/null 2>&1; then ok; else fail "no post written" "$(ls posts)"; fi
}

test_new_with_date_needs_config_mk() {
	sandbox new_date_no_config_mk
	rm -f config.mk
	build_expect_fail new TITLE="Unconfigured" CATEGORY=home DATE=2026-01-02 || return
	assert_out_grep "run \`make setup\` first"
	if [ -z "$(ls posts 2>/dev/null)" ]; then ok; else fail "posts/ should be empty" "$(ls posts)"; fi
}

mkdir -p "$TMPROOT"

test_builds_a_post_and_index
test_index_is_reverse_chronological_and_capped_at_ten
test_build_contains_only_html
test_zero_posts_does_not_hang
test_blog_name_from_config
test_ampersands_are_not_mangled
test_no_op_rebuild_is_quiet
test_parallel_build_is_clean
test_staged_files_persist
test_detected_processor_stages_the_body
test_no_processor_stages_verbatim
test_config_markdown_overrides_detection
test_changing_markdown_restages_posts
test_missing_override_tool_fails_the_build
test_multi_word_override_keeps_its_flags
test_hash_in_markdown_value_fails_the_rebuild
test_uninstalled_detected_processor_fails_the_build
test_stub_list_matches_the_candidate_table
test_probe_rejects_a_smartening_candidate
test_setup_names_a_rejected_candidate
test_probe_accepts_escaped_quotes
test_build_announces_the_processor
test_build_announces_no_processor
test_notice_marks_a_config_override
test_clean_and_setup_print_no_notice
test_markdown_transforms_the_body_not_the_front_matter
test_markdown_staged_file_has_no_blank_line_after_the_delimiter
test_failing_markdown_fails_the_build
test_failed_markdown_leaves_no_stale_chunks
test_markdown_branch_is_parallel_safe
test_markdown_body_reaches_the_feed
test_non_executable_markdown_falls_back_to_verbatim
test_many_delimiter_lines_stage_completely
test_same_date_sibling_slug_does_not_collide
test_post_without_delimiter_stages_cleanly
test_delimiter_on_first_line_leaves_no_stray_delimiter
test_placeholders_in_a_body_are_not_expanded
test_placeholders_in_a_title_are_not_expanded
test_placeholders_in_the_feed_are_not_expanded
test_placeholders_in_the_blog_name_are_not_expanded
test_editing_post_template_rebuilds_fragments
test_editing_base_template_rebuilds_every_page
test_rssitem_has_absolute_link_and_rfc822_date
test_rssitem_link_survives_trailing_slash_in_url
test_rssitem_escapes_title_and_body
test_no_url_means_no_feed
test_feed_is_built_when_url_is_set
test_feed_escapes_titles_and_bodies
test_feed_is_capped_at_ten_newest
test_deleting_a_post_heals_the_index
test_deleting_a_post_heals_the_category_page
test_deleting_a_post_heals_the_feed_after_incremental_growth
test_build_works_without_a_posts_directory
test_deleting_a_post_heals_the_feed
test_feed_with_zero_posts
test_feed_is_byte_stable_across_rebuilds
test_changing_url_rebuilds_the_feed
test_url_omits_the_category
test_multi_hyphen_category_parses
test_filename_without_underscore_fails
test_filename_with_two_underscores_fails
test_filename_with_empty_category_fails
test_duplicate_permalink_fails
test_same_slug_on_different_dates_is_fine
test_unknown_page_target_fails_cleanly
test_unknown_category_page_target_fails_cleanly
test_category_link_on_post_page
test_category_link_display_name_has_spaces
test_category_link_on_index
test_category_page_lists_its_posts_newest_first
test_category_pages_do_not_mix_categories
test_category_page_is_not_capped_at_ten
test_category_page_title_uses_display_name_and_blog_name
test_editing_one_category_does_not_rebuild_another
test_category_pages_are_html_only_in_build
test_migration_converts_old_posts
test_migration_skips_already_migrated_by_missing_category
test_migration_refuses_ambiguous_underscore_title
test_migration_refuses_a_non_ascii_category
test_migration_reports_error_when_rm_fails
test_base_template_advertises_the_feed
test_feed_category_uses_display_form
test_unreadable_post_template_fails_the_build
test_unreadable_base_template_fails_the_build
test_unreadable_rss_item_template_fails_the_build
test_unreadable_rss_template_fails_the_build
test_deleted_post_template_fails_the_build
test_deleted_rss_item_template_fails_the_build
test_body_title_line_is_not_the_page_title
test_clean_works_with_a_file_named_clean
test_deploy_builds_first
test_default_build_works_with_a_file_named_all
test_sandbox_hides_host_markdown_tools
test_glob_character_slug_is_rejected
test_shell_metacharacter_slug_is_rejected
test_unusual_but_safe_slug_still_builds
test_empty_title_slug_is_rejected
test_control_character_slug_is_rejected
test_tab_in_filename_names_the_whole_file
test_del_character_slug_is_rejected
test_ordinary_filenames_survive_the_control_check
test_control_check_ignores_non_post_files
test_out_of_range_date_is_rejected
test_non_numeric_date_is_rejected
test_impossible_calendar_date_is_rejected
test_non_leap_february_29_is_rejected
test_absurdly_long_year_is_rejected
test_unpadded_date_still_builds
test_month_end_dates_still_build
test_character_error_precedes_the_date_error
test_setup_writes_the_host_date_dialect
test_old_make_version_fails_the_build
test_make_version_floor_is_4_2
test_old_make_version_fails_nonbuild_goals_too
test_build_without_config_mk_fails
test_setup_bootstraps_with_a_month_end_post
test_setup_records_the_full_argv
test_setup_prefers_the_earlier_candidate
test_probe_skips_a_candidate_that_eats_raw_html
test_probe_skips_a_whole_document_candidate
test_a_truncating_candidate_does_not_poison_the_walk
test_setup_with_no_processor_records_empty
test_noop_setup_leaves_config_mk_untouched
test_config_mk_without_detected_markdown_fails_the_build
test_old_config_mk_fails_for_an_explicit_page_goal
test_setup_recovers_an_old_config_mk
test_probed_empty_config_mk_builds_fine
test_clean_works_with_an_old_config_mk
test_bad_character_in_a_static_name_fails
test_space_in_a_static_name_fails
test_control_character_in_a_static_name_fails
test_newline_in_a_static_name_fails
test_legal_static_names_are_accepted
test_static_file_is_copied
test_static_subdirectory_is_preserved
test_static_file_is_not_recopied_when_unchanged
test_changed_static_file_is_recopied
test_static_html_page_is_published
test_static_html_page_in_category_dir_is_published
test_static_collision_with_index_fails
test_static_collision_with_the_feed_fails_without_url
test_static_collision_with_a_post_page_fails
test_static_file_shadowing_a_page_directory_fails
test_static_directory_named_for_a_page_fails
test_static_names_near_a_generated_page_are_fine
test_static_character_error_precedes_the_collision_error
test_symlinked_static_directory_is_published
test_fifo_in_static_does_not_hang
test_brace_in_a_static_name_builds
test_build_works_without_a_static_directory
test_setup_creates_static_with_the_stylesheet
test_setup_does_not_clobber_an_edited_stylesheet
test_stock_stylesheet_is_published_and_linked

test_new_requires_a_title
test_new_requires_a_category
test_new_prints_no_markdown_notice
test_new_works_with_a_file_named_new
test_new_creates_a_post_that_builds
test_new_slugifies_a_title
test_new_slugifies_a_category
test_new_keeps_non_ascii
test_new_survives_a_hostile_title
test_new_strips_control_characters
test_new_keeps_the_front_matter_on_one_line
test_new_refuses_a_title_with_no_usable_characters
test_new_refuses_a_category_with_no_usable_characters
test_new_refuses_a_hyphen_only_category
test_new_accepts_an_all_hyphen_title
test_new_refuses_an_existing_post
test_new_refuses_a_duplicate_permalink
test_new_trims_edge_hyphens_from_category
test_new_refuses_a_duplicate_permalink_that_is_a_directory
test_new_backdates_with_date
test_new_accepts_an_unpadded_date
test_new_refuses_an_impossible_date
test_new_refuses_a_malformed_date
test_new_does_not_execute_an_injected_date
test_new_works_without_config_mk
test_new_with_date_needs_config_mk

pass_fail_summary
