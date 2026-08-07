# Rejecting degenerate post filenames — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject two classes of degenerate post filename at parse time — those containing
ASCII punctuation other than `-`, `_`, `.`, and those whose date fields `date -v` refuses —
closing the glob-character-slug bug and the out-of-range-dates item in `docs/backlog.md`.

**Architecture:** Two independent parse-time checks in the same neighbourhood of the
Makefile. The character check is a fourth clause in `check_post_name`, driven by a list of
forbidden characters and a `foreach`/`findstring` fold — pure make, no process. The date
check is two-stage: make proves the ordinary case sound (all-digit year, month 1–12, day
1–28) and only forks to `date` for what it cannot clear. The character check must sit
textually **above** the date check, because the date check interpolates filenames into a
shell command line.

**Tech Stack:** GNU make 3.81, BSD `date`, bash, coreutils. No runtime, no dependencies.

**Spec:** `docs/superpowers/specs/2026-08-07-reject-degenerate-post-filenames-design.md`.
Read it before starting — in particular "Ordering is load-bearing", which is the one place
where getting the sequence wrong is a security bug rather than a style problem.

## Global Constraints

- **Tabs in the Makefile.** Recipe lines are tab-indented. These tasks add no recipes, only
  variables and functions, which are not tab-indented.
- **BSD/macOS only.** `date -v` is already assumed repo-wide. Do not add GNU-isms.
- **`#`-banner comment block above every new helper**, in the existing style.
- **Every test must be watched failing before the fix goes in.** A test that has never
  failed guards nothing. Six of the nine tests here can fail beforehand; three cannot, and
  are marked. Do not skip the RED run for the six.
- **The suite is `make test`** (runs `tests/run.sh` in throwaway sandboxes). Baseline is
  **223 passing, 0 failed** before this work starts, confirmed on 2026-08-07. Confirm that
  number first; if it does not match, stop and report rather than proceeding.
- **New tests must be added to the runner list at the bottom of `tests/run.sh`**, or they
  silently never run.
- **Review cycle.** Per `CLAUDE.md`, each finished task's diff goes to the Fable model via
  the `Agent` tool with `model: "fable"` before the next task starts.
- **Never build in the real repo and never touch `posts/`.** Probes go in throwaway
  directories copying `Makefile`, `.source/`, and `tools/`, the way `tests/run.sh` does.

---

### Task 1: The character check

**Files:**
- Modify: `Makefile` — new `BAD_CHARS` / `bad_chars_in` block immediately above the
  `check_post_name` comment block at `Makefile:215-224`; a fourth clause inside
  `check_post_name` itself
- Test: `tests/run.sh` — three new tests, plus three names in the runner list at the bottom

**Interfaces:**
- Produces: `BAD_CHARS`, a 29-element list of forbidden characters; `bad_chars_in`, a
  function taking a filename and returning the space-separated forbidden characters found in
  it, empty if none. Task 2 does not call either, but depends on `check_post_name` erroring
  first — see Task 2's ordering step.
- Consumes: nothing.

- [ ] **Step 1: Confirm the baseline**

Run: `make test 2>&1 | tail -3`
Expected: `passed: 223  failed: 0`. If not, stop and report.

- [ ] **Step 2: Write the three failing tests**

Add to `tests/run.sh`, after `test_body_title_line_is_not_the_page_title`:

```bash
#
# The bug this whole change exists for. posts/…_a[b]c.txt
# beside posts/…_abc.txt builds at exit 0 today and ships
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
```

Add the three names to the runner list at the bottom of `tests/run.sh`, after
`test_default_build_works_with_a_file_named_all`:

```
test_glob_character_slug_is_rejected
test_shell_metacharacter_slug_is_rejected
test_unusual_but_safe_slug_still_builds
```

- [ ] **Step 3: Run the three tests and watch two of them fail**

Run: `make test 2>&1 | grep -A4 'glob_character_slug\|shell_metacharacter_slug\|unusual_but_safe'`

Expected:
- `test_glob_character_slug_is_rejected` **FAILS** — `make succeeded but should have failed`.
- `test_shell_metacharacter_slug_is_rejected` **FAILS** — iteration 2 (`a*c`) fails with
  `make succeeded but should have failed`; iterations 1, 3, and 4 fail on the
  `illegal character` assertion, which is exactly the point of asserting on the message.
- `test_unusual_but_safe_slug_still_builds` **PASSES** — it is a guard, not a bug test.

If `test_unusual_but_safe_slug_still_builds` fails here, stop: something is wrong with the
sandbox or the accented filename, not with the change.

- [ ] **Step 4: Add `BAD_CHARS` and `bad_chars_in`**

In `Makefile`, immediately above the `check_post_name` comment block that begins at
`Makefile:215`:

```make
#
# Every ASCII punctuation character except the three a post
# filename actually needs: - separates the date fields and
# the category words, _ separates the date/category half
# from the title slug, and . carries the .txt extension.
#
# The set is closed by enumeration rather than by judging
# which characters look dangerous. That is the whole point:
# the glob-character bug this closes existed because [ and ]
# were not on anybody's list of scary characters. Letters,
# digits, and every non-ASCII byte are allowed, which is what
# keeps posts/2026-01-02-home_café.txt building.
#
# \# and $$ are make escapes, not part of the set. Space and
# tab cannot be elements of a make list at all -- a filename
# containing a space splits POST_NAMES into two words and
# dies on the "no category in filename" clause below, naming
# a fragment of the filename rather than the whole thing.
# Loud, if not pretty; verified.
#
BAD_CHARS := ! " \# $$ % & ' ( ) * + , / : ; < = > ? @ [ \ ] ^ ` { | } ~

#
# The forbidden characters present in a filename, or empty.
# findstring returns its needle when found, so the foreach
# collects one word per offending character.
#
bad_chars_in = $(strip $(foreach c,$(BAD_CHARS),$(findstring $(c),$(1))))
```

- [ ] **Step 5: Add the clause to `check_post_name`**

`check_post_name` currently ends with the empty-category clause. Add a fourth clause as the
**first** line of the function, so a filename is rejected on characters before any of the
shape clauses try to make sense of it:

```make
check_post_name = \
	$(if $(call bad_chars_in,$(1)),$(error posts/$(1): illegal character in filename: $(call bad_chars_in,$(1)); a post filename may contain letters, digits, and only these punctuation marks: - _ .))\
	$(if $(word 3,$(call underscore_split,$(1))),$(error posts/$(1): more than one _ in filename; expected y-m-d-category_title.txt))\
	$(if $(word 2,$(call underscore_split,$(1))),,$(error posts/$(1): no category in filename; expected y-m-d-category_title.txt))\
	$(if $(call category_slug,$(1)),,$(error posts/$(1): empty category in filename; expected y-m-d-category_title.txt))
```

- [ ] **Step 6: Verify the list is 29 elements and the message survives a `#`**

A `#` produced by expansion is not a comment, but the error message interpolates
`bad_chars_in`'s output, so confirm rather than assume. In a throwaway directory:

```bash
SB=$(mktemp -d)
cp Makefile "$SB"/; cp -R .source tools "$SB"/
cd "$SB" && make setup >/dev/null 2>&1
: > 'posts/2026-01-02-home_a#c.txt'
make 2>&1 | head -2
cd - >/dev/null
```

Expected: an error naming `posts/2026-01-02-home_a#c.txt` and showing `#` as the illegal
character. Also confirm the list length:

```bash
make -f /dev/stdin probe <<'EOF' 2>&1
include Makefile
probe: ; @true
$(info BAD_CHARS has $(words $(BAD_CHARS)) elements)
EOF
```

Expected: `BAD_CHARS has 29 elements`.

**Name the `probe` goal explicitly.** `include Makefile` pulls in every target, so a bare
`make -f /dev/stdin` takes `all` as the default goal and builds — in whatever directory you
are standing in, which is the real repo. The `$(info)` fires during the parse either way, so
the explicit goal costs nothing.

- [ ] **Step 7: Run the three tests and watch them pass**

Run: `make test 2>&1 | grep -A4 'glob_character_slug\|shell_metacharacter_slug\|unusual_but_safe'`
Expected: no `FAIL:` lines for any of the three.

- [ ] **Step 8: Run the full suite**

Run: `make test 2>&1 | tail -3`
Expected: **`failed: 0`**, with `passed:` risen from 223 by the number of new assertions —
3 from test 1, 8 from test 2 (two per iteration, four iterations), 3 from test 3, so 237.
The gate is `failed: 0`; treat the count as a check that all three tests actually ran rather
than as a target to hit. The character check runs against every post filename in every
sandbox, so a mistake in `BAD_CHARS` shows up as failures in tests unrelated to this work.

- [ ] **Step 9: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Reject post filenames containing ASCII punctuation.

Closes the glob-character slug: posts/2026-01-02-home_a[b]c.txt beside
posts/2026-01-02-home_abc.txt built at exit 0 and published the
SIBLING's body, because \$< is unquoted in the %.staged recipe and the
shell glob-expanded it onto the neighbour. This was the last path in
the repo from a healthy source tree to silently wrong output.

The set is every ASCII punctuation character except - _ and . --
closed by enumeration rather than by judging which look dangerous,
which is the mistake that let [ and ] through in the first place.
Letters, digits, and non-ASCII bytes still build, so an accented or
capitalised slug is unaffected. % and + stop building; % was a make
pattern-rule landmine that happened not to have gone off.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EvhfVMG4ZgqGQLw5ggnAjU"
```

- [ ] **Step 10: Fable review of this task's diff**

Per `CLAUDE.md`, dispatch the `Agent` tool with `model: "fable"` on the Task 1 diff before
starting Task 2. Give it the Makefile framing from `CLAUDE.md`'s review-cycle section, tell
it the character policy is settled with the user, and ask it to prove claims by running
builds in a sandbox.

---

### Task 2: The date check

**Files:**
- Modify: `Makefile` — `date_words` / `date_args` helpers above `date_from_filename`
  (`Makefile:167-170`); `rfc822_from_filename` (`Makefile:186`) rewritten to use `date_args`;
  the two-stage check added immediately below `CHECKED_POST_NAMES` (`Makefile:225`) and above
  `.DELETE_ON_ERROR:` (`Makefile:231`)
- Test: `tests/run.sh` — six new tests, plus six names in the runner list

**Interfaces:**
- Consumes: `check_post_name`'s character clause from Task 1, which **must** already be in
  place. The `$(shell)` here interpolates filenames unquoted; without Task 1 a filename
  containing `` ` `` or `$(` executes during the parse.
- Produces: `date_words` (a filename → the three date fields as words), `date_args` (a
  filename → `-v<y>y -v<m>m -v<d>d`), `strip_digits`, `DATE_OK_MONTHS`, `DATE_OK_DAYS`,
  `date_is_sound` (a filename → `x` if make can prove `date` will accept it, else empty),
  `SUSPECT_POST_DATES`, `BAD_POST_DATES`, `CHECKED_POST_DATES`.

- [ ] **Step 1: Write the six failing tests**

Add to `tests/run.sh`, after the three from Task 1:

```bash
#
# date -v already rejects this date and exits 1. Nothing
# hears it: date_from_filename is a $(shell) call, which
# keeps the output and discards the status, and make 3.81
# has no .SHELLSTATUS. So today the page ships with an empty
# posted-on line and an empty <pubDate>.
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
# CANNOT FAIL BEFORE THE CHANGE. Unpadded dates are
# documented as supported and are the likeliest thing an
# over-strict date check would break.
#
test_unpadded_date_still_builds() {
	sandbox unpadded_date_still_builds
	add_post '2026-7-4-home_unpadded.txt' <<'EOF'
title: Unpadded
-----------------------------------
<p>UNPADDED BODY</p>
EOF
	build || return
	assert_grep 'build/2026/7/4/unpadded.html' 'UNPADDED BODY'
}

#
# CANNOT FAIL BEFORE THE CHANGE. The guard on the prefilter
# boundary: all three of these are days stage one declines
# to clear, so this is the only test exercising stage two's
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
```

Add the six names to the runner list at the bottom of `tests/run.sh`:

```
test_out_of_range_date_is_rejected
test_non_numeric_date_is_rejected
test_impossible_calendar_date_is_rejected
test_non_leap_february_29_is_rejected
test_unpadded_date_still_builds
test_month_end_dates_still_build
```

- [ ] **Step 2: Run the six tests and watch four of them fail**

Run: `make test 2>&1 | grep -A4 'out_of_range_date\|non_numeric_date\|impossible_calendar\|non_leap_february\|unpadded_date\|month_end_dates'`

Expected: the first four **FAIL** with `make succeeded but should have failed`;
`test_unpadded_date_still_builds` and `test_month_end_dates_still_build` **PASS**.

If either of the last two fails here, stop — the date check has not been written yet, so a
failure means the test itself is wrong.

- [ ] **Step 3: Factor out `date_words` and `date_args`**

Both `date_from_filename` and `rfc822_from_filename` build the same `-v` triple, and the new
check must build it *identically* or it answers a slightly different question than the build
asks. Replace `Makefile:167-170`:

```make
#
# The three date fields of a post filename, as words, and
# the date -v arguments they make. Three call sites share
# these: the two date formatters below and the parse-time
# date check further down. The check's correctness depends
# on it running the same arguments the build will, so this
# is factored rather than repeated.
#
date_words = $(wordlist 1, 3, $(subst -, , $(notdir $(1))))
date_args = $(join $(addprefix -v, $(call date_words,$(1))), y m d)

#
# Creates a formatted date from a file name.
#
date_from_filename = $(shell date $(call date_args,$(1)) "+%B %d, %Y")
```

And `Makefile:186`:

```make
rfc822_from_filename = $(shell LC_ALL=C date $(call date_args,$(1)) -v0H -v0M -v0S "+%a, %d %b %Y %H:%M:%S %z")
```

- [ ] **Step 4: Prove the refactor is byte-identical before going further**

This touches every page's and the feed's critical path, so verify it in isolation, with the
date check not yet added. `HEAD` at this point is Task 1's commit, so the only difference
between the two trees is the refactor itself — which is what makes this an isolation test
rather than a general regression check. Do not reorder this after Step 5.

```bash
SB=$(mktemp -d); ORIG=$(mktemp -d)
for d in "$SB" "$ORIG"; do cp -R .source tools "$d"/; done
cp Makefile "$SB"/
git show HEAD:Makefile > "$ORIG/Makefile"
for d in "$SB" "$ORIG"; do
  (cd "$d" && make setup >/dev/null 2>&1
   printf 'name=T\nurl=https://example.com\n' > config
   for i in $(seq 1 12); do
     printf 'title: Post %s & more\n-----------------------------------\n<p>body %s</p>\n' "$i" "$i" \
       > "posts/2026-01-$(printf '%02d' $i)-project-ideas_post-$i.txt"
   done
   make >/dev/null 2>&1)
done
diff -r "$SB/build" "$ORIG/build" && diff -r "$SB/work" "$ORIG/work" && echo "IDENTICAL"
```

Expected: `IDENTICAL`. If it differs, the refactor is wrong — fix it before adding the
check, so the check is never blamed for a rendering change.

- [ ] **Step 5: Add stage one — the pure-make prefilter**

Immediately below `CHECKED_POST_NAMES := …` at `Makefile:225`:

```make
#
# Strips every digit out of a string. An all-digit string
# leaves nothing behind; anything else leaves its non-digit
# characters. Note an empty string also leaves nothing, so
# callers must check for emptiness separately.
#
strip_digits = $(subst 0,,$(subst 1,,$(subst 2,,$(subst 3,,$(subst 4,,$(subst 5,,$(subst 6,,$(subst 7,,$(subst 8,,$(subst 9,,$(1)))))))))))

#
# Months 1-12 and days 1-28, padded and unpadded. 28 and not
# 31 on purpose: 28 is the largest day valid in every month
# of every year, so clearing it needs no calendar knowledge
# at all. Days 29-31 are where month lengths and leap years
# start to matter, and those go to date itself below.
#
DATE_OK_MONTHS := 1 2 3 4 5 6 7 8 9 10 11 12 01 02 03 04 05 06 07 08 09
DATE_OK_DAYS := 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 01 02 03 04 05 06 07 08 09

#
# Non-empty when make can PROVE date will accept this
# filename's date: a non-empty all-digit year, a month in
# 1-12, a day in 1-28. It proves rather than judges -- it
# must never clear anything date would reject, and anything
# it cannot clear is a suspect rather than a reject.
#
# The $(strip) is load-bearing: $(if) treats a whitespace-
# only expansion as true, and the \-continuations below
# would otherwise produce one.
#
date_is_sound = $(strip \
	$(if $(word 1,$(call date_words,$(1))),\
	$(if $(call strip_digits,$(word 1,$(call date_words,$(1)))),,\
	$(if $(filter $(word 2,$(call date_words,$(1))),$(DATE_OK_MONTHS)),\
	$(if $(filter $(word 3,$(call date_words,$(1))),$(DATE_OK_DAYS)),x)))))
```

- [ ] **Step 6: Verify stage one clears and suspects the right names, before wiring stage two**

```bash
make -f /dev/stdin probe <<'EOF' 2>&1
include Makefile
probe: ; @true
NAMES := 2026-01-02-home_a.txt 2026-7-4-home_b.txt 26-7-4-home_c.txt 2026-01-31-home_d.txt 2026-02-30-home_e.txt 2026-13-40-home_f.txt 20xx-ab-cd-home_g.txt 2028-02-29-home_h.txt
$(foreach n,$(NAMES),$(info $(n) sound=[$(call date_is_sound,$(n))]))
EOF
```

The explicit `probe` goal is required for the same reason as in Task 1, Step 6: `include
Makefile` would otherwise make `all` the default goal and build the real repo.

Expected — `sound=[x]` for `2026-01-02`, `2026-7-4`, and `26-7-4`; `sound=[]` (suspect) for
`2026-01-31`, `2026-02-30`, `2026-13-40`, `20xx-ab-cd`, and `2028-02-29`.

**A `sound=[x]` on any of the last five is a correctness bug, not a performance one** — it
means a bad date would never reach `date`. Stop and fix.

- [ ] **Step 7: Add stage two — the batched `date` call**

Directly below `date_is_sound`:

```make
#
# The names stage one could not clear, asked of date itself.
# One shell invocation however many posts there are, running
# one date call per suspect -- which in practice is only
# posts dated the 29th to the 31st.
#
# date already rejects a bad date and exits 1. Nothing in
# the build hears it: date_from_filename is a $(shell) call,
# which keeps the output and throws the status away, and
# make 3.81 has no .SHELLSTATUS. So this is not a second
# implementation of date's judgement, it is the only way to
# hear a verdict date already reaches -- at parse time,
# where a non-zero exit can still become an $(error).
#
# THIS MUST STAY BELOW CHECKED_POST_NAMES. The $(shell)
# interpolates filenames into a shell command line
# unquoted, so a post named …_x$(shell touch PWNED).txt
# executes during the parse. Verified: with the character
# check above, the $(error) fires first and nothing runs;
# with the two swapped, the payload runs and is consumed,
# so even the resulting error message looks clean. Both are
# := , so this is a guarantee about textual order in this
# file and nothing else.
#
# The trailing `true` is for intent, not correctness --
# nothing reads this $(shell)'s exit status.
#
SUSPECT_POST_DATES := $(foreach n,$(POST_NAMES),$(if $(call date_is_sound,$(n)),,$(n)))
BAD_POST_DATES := $(shell $(foreach n,$(SUSPECT_POST_DATES),LC_ALL=C date $(call date_args,$(n)) -v0H -v0M -v0S >/dev/null 2>&1 || echo $(n);) true)
CHECKED_POST_DATES := $(if $(BAD_POST_DATES),$(error no such calendar date in: $(addprefix posts/,$(BAD_POST_DATES)); a post filename must begin with a real y-m-d date))
```

- [ ] **Step 8: Verify the ordering guarantee holds**

```bash
SB=$(mktemp -d)
cp Makefile "$SB"/; cp -R .source tools "$SB"/
cd "$SB" && make setup >/dev/null 2>&1
: > 'posts/20xx-01-02-home_x$(shell touch PWNED).txt'
make 2>&1 | head -2
ls PWNED 2>/dev/null && echo "LEAKED -- ordering is wrong" || echo "no leak"
cd - >/dev/null
```

Expected: an `illegal character` error from Task 1's check, and `no leak`.

- [ ] **Step 9: Run the six tests and watch them pass**

Run: `make test 2>&1 | grep -A4 'out_of_range_date\|non_numeric_date\|impossible_calendar\|non_leap_february\|unpadded_date\|month_end_dates'`
Expected: no `FAIL:` lines.

- [ ] **Step 10: Run the full suite**

Run: `make test 2>&1 | tail -3`
Expected: `failed: 0`. Every sandbox's post dates now go through both stages, so a mistake
here shows up across unrelated tests.

- [ ] **Step 11: Measure the cost and record the real number**

The spec projects ~0.135s against a 0.150s baseline but says explicitly that it must be
measured rather than trusted. Build a 60-post sandbox, all dated the 1st–28th so the
prefilter is doing its job, and time a no-op rebuild against `HEAD`'s Makefile.

`HEAD` is Task 1's commit, so this measures **the date check's cost specifically** — Fable
measured the character check at 0.120s against a 0.150s baseline, i.e. free, inside the
noise. That is the number worth having, since the date check is the only part with a
per-post process in it.

```bash
SB=$(mktemp -d); ORIG=$(mktemp -d)
for d in "$SB" "$ORIG"; do cp -R .source tools "$d"/; done
cp Makefile "$SB"/; git show HEAD:Makefile > "$ORIG/Makefile"
for d in "$SB" "$ORIG"; do
  (cd "$d" && make setup >/dev/null 2>&1
   for i in $(seq 1 60); do
     m=$(( (i % 12) + 1 )); dd=$(( (i % 28) + 1 ))
     printf 'title: Post %s\n-----------------------------------\n<p>body</p>\n' "$i" \
       > "posts/2026-$(printf '%02d' $m)-$(printf '%02d' $dd)-home_post-$i.txt"
   done
   make >/dev/null 2>&1)
done
for d in "$ORIG" "$SB"; do
  echo "== $d"
  ( cd "$d" && for n in 1 2 3 4 5 6 7 8; do /usr/bin/time -p make 2>&1 >/dev/null | awk '/^real/{print $2}'; done )
done
```

Take the mean of each set of eight. Put both numbers in the commit message. If the change
lands materially above the 0.150s baseline — say, past 0.25s — **say so in the commit rather
than shipping it quietly**; the repo has already spent a commit taking this from 0.79s to
0.12s.

- [ ] **Step 12: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Reject post filenames whose date does not exist.

date -v already rejects 2026-13-40, 20xx-ab-cd, and 2026-02-30 and
exits 1. Nothing heard it: date_from_filename is a \$(shell) call,
which keeps the output and discards the status, and make 3.81 has no
.SHELLSTATUS -- so the page shipped with an empty posted-on line and
an empty <pubDate>. This asks the same question at parse time, where a
non-zero exit can still become an \$(error).

Two stages. Make proves the ordinary case sound -- all-digit year,
month 1-12, day 1-28, which is valid in every month of every year --
and only forks to date for what it cannot clear, which is days 29-31
and anything malformed. That is the backlog's own proposed range check
with its known hole plugged: a 1-31 range passes 2026-02-30. The
result is leap-year exact, rejecting 2026-02-29 and building
2028-02-29.

No-op rebuild, 60 posts, mean of 8: BEFORE -> AFTER.

The check must stay below CHECKED_POST_NAMES: its \$(shell)
interpolates filenames unquoted, so a name carrying a backtick or
\$( executes during the parse. The character check rejects those
first. Comment in the Makefile says so.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EvhfVMG4ZgqGQLw5ggnAjU"
```

Replace `BEFORE -> AFTER` with the two measured means from Step 11 before committing.

- [ ] **Step 13: Fable review of this task's diff**

Dispatch `Agent` with `model: "fable"`. Ask it specifically to attack the prefilter: find a
date `date_is_sound` clears that `date` would reject, and confirm the ordering guarantee
independently.

---

### Task 3: Documentation pass

**Files:**
- Modify: `CLAUDE.md` — the "Post format" section; the BSD-only gotcha
- Modify: `docs/backlog.md` — two bullets marked DONE, ranked item 3 struck through, and one
  stale sentence in the staging-glob DONE note

**Interfaces:**
- Consumes: the finished behaviour from Tasks 1 and 2. No code changes.

- [ ] **Step 1: Update `CLAUDE.md`'s Post format section**

The section currently documents two parse-time errors — the one-underscore rule and the
duplicate-permalink check. Add the two new ones, so all four rules a filename must satisfy
are in one place. After the paragraph ending "`CHECKED_POST_PAGES` errors naming both files
rather than letting filename sort order pick a winner.", add:

```markdown
Two more parse-time errors guard the filename itself. **A filename may contain letters,
digits, and only `-`, `_`, and `.`** — every other ASCII punctuation character is rejected by
`BAD_CHARS`. Non-ASCII is fine, so `2026-01-02-home_café.txt` builds. This exists because a
slug containing glob characters used to publish a *different post*: `_a[b]c.txt` beside
`_abc.txt` built at exit 0 and shipped `abc`'s body, since `$<` is unquoted in the `%.staged`
recipe and the shell expanded the glob onto the neighbour before awk saw it. The set is every
ASCII punctuation character but three, closed by enumeration rather than by judging which
look dangerous — which is how `[` and `]` got through in the first place.

**The date must be a real one.** `2026-13-40`, `20xx-ab-cd`, `2026-02-30`, and non-leap
`2026-02-29` are all rejected; `2026-7-4` unpadded and `2028-02-29` build. The check is two
stages: make clears any all-digit year with month 1–12 and day 1–28 — valid in every month of
every year, so no calendar knowledge is needed — and only days 29–31 and malformed fields are
handed to `date` itself. `date` already rejected these dates and exited 1; nothing heard it,
because `date_from_filename` is a `$(shell)` call, which keeps the output and discards the
status, and make 3.81 has no `.SHELLSTATUS`. The result was a page with an empty posted-on
line and an empty `<pubDate>`.

**The date check must stay below `CHECKED_POST_NAMES` in the Makefile.** Its `$(shell)`
interpolates filenames into a shell command line unquoted, so a post named
`…_x$(shell touch PWNED).txt` executes during the parse. The character check rejects the
backtick and `$` first, which is the only reason that is safe — verified in both orders.
```

- [ ] **Step 2: Update the BSD-only gotcha in `CLAUDE.md`**

It currently reads:

```markdown
- **BSD-only.** `date_from_filename` uses `date -v` (BSD/macOS). It fails on GNU
  coreutils, so builds are macOS-only as written.
```

Replace with:

```markdown
- **BSD-only.** `date_from_filename` uses `date -v` (BSD/macOS). It fails on GNU
  coreutils, so builds are macOS-only as written. Since the parse-time date check calls the
  same `date -v`, GNU is now also where a *legal* filename gets rejected: posts dated the
  1st–28th are cleared by the pure-make stage and build, while a post dated the 31st becomes
  a suspect, `date -v` fails for the wrong reason, and the post is rejected as having a bad
  date. A confusing error on a platform this repo does not claim to support, and arguably an
  improvement on GNU's current behaviour, which is to publish empty date fields silently.
```

- [ ] **Step 3: Mark the two backlog bullets DONE**

In `docs/backlog.md`, the bullet beginning `**NEW — a slug containing shell glob characters
silently stages a same-date sibling's content**` and the bullet beginning `**Out-of-range
dates build successfully**`. Use the established shape — a DONE headline, what was done and
what it cost, then `Original finding follows.` and the untouched original text. Both should
record:

- that the fix was to reject the filename rather than to quote the recipes, and why (quoting
  one of three rules half-fixes it and reads as closed);
- that the character set is closed by enumeration, and that `%` and `+` are collateral;
- that the date check turned out leap-year exact, which is more than the item asked for;
- the measured rebuild cost from Task 2, Step 11;
- that the two checks are order-dependent, with the demonstrated injection case named.

- [ ] **Step 4: Strike through ranked item 3 and fix the stale sentence**

In the "What is left, in rough order of how much a reader would care" list, strike through
item 3 (`**Out-of-range dates build successfully**`) in the established `~~…~~` style with a
one-line note.

Then fix the stale sentence in item 1's DONE note, which currently reads:

> That leaves item 5 as the only remaining bullet producing silently wrong output on a
> strange post, plus the newly found glob-character slug above, which is worse than item 5 in
> kind and rarer in practice.

The glob-character slug is no longer open, so this sentence is now false — exactly the class
of stale-but-confident claim the backlog's own item 4 and item 6 were about. Rewrite it to
say the glob-character slug has since been closed and name item 5 (the residual placeholder
hole) as what remains.

- [ ] **Step 5: Verify the docs against the code**

Every claim added in Steps 1–2 is checkable. Run each one:

```bash
SB=$(mktemp -d); cp Makefile "$SB"/; cp -R .source tools "$SB"/
cd "$SB" && make setup >/dev/null 2>&1
for n in '2026-01-02-home_café.txt' '2026-7-4-home_unpadded.txt' '2028-02-29-home_leap.txt'; do
  rm -f posts/*.txt
  printf 'title: T\n-----------------------------------\n<p>b</p>\n' > "posts/$n"
  make >/dev/null 2>&1 && echo "BUILDS: $n" || echo "REJECTED: $n"
done
for n in '2026-01-02-home_a[b]c.txt' '2026-13-40-home_bad.txt' '2026-02-29-home_feb.txt' '2026-02-30-home_feb.txt' '20xx-ab-cd-home_x.txt'; do
  rm -f posts/*.txt
  printf 'title: T\n-----------------------------------\n<p>b</p>\n' > "posts/$n"
  make >/dev/null 2>&1 && echo "BUILDS: $n" || echo "REJECTED: $n"
done
cd - >/dev/null
```

Expected: the first three `BUILDS`, the last five `REJECTED`. Any mismatch means the prose is
wrong, not the test.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/backlog.md
git commit -m "Document the filename checks and close both backlog items.

CLAUDE.md's Post format section now carries all four rules a filename
must satisfy rather than two, since a reader looking for 'what makes a
filename legal' should find them together. The BSD-only gotcha gains
the GNU consequence: date -v now decides legality as well as
formatting, so on GNU a post dated the 31st is rejected as having a
bad date while one dated the 5th builds.

Backlog: the glob-character slug and the out-of-range dates both
marked DONE, ranked item 3 struck through, and the sentence calling
the glob-character slug the last open silently-wrong-output case
corrected -- it was true when written and is not now, which is the
same stale-confident-claim shape as items 4 and 6.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EvhfVMG4ZgqGQLw5ggnAjU"
```

- [ ] **Step 7: Whole-branch Fable review**

The fourth checkpoint in `CLAUDE.md`'s review cycle. Dispatch `Agent` with `model: "fable"`
on the full branch diff against `master`. Ask for blocking / recommended / optional plus a
verified list, and tell it the character policy and the decision not to quote the recipes are
both settled with the user.
