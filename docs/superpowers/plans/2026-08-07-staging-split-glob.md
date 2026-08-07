# Staging split-glob fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `split -p` and its two globs in the `%.staged` rule with a single awk pass
that writes two exactly-named files, closing all three staging defects in `docs/backlog.md`.

**Architecture:** A fifth awk program, `SPLIT_STAGED`, joins the four existing `define`
blocks, is `export`ed, and is invoked as `awk "$$SPLIT_STAGED"`. It copies lines to
`work/<stem>.head` until the first delimiter, drops that line, and copies the rest to
`work/<stem>.body`. The recipe's `&&` chain keeps its shape but loses its only pipe, so
`&&` now covers every stage.

**Tech Stack:** GNU make 3.81, BSD awk, bash, coreutils. No runtime, no dependencies.

**Spec:** `docs/superpowers/specs/2026-08-07-staging-split-glob-design.md`. Read it before
starting — in particular the "Behaviour changes" section, which lists four output changes,
three of which were found by running the proposed program rather than by designing it.

## Global Constraints

- **Tabs in the Makefile.** Recipe lines are tab-indented; `define` block bodies use spaces.
- **`$$` for awk's `$` inside a `define` block.** `$0` must be written `$$0` or make will
  expand it as a make variable.
- **BSD/macOS only.** `date -v` is already assumed repo-wide. Do not add GNU-isms.
- **Recipes are prefixed with `@`** and echo a short human-readable progress line.
- **`#`-banner comment block above every rule and helper**, in the existing style.
- **Every test must be watched failing before the fix goes in.** A test that has never
  failed guards nothing. This is the house rule the backlog repeatedly credits for catching
  wrong fixes.
- **The suite is `make test`** (runs `tests/run.sh` in throwaway sandboxes). Baseline is
  **215 passing, 0 failed** before this work starts. Confirm that number first; if it does
  not match, stop and report rather than proceeding.
- **Review cycle.** Per `CLAUDE.md`, each finished task's diff goes to the Fable model via
  the `Agent` tool with `model: "fable"` before the next task starts.

---

### Task 1: `SPLIT_STAGED` and the rewritten `%.staged` recipe

**Files:**
- Modify: `Makefile` — new `define` block after `WRAP_IN_CHANNEL`'s `endef`; `export` list
  at `Makefile:561-564`; comment block and recipe at `Makefile:743-795`
- Test: `tests/run.sh` — four new tests, plus four names in the runner list at the bottom

**Interfaces:**
- Produces: `SPLIT_STAGED`, an awk program taking `-v head=<path> -v body=<path>` and one
  input file. Writes both files; creates each even when its side is empty. Exits non-zero
  only on awk's own errors (unreadable input), which the `&&` chain catches.
- Consumes: nothing from earlier tasks. The scratch names `.head`, `.body`, `.mdbody` are
  local to this one recipe; no other rule references them.

- [ ] **Step 1: Confirm the baseline**

Run: `make test 2>&1 | tail -3`
Expected: `passed: 215  failed: 0`. If not, stop and report.

- [ ] **Step 2: Make the grep helpers able to see a hyphen**

This is not a detour. `assert_not_grep` runs `grep -qF "$2" "$1"`, and the fourth test's
pattern is 35 hyphens, which grep parses as an unrecognized long option: exit 2, usage spew
on stderr, and `assert_not_grep`'s else-branch counts any non-zero exit as **ok**. The test
would pass against the broken build and guard nothing. Verified directly:

```
$ grep -qF "-----------------------------------" g.txt; echo $?
grep: unrecognized option `-----------------------------------'
2
$ grep -qF -- "-----------------------------------" g.txt; echo $?
0
```

In `tests/run.sh`, add `--` to the four grep-based helpers (`assert_grep`,
`assert_not_grep`, `assert_out_grep`, `assert_out_not_grep`):

```bash
	if grep -qF -- "$2" "$1"; then ok; else fail "expected '$2' in $1" "$(cat "$1")"; fi
```

```bash
	if grep -qF -- "$2" "$1"; then fail "did NOT expect '$2' in $1" "$(cat "$1")"; else ok; fi
```

```bash
	if printf '%s\n' "$BUILD_OUT" | grep -qF -- "$1"; then ok; else fail "expected '$1' in make output" "$BUILD_OUT"; fi
```

```bash
	if printf '%s\n' "$BUILD_OUT" | grep -qF -- "$1"; then fail "did NOT expect '$1' in make output" "$BUILD_OUT"; else ok; fi
```

Run: `make test 2>&1 | tail -3` → still `passed: 215  failed: 0`. The change affects no
existing test; every current pattern starts with something other than a hyphen.

- [ ] **Step 3: Write the four failing tests**

In `tests/run.sh`, immediately after `test_non_executable_markdown_falls_back_to_verbatim`
(the last of the Markdown staging tests), add all four. Each installs the identity Markdown
stub, because the defects live in the `if [ -x Markdown.pl ]` branch and a sandbox has no
real `Markdown.pl`.

```bash
#
# split names chunks .aa, .ab ... .az, .ba, and the old
# reassembly glob was $*.a[b-z]* -- so a body with more
# than 25 delimiter lines lost everything from .ba on,
# silently, at exit 0. Thirty delimiters puts five
# sections past that ceiling.
#
test_many_delimiter_lines_stage_completely() {
	sandbox many_delimiters
	markdown_stub <<'EOF'
#!/bin/sh
cat "$1"
EOF
	# printf -- because the format string starts with a
	# hyphen. The first delimiter is the front-matter
	# separator; the other 29 stay in the body.
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
# matches 2026-01-01-home_x.ab.staged and .tmp -- a
# same-date sibling's real outputs, deleted mid-build.
# Dotted slugs are degenerate, but silently eating another
# post's work is not an acceptable way to say so.
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
	# This must assert on the FIRST build. A second make
	# exits 0 -- the survivor's files are up to date and
	# its rm never runs again -- so a retry here would
	# make the test incapable of failing.
	build || return
	assert_grep build/2026/01/01/x.html "<p>plain x</p>"
	assert_grep build/2026/01/01/x.ab.html "<p>dotted sibling</p>"
}

#
# A post with no delimiter left the body glob matching
# nothing, so cat failed -- into `cat ... | tail`, whose
# status is tail's. The && chain catches a failing step
# and never a failing stage of a pipe, so the build stayed
# at exit 0 with the error loose on stderr. The output
# assertion is the one that pins this: the exit status
# never told the truth here.
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
	# Same outcome as the verbatim branch: the whole file
	# is front matter, so the title renders and the body
	# is empty.
	assert_grep build/2026/01/01/bare.html "Bare"
}

#
# A post opening with the delimiter: split -p left that
# line inside the front-matter chunk, the body glob then
# matched nothing, and the reassembly put a stray 35-hyphen
# line into the rendered body. awk drops the first
# delimiter wherever it is.
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
```

Then add the four names to the runner list at the bottom of the file, after
`test_non_executable_markdown_falls_back_to_verbatim`:

```
test_many_delimiter_lines_stage_completely
test_same_date_sibling_slug_does_not_collide
test_post_without_delimiter_stages_cleanly
test_delimiter_on_first_line_leaves_no_stray_delimiter
```

- [ ] **Step 4: Run the four tests and watch each fail for its own reason**

Run: `make test 2>&1 | grep -A4 'FAIL:'`

Expected — four distinct failures, and it matters that each is the predicted one, not just
that the count is four:

| Test | Expected failure |
| --- | --- |
| `many_delimiter_lines` | `expected '<p>section 30</p>' in build/2026/01/01/many.html` (section 1 passes) |
| `same_date_sibling_slug` | `make failed unexpectedly (exit 2)` with `cat: work/2026-01-01-home_x.ab...: No such file or directory` in the output |
| `post_without_delimiter` | `did NOT expect 'No such file' in make output` (the build itself exits 0) |
| `delimiter_on_first_line` | `did NOT expect '-----------------------------------' in build/2026/01/01/lead.html` |

None of the four templates in `.source/templates/` contains a 35-hyphen run, so the only
source of one in a rendered page is the post body — checked, and it is what makes
`delimiter_on_first_line`'s assertion trustworthy once Step 2 has made grep able to see the
pattern at all.

Suite total should be `passed: 218  failed: 4`: 215 baseline, plus the three assertions that
pass *inside* the failing tests (`<p>section 1</p>`, the `Bare` title, `<p>body only</p>`),
against four tests failing. `assert_*` counts assertions and not tests, which is why the
total goes up rather than down — read the FAIL lines, not the totals.

Without Step 2 this run reads `passed: 219  failed: 3` instead, with
`delimiter_on_first_line` quietly passing. If you see that, Step 2 did not take.

- [ ] **Step 5: Add the `SPLIT_STAGED` program**

In `Makefile`, after the `endef` that closes `WRAP_IN_CHANNEL` and before the
`# Passed to awk through the environment` comment block:

```make
#
# Splits a post into its front matter and its body, one
# file each, for the staging step. This is the only awk
# program that writes files rather than stdout, because
# Markdown.pl has to be handed the body alone and then the
# pieces glued back together.
#
# It shares nothing with PARSE_FRONT_MATTER even though
# both recognise the same delimiter: that one accumulates
# a title and a body into variables for a renderer, this
# one routes lines to two output files and keeps no state
# but `seen`. Factoring them together would couple the
# staging step to the renderers to save one regex.
#
# Only the FIRST delimiter splits. Later ones are body
# text -- a post about grampa's own post format has them
# -- which is why the match is guarded by !seen.
#
# The END block is load-bearing. awk creates a redirect's
# file on first write, so a post with no body would leave
# no body file at all and Markdown.pl would be handed a
# missing argument. printf "" creates the file when
# nothing was written and appends nothing when something
# was: awk holds the redirect open, so this does not
# truncate what came before it.
#
define SPLIT_STAGED
!seen && $$0 ~ /^-----------------------------------/ {
    seen = 1;
    next;
}
{
    if (seen){
        print $$0 > body;
    }else{
        print $$0 > head;
    }
}
END {
    printf "" > head;
    printf "" > body;
}
endef
```

- [ ] **Step 6: Export it**

Add to the export list at `Makefile:561-564`, after `export WRAP_IN_CHANNEL`:

```make
export SPLIT_STAGED
```

Without this the recipe's `"$$SPLIT_STAGED"` expands to an empty awk program, which copies
nothing and exits 0 — a silent failure, so do not skip it.

- [ ] **Step 7: Rewrite the recipe and its comment block**

Replace `Makefile:743-795` (the comment block and the rule) with:

```make
#
# The staging step: split the front matter off the body,
# run just the body through Markdown.pl, then put it back
# together. Every intermediate is named after the post so
# that make -j can't have two posts clobber each other.
#
# This is a target of its own rather than part of %.tmp
# below because the RSS items need the same rendered body
# *and* the post's individual fields -- title, body, date
# -- which the .tmp fragment has already dissolved into
# HTML. Kept by .SECONDARY, so Markdown.pl runs once per
# post rather than once per consumer.
#
# The steps below are chained with && rather than ;, and
# that is load-bearing. With ; the compound's exit status
# is the last command's -- rm -f, which essentially always
# succeeds -- so a failing Markdown.pl was invisible: make
# exited 0, .DELETE_ON_ERROR never fired, and a .staged
# file holding front matter and nothing else was trusted
# by every downstream consumer, publishing a fully
# rendered page with an empty body. Do not relax these
# back to ; -- tests/run.sh's failing-stub test guards it.
#
# There is no pipe anywhere in the chain, and there should
# not be one: && reports a failing step but never a failing
# stage of a pipe, so `a | b` hides a's failure behind b's
# status. That is exactly how a delimiter-less post used to
# fail silently, back when the body was reassembled with
# `cat chunks | tail -n +2`.
#
# The rm at the *head* of the chain is hygiene and not
# correctness, which is a demotion from what it used to be.
# Under the old glob it was load-bearing: a failed run left
# chunks behind and the reassembly globbed whatever it
# found, so a post that later split into fewer chunks swept
# the stale ones back in. Exact filenames cannot do that.
# Every one of the three is truncated before it is read --
# awk's `print >` truncates on first write, the END block's
# printf truncates even when nothing else is written, and
# the shell's `>` truncates .mdbody before Markdown.pl
# starts -- so no stale byte can survive into $@. Verified
# by neutering this rm: the failing-stub test and the
# parallel test both still pass. It stays because a
# persistently failing install should not accumulate
# scratch, and because the truncation argument holds only
# as long as nothing in the chain is reordered.
#
# Every scratch name is an exact filename, never a glob.
# It used to be `split -p` plus $*.a[b-z]*, which was
# wrong twice: the glob stopped at .az so a body with more
# than 25 delimiter lines was silently truncated, and
# $*.a[a-z]* reached onto a same-date sibling's outputs
# (stem ...home_x matching ...home_x.ab.staged) and deleted
# them mid-build.
#
$(WORK_DIR)%.staged: posts/%.txt
	@mkdir -p $(WORK_DIR)

	@if [ -x Markdown.pl ]; \
		then \
		rm -f $(WORK_DIR)$*.head $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody && \
		awk -v head=$(WORK_DIR)$*.head -v body=$(WORK_DIR)$*.body \
			"$$SPLIT_STAGED" $< && \
		./Markdown.pl $(WORK_DIR)$*.body > $(WORK_DIR)$*.mdbody && \
		cat $(WORK_DIR)$*.head .source/splitter.txt $(WORK_DIR)$*.mdbody > $@ && \
		rm -f $(WORK_DIR)$*.head $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody; \
	fi;

	@if [ ! -x Markdown.pl ]; \
		then \
		cp $< $@; \
	fi;
```

The `awk` invocation is split across two continued lines for width; keep the `\` and the
leading tab on the second, as the surrounding recipes do.

- [ ] **Step 8: Run the four tests and watch them pass**

Run: `make test 2>&1 | tail -3`
Expected: `passed: 223  failed: 0` — 215 baseline plus the eight assertions in the four new
tests (2 + 2 + 2 + 2; the `build` calls do not assert). Verify the exact number
rather than eyeballing "0 failed": a test whose sandbox name collides with another's is
silently skipped work.

- [ ] **Step 9: Verify the two existing tests the spec called out**

Run: `make test 2>&1 | grep -c FAIL` → `0`, and confirm by name that these ran:
`test_failed_markdown_leaves_no_stale_chunks` and `test_markdown_branch_is_parallel_safe`.
The first's premise (a failed run's leftovers must not reach the next build's output) is now
carried by truncation rather than by clearing a glob; the second asserts no stray
intermediates in `work/`, which covers the three new scratch names as-is. If either fails,
the fix is wrong — do not adjust the tests to match.

- [ ] **Step 10: Verify no post-format regression by hand**

The suite proves the defects are closed. This proves nothing else moved. In a scratch
directory (not the repo), copying the **now-edited** Makefile — this step is meaningless run
out of order, before Steps 5-7 have touched it:

```bash
S=/private/tmp/claude-501/-Users-andre-Code-grampa/cb99cfb2-a708-43cb-975b-e51102bba9e8/scratchpad/t1
rm -rf "$S" && mkdir -p "$S" && cd "$S"
cp /Users/andre/Code/grampa/Makefile . && cp -R /Users/andre/Code/grampa/.source .
make setup >/dev/null 2>&1
printf '#!/bin/sh\ncat "$1"\n' > Markdown.pl && chmod +x Markdown.pl
printf 'name=T\nurl=https://example.com\n' > config
printf 'title: One\n-----------------------------------\n<p>a</p>\n-----------------------------------\n<p>b</p>\n' > posts/2026-01-01-home_one.txt
printf 'title: Two\n-----------------------------------\n<p>trailing blanks</p>\n\n\n' > posts/2026-02-01-work_two.txt
make >/dev/null && cat build/2026/01/01/one.html
```

Expected: both `<p>a</p>` and `<p>b</p>` in the body with the inner delimiter between them
preserved, and `build/rss.xml` present. Inner-delimiter preservation is the behaviour most
at risk from a mis-written `!seen` guard, and no suite test isolates it.

- [ ] **Step 11: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Split staging with awk instead of split(1) and two globs."
```

Message body should name all three defects and say that the four tests were watched failing
first, with what each failure was.

- [ ] **Step 12: Fable review of this task's diff**

Dispatch `Agent` with `model: "fable"`. Give it the framing `CLAUDE.md` prescribes: this is
a Makefile, so the failure modes are pattern-rule ambiguity, `=` vs `:=` timing,
`.SECONDARY`, awk `&`-in-replacement semantics, and shell quoting. Tell it what is settled
(the mechanism, the non-fatal delimiter-less post, `splitter.txt`'s trailing blank line),
point it at the spec, and tell it to prove claims by running them in a sandbox built the way
`tests/run.sh` builds one — copying `tools/` too, or five migrate tests fail for unrelated
reasons. Ask for blocking / recommended / optional plus what it actively verified.

---

### Task 2: Documentation pass

**Files:**
- Modify: `CLAUDE.md` — opening tool list, build-pipeline diagram, awk-programs section
- Modify: `tests/run.sh` — three stale comment blocks at `394-397`, `408`, `441-443`
- Modify: `docs/backlog.md` — both glob entries, and remaining-work item 1

**Interfaces:**
- Consumes: the mechanism from Task 1. No code changes here; if this task wants a code
  change, that is a finding for Task 1, not something to slip in.

- [ ] **Step 1: Update `CLAUDE.md`'s three affected places**

1. Opening sentence: drop `split` from the tool list. **Keep `tail`** — `CONFIG_NAME` and
   `CONFIG_URL` both end in `tail -1` (`Makefile:133,157`), so it is still load-bearing.
2. The build-pipeline diagram: `└─ split + (optional) Markdown.pl on the body only` becomes
   `└─ awk split + (optional) Markdown.pl on the body only`.
3. The "awk programs" section: it opens "Four awk programs live in `define` blocks" and
   names them. Make it five, add `SPLIT_STAGED`, and say what the Makefile comment says in
   miniature — it is the only one that writes files rather than stdout, and it shares
   nothing with `PARSE_FRONT_MATTER` on purpose.

- [ ] **Step 2: Update the three stale test comments**

None of these tests changes; their comments describe a mechanism that no longer exists, and
because the tests still pass nothing else will ever flag them.

1. `tests/run.sh:394-397` — the block above `test_failed_markdown_leaves_no_stale_chunks`
   explains the premise as "the reassembly collects chunks by glob -- so a post that now
   splits into fewer chunks than it did before would sweep the stale ones back in". That
   mechanism is gone, and the honest rewrite has to say the test is now weaker than its
   comment implies: with exact filenames every scratch file is truncated before it is read,
   so the sweep-back it was written against cannot happen and the test passes even with the
   head `rm` removed — verified. Keep the test; say what it now covers, which is the
   end-to-end property that recovering from a Markdown failure must not republish deleted
   text, by whatever mechanism. Do not dress the head `rm` up as the thing it guards.
2. `tests/run.sh:408` — "Inner delimiter lines make split produce three chunks" becomes a
   statement about what the test actually needs: content after a second delimiter, which the
   author then deletes.
3. `tests/run.sh:441-443` — names `$(WORK_DIR)$*.aa` among the per-post intermediates.
   Update to `.head`, `.body`, `.mdbody`.

- [ ] **Step 3: Update `docs/backlog.md`**

Mark both entries DONE in the established shape — the DONE verdict and what was verified
first, then the original finding preserved below it.

1. **"The `split` cleanup glob stops at `az`"** — DONE. Note that the second half of the
   entry (a delimiter-less post's `cat` error masked by the pipe) closed with it, since the
   pipeline is gone rather than broken up.
2. **"The staging branch's scratch glob can eat a same-date sibling's fragments"** — DONE.
3. Add the upgrade wrinkle to one of the two entries: an install whose `work/` holds
   `.aa`/`.ab` chunks from a pre-change *failed* run keeps them indefinitely, because the
   new `rm -f` does not name them and nothing globs them any more. Inert; `make clean`
   clears them.
4. Record all four behaviour changes from the spec, marked for what they are: the mid-line
   delimiter no longer splitting is the **sought** one, and the other three were found by
   running the new program against the old — delimiter on line 1 (stray hyphen line leaves
   the body), an empty post file (loud failure becomes an empty page, accepted because it
   makes the two staging branches agree), and a post with no trailing newline gaining one
   byte in `.staged`. Do not drop the trailing-newline one for being trivial; an unrecorded
   byte-level change is exactly what makes a future `diff` investigation expensive.
5. Leave the older DONE entries that narrate the `split`-chunk mechanism as history
   (≈lines 72-84 and 270) alone. They are dated records of what was true when written, and
   the "describes a mechanism that no longer exists" standard applied to `tests/run.sh`
   above is about live comments on live code, not about the log.
6. Strike through remaining-work item 1 ("The two staging-branch glob items") in the
   "What is left" list, the way items 1-3 above it are struck through, and renumber nothing
   — the list's existing entries keep their numbers.

- [ ] **Step 4: Verify the docs against the code**

Run: `grep -n 'split' CLAUDE.md` and confirm every surviving hit means the awk split or the
staging step, not `split(1)`. Run `make test 2>&1 | tail -3` → `passed: 223  failed: 0`,
because Step 2 edits a file the suite executes and a stray character in a comment block can
break bash.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md tests/run.sh docs/backlog.md
git commit -m "Document the awk staging split and close both backlog glob items."
```

- [ ] **Step 6: Fable review of this task's diff, then of the whole branch**

Two dispatches, per `CLAUDE.md`'s four checkpoints: this task's diff, and then the branch
end to end (`git diff master...HEAD`). The whole-branch review is the one that catches a
Task 1 decision that only looks wrong once the documentation states it plainly.
