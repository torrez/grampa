# Portable date dialect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make grampa build unmodified on both BSD/macOS and Linux/GNU, choosing the `date` dialect once per install at `make setup`.

**Architecture:** `make setup` probes `date(1)` and writes `DATE_DIALECT := bsd|gnu` into a generated, gitignored `config.mk` that the Makefile `-include`s at parse time. A single factored `date_select` twin per dialect feeds all three date call sites; an unconfigured build fails loud with "run `make setup` first."

**Tech Stack:** GNU Make, awk, coreutils. No runtime, no dependencies.

## Global Constraints

- The Makefile *is* the program — every change is make + awk + coreutils, no new tools, no runtime. (from spec + CLAUDE.md)
- Tabs in the Makefile. Recipes prefixed with `@`, echoing a short human-readable progress line. Comment blocks above each rule/helper in the existing `#`-banner style. (CLAUDE.md Conventions)
- Both dialects stay supported; the mac keeps building. Detection is at `make setup`, persisted to `config.mk`, **not** probed per build. An unconfigured build fails loud rather than falling back to a live probe. (settled with user)
- The parse-time date check must keep running the **exact** args the build runs (why `date_select` is shared, not duplicated). (CLAUDE.md)
- The date check block (`BAD_POST_DATES`) must stay below `CHECKED_POST_NAMES` in the Makefile — unrelated to this change, but do not reorder it. (CLAUDE.md)
- `make test` runs `tests/run.sh` in throwaway sandboxes; `sandbox()` already runs `make setup`. Five tests shell out to `./tools/migrate-categories.sh`.
- Verify the `bsd` twin cannot run on this GNU host — its live `date` run is a BSD/macOS smoke test deferred to the branch checkpoint. (spec Test plan)

---

### Task 1: The date port — detect at setup, `date_select` twins, fail loud

**Files:**
- Modify: `Makefile` — add `-include config.mk` after line 4; rewrite the `date_words`/`date_args` block (178–190) into `date_words` + `date_select`; update `date_from_filename` (195), `rfc822_from_filename` (206–211), `BAD_POST_DATES` (500); add the `config.mk` write to the `setup` recipe (after 1212).
- Modify: `.gitignore` — add `/config.mk` in the per-install group.
- Test: `tests/run.sh` — add `test_setup_writes_the_host_date_dialect` and `test_build_without_config_mk_fails`, and register both at the bottom.

**Interfaces:**
- Produces: `$(DATE_DIALECT)` (values `bsd`/`gnu`), read from `config.mk`; `date_select` (make function taking a post filename, returning `date(1)` args); a generated `config.mk` at repo root.
- Consumes: existing `date_words`, `$(space)` (defined line 98), `POST_NAMES`, `SUSPECT_POST_DATES`.

- [ ] **Step 1: Write the two failing tests**

Add these two functions to `tests/run.sh` immediately after `test_migration_reports_error_when_rm_fails` (ends line 1549):

```bash
#
# make setup probes date(1) and writes the host's dialect
# to a generated config.mk. sandbox() already ran setup, so
# the file is there to inspect.
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
	if make setup < /dev/null > setup.out 2>&1; then ok; else
		fail "make setup deadlocked on a month-end post" "$(cat setup.out)"; fi
	assert_file config.mk
	# And once configured, the build works and the suspect date
	# renders -- proving the gate skipped the check, it did not
	# permanently disable it.
	build
	assert_file build/2026/01/31/endofmonth.html
}
```

Register all three at the bottom of the file, beside the other `test_migration_*` / setup calls (near line 2360):

```bash
test_setup_writes_the_host_date_dialect
test_build_without_config_mk_fails
test_setup_bootstraps_with_a_month_end_post
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run.sh 2>&1 | grep -E "setup_writes_dialect|build_without_config_mk"`
Expected: FAIL lines for both — `config.mk` does not exist yet (`expected file to exist: config.mk`), and the build *succeeds* today (BSD args on GNU actually fail for a different reason, but `build_expect_fail` may pass incidentally; the `config.mk` test is the reliable red). Confirm at least `setup_writes_dialect` FAILs.

- [ ] **Step 3: Add `-include config.mk` at the top of the Makefile**

After line 4 (`SHELL := /bin/bash`), insert:

```make

#
# Per-install platform config, written by `make setup`:
# DATE_DIALECT := bsd|gnu, chosen by probing date(1). The
# leading - suppresses the "no such file" error on a tree
# that has not been set up yet. include is processed at
# parse time, so $(DATE_DIALECT) is in scope for both the
# parse-time date check and the recipes. An unconfigured
# build fails loud in date_select below.
#
-include config.mk
```

- [ ] **Step 4: Replace the `date_words`/`date_args` block with `date_words` + `date_select`**

Replace the block at lines 178–190 (comment through `date_args = ...`) with:

```make
#
# The three date fields of a post filename, as words, and
# the date(1) arguments they make. Three call sites share
# date_select: the two date formatters below and the parse-
# time date check further down. The check's whole correctness
# rests on it running the same arguments the build will, so
# this is factored rather than repeated -- a second copy
# could drift, and a check that answers a slightly different
# question than the build asks is the same class of defect
# as no check.
#
date_words = $(wordlist 1, 3, $(subst -, , $(notdir $(1))))

#
# date_select: the arguments that name that day at midnight,
# one twin per dialect, chosen by DATE_DIALECT from config.mk.
#   bsd: -v2026y -v07m -v04d -v0H -v0M -v0S
#   gnu: -d "2026-07-04 00:00:00"
# The midnight pin is folded in for both: %B %d, %Y prints no
# time, so it is output-preserving for the long form, and it
# is what rfc822 and the check need (date with only y/m/d
# keeps the current clock time). The else branch fails loud --
# date_select is expanded only while building something dated,
# never by setup's own recipe, so `make setup` still boots a
# tree that has no config.mk yet.
#
ifeq ($(DATE_DIALECT),bsd)
date_select = $(join $(addprefix -v,$(call date_words,$(1))),y m d) -v0H -v0M -v0S
else ifeq ($(DATE_DIALECT),gnu)
date_select = -d "$(subst $(space),-,$(call date_words,$(1))) 00:00:00"
else
date_select = $(error grampa: no DATE_DIALECT -- run `make setup` first)
endif
```

- [ ] **Step 5: Point the three call sites at `date_select`**

`date_from_filename` (was line 195):

```make
date_from_filename = $(shell date $(call date_select,$(1)) "+%B %d, %Y")
```

`rfc822_from_filename` (was line 211) — drop the now-redundant trailing `-v0H -v0M -v0S`, since `date_select` folds the pin in:

```make
rfc822_from_filename = $(shell LC_ALL=C date $(call date_select,$(1)) "+%a, %d %b %Y %H:%M:%S %z")
```

In the comment block just above `rfc822_from_filename` (lines 206–210), replace the `-v0H -v0M -v0S` paragraph so it points at `date_select` for the pin rather than describing args this line no longer carries:

```make
# The midnight pin lives in date_select now (bsd's -v0H -v0M
# -v0S, gnu's literal 00:00:00): date with only y/m/d keeps
# the current clock time, so without it every build would
# stamp a different pubDate and rss.xml would look changed on
# every deploy. LC_ALL=C stays here -- RFC 822 day and month
# names are literal English tokens in either dialect.
```

`BAD_POST_DATES` (was line 500) — swap `date_args` for `date_select`, drop the trailing `-v0H -v0M -v0S`, **and gate the whole check on `$(DATE_DIALECT)`** so it never runs (and so never expands `date_select`) on an unconfigured tree:

```make
BAD_POST_DATES := $(if $(DATE_DIALECT),$(if $(SUSPECT_POST_DATES),$(shell $(foreach n,$(SUSPECT_POST_DATES),LC_ALL=C date $(call date_select,$(n)) >/dev/null 2>&1 || echo $(n);) true)))
```

The `$(if $(DATE_DIALECT),...)` gate is **load-bearing, not cosmetic** (spec §3): without it, a
month-end post on an unconfigured tree makes this `:=` line expand `date_select`'s `$(error)` at
parse time — which kills `make setup` itself before it can write `config.mk`, a deadlock. Gated,
an unconfigured build instead fails one step later at recipe time via `date_from_filename`, with
the same message, and `make setup` always succeeds. Add a short comment above the line noting the
gate exists to keep `make setup` bootstrappable, not to skip validation (a configured build runs
the check exactly as before).

- [ ] **Step 6: Make `setup` write `config.mk`**

Append to the `setup` recipe, after line 1212 (`... deploy.sh ... 2>/dev/null`):

```make
	@if date -v1d >/dev/null 2>&1; then dialect=bsd; \
	elif date -d 2026-01-15 >/dev/null 2>&1; then dialect=gnu; \
	else echo "grampa: no supported date dialect (need BSD 'date -v' or GNU 'date -d')" >&2; exit 1; fi; \
	echo "DATE_DIALECT := $$dialect" > config.mk; \
	echo "Configured date dialect: $$dialect"
```

Add a one-line comment above the `setup:` line (or fold into its existing comment) noting `config.mk` is *generated* — always rewritten, the one deliberate exception to setup's non-clobbering `cp -i`, because it is derived from the machine, not authored.

- [ ] **Step 7: Add `/config.mk` to `.gitignore`**

In the anchored per-install group, add the line directly after `/config`:

```
/config
/config.mk
```

- [ ] **Step 8: Run the two new tests — verify they pass**

Run: `bash tests/run.sh 2>&1 | grep -E "FAIL:|passed:"`
Expected: the only FAIL lines are the four under `migration_rm_fails` (the BSD-only `chflags`
test, fixed in Task 2); none of the three new tests appear in a FAIL line. The tally reads
**`failed: 4`** — the load-bearing half. The `passed:` count is ~276 on this GNU host, but do
not gate on the exact number; gate on `failed: 4` and all four being `migration_rm_fails`.

- [ ] **Step 9: Verify the build actually works end-to-end on this GNU host**

Run:
```bash
rm -rf /tmp/grampa-t1 && mkdir /tmp/grampa-t1 && cp Makefile /tmp/grampa-t1/ && cp -R .source /tmp/grampa-t1/ && cd /tmp/grampa-t1 && make setup >/dev/null && printf 'title: Hi\n-----------------------------------\n<p>Body.</p>\n' > posts/2026-07-04-home_first.txt && make 2>&1 | tail -3 && grep -o 'July 04, 2026' build/2026/07/04/first.html; cd - >/dev/null
```
Expected: build succeeds, `config.mk` contains `DATE_DIALECT := gnu`, and the page contains `July 04, 2026`.

- [ ] **Step 10: Commit**

```bash
git add Makefile .gitignore tests/run.sh
git commit -m "Port off BSD: detect date dialect at make setup."
```

---

### Task 2: Guard the BSD-only `chflags` migration test

**Files:**
- Modify: `tests/run.sh` — `test_migration_reports_error_when_rm_fails` (1526–1549).

**Interfaces:**
- Consumes: nothing new. Uses the existing `sandbox`, `assert_*` helpers.
- Produces: a test that skips cleanly where `chflags` is unavailable, so `make test` is green on both platforms.

- [ ] **Step 1: Confirm the failure this closes**

Run: `bash tests/run.sh 2>&1 | grep -E "migration_rm_fails|passed:"`
Expected (after Task 1): 4 FAIL lines under `migration_rm_fails`, `failed: 4`. This is the state the guard removes.

- [ ] **Step 2: Add the skip guard at the top of the test body**

Insert immediately after `sandbox migration_rm_fails` (line 1527), before `cp -R "$REPO/tools" .`:

```bash
	# chflags uchg is the only realistic way to make a file
	# un-removable without root, and it is BSD/macOS-only. On
	# a host without it (GNU/Linux) there is nothing to test
	# -- rm would just succeed -- so skip rather than fail.
	if ! command -v chflags >/dev/null 2>&1; then
		echo "SKIP: $CURRENT (no chflags on this host)"
		return 0
	fi
```

- [ ] **Step 3: Run the suite — verify green**

Run: `bash tests/run.sh 2>&1 | tail -1`
Expected: `passed: N  failed: 0` (on this GNU host the migration test prints a SKIP line and increments neither counter).

- [ ] **Step 4: Confirm `make test` passes through its real entry point**

Run: `make test 2>&1 | tail -3`
Expected: exits 0, final line `passed: N  failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh
git commit -m "Skip the chflags migration test where chflags is absent."
```

---

### Task 3: Documentation — bring CLAUDE.md in line with the ported code

**Files:**
- Modify: `CLAUDE.md` — the **BSD-only** gotcha; the Layout table; the setup-section "Serial `make setup all` is fine" claim; the make-helper list; the Post-format date paragraph; add a `config.mk` note.

**Interfaces:**
- Consumes: the shipped Task 1/2 code. Produces: docs that match it.
- Note for the reviewer: CLAUDE.md's date-helper wording lagging the ported code across Tasks 1–2 is *deliberately* deferred to this task (settled), so do not flag it as a Task 1 defect. (CLAUDE.md names no `date_args`, so this is an insert of `date_words`/`date_select`, not a rename.)

- [ ] **Step 1: Rewrite the BSD-only gotcha**

Replace the bullet beginning `**BSD-only.** \`date_from_filename\` uses \`date -v\` ...` (in the Gotchas list) with:

```markdown
- **Portable across BSD and GNU, chosen at `make setup`.** `date_select` has one twin per
  dialect — BSD's `-v<y>y -v<m>m -v<d>d` selectors, GNU's `-d "<y-m-d> 00:00:00"` — and `make
  setup` probes `date(1)` once and writes the winner to a generated `config.mk` (`DATE_DIALECT
  := bsd|gnu`) that the Makefile `-include`s. All three date sites (`date_from_filename`,
  `rfc822_from_filename`, the parse-time `BAD_POST_DATES` check) share `date_select`, so the
  check still runs the exact args the build runs. A build on a tree with no `config.mk` fails
  loud — see the "unconfigured build" note below. The one behavioural difference between
  dialects: a two-digit-year filename like `26-7-4-home_x.txt` renders its *displayed* date as
  year `0026` under BSD but `2026` under GNU; the URL is `/26/7/4/x.html` either way, since
  paths come from the raw filename, not `date`. Edge case, documented not fixed.
```

- [ ] **Step 2: Add the unconfigured-build gotcha**

Add a new bullet just after the one above:

```markdown
- **An unconfigured build fails loud at recipe time, and `make setup` always bootstraps.** With
  no `config.mk`, `$(DATE_DIALECT)` is empty and `date_select`'s else branch is `$(error grampa:
  no DATE_DIALECT -- run `make setup` first)`. Two things keep this loud without deadlocking
  `setup`: `setup`'s own recipe writes `config.mk` without expanding any date helper, and the
  parse-time `BAD_POST_DATES` check is gated `$(if $(DATE_DIALECT),...)` so it does not run — and
  so does not expand `date_select` — while unconfigured. The `:=` check would otherwise expand
  `date_select` at parse time on a month-end post during `make setup` itself, `$(error)`ing
  before the recipe writes `config.mk`: a deadlock (can't build without it, can't `setup` to make
  it). Gated, the failure is uniform — every unconfigured build dies at **recipe time** on the
  first dated page's `date_from_filename`, before any page is written — and `make setup` succeeds
  for any corpus. The gate skips the check, it does not disable it: a configured build runs it
  exactly as before. This is the upgrade path for an existing BSD install: pull the new Makefile →
  first `make` says "run `make setup` first" → `make setup` (which only *adds* `config.mk`,
  clobbering nothing else, and now never deadlocks) → builds resume.
```

- [ ] **Step 3: Qualify the "Serial `make setup all` is fine" claim**

The sentence is wrapped across lines 29–30 of CLAUDE.md: `... Serial \`make setup all\` is fine,
and so is the documented \`make setup\`` / `then \`make\`.`. Match it across the wrap (or reflow
the paragraph) and replace the whole sentence — from `Serial` through `then \`make\`.` — with:

```markdown
Serial `make setup all` is fine **only when `config.mk` already exists or `posts/` is empty**;
on a tree that already has dated posts it fails, because `-include config.mk` runs once at parse
time (empty on a virgin tree) and make does not re-include a fileless-rule include after `setup`'s
recipe writes it, so the `build` half of the same process still has `DATE_DIALECT` empty and
fires `date_select`'s `$(error)` at recipe time. But `make setup` alone always succeeds and
writes `config.mk` — the parse-time date check is gated on `$(DATE_DIALECT)` (see the portable-date
gotcha) precisely so an unconfigured `setup` never trips the error before writing the file — so a
second `make` then succeeds. This is the same lazy-parse-vs-recipe split already documented for
`config`/`FEED_PAGES`, reaching an `-include` this time. The documented `make setup` then `make`
is unaffected and remains the primary flow.
```

- [ ] **Step 4: Add `config.mk` to the Layout table and the config section**

In the Layout table, add a row after the `config`, `deploy.sh` row (or as its own row):

```markdown
| `config.mk` | no | Per-install, **generated** by `make setup` probing `date(1)`: `DATE_DIALECT := bsd\|gnu`. No `.source` twin — it is derived, not copied, so setup always rewrites it. |
```

And note in the paragraph about `make setup` copying with `yes n | cp -i`: `config.mk` is the exception — it is generated and unconditionally (re)written, which is also what re-fixes the dialect if a checkout ever moves between OSes.

- [ ] **Step 5: Insert `date_words`/`date_select` into the make-helper list**

CLAUDE.md's helper list (line 414) reads `` `reverse`, `space`, `date_from_filename`,
`rfc822_from_filename`, `underscore_split`, ... `` — it names **no** `date_args` (there is nothing
to rename). Insert `` `date_words`, `date_select`, `` immediately before `date_from_filename`, so
it becomes `` ... `space`, `date_words`, `date_select`, `date_from_filename`, ... ``. Nothing else
in that paragraph mentions the pin, so there is no pin-location edit here — that lives in Step 5b.

- [ ] **Step 5b: Fix the now-stale `rfc822_from_filename` midnight-pin Gotchas bullet**

CLAUDE.md line 504 is a standalone Gotchas bullet: `` **`rfc822_from_filename` pins the time to
midnight with `-v0H -v0M -v0S`.** `date -v` with only y/m/d ... ``. After Task 1 the pin lives in
`date_select` and `rfc822_from_filename` no longer carries `-v0H`. Replace that bullet with:

```markdown
- **`date_select` pins the time to midnight** — BSD's `-v0H -v0M -v0S`, GNU's literal `00:00:00`
  in the `-d` string. `date` with only y/m/d keeps the current wall-clock time, so without the pin
  every build would stamp a different `<pubDate>` on the same post and `rss.xml` would look
  changed on every deploy. The long form `%B %d, %Y` prints no time, so the pin is invisible
  there; it is `rfc822_from_filename` and the parse-time check that need it.
```

- [ ] **Step 5c: Update the stale `date_args` reference in the Makefile comment**

`Makefile:52` reads `# Same argument as date_args -- a check that`. `date_args` no longer exists;
change it to `# Same argument as date_select -- a check that`. (This is a code-comment edit that
rode along in Task 1's file; correcting it here keeps the doc pass self-contained. Re-`git add
Makefile` in Step 9.)

- [ ] **Step 6: Update the Post-format date paragraph**

Where CLAUDE.md's Post-format section says `\`2026-7-4\` unpadded, \`26-7-4\` two-digit, and \`2028-02-29\` build`, add a parenthetical after `26-7-4`: `(rendered year 0026 under BSD, 2026 under GNU — see the portable-date gotcha)`. Leave the rest of the date rules unchanged.

- [ ] **Step 7: Re-read CLAUDE.md against the shipped code**

Read the edited sections back and confirm: no surviving `date -v`-only claim (BSD-only bullet, midnight-pin bullet), no `date_args` reference in CLAUDE.md **or** at `Makefile:52`, the helper list names `date_words`/`date_select`, the Layout table lists `config.mk`, the "setup all" sentence matches the gated (no-deadlock) behavior, and the two-digit-year note is consistent between the gotcha and the Post-format section.

- [ ] **Step 8: Verify the suite is still green (docs-only change must not move it)**

Run: `make test 2>&1 | tail -1`
Expected: `passed: N  failed: 0`.

- [ ] **Step 9: Commit**

```bash
git add CLAUDE.md Makefile
git commit -m "Document the portable date dialect and its setup-time detection."
```

---

## Self-Review

**Spec coverage:**
- Configure mechanism (`config.mk` + `-include`) → Task 1 Steps 3, 6, 7. ✓
- `date_select` twins + three call sites → Task 1 Steps 4, 5. ✓
- Fail-loud else branch → Task 1 Step 4; tested Step 1 (`test_build_without_config_mk_fails`). ✓
- **B1 gate** (`BAD_POST_DATES` gated on `$(DATE_DIALECT)`, no `make setup` deadlock) → Task 1 Step 5; regression-tested Step 1 (`test_setup_bootstraps_with_a_month_end_post`); documented Task 3 Steps 2, 3. ✓
- Setup probe order (bsd then gnu) → Task 1 Step 6, mirrors `probe-platform.sh`. ✓
- `.gitignore` / `make clean` leaves `config.mk` → Task 1 Step 7; `clean` untouched (unchanged target = leaves it). ✓
- Three new tests → Task 1 Step 1. ✓
- chflags guard (spec §4 ripple) → Task 2. ✓
- CLAUDE.md ripple (BSD-only gotcha, unconfigured-build/B1 gotcha, Layout, setup-all claim, helper-list insert, midnight-pin bullet, two-digit-year) + `Makefile:52` comment → Task 3. ✓
- `bsd` twin BSD smoke test deferred to branch checkpoint → Global Constraints + spec Test plan. ✓

**Placeholder scan:** No TBD/TODO; every code and test step carries actual content.

**Type consistency:** `date_select` (not `date_args`) named consistently across Task 1 Steps 4/5 and Task 3, and CLAUDE.md is confirmed to contain no `date_args` (Step 5 is an insert, not a rename). `DATE_DIALECT` values `bsd`/`gnu` consistent across setup write (Task 1 Step 6), the `BAD_POST_DATES` gate (Step 5), tests (Step 1), and docs (Task 3). `build`, `build_expect_fail`, `assert_out_grep`, `assert_file`, `ok`, `fail` all match helpers defined in `tests/run.sh`.
