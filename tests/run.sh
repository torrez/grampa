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
PASSED=0
FAILED=0
CURRENT=""

#
# Fresh sandbox for the test named in $1. cds into it.
#
sandbox() {
	CURRENT="$1"
	SBOX="$TMPROOT/$1"
	rm -rf "$SBOX"
	mkdir -p "$SBOX"
	cp "$REPO/Makefile" "$SBOX/"
	cp -R "$REPO/.source" "$SBOX/"
	cd "$SBOX" || exit 1
	make setup >/dev/null 2>&1
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
# so a sandbox never has one and the whole
# `if [ -x Markdown.pl ]` staging branch would otherwise
# never be executed by this suite. The stub stands in for
# it: same calling convention (one filename argument,
# transformed body on stdout).
#
markdown_stub() {
	cat > Markdown.pl
	chmod +x Markdown.pl
}

#
# Builds, capturing output. Fails the test if make
# fails. Stdin is closed so a hang shows up as an
# error rather than blocking the suite.
#
build() {
	BUILD_OUT=$(make "$@" < /dev/null 2>&1)
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
	BUILD_OUT=$(make "$@" < /dev/null 2>&1)
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
	make "$@" < /dev/null > "$out" 2>&1 &
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

assert_grep() {
	if [ ! -f "$1" ]; then
		fail "cannot grep missing file: $1"
		return
	fi
	if grep -qF "$2" "$1"; then ok; else fail "expected '$2' in $1" "$(cat "$1")"; fi
}

assert_not_grep() {
	if [ ! -f "$1" ]; then
		fail "cannot grep missing file: $1"
		return
	fi
	if grep -qF "$2" "$1"; then fail "did NOT expect '$2' in $1" "$(cat "$1")"; else ok; fi
}

#
# Assertions against the captured make output. These
# exist because process substitution gives a /dev/fd
# path that is not a regular file on macOS, so the
# file-based helpers above cannot be used on it.
#
assert_out_grep() {
	if printf '%s\n' "$BUILD_OUT" | grep -qF "$1"; then ok; else fail "expected '$1' in make output" "$BUILD_OUT"; fi
}

assert_out_not_grep() {
	if printf '%s\n' "$BUILD_OUT" | grep -qF "$1"; then fail "did NOT expect '$1' in make output" "$BUILD_OUT"; else ok; fi
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
# below. These use the CURRENT filename format and are
# rewritten in Task 2 when the format changes.
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
	assert_eq "extensions under build/" "html" "$(find build -type f | sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
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
	# Counts dated post pages only, so category pages
	# added in Task 4 do not change the expected number.
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
	markdown_stub <<'EOF'
#!/bin/sh
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
# A failed staging run leaves its split chunks in work/.
# The next build re-splits into the same namespace, but
# the reassembly collects chunks by glob -- so a post that
# now splits into fewer chunks than it did before would
# sweep the stale ones back in and republish text the
# author had deleted. Recovering from a Markdown failure
# must not resurrect content.
#
test_failed_markdown_leaves_no_stale_chunks() {
	sandbox markdown_stale_chunks
	markdown_stub <<'EOF'
#!/bin/sh
exit 1
EOF
	# Inner delimiter lines make split produce three chunks.
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
	# GNU make 3.81's mtime comparisons resolve to whole
	# seconds, so a touch landing in the same wall-clock
	# second as the first build looks "not newer" and gets
	# skipped. Same reason test_editing_one_category_does_
	# not_rebuild_another sleeps.
	sleep 1
	touch templates/post.txt
	build || return
	assert_out_grep "Building work/2026-08-06-home_hello.tmp"
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
# Guards the decision NOT to list RSSITEM_FILES in
# .SECONDARY. Adding them looks like an obvious tidy-up --
# it matches what .tmp and .staged do and it passes every
# other assertion in this file -- but it makes make tolerate
# a missing .rssitem, which suppresses the rebuild that pulls
# the next-oldest post into the window when one is deleted.
# The feed goes stale instead of healing.
#
# Deleting a post is otherwise untested. Note the heal is
# narrower than "more than ten posts": it needs the newly
# in-window post to have NO .rssitem on disk, so that
# building the missing one is what makes rss.tmp out of
# date. A blog grown a post at a time past ten already has
# that fragment from when the post was last in-window, and
# goes stale until make clean -- see the deleted-post gotcha
# in CLAUDE.md. This sandbox builds all twelve at once, so
# posts 1 and 2 never got a fragment, which is the history
# the heal needs.
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
	make clean >/dev/null 2>&1
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
	# GNU make 3.81's mtime comparisons resolve to whole
	# seconds. Without this, a rebuild that lands in the
	# same wall-clock second as the first build can look
	# "not newer" than files the first build produced, and
	# get skipped -- flaky, not a real rebuild-scope bug.
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
	assert_eq "extensions under build/" "html" "$(find build -type f | sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
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
# so under make 3.81's pattern search they are not files
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
test_markdown_transforms_the_body_not_the_front_matter
test_failing_markdown_fails_the_build
test_failed_markdown_leaves_no_stale_chunks
test_editing_post_template_rebuilds_fragments
test_rssitem_has_absolute_link_and_rfc822_date
test_rssitem_link_survives_trailing_slash_in_url
test_rssitem_escapes_title_and_body
test_no_url_means_no_feed
test_feed_is_built_when_url_is_set
test_feed_escapes_titles_and_bodies
test_feed_is_capped_at_ten_newest
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

pass_fail_summary
