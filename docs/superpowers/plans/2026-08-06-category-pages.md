# Category Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dead `{{category}}.gif` line in `post.txt` with a link to a per-category archive page, moving the category from front matter into the post filename.

**Architecture:** Post filenames become `y-m-d-<category>_<title>.txt`. Splitting on `_` before `-` lets make derive date, category, and title slug with pure string functions, so category discovery needs no shell and no reading of post contents. Category pages reuse the existing `.tmp` fragments and `WRAP_IN_BASE` awk program, making them structurally identical to `index.html`.

**Tech Stack:** GNU make 3.81, awk, BSD/macOS userland (`date -v`, `split -p`, `sed`, `tr`). No dependencies. `Markdown.pl` optional.

## Global Constraints

- Target GNU make **3.81** (macOS system make). `.SECONDEXPANSION` and `.SECONDARY` are available; do not rely on anything newer.
- BSD/macOS userland only. `date -v` for dates, `split -p` for splitting. Do not use GNU-only flags.
- No new dependencies. Everything must run with a stock macOS toolchain.
- Post filenames contain **exactly one** `_`. Neither category nor title may contain one.
- Category slug charset is `[a-z0-9-]`. Display name is the slug with hyphens as spaces.
- **Post URLs must not change**: `posts/2026-08-06-home_installing-a-doorbell.txt` → `/2026/08/06/installing-a-doorbell.html`. The category must never appear in a post URL.
- `build/` contains only publishable HTML. All intermediates live in `work/`.
- Template substitution goes through the awk `fill()` helper, never `sub()`, because `sub()` treats `&` in the replacement as the matched text.
- Recipes are `@`-prefixed and echo a short progress line. Comment blocks above each rule and helper, in the existing `#`-banner style.

---

### Task 1: Test harness

Nothing in this repo is currently testable except by hand. This task builds the harness the remaining tasks depend on, and locks in current behaviour as a baseline so the filename change can't silently regress it.

**Files:**
- Create: `tests/run.sh`
- Modify: `Makefile` (add a `test` target next to `deploy`)
- Modify: `.gitignore` (ignore `tests/tmp/`)

**Interfaces:**
- Consumes: nothing
- Produces: `tests/run.sh`, runnable as `./tests/run.sh` or `make test`. Shell functions later tasks call: `sandbox`, `add_post NAME CONTENT`, `build`, `build_expect_fail`, `assert_file`, `assert_no_file`, `assert_grep FILE PATTERN`, `assert_not_grep FILE PATTERN`, `assert_eq LABEL EXPECTED ACTUAL`, `pass_fail_summary`. Every test function is named `test_*` and is invoked by name at the bottom of the file.

- [ ] **Step 1: Write the test harness with baseline tests**

Create `tests/run.sh`:

```bash
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
	add_post 2026-08-06-hello-world.txt <<'EOF'
title: Hello World
category: example
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
		add_post "2026-01-0$i-post-0$i.txt" <<EOF
title: Post 0$i
category: n
-----------------------------------
<p>Body $i.</p>
EOF
	done
	add_post 2026-01-10-post-10.txt <<'EOF'
title: Post 10
category: n
-----------------------------------
<p>Body 10.</p>
EOF
	add_post 2026-10-1-unpadded.txt <<'EOF'
title: Unpadded Oct
category: n
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
	add_post 2026-08-06-hello.txt <<'EOF'
title: Hello
category: example
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
	add_post 2026-08-06-hello.txt <<'EOF'
title: Hello
category: example
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
	add_post 2026-08-06-tom-and-jerry.txt <<'EOF'
title: Tom & Jerry
category: cartoons
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
	add_post 2026-08-06-hello.txt <<'EOF'
title: Hello
category: example
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	build || return
	assert_not_grep <(echo "$BUILD_OUT") "Building"
}

test_parallel_build_is_clean() {
	sandbox parallel
	local i
	for i in 1 2 3 4 5 6; do
		add_post "2026-0$i-01-post-$i.txt" <<EOF
title: Post $i
category: n
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build -j8 || return
	assert_eq "pages built" "6" "$(find build -name '*.html' -not -name index.html | wc -l | tr -d ' ')"
	assert_eq "no stray intermediates" "" "$(ls work/ | grep -v '\.tmp$' | tr '\n' ' ' | sed 's/ *$//')"
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

pass_fail_summary
```

Then `chmod +x tests/run.sh`.

Note: `assert_not_grep <(echo "$BUILD_OUT") ...` relies on bash process substitution, which is fine because the Makefile sets `SHELL := /bin/bash` and the script has a bash shebang.

- [ ] **Step 2: Add the test target to the Makefile**

In `Makefile`, immediately after the `deploy` rule at the end of the file, add:

```make
#
# Runs the test suite in tests/tmp sandboxes. Never
# touches your real posts/ or build/.
#
.PHONY: test
test:
	@./tests/run.sh
```

- [ ] **Step 3: Ignore the sandbox directory**

In `.gitignore`, add a line after `work/`:

```
tests/tmp/
```

- [ ] **Step 4: Run the suite and verify it passes**

Run: `make test`
Expected: every assertion passes, final line `passed: N  failed: 0`, exit status 0.

If anything fails here it is a bug in the harness, not in the Makefile — these tests describe behaviour verified working before this plan was written.

- [ ] **Step 5: Verify the harness actually catches failures**

Temporarily break something to confirm the suite is not vacuously passing:

Run: `sed -i '' 's/%B %d, %Y/%B %m, %Y/' Makefile && make test; git checkout Makefile`
Expected: `test_builds_a_post_and_index` FAILS on the `posted on August 06, 2026` assertion, summary shows `failed: 1`, exit status non-zero. Then the Makefile is restored.

- [ ] **Step 6: Commit**

```bash
git add tests/run.sh Makefile .gitignore
git commit -m "Add a test suite.

Plain bash, no framework, sandboxed per test. Locks in current
behaviour -- dates, index ordering and cap, html-only build output,
config-driven titles, ampersand handling, no-op rebuilds, -j safety
-- so the filename change coming next cannot regress it silently."
```

---

### Task 2: Filename scheme

Move the category into the filename and make everything that currently derives from filenames keep working. No category rendering yet — this task's deliverable is that posts named the new way build to the same URLs as before, and that bad names fail loudly.

**Files:**
- Modify: `Makefile` (helper functions block, `%.html` rule prerequisites, `.tmp` recipe permalink, add validation and `.DELETE_ON_ERROR:`)
- Modify: `tests/run.sh` (convert baseline fixtures to the new format, add format tests)
- Modify: `README.md` (post format section)

**Interfaces:**
- Consumes: `tests/run.sh` helpers from Task 1.
- Produces make functions later tasks call, each taking one post/tmp/html filename:
  - `underscore_split` → the name split on `_` into words
  - `title_slug` → `installing-a-doorbell.tmp` (extension preserved)
  - `post_slug` → `installing-a-doorbell` (extension stripped)
  - `category_slug` → `project-ideas`
  - `category_display` → takes a *slug*, returns `project ideas`
  - `category_url` → `/category/project-ideas.html`
  - `page_for` → `2026/08/06/installing-a-doorbell` (no extension, no `build/`)
  - `tmp_for_page` → given an html stem, the one `work/*.tmp` that builds it
  - `post_for_page` → given an html stem, the one `posts/*.txt` behind it
  - `CATEGORY_SLUGS` → sorted unique category slugs across all posts

- [ ] **Step 1: Write the failing tests**

In `tests/run.sh`, replace every existing `add_post` filename with the new format and drop the `category:` lines. The renames are:

| Old | New |
| --- | --- |
| `2026-08-06-hello-world.txt` | `2026-08-06-example_hello-world.txt` |
| `2026-01-0$i-post-0$i.txt` | `2026-01-0$i-n_post-0$i.txt` |
| `2026-01-10-post-10.txt` | `2026-01-10-n_post-10.txt` |
| `2026-10-1-unpadded.txt` | `2026-10-1-n_unpadded.txt` |
| `2026-08-06-hello.txt` | `2026-08-06-example_hello.txt` |
| `2026-08-06-tom-and-jerry.txt` | `2026-08-06-cartoons_tom-and-jerry.txt` |
| `2026-0$i-01-post-$i.txt` | `2026-0$i-01-n_post-$i.txt` |

Every heredoc loses its `category:` line, so for example the first becomes:

```bash
	add_post 2026-08-06-example_hello-world.txt <<'EOF'
title: Hello World
-----------------------------------
<p>Hi.</p>
EOF
```

The asserted output paths do **not** change — `build/2026/08/06/hello-world.html` stays exactly that. That is the point of the task.

Then add these new tests, and add their names to the invocation list at the bottom of the file:

```bash
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
	assert_grep <(echo "$BUILD_OUT") "2026-08-06-no-category-here.txt"
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
	assert_grep <(echo "$BUILD_OUT") "2026-08-06-a_b_c.txt"
}

test_filename_with_empty_category_fails() {
	sandbox empty_category
	add_post 2026-08-06-_orphan.txt <<'EOF'
title: Oops
-----------------------------------
<p>Hi.</p>
EOF
	build_expect_fail || return
	assert_grep <(echo "$BUILD_OUT") "2026-08-06-_orphan.txt"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: the renamed baseline tests FAIL (make cannot build pages from the new names yet — the `%.html` rule's slash-to-hyphen mapping looks for `work/2026-08-06-hello-world.tmp` and the fragment is now `work/2026-08-06-example_hello-world.tmp`), and the three `_fails` tests FAIL because make currently succeeds on malformed names. Non-zero exit.

- [ ] **Step 3: Replace the filename helper functions**

In `Makefile`, replace this block:

```make
#
# Takes a filepath of a (tmp,txt,html) file
# and returns just the file name. Date info
# stripped.
#
post_filename = $(subst $(space),-,$(wordlist 4, $(words $(subst -,$(space), $(notdir $(1)))), $(subst -,$(space), $(notdir $(1)))))
html_post_filename = $(call post_filename, $(1:.tmp=.html))
```

with:

```make
#
# Post filenames are y-m-d-<category>_<title>.txt.
# Splitting on the underscore first gives two halves:
# the date and category on the left, the title slug on
# the right. Everything else falls out of those.
#
underscore_split = $(subst _,$(space),$(notdir $(1)))
date_and_category = $(firstword $(call underscore_split,$(1)))
title_slug = $(word 2,$(call underscore_split,$(1)))
post_slug = $(basename $(call title_slug,$(1)))

#
# The category is whatever follows the three date
# fields in the left half, rejoined with hyphens so
# that multi-word categories survive.
#
dc_words = $(subst -,$(space),$(call date_and_category,$(1)))
category_slug = $(subst $(space),-,$(wordlist 4, $(words $(call dc_words,$(1))), $(call dc_words,$(1))))

#
# Display form of a category *slug*, and the page it
# links to. category_display takes a slug; the others
# take a filename.
#
category_display = $(subst -,$(space),$(1))
category_url = /category/$(call category_slug,$(1)).html
```

- [ ] **Step 4: Add the page path helpers and the reverse lookup**

Immediately after the `path_from_filename` block, add:

```make
#
# The page a post builds to, without build/ or the
# .html extension. The category is deliberately absent
# -- it lives in the source filename but never in a
# URL, so permalinks did not change when categories
# moved into filenames.
#
page_for = $(call path_from_filename,$(1))/$(call post_slug,$(1))

#
# Because the category is in the filename but not the
# URL, a page cannot be mapped back to its fragment by
# turning slashes into hyphens. Search instead.
#
# O(posts) per target, so O(posts squared) per build.
# Fine at blog scale; if it ever drags, generate
# explicit per-post rules with foreach and eval.
#
tmp_for_page = $(strip $(foreach f,$(TMP_FILES),$(if $(filter $(1),$(call page_for,$(f))),$(f))))
post_for_page = $(patsubst $(WORK_DIR)%.tmp,posts/%.txt,$(call tmp_for_page,$(1)))
```

- [ ] **Step 5: Rewrite html_post_files to use page_for**

Replace:

```make
html_post_files = $(foreach f,$(TMP_FILES),$(call path_from_filename, $(f))/$(call post_filename, $(f:.tmp=.html)))
```

with:

```make
html_post_files = $(foreach f,$(TMP_FILES),$(call page_for,$(f)).html)
```

- [ ] **Step 6: Add filename validation and DELETE_ON_ERROR**

After the `CATEGORY_SLUGS`-adjacent variable block — specifically right after the `TMP_FILES` assignment near the top — add:

```make
#
# A malformed filename is a parse-time error, so the
# build stops before any recipe runs. Assigning with
# := forces the check to happen now; the result is
# discarded.
#
check_post_name = \
	$(if $(word 3,$(call underscore_split,$(1))),$(error posts/$(1): more than one _ in filename; expected y-m-d-category_title.txt))\
	$(if $(word 2,$(call underscore_split,$(1))),,$(error posts/$(1): no category in filename; expected y-m-d-category_title.txt))\
	$(if $(call category_slug,$(1)),,$(error posts/$(1): empty category in filename; expected y-m-d-category_title.txt))
CHECKED_POST_NAMES := $(foreach f,$(POST_NAMES),$(call check_post_name,$(f)))

#
# Never leave a half-written target behind for the next
# build to trust.
#
.DELETE_ON_ERROR:
```

Note the `check_post_name` definition must appear *after* `underscore_split` and `category_slug` are defined, since `:=` on `CHECKED_POST_NAMES` expands it immediately. Place the whole block after the `category_url` helper from Step 3 rather than at the top of the file.

- [ ] **Step 7: Point the %.html rule at the lookup**

Replace the `%.html` rule's target line:

```make
$(BUILD_DIR)%.html: $$(call tmp_for,$$*) $$(call post_for,$$*) templates/base.txt config
```

with:

```make
$(BUILD_DIR)%.html: $$(call tmp_for_page,$$*) $$(call post_for_page,$$*) templates/base.txt config
```

and in its recipe replace `$(call post_for,$*)` with `$(call post_for_page,$*)`:

```make
	@title=$$(sed -n 's/^title:[[:space:]]*//p' $(call post_for_page,$*) | head -1); \
```

Then delete the now-unused `tmp_for` and `post_for` helpers.

- [ ] **Step 8: Fix the permalink in the .tmp recipe**

In the `$(WORK_DIR)%.tmp` recipe, replace:

```make
-v permalink="/$(call path_from_filename, $@)/$(call html_post_filename, $@)"
```

with:

```make
-v permalink="/$(call page_for,$@).html"
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `make test`
Expected: all tests pass, including the three malformed-filename tests, and every asserted post URL is unchanged from Task 1. `passed: N  failed: 0`.

- [ ] **Step 10: Update the README post format section**

In `README.md`, replace the `## post format` section body through the end of the format example with:

```markdown
A post file name _must_ be in the format: y-m-d-category_title-of-post.txt

Anything to the left of the `_` is the date and the category. Anything to the
right is the title of the post. Exactly one `_` per filename, please — neither
the category nor the title may contain one. Categories can contain hyphens, so
`project-ideas` is fine.

	posts/2026-08-06-home_installing-a-doorbell.txt
	posts/2026-07-04-project-ideas_raspberry-pi-backup.txt

Zero-padding the date is optional — posts sort correctly either way — but
`2026-08-06` gives you a tidier URL than `2026-8-6`.

The category never appears in the URL. That post above lives at
`/2026/08/06/installing-a-doorbell.html`.

The contents of the post _must_ be in this format:

	title: A text title
	-----------------------------------
	<p>
	Body of your post.
	</p>
```

- [ ] **Step 11: Commit**

```bash
git add Makefile tests/run.sh README.md
git commit -m "Move the category into the post filename.

Posts are now y-m-d-category_title.txt. Splitting on the underscore
before the hyphen gives the date, category and title slug with pure
make string functions, so nothing has to read post contents to know
what to build. Front matter drops to just title:.

Post URLs are unchanged -- the category lives in the source filename
and never in a URL. That does mean a page can no longer be mapped
back to its fragment by turning slashes into hyphens, so tmp_for_page
searches for it instead.

A filename with no underscore, more than one, or an empty category is
a parse-time error naming the file. Also adds .DELETE_ON_ERROR."
```

---

### Task 3: Category link on posts

**Files:**
- Modify: `.source/templates/post.txt`
- Modify: `Makefile` (`RENDER_POST` define, `.tmp` recipe awk invocation)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `category_display`, `category_slug`, `category_url` from Task 2.
- Produces: rendered fragments containing a category link, which Task 4 concatenates into category pages. Two new template placeholders: `{{category}}` (display name) and `{{category_url}}` (path).

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`, and add the names to the invocation list:

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: the three new tests FAIL. The pages contain ` home.gif` from the old template line, and no `/category/home.html` link.

- [ ] **Step 3: Update the post template**

Replace the whole of `.source/templates/post.txt` with:

```html
<h4>{{title}}</h4>
{{body}}
<p>
<a href="{{permalink}}">posted on {{pub_date}}</a> in <a href="{{category_url}}">{{category}}</a>
</p>
```

- [ ] **Step 4: Stop parsing category from front matter**

In the `RENDER_POST` define, delete this branch:

```make
        }else if ($$0 ~ /^category:/){
            category = $$0;
            sub(/^category:[ \t]*/, "", category);
```

so the front-matter loop reads:

```make
{
    if (!seen){
        if ($$0 ~ /^-----------------------------------/){
            seen = 1;
        }else if ($$0 ~ /^title:/){
            title = $$0;
            sub(/^title:[ \t]*/, "", title);
        }
    }else{
        body = (body == "" ? $$0 : body "\n" $$0);
    }
}
```

A stale `category:` line left in a post's front matter is now simply ignored, which is what makes the migration in Task 5 safe to run before or after this change.

- [ ] **Step 5: Fill the two new placeholders**

In the `RENDER_POST` define's `END` block, replace the substitution list with:

```make
END {
    while (getline < "templates/post.txt"){
        new_line = fill($$0, "title", title);
        new_line = fill(new_line, "body", body);
        new_line = fill(new_line, "pub_date", pub_date);
        new_line = fill(new_line, "permalink", permalink);
        new_line = fill(new_line, "category_url", category_url);
        new_line = fill(new_line, "category", category);
        post_output = post_output new_line "\n";
    }
    print post_output;
}
```

`category_url` is filled before `category` for clarity only; `fill()` matches the literal `{{category}}`, which does not occur inside `{{category_url}}`, so either order is correct.

- [ ] **Step 6: Pass the new values into awk**

In the `$(WORK_DIR)%.tmp` recipe, replace the awk invocation line:

```make
	@awk -v pub_date="$(call date_from_filename, $@)" -v permalink="/$(call page_for,$@).html" "$$RENDER_POST" $(WORK_DIR)$*.staged > $@;
```

with:

```make
	@awk -v pub_date="$(call date_from_filename, $@)" \
		-v permalink="/$(call page_for,$@).html" \
		-v category="$(call category_display,$(call category_slug,$@))" \
		-v category_url="$(call category_url,$@)" \
		"$$RENDER_POST" $(WORK_DIR)$*.staged > $@;
```

The category display name comes from a filename slug, so it can only contain `[a-z0-9-]` and the spaces this substitution introduces. It is safe inside double quotes.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `make test`
Expected: all tests pass. `passed: N  failed: 0`.

- [ ] **Step 8: Commit**

```bash
git add .source/templates/post.txt Makefile tests/run.sh
git commit -m "Render the category as a link.

Replaces {{category}}.gif, dead text in post.txt since 2016, with a
link into /category/<slug>.html, folded into the posted-on line where
the other metadata lives.

Two placeholders rather than one so the markup stays in the template:
{{category}} is the display name, {{category_url}} the path. Both come
from the filename now, passed to awk on the command line, so
RENDER_POST no longer parses category out of front matter.

Fragments are shared, so the link appears on post pages and the index
from this one change. The pages it points at come next."
```

---

### Task 4: Category pages

**Files:**
- Modify: `Makefile` (`CATEGORY_SLUGS`, `tmp_files_in_category`, `CATEGORY_PAGES`, the `build` target, a new `category/%.html` rule)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `category_slug`, `category_display`, `reverse`, `TMP_FILES`, `WRAP_IN_BASE`, `BLOG_NAME` from earlier tasks.
- Produces: `build/category/<slug>.html` for every category, and `CATEGORY_SLUGS` / `CATEGORY_PAGES` variables.

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`, and add the names to the invocation list:

```bash
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
	build || return
	assert_grep <(echo "$BUILD_OUT") "build/category/home.html"
	assert_not_grep <(echo "$BUILD_OUT") "build/category/project-ideas.html"
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: the six new tests FAIL — `build/category/*.html` does not exist, so the `assert_file` and every `assert_grep` on those paths fail.

- [ ] **Step 3: Add the category variables**

In `Makefile`, immediately after the `RECENT_FILES` block, add:

```make
#
# Every category that has at least one post. sort
# dedupes and orders in one call, so this needs no
# shell at all -- categories are in the filenames.
#
CATEGORY_SLUGS = $(sort $(foreach f,$(POST_NAMES),$(call category_slug,$(f))))
CATEGORY_PAGES = $(addprefix $(BUILD_DIR)category/,$(addsuffix .html,$(CATEGORY_SLUGS)))

#
# The fragments belonging to one category, newest
# first. Reversing before filtering keeps the ordering
# the index already established.
#
tmp_files_in_category = $(foreach f,$(call reverse,$(TMP_FILES)),$(if $(filter $(1),$(call category_slug,$(f))),$(f)))
```

- [ ] **Step 4: Add the category pages to the build target**

Replace:

```make
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html
```

with:

```make
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html $(CATEGORY_PAGES)
```

- [ ] **Step 5: Add the category page rule**

Immediately before the `config:` rule near the end of the Makefile, add:

```make
#
# One archive page per category, every post in it,
# newest first. Prerequisites are exact -- only the
# fragments in this category -- because make knows the
# categories at parse time.
#
# Two pattern rules match build/category/notes.html:
# this one and %.html. Make picks the shortest stem,
# which is this one.
#
$(BUILD_DIR)category/%.html: $$(call tmp_files_in_category,$$*) templates/base.txt config
	@echo "Building $@"
	@mkdir -p $(dir $@)
	@PAGE_TITLE="$(call category_display,$*) - $$BLOG_NAME" \
		awk "$$WRAP_IN_BASE" $(call tmp_files_in_category,$*) > $@;
```

awk concatenates all its input files, so `WRAP_IN_BASE` accumulates every fragment into `main_output` without needing a separate `cat` step or an intermediate `.tmp` the way the index does.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: all tests pass, including the exact-rebuild-scope test. `passed: N  failed: 0`.

- [ ] **Step 7: Verify parallel and clean builds by hand**

Run: `make test && rm -rf tests/tmp`
Expected: suite green. The `test_parallel_build_is_clean` case already covers `-j8`; this step confirms the sandbox teardown leaves nothing behind.

- [ ] **Step 8: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Build a page per category.

/category/<slug>.html lists every post in that category, newest
first, full bodies -- the same shape as index.html, reusing the same
fragments and the same WRAP_IN_BASE awk. The index stays capped at
ten; category pages are not, so old posts stay reachable.

Prerequisites are exact rather than 'every fragment', because
categories come from filenames and so are known at parse time.
Editing a post in one category leaves the others alone.

awk takes the fragments as multiple input files, so unlike the index
this needs no intermediate .tmp."
```

---

### Task 5: Migration, docs, and full verification

**Files:**
- Create: `tools/migrate-categories.sh`
- Modify: `CLAUDE.md`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: `tools/migrate-categories.sh`, a one-time converter from the old filename format. Dry-run by default; `--apply` performs the renames.

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh`, and add the name to the invocation list:

```bash
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
	# Dry run must change nothing.
	./tools/migrate-categories.sh >/dev/null 2>&1
	assert_file posts/2026-08-06-installing-a-doorbell.txt
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: `test_migration_converts_old_posts` FAILS — `tools/` does not exist, so `cp -R` fails and the script cannot run.

- [ ] **Step 3: Write the migration script**

Create `tools/migrate-categories.sh`:

```bash
#!/bin/bash
#
# One-time migration for the filename change that moved
# categories out of front matter and into post names.
#
#   before: posts/2026-08-06-installing-a-doorbell.txt
#           with a "category: Home" line in front matter
#   after:  posts/2026-08-06-home_installing-a-doorbell.txt
#           with that line removed
#
# Post URLs are unaffected -- the category never appears
# in one.
#
# Prints what it would do and changes nothing. Pass
# --apply to actually rename.
#
set -uo pipefail

APPLY=no
if [ "${1:-}" = "--apply" ]; then
	APPLY=yes
fi

if [ ! -d posts ]; then
	echo "no posts/ directory here; run this from your grampa checkout" >&2
	exit 1
fi

changed=0
skipped=0
errors=0

for f in posts/*.txt; do
	[ -e "$f" ] || continue
	base=$(basename "$f" .txt)

	# Already migrated?
	case "$base" in
		*_*)
			echo "skip     $f (already has a category in the name)"
			skipped=$((skipped + 1))
			continue
			;;
	esac

	# Category comes from front matter, which ends at the
	# delimiter -- so a "category:" line in the body is
	# not mistaken for it.
	category=$(sed -n '/^-----------------------------------/q; s/^category:[[:space:]]*//p' "$f" | head -1)
	if [ -z "$category" ]; then
		echo "ERROR    $f has no category: line; rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	slug=$(printf '%s' "$category" \
		| tr '[:upper:]' '[:lower:]' \
		| tr ' ' '-' \
		| sed 's/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//')
	if [ -z "$slug" ]; then
		echo "ERROR    $f: category '$category' slugifies to nothing; rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	date_part=$(printf '%s' "$base" | cut -d- -f1-3)
	title_part=$(printf '%s' "$base" | cut -d- -f4-)
	if [ -z "$title_part" ]; then
		echo "ERROR    $f: cannot find a title after the date; rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	new="posts/${date_part}-${slug}_${title_part}.txt"
	if [ -e "$new" ]; then
		echo "ERROR    $f: $new already exists" >&2
		errors=$((errors + 1))
		continue
	fi

	echo "rename   $f -> $new"
	changed=$((changed + 1))

	if [ "$APPLY" = yes ]; then
		# Drop the category: line, but only from front matter.
		awk '
			/^-----------------------------------/ { seen = 1 }
			{ if (!seen && $0 ~ /^category:/) next; print }
		' "$f" > "$new" || exit 1
		rm "$f"
	fi
done

echo
if [ "$APPLY" = yes ]; then
	echo "renamed $changed, skipped $skipped, errors $errors"
else
	echo "would rename $changed, skip $skipped, errors $errors"
	echo "nothing changed. re-run with --apply to do it."
fi

[ "$errors" -eq 0 ]
```

Then `chmod +x tools/migrate-categories.sh`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all tests pass including the migration test. `passed: N  failed: 0`.

- [ ] **Step 5: Update CLAUDE.md**

Four edits.

First, in the **config** section, leave it as is — `name=` behaviour is unchanged.

Second, replace the `## Post format` section's filename paragraph and example with:

```markdown
Filename **must** be `posts/<y>-<m>-<d>-<category>_<slug-words>.txt`. Everything left of
the `_` is the date and the category; everything right of it is the title slug. Exactly one
`_` per filename — neither the category nor the title may contain one. Categories may
contain hyphens (`project-ideas`). A malformed name is a parse-time `$(error)`.

```
posts/2026-08-06-home_installing-a-doorbell.txt   →  /2026/08/06/installing-a-doorbell.html
posts/2026-07-04-project-ideas_raspberry-pi-backup.txt
```

The category never appears in a URL.

```
title: A text title
-----------------------------------
<p>
Body of your post.
</p>
```
```

Third, in the **Build pipeline** section, add after the existing diagram:

```markdown
Category pages are a third consumer of the same fragments:

```
work/2026-08-06-home_installing-a-doorbell.tmp
  ├─ awk + templates/base.txt → build/2026/08/06/installing-a-doorbell.html
  ├─ cat 10 newest            → work/index.tmp → build/index.html
  └─ awk over all fragments in the category → build/category/home.html
```

The category page rule takes its fragments as multiple awk input files, so it needs no
intermediate `.tmp` the way the index does. Its prerequisites are exact, because
`CATEGORY_SLUGS` is derived from filenames at parse time.

Because the category is in the filename but not the URL, a page cannot be mapped back to its
fragment by turning slashes into hyphens. `tmp_for_page` searches `TMP_FILES` instead, which
is O(posts) per target and so O(posts²) per build — fine at blog scale, fixable with
`$(eval)`-generated explicit rules if it ever drags.
```

Fourth, replace the `{{category}}.gif` gotcha bullet:

```markdown
- **`templates/post.txt` renders `{{category}}.gif`** as literal text, which looks like
  leftover scaffolding rather than an intent.
```

with:

```markdown
- **Categories come from filenames, not front matter.** `CATEGORY_SLUGS` is
  `$(sort $(foreach …))` over `POST_NAMES`, so discovering them needs no shell and no
  reading of post contents. Renaming a category means renaming files — see
  `tools/migrate-categories.sh` for the pattern.
- **Renaming or deleting a category leaves its old page in `build/`**, same as deleting a
  post. `make clean` fixes it.
```

And in the **Commands** section, add `make test` next to the others:

```markdown
make test      # run tests/run.sh in throwaway sandboxes
```

- [ ] **Step 6: Full verification**

Run: `make test`
Expected: `failed: 0`, exit 0.

Run: `rm -rf tests/tmp && git status --short`
Expected: only the intended modified/created files; no stray sandboxes or build output.

- [ ] **Step 7: Commit**

```bash
git add tools/migrate-categories.sh CLAUDE.md tests/run.sh
git commit -m "Add the category migration script and update docs.

migrate-categories.sh converts old-format posts: reads the category
out of front matter, slugifies it into the filename, and drops the
line. Dry-run by default, --apply to commit to it. Refuses rather
than guesses when a post has no category or the name has no title
after the date.

CLAUDE.md picks up the filename format, the category page rule, the
tmp_for_page lookup and why it exists, and make test."
```

---

## Self-Review

**Spec coverage.** Walked each spec section against the tasks:

| Spec section | Task |
| --- | --- |
| Post filenames, underscore scheme | 2 |
| Why the date stays in the filename | Recorded in the spec; no code needed |
| Page content, full posts | 4 |
| All posts, newest first, index still capped | 4 (`test_category_page_is_not_capped_at_ten`) |
| `/category/<slug>.html` URL | 4 |
| Display name, hyphens to spaces | 3 (`test_category_link_display_name_has_spaces`), 4 (page title) |
| Exact rebuild scope | 4 (`test_editing_one_category_does_not_rebuild_another`) |
| URLs do not change | 2 (`test_url_omits_the_category`), 5 (migration test asserts original URLs) |
| Template, two placeholders | 3 |
| Build wiring, shortest-stem precedence | 4 |
| Fragment lookup | 2 |
| Validation, parse-time error | 2 (three `_fails` tests) |
| `.DELETE_ON_ERROR:` | 2 |
| Migration | 5 |
| Known limitation, stale category pages | 5 (documented in CLAUDE.md, not solved — matches spec) |
| Testing list | 1-5; every item mapped to a named test |

Two spec testing items were not covered by a named test and are now handled: "`build/` still contains only publishable HTML" after category pages exist is `test_category_pages_are_html_only_in_build` in Task 4, and the `Markdown.pl` path is covered by the existing behaviour rather than a new test — it is exercised only when `Markdown.pl` is present, which the sandbox never is. **Gap accepted and called out:** the Markdown path is not regression-tested by this suite. It was verified by hand earlier in this work and is untouched by these tasks.

**Placeholder scan.** No TBDs, no "add error handling", no "similar to Task N". Every code step carries the actual content. The one place a step says "replace X with Y" it quotes both sides verbatim.

**Type consistency.** Checked the make function names used across tasks: `underscore_split`, `date_and_category`, `title_slug`, `post_slug`, `dc_words`, `category_slug`, `category_display`, `category_url`, `page_for`, `tmp_for_page`, `post_for_page`, `tmp_files_in_category`, `CATEGORY_SLUGS`, `CATEGORY_PAGES`, `check_post_name`. Task 2 defines all of the first group and Task 4 the last three; Tasks 3 and 4 only consume names Task 2 defined. `tmp_for`/`post_for` from the pre-existing Makefile are deleted in Task 2 Step 7 and referenced nowhere afterwards. Test helper names in Task 1 (`sandbox`, `add_post`, `build`, `build_expect_fail`, `assert_file`, `assert_no_file`, `assert_grep`, `assert_not_grep`, `assert_eq`) match every later call site.

One ordering constraint worth restating, because getting it wrong is a parse error rather than a test failure: `CHECKED_POST_NAMES := ...` in Task 2 Step 6 must be placed *after* `underscore_split` and `category_slug` are defined, since `:=` expands immediately. The step says so explicitly.
