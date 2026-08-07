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
	markdown_stub <<'EOF'
#!/bin/sh
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
# The Makefile tests [ -x Markdown.pl ], not [ -f ], so a
# copy that was never chmod +x is skipped and the body
# stays verbatim HTML. That is a silent fallback with no
# warning, which makes it worth pinning: README.md now
# tells people to check the execute bit precisely because
# nothing else will tell them. Relax the test to [ -f ] and
# this fails.
#
test_non_executable_markdown_falls_back_to_verbatim() {
	sandbox markdown_not_executable
	markdown_stub <<'EOF'
#!/bin/sh
sed 's|\*\([^*]*\)\*|<em>\1</em>|g' "$1"
EOF
	chmod 644 Markdown.pl
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
# no ls will show. Found by the Task 1 review. The sibling
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
# The date half. date -v already rejects every bad date
# below and exits 1; nothing hears it, because
# date_from_filename is a $(shell) call, which keeps the
# output and throws the status away, and make 3.81 has no
# .SHELLSTATUS. So today these all publish a page with an
# empty posted-on line and an empty <pubDate>.
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
# over-strict date check would break. The five-digit year
# is here because YEAR_SHAPES stops at five: it must still
# be cleared by stage one rather than merely survive.
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
# that. Found by the Task 2 review: with the two checks
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
test_clean_works_with_a_file_named_clean
test_default_build_works_with_a_file_named_all
test_glob_character_slug_is_rejected
test_shell_metacharacter_slug_is_rejected
test_unusual_but_safe_slug_still_builds
test_empty_title_slug_is_rejected
test_out_of_range_date_is_rejected
test_non_numeric_date_is_rejected
test_impossible_calendar_date_is_rejected
test_non_leap_february_29_is_rejected
test_absurdly_long_year_is_rejected
test_unpadded_date_still_builds
test_month_end_dates_still_build
test_character_error_precedes_the_date_error

pass_fail_summary
