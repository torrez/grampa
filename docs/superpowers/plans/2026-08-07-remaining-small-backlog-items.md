# The four small remaining backlog items — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close backlog ranked items 4, 5, 7, and 8 — a control character in a post filename, `make deploy`'s missing prerequisite, `.source/splitter.txt`'s trailing blank line, and the undocumented `make -j setup all` race.

**Architecture:** Four independent changes to one Makefile, one tracked data file, and three documents. The only new mechanism is a parse-time `$(shell)` that re-reads `posts/` and greps for control characters, placed above the existing filename checks. Nothing couples the four; the tasks are ordered largest-first only so the riskiest lands while attention is freshest.

**Tech Stack:** GNU make 3.81 (what macOS ships and what this repo targets), BSD `ls`/`grep`/`cat`/`date`, awk, bash for the test suite.

**Spec:** `docs/superpowers/specs/2026-08-07-remaining-small-backlog-items-design.md`. Read it before starting. Its **"Already verified by execution — do not re-check"** section lists nine mechanisms Fable proved in sandboxes at the spec checkpoint; do not spend time re-proving them.

## Global Constraints

- **Tabs in the Makefile**, never spaces. Recipes are prefixed with `@` and echo a short human-readable progress line.
- **Comment blocks above each rule and helper**, in the existing `#`-banner style. Every non-obvious decision gets a comment saying *why*, not *what*.
- **BSD/macOS only.** `date -v`, `cat -vt`, and BSD `ls` piping raw bytes are all assumed.
- **Never build in the real repo.** Sandboxes only: `tests/run.sh` makes them, or copy `Makefile`, `.source/`, and `tools/` into a scratch directory under `/private/tmp/claude-501/-Users-andre-Code-grampa/a83b5b19-227e-4be4-8843-fbc1f162cfa2/scratchpad/`.
- **Suite baseline is `passed: 259  failed: 0`** at `f3478d0`. Quote the suite's own `passed:` line, never `grep -c '^test_'` — that counts each of the 80 test functions twice.
- **Every new test is watched failing first**, except where this plan marks one as unable to fail and says what it guards instead. A test that has never failed guards nothing.
- **Assert on message text, not exit status**, wherever the input already fails today for an unrelated reason. This suite has twice shipped assertions that could only pass.
- **Never write `$(printf '\n')` to build a filename with a newline** — command substitution strips trailing newlines and you get a clean filename. Use `$'\n'`.
- Each task ends with the full suite green and one commit.

---

### Task 1: Reject control characters in post filenames

**Files:**
- Modify: `Makefile:46` — split `POST_NAMES`' pipeline into a shared `POST_LS`
- Modify: `Makefile:258-284` — new check above the `check_post_name` block; amend that block's opening comment
- Modify: `tests/run.sh` — four new tests plus four invocations
- Modify: `CLAUDE.md` — the Post format section's residual sentence and rule count
- Modify: `docs/backlog.md` — ranked item 4 marked DONE

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `POST_LS` (a `:=` holding the shell fragment `ls posts 2>/dev/null | grep '\.txt$'`), `CONTROL_CHAR_NAMES`, `CHECKED_CONTROL_CHARS`. No later task depends on these.

- [ ] **Step 1: Write the four failing tests**

Add to `tests/run.sh`, above the invocation list, in the style of the existing filename tests:

```bash
#
# A control byte in a slug builds today at exit 0 and lands
# in the URL: build/2026/01/02/a<0x01>c.html, control byte
# and all. Not shell-hazardous -- no globbing, no word
# splitting -- so the sibling-body bug that motivated
# BAD_CHARS stayed closed and this is a policy gap rather
# than a reopened hole. The load-bearing assertion is that
# no page was published under the byte's name, not merely
# that the build failed.
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
	assert_out_grep '2026-01-02-home_a^Ac.txt'
	assert_no_file "build/2026/01/02/$(printf 'a\001c').html"
	assert_no_file 'build/2026/01/03/ok.html'
}

#
# A tab ALREADY fails today, so an exit-status assertion
# would pass against the behaviour being fixed. What is
# wrong today is the message: POST_NAMES word-splits on the
# tab and check_post_name then judges the fragments, so the
# build says "posts/c.txt: no category in filename" --
# naming a file that does not exist, for a reason that is
# not the reason. Assert the text, both halves.
#
# This test also pins the check's POSITION: with it moved
# below CHECKED_POST_NAMES the fragment message comes back.
#
test_tab_in_filename_names_the_whole_file() {
	sandbox tab_in_filename_names_the_whole_file
	add_post "$(printf '2026-01-02-home_a\tc.txt')" <<'EOF'
title: Tabbed
-----------------------------------
<p>TAB BODY</p>
EOF
	build_expect_fail || return
	assert_out_grep '2026-01-02-home_a^Ic.txt'
	assert_out_not_grep 'no category in filename'
}

#
# DEL is the one control character outside the 0x00-0x1F
# run, so a hand-written character class that stopped at
# 0x1F would pass the 0x01 test above and fail this one.
# That is the whole reason it is a separate test.
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
	assert_out_grep '2026-01-02-home_a^?c.txt'
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
# installed on this machine against a corpus of exactly
# these names plus 0x01, 0x7F, and tab: zero locales differ
# from the LC_ALL=C reference, en_US.ISO8859-1 included.
# APFS also rejects invalid UTF-8 filenames outright, so the
# continuation-byte hazard cannot reach the grep here at
# all. LC_ALL=C stays as a pin by principle, the same
# standing rfc822_from_filename's has -- both are about
# environments this machine cannot reproduce.
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
```

Add the four names to the invocation list at the bottom of the file, beside the other filename tests:

```bash
test_control_character_slug_is_rejected
test_tab_in_filename_names_the_whole_file
test_del_character_slug_is_rejected
test_ordinary_filenames_survive_the_control_check
```

- [ ] **Step 2: Run them and watch three fail for the stated reasons**

Run: `./tests/run.sh 2>&1 | tail -30`

Expected: `test_control_character_slug_is_rejected` fails because make **succeeds** and publishes the page; `test_del_character_slug_is_rejected` the same; `test_tab_in_filename_names_the_whole_file` fails on the message assertions while the build does fail. `test_ordinary_filenames_survive_the_control_check` passes — it cannot fail yet, by design.

**Read the failure text and confirm each is failing for its stated reason**, not incidentally. A test failing for the wrong reason is not a red test.

- [ ] **Step 3: Factor the directory listing into `POST_LS`**

In `Makefile`, at the `POST_NAMES` assignment (line 46), replace:

```make
POST_NAMES := $(shell ls posts 2>/dev/null | grep '\.txt$$' | sort -t- -k1,1n -k2,2n -k3,3n)
```

with:

```make
POST_LS := ls posts 2>/dev/null | grep '\.txt$$'
POST_NAMES := $(shell $(POST_LS) | sort -t- -k1,1n -k2,2n -k3,3n)
```

Add to the existing comment block above it:

```make
# POST_LS is the listing itself, shared with the
# control-character check below so the two cannot drift
# about which files are posts. It holds a shell fragment,
# not a command that runs: the $$ escapes to a single $ once
# here, and the stored value is substituted verbatim into
# both $(shell) calls rather than rescanned. Same argument
# as date_args -- a check that answers a slightly different
# question than the build asks is the same class of defect
# as no check.
```

- [ ] **Step 4: Add the control-character check above `check_post_name`**

In `Makefile`, immediately above the `check_post_name` comment block (around line 258), add:

```make
#
# Control characters, rejected before anything tries to make
# sense of the filename's shape.
#
# LC_ALL=C pins [[:cntrl:]] to 0x00-0x1F and 0x7F. The pin is
# by principle rather than by demonstration: all 288 locales
# installed on the development machine agree with C here, and
# APFS refuses invalid UTF-8 filenames outright, so no
# undecodable byte can reach the grep on this platform. It is
# the same standing rfc822_from_filename's LC_ALL=C has --
# both are about environments this machine cannot reproduce,
# and neither is guarded by a test that could fail.
#
# This re-reads the directory rather than interpolating
# $(POST_NAMES) into the shell, which is why -- unlike the
# date check below -- it has no ordering dependency in
# either direction. That freedom is spent on putting it
# FIRST: a tab in a filename word-splits POST_NAMES, so
# checked second it dies on check_post_name's category
# clause naming "posts/c.txt", a file that does not exist,
# for a reason that is not the reason. Checked first it
# names the whole file. Guarded by
# test_tab_in_filename_names_the_whole_file, which asserts
# both the new text and the absence of the old.
#
# cat -vt and not cat -v: BSD cat -v passes a tab through
# untouched, and a raw tab in the message would split the
# filename back into two make words -- reintroducing the
# fragment problem this ordering exists to fix. -t renders
# it ^I. The rendering also keeps raw control bytes off the
# terminal, at the cost of the message showing ^A for one
# byte, which is why it says so.
#
# The one-make-word guarantee covers control characters
# alone. A filename holding both a control byte and a SPACE
# still renders with the space intact and still fragments --
# loudly, and with the control-character message, so the
# diagnosis stays right even when the naming does not.
#
# 0x0A is the one control character this cannot catch: a
# line-based grep cannot see a newline inside a filename, so
# ls prints such a name as two lines and neither matches. It
# falls through to the fragment message, exactly as a tab
# used to. Deliberately left -- closing it needs -print0 and
# a different shape of check for one byte nobody can type by
# accident. Documented in CLAUDE.md beside the : residual.
#
CONTROL_CHAR_NAMES := $(shell $(POST_LS) | LC_ALL=C grep '[[:cntrl:]]' | cat -vt)
CHECKED_CONTROL_CHARS := $(if $(CONTROL_CHAR_NAMES),$(error control character in filename: $(addprefix posts/,$(CONTROL_CHAR_NAMES)); shown rendered, so ^A is one byte. A post filename may contain letters, digits, and only these punctuation marks: - _ .))
```

- [ ] **Step 5: Amend `check_post_name`'s opening comment**

That block currently opens "Characters are checked first, before any clause tries to make sense of the filename's shape." Replace that sentence with one saying the control-character check above runs before it; that `BAD_CHARS` running above `BAD_POST_DATES` is the constraint that still matters and is unchanged; and that the control check's own position is a free choice, not a requirement, because it interpolates nothing.

- [ ] **Step 6: Run the four tests and the full suite**

Run: `./tests/run.sh 2>&1 | tail -20`

Expected: all four new tests pass, and the final line reads `passed: 271  failed: 0` — the 259 baseline plus this task's **12** new assertions (test 1 contributes 4, test 2 contributes 2, test 3 contributes 3, test 4 contributes 3; only `assert_*` calls increment the counter, the `build` helpers do not). If any pre-existing test broke, stop: the control check runs against every post filename in every sandbox, so a mistake here breaks unrelated tests.

The count is confirmed by execution, not arithmetic — the plan review applied Tasks 1–3 and got `passed: 274  failed: 0`, working back to 271 here.

- [ ] **Step 7: Verify the `$`-plus-control-byte interaction by hand**

Not covered by the tests above, and worth one probe because the control check now runs *before* `BAD_CHARS` rejects `$`. A filename holding both puts a literal `$` into `CONTROL_CHAR_NAMES`, and the question is whether make re-expands it inside the `$(error)`.

In a scratch sandbox:

```sh
touch "posts/2026-01-02-home_a$(printf '\001')\$(PWN).txt"
make 2>&1 | head -3
```

Expected: the control-character error, with `$(PWN)` appearing literally or as an empty expansion — **not** a make syntax error and not an expansion of anything real. `:=` expands its right-hand side once and does not rescan a function's result, so this should be safe; confirm it rather than assume it. If it misbehaves, that is a blocking finding — report it rather than patching around it.

- [ ] **Step 8: Measure the cost at 60 posts**

Build a 60-post sandbox dated across the 1st–28th, and time a no-op rebuild five times with and without the check (comment out the two new lines for the "without" run).

Expected: within noise of the 0.12s the repo currently quotes. Fable pre-measured 0.10s → 0.11s at 42 posts. Record the real number for the commit message; if it lands materially above 0.12s, say so in the commit rather than shipping it quietly.

- [ ] **Step 9: Update `CLAUDE.md`**

In the Post format section, the sentence beginning "Two things still get through: an ASCII **control character** builds and lands in the URL" is now wrong. **It wraps across a line break at `CLAUDE.md:135-136`** ("Two\nthings still get through"), so do not grep for the full phrase when locating it. Replace with: control characters are rejected, naming the check; the residual is `0x0A` alone, because a line-based grep cannot see a newline inside a filename, and it still dies with the fragment message; and the `:` residual, unchanged. Note CR is caught and renders `^M`, so the residual is one byte and not a category.

Update "there are four rules in all" to five, and add a short paragraph for the new rule alongside the existing character, date, and duplicate-permalink ones — this is the section that promises to be "the one place to find them".

- [ ] **Step 10: Update `docs/backlog.md`**

Mark ranked item 4 (the ASCII control character bullet) **DONE** in the established "**DONE**, then the original finding follows" shape. Record what the item did not predict: that the fix also repairs the tab message, and that `0x0A` is a genuine residual rather than the class being closed.

- [ ] **Step 11: Commit**

```bash
git add Makefile tests/run.sh CLAUDE.md docs/backlog.md
git commit
```

Message: what changed, that the check re-reads the directory so it has no ordering hazard, why it goes first (the tab message), the `0x0A` residual, the measured cost, and the `$`-probe result.

---

### Task 2: `make deploy` builds first

**Files:**
- Modify: `Makefile:1132-1134` — the `deploy` target
- Modify: `tests/run.sh` — one new test plus its invocation
- Modify: `CLAUDE.md` — Commands section
- Modify: `docs/backlog.md` — ranked item 5 marked DONE

**Interfaces:**
- Consumes: nothing. `all` and `.PHONY: deploy` already exist.
- Produces: nothing later tasks use.

- [ ] **Step 1: Write the failing test**

```bash
#
# make clean && make deploy handed deploy.sh an empty
# build/ -- verified, 0 entries, no warning. deploy.sh is
# user-supplied and the example is an rsync; a --delete in
# it turns that sequence into "unpublish the site".
#
# The stub records what it was handed rather than asserting
# inside itself, so a failure shows the real listing. make's
# own output goes to files rather than /dev/null for the
# same reason: if the green path ever regresses before
# deploy.sh runs, an empty deployed.txt with no other
# evidence is a FAIL nobody can diagnose.
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
	make clean > deploy-clean.out 2>&1
	make deploy > deploy-make.out 2>&1
	assert_file deployed.txt
	assert_grep deployed.txt 'index.html'
}
```

Add `test_deploy_builds_first` to the invocation list.

- [ ] **Step 2: Run it and watch it fail**

Run: `./tests/run.sh 2>&1 | grep -A 5 deploy_builds_first`

Expected: `deployed.txt` exists but is empty, so the `index.html` assertion fails — `ls` on a `build/` that `make clean` removed writes nothing to it. Confirm the failure is the empty listing and not a missing stub.

- [ ] **Step 3: Add the prerequisite**

In `Makefile`, change:

```make
.PHONY: deploy
deploy:
	@./deploy.sh $(BUILD_DIR)
```

to:

```make
#
# deploy: all, and not a bare deploy, because
# make clean && make deploy handed deploy.sh an empty
# build/ at exit 0 -- and deploy.sh is user-supplied, with
# an rsync in the example. A --delete in it makes that
# sequence unpublish the site. The cost is one incremental
# no-op build, which is quiet and measured in tenths of a
# second.
#
# It does mean deploy is no longer a leaf target: hand-edits
# to build/ are rebuilt over. Run ./deploy.sh build/
# directly if that is ever what you want.
#
# Guarded by test_deploy_builds_first.
#
.PHONY: deploy
deploy: all
	@./deploy.sh $(BUILD_DIR)
```

- [ ] **Step 4: Run the test and the full suite**

Run: `./tests/run.sh 2>&1 | tail -20`

Expected: `test_deploy_builds_first` passes; the final line reads `passed: 273  failed: 0` — Task 1's 271 plus 2.

- [ ] **Step 5: Verify it under `-j8` and on a fresh install**

In a scratch sandbox: `make clean && make -j8 deploy` exits 0 and the stub sees a populated `build/` including `rss.xml` if `url=` is set.

Then the fresh-install case. **Stage it as: run `make setup` first, then `rm -rf config build/`.** Expected: `make deploy` recreates `config`, builds, and deploys at exit 0.

Do **not** stage it as a directory where `make setup` was never run — the plan review lost a probe cycle to exactly that. Without `setup` there are no `templates/`, so `make deploy` fails with `No rule to make target 'templates/base.txt'` and creates no `config`. That is correct behaviour and unchanged by this task, but it looks like the diff is broken. `deploy` builds first; it does not set up first, and nothing here claims it does.

- [ ] **Step 6: Update `CLAUDE.md`**

In the Commands section, the `make deploy` line currently reads "runs ./deploy.sh build/". Say three things: it builds first; it still needs `make setup` to have been run once, since it builds rather than sets up; and `./deploy.sh build/` run directly is the way to ship exactly what is on disk without rebuilding.

- [ ] **Step 7: Update `docs/backlog.md`**

Mark the `make deploy` bullet and ranked item 5 **DONE**. The item's own framing — "arguably the current form is more honest about doing exactly what it says" — should be answered rather than dropped: it lost to the failure mode, and the entry should say so.

- [ ] **Step 8: Commit**

```bash
git add Makefile tests/run.sh CLAUDE.md docs/backlog.md
git commit
```

---

### Task 3: Strip the trailing blank line from `.source/splitter.txt`

**Files:**
- Modify: `.source/splitter.txt`
- Modify: `tests/run.sh` — one new test plus its invocation
- Modify: `docs/backlog.md` — ranked item 7 marked DONE

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

```bash
#
# The Markdown branch reassembles head + splitter + body,
# so the splitter's trailing blank line put an extra empty
# line at the top of every Markdown-staged body -- a one-byte
# disagreement with the verbatim branch, which cp's the post
# through untouched.
#
# It reaches no output: PARSE_FRONT_MATTER accumulates with
# body = (body == "" ? $0 : body "\n" $0), so a leading empty
# line leaves body empty and the next line swallows it.
# Verified byte-identical over build/ including rss.xml. The
# point of closing it is that the two staging branches now
# produce the same intermediate for the same input, so
# .staged files are diffable across branches.
#
test_markdown_staged_file_has_no_blank_line_after_the_delimiter() {
	sandbox markdown_staged_file_has_no_blank_line_after_the_delimiter
	markdown_stub <<'EOF'
#!/bin/sh
sed 's/^/MD:/' "$1"
EOF
	add_post '2026-01-02-home_s.txt' <<'EOF'
title: Staged
-----------------------------------
<p>STAGED BODY</p>
EOF
	build || return
	assert_eq 'line after the delimiter' \
		'MD:<p>STAGED BODY</p>' \
		"$(sed -n '3p' work/2026-01-02-home_s.staged)"
}
```

Add `test_markdown_staged_file_has_no_blank_line_after_the_delimiter` to the invocation list.

- [ ] **Step 2: Run it and watch it fail**

Run: `./tests/run.sh 2>&1 | grep -A 5 markdown_staged_file`

Expected: `expected [MD:<p>STAGED BODY</p>] got []` — line 3 is the blank line today.

- [ ] **Step 3: Strip the blank line**

```sh
printf -- '-----------------------------------\n' > .source/splitter.txt
od -c .source/splitter.txt
```

Expected from `od -c`: 35 hyphens then a single `\n`, and nothing after it. Do not hand-edit in an editor that may re-add a trailing newline.

- [ ] **Step 4: Run the test and the full suite**

Run: `./tests/run.sh 2>&1 | tail -20`

Expected: the new test passes; the final line reads `passed: 274  failed: 0` — Task 2's 273 plus 1. The Markdown-branch tests are the ones at risk here — if any of them broke, the change has an output effect the spec says it does not have, and that is a blocking finding.

- [ ] **Step 5: Re-confirm `build/` is byte-identical**

In a scratch sandbox with `url=` set and a transforming Markdown stub, build a corpus including a post whose body starts with a blank line, one with no body, one whose delimiter is on line 1, and one with no trailing newline. Build with the old splitter, copy `build/` aside, strip the blank line, `make clean && make`, then `diff -r`.

Expected: empty. The only difference anywhere is one blank line per `.staged`. Fable verified this over an 11-post corpus at the spec checkpoint; this is confirmation against the real diff.

- [ ] **Step 6: Update `docs/backlog.md`**

Mark the `.source/splitter.txt` bullet and ranked item 7 **DONE**, correcting the finding's own description: it says Markdown-staged bodies "gain a leading blank line", which sounds like an output bug. The blank line never reached `build/`. Say what the change actually buys — the two staging branches agreeing on their intermediate.

- [ ] **Step 7: Commit**

```bash
git add .source/splitter.txt tests/run.sh docs/backlog.md
git commit
```

---

### Task 4: Document that `setup` wants its own invocation

**Files:**
- Modify: `CLAUDE.md` — Commands section
- Modify: `README.md` — the `make setup` sentence
- Modify: `docs/backlog.md` — ranked item 8 marked DONE, and the ranked list's preamble rewritten

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

No test. The suite's sandboxes run `make setup` before every test, so reproducing the race inside one would mean a test that deliberately builds a half-set-up sandbox — more machinery than a documented one-time step deserves.

- [ ] **Step 1: Reproduce the race once**

In a fresh scratch directory with `Makefile` and `.source/` copied in and **no** `make setup` run yet:

```sh
make -j4 setup all 2>&1 | tail -3
```

Expected: `No rule to make target 'templates/…', needed by …`. **Note which template it names.** It is race-dependent — the backlog's reproduction got `base.txt`, the spec review's got `post.txt`. Then confirm serial `make setup all` exits 0.

- [ ] **Step 2: Add the line to `CLAUDE.md`**

In the Commands section, below the command list, add a short paragraph: `setup` is a one-time step and should not be combined with a build goal under `-j`, because the template copying races the build rules and stops with `No rule to make target 'templates/…'`. Serial `make setup all` is fine, and so is the documented `make setup` then `make`.

**Do not name a specific template.** Which one loses the race varies between runs, and this document's stated identity is that it is checkable against the code — a reader who checks a specific string will half the time find it false. Say so in the paragraph, briefly: it is the kind of detail a later contributor would otherwise "helpfully" make specific.

Say also why it is not fixed in the Makefile: `setup` is `.PHONY`, so an order-only `build: | setup` would run the copying on every build — verified with `make --debug=b` — and making it non-phony means inventing a stamp file for a one-time step.

- [ ] **Step 3: Add the caveat to `README.md`**

The README opens "Check out this repo and run `make setup`." Add that it is a one-time step to run on its own, and not to combine it with `make` in one `-j` invocation.

- [ ] **Step 4: Rewrite the backlog's ranked list preamble**

Mark ranked item 8 **DONE**. Then rewrite the "**What is left, in rough order of how much a reader would care**" preamble: with these four closed, what remains is exactly two items — the feed's post-deletion self-heal (item 8's behaviour half) and the single-pass `fill()`. Both are deliberate deferrals with written reasoning, not oversights.

That is a real change in the list's character and worth stating: it stops being a pile of small things and becomes two decisions nobody has made yet. A reader arriving at the backlog should learn that in the first paragraph rather than by reading to the end.

- [ ] **Step 5: Run the full suite one more time**

Run: `./tests/run.sh 2>&1 | tail -5`

Expected: `passed: 274  failed: 0`, unchanged from Task 3. Prose-only changes should not move it — if they did, something was edited that was not prose.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md README.md docs/backlog.md
git commit
```

---

## Already verified by execution at checkpoint 2 — do not re-check

The plan review applied Tasks 1–3 to a sandbox verbatim and ran the suite. Beyond the spec's
own verified list, these are settled:

1. **The exact `$(error)` line parses on make 3.81.** The `;`, `:`, the comma inside
   `$(addprefix …)`, and the trailing `- _ .` all survive. Two offenders produce one error
   naming both, rendered `^A` and `^?`.

   Note the message ends `- _ ..  Stop.` — our trailing `.` plus make's own. That matches the
   existing `check_post_name` errors' style, and every assertion uses `grep -qF` substring
   matching, so it breaks nothing. Recorded so nobody later "fixes" a test to expect an exact
   line.

2. **Step 7's `$`-probe is inert, in three spellings.** `$(>PWN)` renders literally and
   creates no file; backticks are literal; and decisively, `$(SHELL)` prints as literal
   `$(SHELL)` rather than `/bin/bash` — `:=` never rescans a function's result, even for a
   variable that *is* defined. The ordering decision stands. Step 7 is still worth running
   against the real diff, but the answer is known.

3. **All six tests fail red for their stated reasons** (`passed: 263 failed: 6`), and the red
   sandbox really does publish `build/2026/01/02/a^Ac.html` with the raw byte in the name.
   Command substitution preserves the `\001` and `\t` bytes, `add_post` creates the intended
   filenames, and `assert_out_grep '…a^Ac.txt'` matches because `cat -vt`'s `^A` is two
   literal characters and the helper greps with `-qF --`.

4. **Green full suite is `passed: 274  failed: 0`.**

5. **Cost at 60 posts: 0.13s with the check, 0.12s without.** Step 8 should confirm, not
   discover.

6. **Test 4's multibyte corpus works end to end** with `url=` set — post pages, index links,
   category page, and `rss.xml` `<link>` elements all correct.

7. **Every line-number anchor in this plan is correct**: `Makefile:46`, `Makefile:258-284`,
   `Makefile:1132-1134`, `README.md:11`, and the four backlog ranked items.

## Self-review notes

**Spec coverage.** Every section of the spec maps to a task: item 3 → Task 1, item 4 → Task 2, item 5 → Task 3, item 6 → Task 4. All six specified tests appear, with one deliberate change recorded below. The spec's four documentation targets (`Makefile`, `CLAUDE.md`, `README.md`, `docs/backlog.md`) are all covered.

**One deliberate departure from the spec.** The spec's test 4 reuses `test_unusual_but_safe_slug_still_builds`' corpus of `café`, uppercase, and dotted slugs. This plan uses `café`, CJK, and emoji instead. Reason: the existing test already guards `BAD_CHARS`' false-positive surface with that ASCII-ish set, and duplicating it would add assertions without adding coverage. A byte-oriented grep is likeliest to trip on **multibyte** input, which is the surface this test is actually for. Flag it at the task review.

**Two verifications this plan adds that the spec did not ask for.** Task 1 Step 7 probes a filename holding both a control byte and `$` — reachable only because the control check now runs *before* `BAD_CHARS` rejects `$`, which is new with this change. Task 1 Step 8 measures cost at 60 posts rather than trusting the 42-post pre-measurement.

**Naming consistency.** `POST_LS`, `CONTROL_CHAR_NAMES`, and `CHECKED_CONTROL_CHARS` are used identically in the spec and in every step here. `CHECKED_CONTROL_CHARS` follows the existing `CHECKED_POST_NAMES`/`CHECKED_POST_DATES` naming, which is the file's convention for a `:=` whose only purpose is to make an `$(error)` fire.
