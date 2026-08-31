# Refusing a decorated date in a post filename — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close `docs/backlog.md` item 15 — a repeated hyphen inside a post filename's y-m-d span builds a page path with a repeated slash, which the kernel collapses onto another post's permalink, silently overwriting it at exit 0.

**Architecture:** One new clause in `check_post_name`, last of six, requiring the filename's date-and-category segment to begin with its own three date fields joined by single hyphens. `$(word)` normalizes where `$(wordlist)` preserves, so building a prefix from one and matching it against the raw segment detects exactly the decoration `$(wordlist)` would have carried into the path. No recipe, no shell, no new file.

**Tech Stack:** GNU make (4.2 floor), bash, the existing `tests/run.sh` suite.

**Spec:** `docs/superpowers/specs/2026-08-24-repeated-hyphen-permalink-clobber-design.md`. Read it before Task 1; it carries the survey tables and the mutation evidence this plan assumes.

## Global Constraints

- **GNU make 4.2 floor**, enforced by a `$(MAKE_VERSION)` guard. Do not use constructs newer than that.
- **Tabs in the Makefile.** Recipes are `@`-prefixed. Every helper and rule gets a `#`-banner comment block in the existing style.
- **No new dependency, no new file.** If a change cannot be expressed in make + awk + coreutils, it does not belong here.
- **`tests/run.sh` uses tabs** for indentation and a `#`-banner comment above each test.
- **A test must be watched failing** against the specific regression it guards, or — where the behaviour is already correct on `main` — proved by a named mutation that was actually run. A test that can only pass is worse than no assertion.
- **Baseline is 526 passed / 0 failed** (one environmental SKIP for `chflags` on Linux). Run the suite from a scratch copy: `cp Makefile .source tests tools` into a scratch dir, then `MAKE=make bash tests/run.sh`. Never build in the real repo tree.
- **Record measured numbers, do not predict them.** Every count in a commit message or comment must be one you ran.

---

### Task 1: The clause, and the three tests that can be watched failing

**Files:**
- Modify: `Makefile` — insert two helpers above `check_post_name` (currently line 845) and a sixth clause into it (clauses currently lines 846-850)
- Modify: `tests/run.sh` — three new test functions, plus three registrations in the runner list, after the `test_empty_title_slug_is_rejected` line at 4530

**Interfaces:**
- Produces: `date_prefix` and `filter_date_prefix`, two recursively-expanded make functions taking a bare post filename (no `posts/` prefix). `filter_date_prefix` returns non-empty when the name is **acceptable** and empty when it must be refused. Task 2 refers to both by name.
- Consumes: the existing `dc_words` (Makefile line 633) and `date_and_category` (line 624). Both already take a bare filename.

- [ ] **Step 1: Write the two failing tests**

Add all three functions to `tests/run.sh`, immediately after `test_empty_title_slug_is_rejected` (which ends around line 2884), keeping the `#`-banner style:

```bash
#
# A doubled hyphen INSIDE the y-m-d span builds a page path
# carrying a doubled slash -- build/2026/01//02/x.html --
# which the kernel collapses onto build/2026/01/02/x.html
# while CHECKED_POST_PAGES compares the two path strings
# byte-exactly and reports no collision. Exit 0, and
# whichever rule runs last wins the write.
#
# The load-bearing assertion is that the TWIN's page still
# holds its own body, not merely that the build failed. The
# bug is a silent overwrite; a test asserting only exit
# status would pass against a "fix" that refused the name
# after clobbering.
#
test_repeated_hyphen_before_the_day_is_rejected() {
	sandbox repeated_hyphen_before_the_day_is_rejected
	add_post '2026-01-02-home_x.txt' <<'EOF'
title: Real
-----------------------------------
<p>REAL BODY</p>
EOF
	build || return
	assert_grep build/2026/01/02/x.html 'REAL BODY'
	add_post '2026-01--02-evil_x.txt' <<'EOF'
title: Evil
-----------------------------------
<p>EVIL BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026-01--02-evil_x.txt'
	assert_out_grep 'repeated or leading hyphen in date'
	assert_grep build/2026/01/02/x.html 'REAL BODY'
}

#
# The sibling shape, between the year and the month. It gets
# its own function rather than a second loop iteration
# because `build_expect_fail || return` returns from the whole
# FUNCTION, not from the loop -- so a looped form stops at the
# first shape during the RED run and the second shape is never
# watched failing at all. Verified: the looped form failed
# only iteration 1 against the unfixed Makefile.
#
test_repeated_hyphen_before_the_month_is_rejected() {
	sandbox repeated_hyphen_before_the_month_is_rejected
	add_post '2026-01-02-home_x.txt' <<'EOF'
title: Real
-----------------------------------
<p>REAL BODY</p>
EOF
	build || return
	assert_grep build/2026/01/02/x.html 'REAL BODY'
	add_post '2026--01-02-evil_x.txt' <<'EOF'
title: Evil
-----------------------------------
<p>EVIL BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/2026--01-02-evil_x.txt'
	assert_out_grep 'repeated or leading hyphen in date'
	assert_grep build/2026/01/02/x.html 'REAL BODY'
}

#
# The collateral, asserted deliberately so a reader finds it
# intended rather than incidental. A leading hyphen builds
# correctly today when it is alone: make's tokenizer skips
# it, so the page path is identical to the undecorated
# name's and the existing collision check already catches
# the only case that can clobber anything. It is refused
# anyway, because the date span is where decoration is
# refused and `make new` already refuses DATE=-2026-01-02.
#
test_leading_hyphen_in_date_is_rejected() {
	sandbox leading_hyphen_in_date_is_rejected
	add_post '-2026-01-02-home_q.txt' <<'EOF'
title: Leading
-----------------------------------
<p>LEADING BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'posts/-2026-01-02-home_q.txt'
	assert_out_grep 'repeated or leading hyphen in date'
	assert_no_file 'build/2026/01/02/q.html'
}
```

Register both by adding these two lines to the runner list, directly after the existing `test_empty_title_slug_is_rejected` line (near line 4530):

```
test_repeated_hyphen_before_the_day_is_rejected
test_repeated_hyphen_before_the_month_is_rejected
test_leading_hyphen_in_date_is_rejected
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd "$(mktemp -d)" && cp -r /home/andre/Code/grampa/{Makefile,.source,tests,tools} . && MAKE=make bash tests/run.sh 2>&1 | grep -E "^FAIL|^passed:"
```

Expected: **all three** new tests FAIL, each at `make succeeded but should have failed` — the clobber is live, so the second build exits 0. **If any of the three passes here, stop**: the fixture is wrong and would guard nothing.

Three and not two is the whole reason the two repeated-hyphen shapes are separate functions. `build_expect_fail || return` returns from the *function*, so a single looped test stops after the first shape and the second is never watched failing — measured, in the looped form this plan originally carried: `passed: 527 failed: 2`, with iteration 2 never reached.

- [ ] **Step 3: Write the two helpers**

Insert **above `check_post_name`'s existing comment banner** — not between that banner and the function it describes — including the whole comment block below. The banner currently ends at line 844 and `check_post_name = \` begins at 845; the new helpers and their block go above line 844, so the banner stays adjacent to the function. Step 4 then appends a paragraph to the end of that banner.

```make
#
# The date span must be undecorated: the filename's
# date-and-category segment has to BEGIN with its own three
# date fields joined by single hyphens.
#
# $(word) normalizes where $(wordlist) preserves. $(wordlist)
# returns the substring of the original text running from the
# first selected word to the last, so internal spacing
# survives it -- which is why path_from_filename turns
# 2026-01--02 into 2026/01//02, a path the kernel collapses
# onto another post's permalink while CHECKED_POST_PAGES
# compares the two strings byte-exactly and sees nothing
# wrong. Building the prefix from $(word) and matching it
# against the raw segment detects exactly the decoration
# $(wordlist) would otherwise carry into the path.
#
# Scoped to the date span on purpose. A hyphen run AFTER the
# day is category territory, where runs are legal and where
# make new writes them: CATEGORY='a--b' produces
# 2026-01-02-a--b_x.txt, which builds category/a--b.html.
# Such a run is harmless here because it falls OUTSIDE
# $(wordlist 1, 3, ...)'s window, so path_from_filename
# returns a byte-identical 2026/01/02 and a twin is caught by
# CHECKED_POST_PAGES the ordinary way. It is not that anything
# collapses the run: category_slug preserves it -- that is why
# the page is a--b.html -- and the category never appears in a
# post URL at all.
#
# This closes // in a page path but NOT /./, and . is a legal
# filename character: 2026-.-01-home_x.txt would build
# 2026/./01/x.html and collide by the same mechanism. It does
# not build only because CHECKED_POST_DATES refuses every
# dotted field first. Relaxing the calendar check reopens
# this.
#
date_prefix = $(word 1,$(call dc_words,$(1)))-$(word 2,$(call dc_words,$(1)))-$(word 3,$(call dc_words,$(1)))-
filter_date_prefix = $(filter $(call date_prefix,$(1))%,$(call date_and_category,$(1)))
```

- [ ] **Step 4: Add the sixth clause**

`check_post_name`'s last clause is currently the `post_slug` one and has no trailing `\`. Give it one and append:

```make
	$(if $(call post_slug,$(1)),,$(error posts/$(1): empty title slug in filename; expected y-m-d-category_title.txt))\
	$(if $(call filter_date_prefix,$(1)),,$(error posts/$(1): repeated or leading hyphen in date; expected y-m-d-category_title.txt))
```

Then extend the existing comment banner above `check_post_name` — the one that already explains why characters are checked first — by appending this paragraph to it:

```make
# The date-shape clause is last of the six, and both clauses
# it must follow are about the MESSAGE rather than about
# safety. Unlike the character check's standing over
# BAD_POST_DATES, this detector reaches no shell at all:
# $(filter) is pure text and executes nothing. Placed first
# it merely reports its own message for a name whose real
# fault is a bad character -- a % in a date field builds a
# two-% pattern, which matches nothing -- or a missing field.
# It follows the empty-category clause for a second reason
# too: % matches the empty string, so a segment exactly equal
# to its own date prefix would be ACCEPTED here, and is
# unreachable only because such a segment means an empty
# category, refused by the clause above.
```

- [ ] **Step 5: Run the suite to verify green**

```bash
cd "$(mktemp -d)" && cp -r /home/andre/Code/grampa/{Makefile,.source,tests,tools} . && MAKE=make bash tests/run.sh 2>&1 | tail -3
```

Expected: 0 failed, and a pass count **above** 526. The review measured **537** after Task 1 and **544** after Task 2; splitting the looped test moves assertions between functions rather than adding any, so those should still hold. Record the actual number — it goes in the commit message, and a predicted count is not a measured one.

- [ ] **Step 6: Verify the closure measurement, which needs an unbuilt tree**

```bash
cd "$(mktemp -d)" && cp -r /home/andre/Code/grampa/{Makefile,.source} . && make setup >/dev/null 2>&1
printf 'title: R\n-----------------------------------\n<p>R</p>\n' > posts/2026-01-02-home_x.txt
printf 'title: E\n-----------------------------------\n<p>E</p>\n' > posts/2026-01--02-evil_x.txt
make 2>&1 | tail -2
```

Expected: refused at parse with `repeated or leading hyphen in date`. Then delete the offending post, add every accepted shape from the spec's table, and confirm the target strings carry no repeated slash:

```bash
rm posts/2026-01--02-evil_x.txt
for n in 2026-7-4-home_y 26-7-4-home_z 2026-03-04-a--b_w 2026-05-06-project-ideas_v 2026-05-07-._u; do
  printf 'title: T\n-----------------------------------\n<p>B</p>\n' > "posts/$n.txt"
done
make clean >/dev/null 2>&1
make -n 2>/dev/null | grep -o 'build/[^ "]*' | grep -c '//'
```

Expected: `0`. The `make clean` is load-bearing — on an already-built tree `make -n` prints nothing and scores 0 regardless, which is not evidence of anything.

- [ ] **Step 7: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Refuse a repeated or leading hyphen in a post filename's date"
```

Use a body explaining the mechanism ( `$(wordlist)` preserves internal spacing, `$(word)` does not ) and quoting the measured suite count from Step 5.

---

### Task 2: The two tests that cannot fail on `main`, plus the scope test, each proved by a named mutation

**Files:**
- Modify: `tests/run.sh` — three new test functions plus three registrations

**Interfaces:**
- Consumes: `filter_date_prefix` and the sixth clause from Task 1. The mutations below move or rewrite that clause; none of them changes its name.

These three assert behaviour that is **already correct on `main`**, so none can be watched failing. Each is proved by running a mutation. Do not skip the mutation runs — a test that claims to pin something it does not is the defect `docs/backlog.md` item 14 instance 16 records.

- [ ] **Step 1: Write the three tests**

Add after the two from Task 1:

```bash
#
# The date-shape clause must stay BELOW the character clause,
# and the reason is the message rather than safety: $(filter)
# reaches no shell, so nothing executes in either order. A %
# in a date field builds a two-% pattern that matches nothing,
# so the clause placed first refuses this name for a reason
# that is not the reason.
#
# Cannot fail against main -- the character clause is
# pre-existing. Proved by mutation: move the date-shape clause
# to first in check_post_name and this reports "repeated or
# leading hyphen in date" instead.
#
test_date_shape_error_follows_the_character_error() {
	sandbox date_shape_error_follows_the_character_error
	add_post '2026-%1-02-home_x.txt' <<'EOF'
title: Both Wrong
-----------------------------------
<p>BOTH WRONG BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'illegal character'
	assert_out_not_grep 'repeated or leading hyphen in date'
}

#
# And below the empty-category clause. 2026-01_x.txt has no
# third field, so $(word 3,...) is empty and the detector
# refuses it for a reason that is not the reason.
#
# Cannot fail against main -- the empty-category clause is
# pre-existing. Proved by the same mutation as its sibling
# above: clause first, and this reports the shape message.
#
test_date_shape_error_follows_the_empty_category_error() {
	sandbox date_shape_error_follows_the_empty_category_error
	add_post '2026-01_x.txt' <<'EOF'
title: No Category
-----------------------------------
<p>NO CATEGORY BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep 'empty category'
	assert_out_not_grep 'repeated or leading hyphen in date'
}

#
# The scope line: a hyphen run AFTER the day is category
# territory and stays legal, because category_slug collapses
# it out of the page path and make new writes such names
# (CATEGORY='a--b').
#
# Cannot fail against main, and it is NOT the only thing that
# catches the tightening it guards: overtightening the rule to
# the whole segment ($(findstring --,$(call
# date_and_category,$(1)))) already fails
# test_new_trims_edge_hyphens_from_category, measured at
# 524/1. That test catches it INCIDENTALLY, though -- it is a
# make new test that happens to build, and its failure reads
# "make failed unexpectedly (exit 2)", naming nothing about
# scope. This one exists to name the reason, not to be the
# only net.
#
test_doubled_hyphen_category_still_builds() {
	sandbox doubled_hyphen_category_still_builds
	add_post '2026-01-02-a--b_x.txt' <<'EOF'
title: Interior Run
-----------------------------------
<p>INTERIOR BODY</p>
EOF
	build || return
	assert_file 'build/2026/01/02/x.html'
	assert_file 'build/category/a--b.html'
	assert_grep 'build/category/a--b.html' 'INTERIOR BODY'
}
```

Register all three after the two registered in Task 1.

- [ ] **Step 2: Run the suite to confirm all three pass**

```bash
cd "$(mktemp -d)" && cp -r /home/andre/Code/grampa/{Makefile,.source,tests,tools} . && MAKE=make bash tests/run.sh 2>&1 | tail -3
```

Expected: 0 failed. Record the count.

- [ ] **Step 3: Prove the ordering tests by mutation**

In a scratch copy only, move the date-shape clause from last to first inside `check_post_name` — cut the `$(if $(call filter_date_prefix,...))` line and paste it directly after `check_post_name = \`, fixing the trailing backslashes so the last clause has none.

```bash
MAKE=make bash tests/run.sh 2>&1 | grep -E "^FAIL|^passed:"
```

Expected: **both** `date_shape_error_follows_the_character_error` and `date_shape_error_follows_the_empty_category_error` FAIL. If only one fails, one of the two is inert — fix the fixture before continuing. Discard the scratch copy.

- [ ] **Step 4: Prove the scope test by mutation**

In a fresh scratch copy, replace the clause's condition with the overtightened form:

```make
	$(if $(findstring --,$(call date_and_category,$(1))),$(error posts/$(1): repeated or leading hyphen in date; expected y-m-d-category_title.txt))
```

```bash
MAKE=make bash tests/run.sh 2>&1 | grep -E "^FAIL|^passed:"
```

Expected: **three** failures — `doubled_hyphen_category_still_builds`, the pre-existing `new_trims_edge_hyphens`, and `leading_hyphen_in_date_is_rejected`. Measured `passed: 536 failed: 3`.

The third is not noise and is worth recording: `$(findstring --,-2026-01-02-home)` is empty, so the overtightened form does not see a lone leading hyphen at all and `-2026-01-02-home_q.txt` builds under it. Task 1's collateral test independently pins that mutation. Record all three. Discard the scratch copy.

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh
git commit -m "Pin the date-shape clause's ordering and its scope line by mutation"
```

Body should record which mutation each test was proved against and the measured failure counts from Steps 3 and 4.

---

### Task 3: Documentation

**Files:**
- Modify: `CLAUDE.md` — the Post format section, which currently says there are five parse-time filename rules and that this is "the one place to find them" (near line 235)
- Modify: `docs/backlog.md` — item 15, currently headed `### 15. NEW, STILL OPEN — …`

- [ ] **Step 1: Update CLAUDE.md's Post format section**

Change the "five rules in all" sentence to six. Add a paragraph in the existing voice covering, in this order: what is refused (`2026--01-02`, `2026-01--02`, `-2026-01-02`); the mechanism in one sentence (`$(wordlist)` preserves internal spacing, so the path gained a `//` the kernel collapsed onto another post's permalink while the guard compared strings); the scope line and why decoration after the day stays legal; the collateral that `-2026-01-02-home_q.txt` used to build; and the counterexample that a leading **dot** is not refused but invisible, since `POST_LS` is `ls posts` without `-A`.

Do not restate the calendar-check dependency here as well as in the Makefile. State it once, in the Makefile comment, and point at it. Three attempts to compress a two-place mechanism into a CLAUDE.md bullet each produced something false — see `docs/backlog.md` item 14, whose only reliable cure is one statement in one place plus a pointer.

- [ ] **Step 2: Update the backlog**

Rewrite item 15's heading to `### 15. DONE — a hand-typed doubled-hyphen date in a post filename silently clobbered a same-permalink post's page at exit 0`, and add the closure above the original finding, keeping `Original finding follows.` and the finding itself intact, exactly as every other closed item in that file does.

The closure should record, because each cost something to learn:
- the fix in one sentence, and that it is scoped to the date span;
- that the spec's first closure measurement was **vacuous** — `find build … | grep -c '//'` returns 0 on every Makefile, since the kernel collapses the slash at file creation — and that the working instrument reads make's target strings from an **unbuilt** tree, scoring 4 on the bug and 0 on the fix;
- that three of the five tests cannot fail against `main` and are mutation-proved instead, with the mutations named;
- that the scope test is not the only net for its mutation (`test_new_trims_edge_hyphens_from_category` catches it at 524/1) and exists to name the reason;
- the two residuals this does **not** close: `/./` via dotted date fields, held shut only by `CHECKED_POST_DATES`, and the leading-dot names that `POST_LS` cannot see.

- [ ] **Step 3: Add the item-14 count**

Item 14 counts this repo's recurring confident-but-false-claim defect, currently at eighteen. The vacuous closure measurement is instance nineteen: a claim that read as a measurement, passed review twice, and was false in the section titled "What closes the item". Add it in the established style — what was claimed, why it was false, and that it was caught by running the instrument against the unfixed tree rather than by reading it.

- [ ] **Step 4: Verify the docs against the code**

Every filename shape named in the new CLAUDE.md paragraph must be run, not asserted:

```bash
cd "$(mktemp -d)" && cp -r /home/andre/Code/grampa/{Makefile,.source} . && make setup >/dev/null 2>&1
for n in '2026--01-02-evil_x' '2026-01--02-evil_x' '-2026-01-02-home_q' '2026-01-02--evil_x' '2026-01-02-a--b_w'; do
  printf 'title: T\n-----------------------------------\n<p>B</p>\n' > "posts/$n.txt"
  printf '%-24s -> ' "$n"; make -n >/dev/null 2>&1 && echo builds || echo refused
  rm -f "posts/$n.txt"
done
```

Expected: refused, refused, refused, builds, builds. Any disagreement with the paragraph means the paragraph is wrong.

Then confirm the invariant the spec leans on — that `make new` cannot write a filename the new
rule refuses, which is the whole reason `make new` exists:

```bash
for d in 2026-01--02 -2026-01-02 2026--01-02; do
  printf '%-14s -> ' "DATE=$d"
  make new TITLE=T CATEGORY=home DATE="$d" 2>&1 | grep -oE 'grampa: new:.*|Created.*' | head -1
done
make new TITLE=Notes CATEGORY='a--b' 2>&1 | grep -oE 'Created.*'
make >/dev/null 2>&1 && echo "tree still builds"
```

Expected: three `grampa: new: DATE must be YYYY-MM-DD` refusals, then a `Created posts/…-a--b_notes.txt`
that still builds. The suite already covers this through the `test_new_refuses_*` family and
`test_new_trims_edge_hyphens_from_category`, so this is a cross-check of the spec's claim rather
than new coverage — but the claim is the kind that reads true and is worth one command.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/backlog.md
git commit -m "Document the sixth filename rule and close backlog item 15"
```

---

## After the last task

Run the whole suite once more from a clean scratch copy and record the final count. Then dispatch the **whole-branch Fable review** — the fourth CLAUDE.md checkpoint — before merging. Give it the branch diff, the spec, and this plan, and tell it to prove claims by running commands in a sandbox rather than asserting from inspection.
