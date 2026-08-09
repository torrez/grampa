# Static assets (`static/` → `build/`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `static/` source directory whose contents are copied into `build/` mirrored at the site root, with parse-time guards against every way a static file can collide with a generated page, plus a stock stylesheet so a new install renders styled.

**Architecture:** One `$(shell find)` snapshot at parse time (`STATIC_SRC`), three parse-time `$(error)` guards over it, and a **static pattern rule** (`$(STATIC_PAGES): $(BUILD_DIR)%: static/%`) that copies each file. The static pattern rule is explicit for exactly the listed targets, so it never competes with `$(BUILD_DIR)%.html` on stem length — the spec review proved a plain pattern rule loses that contest in reachable states and ships an impostor page at exit 0.

**Tech Stack:** GNU make 4.2+, `find`, `grep`, `sort`, `cp`, `cat -vt`. No new dependency; every tool used is already required by the Makefile.

**Spec:** `docs/superpowers/specs/2026-08-09-static-assets-design.md`. Read it before starting — particularly section 3, which records a falsified argument alongside the correct one.

## Global Constraints

- **Tabs in the Makefile.** Recipe lines begin with a literal tab, never spaces.
- **Comment blocks above each rule and helper**, in the existing `#`-banner style. This repo's comments carry the *why*, including what was tried and failed. Match that density.
- **Recipes are prefixed with `@`** and echo a short human-readable progress line.
- **All three static checks must sit textually above the first rule that expands `STATIC_PAGES`.** Verified: below it, a `static/a:b.css` dies at make's own `target pattern contains no '%'` instead of the good message. Pinned by a test in Task 3.
- **The rejected character set is the minimal one**, settled with the user: whitespace, control characters, and `: % $ # \ * ? [ ] ` ( ) & ' " | ; < > =`. `logo@2x.png`, `style,min.css`, `a+b.css`, `café.jpg` and emoji names must stay legal. Do not widen it to match `BAD_CHARS`.
- **The recipe is single-quoted** — `'$(dir $@)'`, `'$<'`, `'$@'`. `{` and `}` are legal in a static filename and brace-expand in an unquoted `cp` on any bash-`/bin/sh` host.
- **Never publish wrong content at exit 0.** Every guard here exists because its absence was demonstrated to do exactly that. A guard that turns a silent wrong page into a loud failure is working as designed.
- **`make test` runs the suite**; it passes `$(MAKE)` in. Full suite must stay green. Record the baseline `passed:`/`failed:` line before Task 1 — the counter counts **assertions, not tests**, so the only invariant is `failed: 0` and a `passed:` that never drops.
- Every test is **watched failing first**. A test that passes before its implementation lands is not a test, and this repo has caught that by mutation before.

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `Makefile` | Modify — insert a block after line 784 (`CHECKED_POST_PAGES`), one line at 1186 (`build:`), one rule after line 1304 | Enumeration, three guards, the copy rule |
| `.source/static/style.css` | Create | The stock stylesheet, copied by setup |
| `.source/templates/base.txt` | Modify | Add the `<link rel="stylesheet">` |
| `.source/templates/post.txt` | Modify | Add `class="meta"` to the posted-on line so it can be styled |
| `tests/run.sh` | Modify | 18 tests plus their registration calls |
| `README.md` | Modify | Install, a Static files section, What it builds, Known issues, remove the "Not done yet" line |
| `CLAUDE.md` | Modify | Layout table, the checks, the corrected rule-selection account, two new gotchas |

The whole Makefile change is one contiguous block plus two one-line edits. This repo keeps the program in a single file by design; do not split it.

---

### Task 1: Enumeration and the two filename checks

**Files:**
- Modify: `Makefile` — insert after line 784, the `CHECKED_POST_PAGES :=` line
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `$(BUILD_DIR)` (defined `Makefile:146`)
- Produces: `STATIC_LS`, `STATIC_SRC`, `STATIC_PAGES`, `HASH` — Task 2 uses `STATIC_PAGES`, Task 3 appends to the same block

- [ ] **Step 1: Write the failing tests**

Add these five functions to `tests/run.sh`. Put them after `test_control_check_ignores_non_post_files`, keeping the filename-check tests together.

```bash
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
```

Register all five by adding their names, one per line, immediately before `pass_fail_summary` at the bottom of `tests/run.sh`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make test 2>&1 | tail -20`

Expected: the four `_fails` tests FAIL with `make succeeded but should have failed` (nothing rejects anything yet). `test_legal_static_names_are_accepted` PASSES already — that is expected and correct; it is a regression guard, not a driver. Note it in the commit message so a later reader does not mistake it for an untested assertion.

- [ ] **Step 3: Write the implementation**

Insert this block into `Makefile` immediately after line 784 (the `CHECKED_POST_PAGES :=` line) and its following blank line.

```make
#
# static/ is copied into build/ verbatim, mirrored at the
# site root: static/style.css publishes at /style.css. It is
# the only source of a page grampa did not generate, which is
# what makes /favicon.ico and /robots.txt reachable at all.
#
# The trailing slash on `find static/` is load-bearing. If
# static is itself a symlink to a directory -- assets living
# outside the repo -- then `find static` prints the symlink
# and nothing under it. patsubst leaves that unmatched word
# alone, so STATIC_PAGES acquires the literal word `static`,
# which exists as a prerequisite, and the build exits 0
# having copied nothing and said nothing. The slash traverses
# it, and is transparent for a real directory and a missing
# one. Verified all three.
#
# ! -type d rather than -type f so a symlinked asset is
# copied -- cp follows the link -- rather than skipped.
#
# sort because find walks in directory order, which is
# neither stable across filesystems nor meaningful to read.
#
# 2>/dev/null is what lets a tree with no static/ build clean
# at exit 0, the same handling POST_LS gives a missing
# posts/. Unlike posts, static/ has no rule that creates it:
# nothing downstream requires it to exist.
#
# := throughout. STATIC_SRC is read by three checks and one
# prerequisite list, and the lazy-expansion argument that
# keeps CONFIG_NAME on = does not apply -- static/ needs no
# recipe to have run first.
#
# STATIC_LS holds a shell fragment rather than a command that
# runs, exactly as POST_LS does, so the character check below
# shares the identical listing and the two cannot drift about
# what the directory holds.
#
STATIC_LS := find static/ ! -type d 2>/dev/null | sort
STATIC_SRC := $(shell $(STATIC_LS))
STATIC_PAGES := $(patsubst static/%,$(BUILD_DIR)%,$(STATIC_SRC))

#
# A static filename may contain anything except whitespace, a
# control character, and the punctuation that breaks make or
# an unquoted shell word. This is deliberately NOT the
# BAD_CHARS set posts use: logo@2x.png and style,min.css are
# legal asset names that break nothing, and rejecting them
# for symmetry's sake would be a rule with no failure behind
# it. Non-ASCII is fine, so café.jpg and emoji names build.
#
# Three escaping layers stack on the grep line. $$ is make's
# escape for a literal $, \# is make's for a literal #, and
# '\'' is the shell's way to put a single quote inside a
# single-quoted string. ] leads the bracket expression
# because that is the only position where it is literal.
#
# \\ is chosen for portability rather than by test: POSIX
# says a backslash is literal inside a bracket expression, so
# \\ contributes one twice and harmlessly, while GNU reads it
# as an escaped backslash and contributes it once. Both
# readings yield the same set. Verified against 21 bad names
# and 11 legal ones on GNU grep 3.12 and ugrep 7.5.0.
#
# It greps the directory listing rather than STATIC_SRC, and
# that is load-bearing rather than tidy: a filename
# containing a space cannot be an element of the list you
# would be checking, because make splits on whitespace. A
# check written over STATIC_SRC could not see the principal
# thing it exists to catch. Same lesson as
# CONTROL_CHAR_NAMES above.
#
# LC_ALL=C pins the classes to bytes, matching the control
# check's definition -- 0x00-0x1F and 0x7F -- so U+0085
# arrives as two bytes and builds, the same line café is on.
#
# cat -vt renders a control byte as ^A rather than spraying
# it at a terminal. It renders non-ASCII the same way, so a
# rejected café(1).jpg is named as cafM-CM-)(1).jpg -- ugly,
# but it only ever applies to a name already being rejected.
#
# HASH exists because make's \# escape works in a plain
# assignment but NOT inside a function argument: written
# directly in the $(error) text it reaches the terminal as
# \#. Verified. The backslash is named in words for the same
# reason -- \\ in the message renders as \\ and there is no
# assignment trick that fixes it.
#
HASH := \#
BAD_STATIC_NAMES := $(shell $(STATIC_LS) | LC_ALL=C grep -e '[[:space:][:cntrl:]]' -e '[]:%$$\#\\*?[`()&'\''"|;<>=]' | cat -vt)
CHECKED_STATIC_CHARS := $(if $(BAD_STATIC_NAMES),$(error bad character in static filename: $(BAD_STATIC_NAMES); shown rendered, so ^A is one byte. A static filename may not contain whitespace, a control character, or any of these: : % $$ $(HASH) * ? [ ] ` ( ) & ' " | ; < > = -- nor a backslash))

#
# The one hole the posts checks still have, closed here for
# one line. A 0x0A inside a filename is invisible to a
# line-based grep: find prints such a name as two lines and
# neither matches the character class. Both halves then
# word-split into STATIC_SRC entries that name no file on
# disk, so a positive existence test catches what a denylist
# structurally cannot.
#
# It runs second because its message is worse -- it names a
# fragment, since a fragment is all that exists to name --
# so the check with the good message gets first refusal.
#
# Residual, documented not cured: if a split fragment
# coincidentally names a real path relative to the repo root,
# that fragment passes here. It is then a source file the
# copy rule cannot find, so the build still fails, just later
# and less clearly.
#
CHECKED_STATIC_SPLIT := $(foreach f,$(STATIC_SRC),$(if $(wildcard $(f)),,$(error static filename splits a make list, most likely a newline in it: $(f) is not a file. Rename it.)))
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `make test 2>&1 | tail -5`

Expected: `failed: 0`, and the `passed:` count higher than the baseline you recorded before starting. **`passed:` counts assertions, not tests**, so do not predict an exact number — record the baseline with `make test 2>&1 | tail -1` before Task 1 and check it only ever goes up. If `test_legal_static_names_are_accepted` now fails, the character set has been widened by mistake — re-check the bracket expression against the Global Constraints.

- [ ] **Step 5: Verify the message renders correctly**

Run:

```bash
cd "$(mktemp -d)" && cp ~/Code/grampa/Makefile . && cp -R ~/Code/grampa/.source . && cp -R ~/Code/grampa/tools . \
  && make setup >/dev/null 2>&1 && mkdir -p static && : > 'static/a:b.css' && make 2>&1 | grep -o 'any of these.*Stop'
```

Expected exactly: `any of these: : % $ # * ? [ ] ` ( ) & ' " | ; < > = -- nor a backslash.  Stop`

A `\#` in that output means `HASH` was inlined instead of referenced.

- [ ] **Step 6: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Enumerate static/ and check its filenames

The rejected set is the minimal one -- whitespace, control
characters, and the punctuation that breaks make or an unquoted
shell word -- not the stricter BAD_CHARS posts use, so logo@2x.png
stays legal.

The existence check closes the newline hole the posts checks still
have. test_legal_static_names_are_accepted passes before the
implementation too; it is a regression guard on the narrow set, not
a driver."
```

---

### Task 2: The copy rule

**Files:**
- Modify: `Makefile:1186` (the `build:` prerequisite line), and insert a rule after line 1304
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `STATIC_PAGES` from Task 1
- Produces: files under `build/`. Task 3 guards this rule; Task 4's stylesheet is published by it.

- [ ] **Step 1: Write the failing tests**

Add these nine functions to `tests/run.sh`, after the Task 1 tests.

```bash
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

#
# find static (no slash) prints only the symlink, so
# STATIC_PAGES got the literal word `static`, which exists,
# and the build exited 0 having copied nothing.
#
test_symlinked_static_directory_is_published() {
	sandbox static_symlink
	mkdir -p assets
	echo "body{color:blue}" > assets/style.css
	ln -s assets static
	build || return
	assert_file build/style.css
	assert_grep build/style.css "body{color:blue}"
}

#
# { } and , are legal under the minimal set, and brace-expand
# in an unquoted cp on a bash-/bin/sh host. Passes either way
# on a dash host, so this is host-conditional coverage --
# honest about that rather than claiming universal.
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
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
<p>Hi.</p>
EOF
	build || return
	assert_file build/2026/08/06/hello.html
	assert_no_file build/style.css
}
```

Register all nine before `pass_fail_summary`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make test 2>&1 | tail -20`

Expected: eight FAIL on missing `build/…` files. `test_build_works_without_a_static_directory` PASSES already — a regression guard, same note as Task 1's.

- [ ] **Step 3: Add `$(STATIC_PAGES)` to `build`'s prerequisites**

`Makefile:1186`. Change:

```make
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html $(CATEGORY_PAGES) $(FEED_PAGES)
```

to:

```make
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html $(CATEGORY_PAGES) $(FEED_PAGES) $(STATIC_PAGES)
```

- [ ] **Step 4: Add the copy rule**

Insert after line 1304 (the `awk "$$WRAP_IN_BASE" $< > $@;` line ending the `$(BUILD_DIR)%.html` rule), before the comment block introducing `$(WORK_DIR)index.tmp`.

```make
#
# static/ files, copied into build/ with their relative path
# preserved. The whole feature, three lines of recipe.
#
# A STATIC PATTERN RULE, not a plain $(BUILD_DIR)% pattern
# rule, and the difference is not style. The first draft was
# plain, argued safe on the grounds that shortest-stem
# selection would keep it away from generated pages. That
# argument is FALSE. Make's implicit-rule search orders
# candidates by stem length, but its first pass only accepts
# a rule whose prerequisites already exist or are themselves
# makeable. Stem length orders the trial; existence decides
# it. So on any build where a post's .tmp fragment is not yet
# on disk, $(BUILD_DIR)%.html fails that pass while a
# $(BUILD_DIR)% rule whose static/ twin exists on disk passes
# it -- and the LONGER stem wins. Verified: with a twin at
# static/2026/08/06/hello.html and the collision guards
# removed, the impostor shipped at exit 0, in serial, under
# -j8, and when the page was asked for by name.
#
# A static pattern rule is an explicit rule for exactly the
# listed targets, so it enters no such contest, and it is
# inert for anything not in STATIC_PAGES -- a hand-typed
# make build/nope.css still gets make's own "No rule to make
# target". An empty STATIC_PAGES parses and builds fine,
# which is the tree with no static/ at all.
#
# It also fixes a plain behavioural bug the pattern form had:
# a legal, non-colliding static/about.html BROKE the build,
# because %.html beat $(BUILD_DIR)% for it -- an empty
# tmp_for_page plus templates/base.txt and config all exist
# -- and fired the unknown-page guard. /about.html, and the
# /404.html GitHub Pages wants at the root, failed with a
# message about posts.
#
# The guards above are therefore the SOLE containment against
# a static file claiming a generated page: under either rule
# form the twin wins silently without them. They are not a
# backstop to a rule-selection argument. There is no
# rule-selection argument.
#
# Everything is single-quoted. The rejected character set is
# the minimal one, so { } and , are legal in a static
# filename, and static/x{1,2}y.css brace-expands in an
# unquoted cp on any host whose /bin/sh is bash. ' is
# rejected, so nothing can escape the quotes.
#
# Plain cp, not cp -p: the copy takes a current mtime, newer
# than its source, which is what make wants. Preserving the
# source mtime would leave the two equal and lean on make's
# treatment of a tie.
#
$(STATIC_PAGES): $(BUILD_DIR)%: static/%
	@echo "Copying $@"
	@mkdir -p '$(dir $@)'
	@cp '$<' '$@'
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `make test 2>&1 | tail -5`

Expected: `failed: 0`, count up from Task 1's.

- [ ] **Step 6: Verify `-j` safety and a by-name target**

```bash
cd "$(mktemp -d)" && cp ~/Code/grampa/Makefile . && cp -R ~/Code/grampa/.source . && cp -R ~/Code/grampa/tools . \
  && make setup >/dev/null 2>&1 && mkdir -p static/img posts \
  && printf 'title: H\n-----------------------------------\n<p>Hi.</p>\n' > posts/2026-08-06-home_hello.txt \
  && echo a > static/style.css && echo b > static/img/x.svg \
  && make -j8 >/dev/null 2>&1 && find build -type f | sort \
  && make build/nope.css 2>&1 | tail -1
```

Expected: six files listed, and `No rule to make target 'build/nope.css'` on the last line.

- [ ] **Step 7: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Copy static/ into build/ with a static pattern rule

Not a plain \$(BUILD_DIR)% pattern rule: shortest-stem selection
does not protect generated pages, because make's first pass accepts
on prerequisite existence and only orders by stem length. A static
twin of a post page shipped at exit 0 in serial, under -j8, and by
name. A static pattern rule enters no such contest.

It also fixes a legal static/about.html breaking the build with a
message about posts."
```

---

### Task 3: The three collision guards

**Files:**
- Modify: `Makefile` — append to the block from Task 1, still above line 1186
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `STATIC_PAGES` (Task 1), `POST_PAGES` (`Makefile:778`), `CATEGORY_PAGES` (`Makefile:268`), `BUILD_DIR`
- Produces: `GENERATED_PAGES` — the authoritative list of every page grampa builds. Any future page type must join it.

- [ ] **Step 1: Write the failing tests**

```bash
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
# A name bad in BOTH ways must get the character message. With
# the checks below build's prerequisite line, a : dies at make's
# own "target pattern contains no '%'" instead.
#
test_static_character_error_precedes_the_collision_error() {
	sandbox static_check_order
	mkdir -p static
	: > 'static/index:x.html'
	build_expect_fail || return
	assert_out_grep "bad character in static filename"
	assert_out_not_grep "target pattern contains no"
}
```

Register all seven before `pass_fail_summary`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make test 2>&1 | tail -25`

Expected: the six `_fails` tests FAIL — most with `make succeeded but should have failed`, and `test_static_file_shadowing_a_page_directory_fails` demonstrating the silent behaviour the guard exists for. `test_static_names_near_a_generated_page_are_fine` PASSES already; regression guard.

- [ ] **Step 3: Write the implementation**

Append to the Task 1 block in `Makefile`, after `CHECKED_STATIC_SPLIT`.

```make
#
# Every page grampa itself builds. A static file that claims
# one of these paths -- or a directory one of them lives in
# -- is a parse-time error naming both sides, the same
# refusal to pick a winner CHECKED_POST_PAGES makes for two
# posts wanting one URL.
#
# This is the SOLE containment. See the copy rule's comment:
# there is no rule-selection argument keeping a static file
# out of a generated page's target, so without these guards
# the static file wins silently at exit 0.
#
# POST_PAGES (:=) and not html_post_files (=): the two name
# the same set, but the recursive one re-walks TMP_FILES on
# every expansion -- the shape that cost 131 shell calls on a
# 60-post rebuild before POST_NAMES became :=. Verified equal
# to what build names at the build: line, over unpadded
# dates, two-digit years, hyphenated categories and
# non-ASCII slugs.
#
# rss.xml is listed UNCONDITIONALLY, not through FEED_PAGES.
# With url= unset FEED_PAGES is empty, so a gated check would
# accept static/rss.xml today and break the build on the day
# url= gets set -- a failure whose cause was added weeks
# earlier. The feed page is a reserved path whether or not it
# is currently built.
#
# Anything added to build's output must be added here too. A
# future page type that forgets silently reopens every
# collision these three close.
#
GENERATED_PAGES := $(BUILD_DIR)index.html $(BUILD_DIR)rss.xml $(addprefix $(BUILD_DIR),$(addsuffix .html,$(POST_PAGES))) $(CATEGORY_PAGES)

#
# Three conditions, not one. Exact equality is the obvious
# case; the other two are worse, and the middle one is the
# only silent failure of the three.
#
# STATIC_SHADOWS_DIR: a static file whose published path
# equals a DIRECTORY generated pages live under. static/2026
# beside a 2026-dated post exits 0 having never published the
# file -- build/2026/ exists as a directory newer than the
# source, so make judges the target up to date -- and after a
# touch, cp copies INTO the directory and lands at
# build/2026/2026. Exit 0 both times, content nowhere. Under
# -j4 from clean it is a race-dependent mkdir failure
# instead. A file named `category` does the same.
#
# STATIC_UNDER_PAGE: the inverse, a static DIRECTORY named
# for a generated page. It fails on its own today, but with a
# mkdir message rather than an explanation.
#
# No ancestor-walking needed: filter's % anchored by the /
# does it in one pass each. Verified against the near-misses
# that must not fire -- hello.htmlx and categoryextra.css.
#
STATIC_EXACT_COLLISIONS := $(filter $(GENERATED_PAGES),$(STATIC_PAGES))
STATIC_SHADOWS_DIR := $(strip $(foreach s,$(STATIC_PAGES),$(if $(filter $(s)/%,$(GENERATED_PAGES)),$(s))))
STATIC_UNDER_PAGE := $(strip $(foreach g,$(GENERATED_PAGES),$(if $(filter $(g)/%,$(STATIC_PAGES)),$(g))))
CHECKED_STATIC_EXACT := $(if $(STATIC_EXACT_COLLISIONS),$(error static file and a generated page both build $(STATIC_EXACT_COLLISIONS); rename or remove the file in static/))
CHECKED_STATIC_SHADOW := $(if $(STATIC_SHADOWS_DIR),$(error static file $(STATIC_SHADOWS_DIR) has the same path as a directory generated pages live in; rename or remove it))
CHECKED_STATIC_UNDER := $(if $(STATIC_UNDER_PAGE),$(error static directory $(STATIC_UNDER_PAGE) has the same path as a generated page; rename or remove it))
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `make test 2>&1 | tail -5`

Expected: `failed: 0`, count up from Task 2's.

- [ ] **Step 5: Prove by mutation that the guard is what contains the rule**

Comment the exact-collision guard out in a scratch copy and confirm the impostor ships. This is
the whole justification for the guard existing, so run it rather than assuming it:

```bash
D="$(mktemp -d)" && cd "$D" && cp ~/Code/grampa/Makefile . && cp -R ~/Code/grampa/.source . && cp -R ~/Code/grampa/tools . \
  && make setup >/dev/null 2>&1 && mkdir -p posts static/2026/08/06 \
  && printf 'title: Real\n-----------------------------------\n<p>Real body.</p>\n' > posts/2026-08-06-home_hello.txt \
  && echo "<h1>IMPOSTOR</h1>" > static/2026/08/06/hello.html \
  && sed -i 's/^CHECKED_STATIC_EXACT :=/#&/' Makefile \
  && make >/dev/null 2>&1 ; echo "exit $?" ; cat build/2026/08/06/hello.html
```

Expected: `exit 0`, and the page's entire content is `<h1>IMPOSTOR</h1>` — the real post's body
gone, no error, nothing on stderr. Verified during planning.

**A static pattern rule is an explicit rule, so it beats `$(BUILD_DIR)%.html` outright** — the
same way `build/index.html`'s explicit rule beats every pattern rule. Switching from a plain
pattern rule to a static pattern rule in Task 2 fixed `about.html` and removed the stem-length
lottery; it did **not** make a twin safe, and nothing about the rule form could. If this step
prints anything other than the impostor, the guard did not actually get commented out — check
the `sed` matched.

- [ ] **Step 6: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Guard every way a static file can collide with a page

Three conditions, not one: exact equality, a static file shadowing
a directory generated pages live in, and a static directory named
for a page. The middle one was silent wrong output at exit 0 --
static/2026 beside a dated post never published, then landed at
build/2026/2026 after a touch.

rss.xml is reserved unconditionally rather than via FEED_PAGES, so
setting url= later cannot break a build for a file added weeks
earlier."
```

---

### Task 4: Setup, gitignore, and the stock stylesheet

**Files:**
- Create: `.source/static/style.css`
- Modify: `.source/templates/base.txt`, `.source/templates/post.txt`, `Makefile` (the `setup` recipe, ~line 1524), `.gitignore`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: the copy rule from Task 2 publishes `static/style.css` as `build/style.css`
- Produces: nothing later tasks depend on

- [ ] **Step 1: Write the failing tests**

```bash
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
```

Register all three before `pass_fail_summary`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make test 2>&1 | tail -15`

Expected: all three FAIL — `expected file to exist: static/style.css`, and the missing `<link>`.

- [ ] **Step 3: Create `.source/static/style.css`**

```css
/*
 * Grampa's stock stylesheet.
 *
 * Copied into static/ by `make setup` and published at
 * /style.css by the static/ copy rule. Setup never
 * overwrites a file you already have, so edit this freely --
 * or delete it, and drop the <link> line from
 * templates/base.txt.
 *
 * It styles what post.txt actually emits and nothing else:
 * the h4 title, the body, and the .meta posted-on line.
 */

:root {
	color-scheme: light dark;
}

body {
	font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
	line-height: 1.6;
	max-width: 38rem;
	margin: 0 auto;
	padding: 2rem 1rem 4rem;
}

h4 {
	font-size: 1.4rem;
	line-height: 1.25;
	margin: 2.5rem 0 0.5rem;
}

h4:first-child {
	margin-top: 0;
}

p {
	margin: 0 0 1rem;
}

.meta {
	font-size: 0.85rem;
	opacity: 0.7;
	margin-bottom: 2.5rem;
}

img {
	max-width: 100%;
	height: auto;
}

pre {
	overflow-x: auto;
	padding: 0.75rem 1rem;
}

pre, code {
	font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
	font-size: 0.9em;
}
```

- [ ] **Step 4: Add the stylesheet link to `.source/templates/base.txt`**

Insert after the existing `<link rel="alternate" …>` line, with the same leading tabs:

```html
		<link rel="stylesheet" href="/style.css">
```

- [ ] **Step 5: Give the posted-on line a class in `.source/templates/post.txt`**

Change `<p>` on the posted-on line (line 3) to `<p class="meta">`. The file becomes:

```html
<h4>{{title}}</h4>
{{body}}
<p class="meta">
<a href="{{permalink}}">posted on {{pub_date}}</a> in <a href="{{category_url}}">{{category}}</a>
</p>
```

Only the posted-on paragraph gets the class. Do not touch `{{body}}` — a post body is author HTML and this template must not decorate it.

- [ ] **Step 6: Add `static/` to the `setup` recipe**

In `Makefile`, in the `setup` recipe (~line 1524), after the `@mkdir -p templates;` line:

```make
	@mkdir -p static;
```

and after the existing `cp -i .source/templates/*` line:

```make
	-@yes n | cp -i .source/static/* static/ 2>/dev/null
```

Same `-@` and `2>/dev/null` as the line above it, for the same reason: `cp -i` answered `n` exits non-zero.

- [ ] **Step 7: Add `/static/` to `.gitignore`**

Insert after the `/posts/` line, inside the block the existing anchoring comment covers:

```
/static/
```

- [ ] **Step 8: Run the tests and verify they pass**

Run: `make test 2>&1 | tail -5`

Expected: `failed: 0`, count up from Task 3's.

- [ ] **Step 9: Verify the virgin-tree lag is what the spec says it is**

```bash
D="$(mktemp -d)" && cd "$D" && cp ~/Code/grampa/Makefile . && cp -R ~/Code/grampa/.source . && cp -R ~/Code/grampa/tools . \
  && make setup >/dev/null 2>&1 && make >/dev/null 2>&1 \
  && ls build/style.css 2>&1 | tail -1
```

Expected: `build/style.css` exists. The lag only appears when `setup` and a build share one invocation (`make setup all`), which the documented flow does not do. Confirm that case too:

```bash
D="$(mktemp -d)" && cd "$D" && cp ~/Code/grampa/Makefile . && cp -R ~/Code/grampa/.source . && cp -R ~/Code/grampa/tools . \
  && make setup all >/dev/null 2>&1 ; ls build/style.css 2>&1 | tail -1
```

Expected: `No such file or directory` — one build late, exactly as the spec's section 5 documents. Then a plain `make` produces it.

- [ ] **Step 10: Commit**

```bash
git add .source/static/style.css .source/templates/base.txt .source/templates/post.txt Makefile .gitignore tests/run.sh
git commit -m "Ship a stock stylesheet, wired up at setup

A new install renders styled; an existing install gets neither the
file nor the link, since cp -i will not clobber its base.txt, so
nobody acquires a stylesheet link pointing at a file they do not
have.

post.txt's posted-on line gets class=\"meta\" so it can be styled
without touching the author's body HTML."
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above
- Produces: nothing

- [ ] **Step 1: Update `README.md`**

Five edits:

1. **Install section** — the `make setup` paragraph lists what it creates. Add `static/` to that list.
2. **New section, after "Writing a post"**, titled `## Static files`:

```markdown
Anything in `static/` is copied into `build/` with its path preserved, so
`static/style.css` publishes at `/style.css` and `static/img/logo.png` at `/img/logo.png`.
That mirroring at the root is what lets you serve `/favicon.ico`, `/robots.txt`, or a
`CNAME`. `make setup` creates the directory and puts a stock stylesheet in it.

A static file may not have the same path as a page grampa builds. `static/index.html` and a
`static/2026/08/06/hello.html` twin of a real post both stop the build and name the two
sides, rather than one silently winning. So does a file named for a directory pages live in,
like `static/2026`.

Static filenames are checked, but less strictly than post filenames: no whitespace, no
control characters, and none of `: % $ # \ * ? [ ] ` ( ) & ' " | ; < > =`. Everything else
is fine, so `logo@2x.png` and `style,min.css` both work, as do accents and emoji.

It is a copy, not a filter — `style.css~`, `.DS_Store` and editor swap files in `static/`
get published along with everything else.
```

3. **"What it builds"** — add a bullet: `**Anything in `static/`** — copied to the matching path under `build/`, so `static/style.css` becomes `build/style.css`.`
4. **"Known issues"** — add: `**Deleting a static file leaves its copy behind in `build/`**, the same as deleting a post, and for the same reason: nothing tracks an output whose source is gone. `make clean && make` clears it.`
5. **"Not done yet"** — delete the `A home for static files (CSS, images) that aren't generated from posts` line.

- [ ] **Step 2: Update `CLAUDE.md`**

Four edits:

1. **Layout table** — a row: `| `static/` | no | Per-install static assets, copied verbatim into `build/` |`, and a row for `.source/static/` marked tracked.
2. **Post format section** — after the filename rules, a paragraph noting `static/` filenames use a *different, narrower* set, and why: the two directories answer different questions, and `logo@2x.png` is a legal asset name that breaks nothing.
3. **Build pipeline** — `static/` as a fifth consumer of nothing, sitting beside the four fragment consumers: it is the one output with no fragment behind it.
4. **Gotchas** — three new bullets:
   - **The copy rule is a static pattern rule, and the reason is not style.** Write the corrected account: stem length orders make's trial, prerequisite existence decides it, so a plain `$(BUILD_DIR)%` rule wins over `%.html` whenever the post's `.tmp` is not yet on disk — verified shipping an impostor at exit 0 in serial, under `-j8`, and by name. The three collision guards are the sole containment; there is no rule-selection argument. **Do not write the shortest-stem version. It is false, it was believed during this feature's design, and it is recorded as falsified in the spec.**
   - **`GENERATED_PAGES` is hand-maintained.** A future page type that does not join it silently reopens every collision the guards close.
   - **The stock stylesheet is one build late on `make setup all`** — `STATIC_SRC` is snapshotted at parse, before setup's recipe copies the file. The next `make` heals it. The newest member of the parse-time-vs-recipe-time family documented in this file.

- [ ] **Step 3: Verify the docs against the code**

Run: `make test 2>&1 | tail -3`

Expected: `failed: 0` and the count unchanged from Task 4's — docs change no behaviour, so a moved number means something was edited by accident.

Then re-read both documents against the Makefile as it now stands. This repo's backlog item 14 catalogues eight confident-but-false documentation claims; the check is not optional. Specifically confirm: the character list in README matches the bracket expression in the Makefile character-for-character, and the CLAUDE.md rule-selection account matches the copy rule's comment block.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document static/

The rule-selection account in CLAUDE.md is the corrected one:
stem length orders make's trial, prerequisite existence decides it,
and the collision guards are the sole containment. The falsified
shortest-stem version stays in the spec, where its record is useful,
and must not reach this file."
```

---

## Final: branch review

- [ ] Run the full suite one more time: `make test`. Expect `failed: 0` and 21 tests' worth of new assertions above the baseline recorded before Task 1.
- [ ] Dispatch the Fable **branch** review — the fourth checkpoint in `CLAUDE.md`'s cycle. Give it the whole diff against `main`, the spec, and this plan. Tell it the four settled decisions are settled, and that section 3 of the spec records an argument already falsified once so it should be checked rather than assumed. Ask for blocking / recommended / optional plus what it actively verified.
- [ ] Fold the findings in, then use `superpowers:finishing-a-development-branch` to decide integration.

## Self-review notes

**Spec coverage.** Section 1 → Task 1. Section 2 (both checks, placement) → Task 1 + Task 3's ordering test. Section 3 (rule, quoting, `.SECONDARY`) → Task 2. Section 4 (all three collision conditions) → Task 3. Section 5 (setup, gitignore, base.txt, stylesheet, the virgin-tree lag) → Task 4. Section 6 (docs) → Task 5. Testing table: all 18 tests placed, plus `test_static_names_near_a_generated_page_are_fine`, `test_setup_does_not_clobber_an_edited_stylesheet`, and `test_stock_stylesheet_is_published_and_linked`, which the spec's table implied but did not name — 21 in total.

**Deviation from the spec, deliberate.** The spec said the stylesheet would style "the posted-on/category line". `post.txt` gives that paragraph no hook, so Task 4 adds `class="meta"` to `.source/templates/post.txt`. That is a template change the spec did not name. It reaches new installs only, like the `base.txt` edit beside it, and no test asserts on `post.txt`'s own markup (checked: all 130 `<p>` occurrences in `tests/run.sh` are post bodies the tests author themselves). Flagging it for the branch review rather than doing it silently.

**Verified before writing.** Every Makefile block and every `$(error)` message in this plan was run against a real copy of the Makefile, not composed from inspection: the full patch builds six files from one post and three assets; all six error paths fire with the messages quoted here; the no-op rebuild copies nothing; a touched source re-copies; `x{1,2}y.css` publishes under the quoted recipe. Two message defects were found and fixed that way — `\#` and `\\` reach an `$(error)` with their backslashes intact, because make's escape works in a plain assignment but not inside a function argument. Hence `HASH := \#`, and the backslash named in words.
