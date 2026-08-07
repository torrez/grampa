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
	build -j8 || return
	# Counts dated post pages only, so category pages
	# added in Task 4 do not change the expected number.
	assert_eq "post pages built" "6" "$(find build -type f -name '*.html' -path 'build/2*' | wc -l | tr -d ' ')"
	assert_eq "no stray intermediates" "" "$(ls work/ | grep -vE '\.(tmp|staged|rssitem)$' | tr '\n' ' ' | sed 's/ *$//')"
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
test_editing_post_template_rebuilds_fragments
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

pass_fail_summary
