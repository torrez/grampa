# Multiple Markdown Processors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect an installed markdown processor at `make setup` from a preference-ordered table of twelve, record it in the generated `config.mk`, and let `markdown=` in `config` override it.

**Architecture:** A `define` block of `probe|argv` pairs is the only new data. `setup`'s recipe walks it, running each candidate against a throwaway file, and writes the winner's full argv as `DETECTED_MARKDOWN :=` into `config.mk` beside `DATE_DIALECT`. `MARKDOWN_CMD` combines that with a lazily-read `markdown=` from `config`, and `%.staged` runs it. Two parse-time additions — an upgrade guard and a one-line notice — share a `BUILD_GOAL` variable.

**Tech Stack:** GNU make, POSIX shell, awk. No new dependencies. The spec is `docs/superpowers/specs/2026-08-08-multiple-markdown-processors-design.md`; read it before starting.

## Global Constraints

- **Tabs in the Makefile.** Recipes are `@`-prefixed and echo a short human-readable progress line. Comment blocks above each rule and helper in the existing `#`-banner style.
- **`build/category/%.html` must stay defined above the `%.html` rule.** Nothing in this plan touches either, but do not reorder rules.
- **The date check must stay below `CHECKED_POST_NAMES`.** Nothing here moves it; do not.
- **Never `:=` anything that reads `config`.** `config` may not exist at parse time. `CONFIG_NAME` and `CONFIG_URL` are `=` for this reason and `CONFIG_MARKDOWN` must be too.
- **`make` must be run from the repo root**; awk reads templates by relative path.
- Run the suite with `./tests/run.sh` from the repo root. It must be green at the end of every task.
- Commit at the end of every task. Never commit a red suite.
- **CLAUDE.md mandates a Fable review of each task's diff before the next task starts.** Dispatch with the `Agent` tool using `model: "fable"`, give it the Makefile failure modes named in CLAUDE.md's Review cycle section, and tell it to prove claims in a sandbox.

---

### Task 1: Make the suite host-independent

Detection reads the real `PATH`. On any machine with a markdown processor installed, every existing test would start staging its bodies through it, and the suite's results would depend on the developer's laptop. This must land **before** anything that detects, or every later task's tests are meaningless.

**Files:**
- Modify: `tests/run.sh:23-36` (the `sandbox()` helper), plus a new helper above it

**Interfaces:**
- Produces: `hide_markdown_tools()`, callable from any test; writes `exit 1` stubs for all eleven PATH candidate names into `$SBOX/bin` and prepends it to `PATH`. Later tasks call it implicitly via `sandbox()`.

- [ ] **Step 1: Write the failing test**

Add near the other setup tests at the end of `tests/run.sh`, and register it in the runner list at the bottom of the file:

```bash
#
# sandbox() must pin detection off regardless of what the
# developer has installed, or the whole suite's output
# depends on their laptop. Non-executable placeholders do
# not shadow a real tool -- PATH lookup skips them -- so
# the stubs must be executable and exit non-zero.
#
test_sandbox_hides_host_markdown_tools() {
	sandbox sandbox_hides_tools
	for t in lowdown cmark cmark-gfm md2html comrak multimarkdown markdown smu markdown_py markdown-it pandoc; do
		if [ -x "bin/$t" ]; then ok; else fail "expected a stub for $t"; fi
		if "./bin/$t" /dev/null >/dev/null 2>&1; then fail "stub $t must exit non-zero"; else ok; fi
	done
	assert_eq "PATH is prefixed with the sandbox bin" "$SBOX/bin" "${PATH%%:*}"
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./tests/run.sh 2>&1 | grep -A2 sandbox_hides_tools`
Expected: FAIL, `expected a stub for lowdown`.

- [ ] **Step 3: Add the helper and call it from `sandbox()`**

Insert above `sandbox()` in `tests/run.sh`:

```bash
#
# Executable stubs that exit 1 for every PATH candidate in
# the Makefile's table, so `make setup` finds nothing and
# staging stays verbatim -- today's behaviour, and the same
# on every machine. An `exit 1` stub is what it takes: a
# non-executable placeholder does not shadow /usr/bin/x,
# because PATH lookup skips files it cannot execute, and a
# plain `exit` would be ACCEPTED by the probe.
#
# A test wanting a real processor overwrites one stub and
# re-runs `make setup`.
#
hide_markdown_tools() {
	mkdir -p "$SBOX/bin"
	for t in lowdown cmark cmark-gfm md2html comrak multimarkdown \
		markdown smu markdown_py markdown-it pandoc; do
		printf '#!/bin/sh\nexit 1\n' > "$SBOX/bin/$t"
		chmod +x "$SBOX/bin/$t"
	done
	PATH="$SBOX/bin:$PATH"
	export PATH
}
```

Then in `sandbox()`, insert the call between the `cd` and the `make setup`:

```bash
	cd "$SBOX" || exit 1
	hide_markdown_tools
	make setup >/dev/null 2>&1
```

`PATH` is restored implicitly because each test runs in the same shell — so also reset it at the top of `sandbox()`, before the stubs are made, to avoid accumulating one `bin` per test:

```bash
sandbox() {
	CURRENT="$1"
	SBOX="$TMPROOT/$1"
	PATH="$ORIGINAL_PATH"
	...
```

and near the top of the file, beside `REPO=`:

```bash
ORIGINAL_PATH="$PATH"
```

- [ ] **Step 4: Run the full suite**

Run: `./tests/run.sh`
Expected: the new test passes and **every pre-existing test still passes**. The count should rise by exactly the new assertions and `failed: 0`. If any existing test now fails, stop — it means something already depended on host tools.

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh
git commit -m "Pin markdown detection off in the test sandbox."
```

---

### Task 2: The candidate table, the setup probe, and config.mk

**Files:**
- Modify: `Makefile` — new `define` block near the other data; `setup` recipe at `Makefile:1255-1267`
- Modify: `.gitignore` — add `/config.mk.new`
- Modify: `tests/run.sh` — new tests

**Interfaces:**
- Produces: `MARKDOWN_CANDIDATES` (exported `define`), and `DETECTED_MARKDOWN := <full argv>` written into `config.mk`. Task 4 consumes `DETECTED_MARKDOWN`.

- [ ] **Step 1: Write the failing tests**

```bash
#
# Detection records field 2 -- the whole command line --
# not the probe name. Recorded as field 1, cmark-gfm loses
# -e table and renders tables as paragraphs at exit 0.
#
test_setup_records_the_full_argv() {
	sandbox setup_full_argv
	printf '#!/bin/sh\ncat "$2"\n' > bin/cmark-gfm; chmod +x bin/cmark-gfm
	make setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := cmark-gfm --unsafe -e table"
}

#
# Preference order: the table's first working candidate
# wins, not whichever happens to be installed.
#
test_setup_prefers_the_earlier_candidate() {
	sandbox setup_order
	printf '#!/bin/sh\ncat "$1"\n' > bin/cmark; chmod +x bin/cmark
	make setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
	printf '#!/bin/sh\ncat "$4"\n' > bin/lowdown; chmod +x bin/lowdown
	make setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := lowdown --out-no-smarty"
}

#
# The probe tests the flags, not just the binary: a
# candidate that drops raw HTML is skipped, which is the
# real behaviour of cmark/cmark-gfm/lowdown without their
# --unsafe-family flags.
#
test_probe_skips_a_candidate_that_eats_raw_html() {
	sandbox probe_raw_html
	printf '#!/bin/sh\nsed "s/<i>y<\\/i>/RAWGONE/" "$4"\n' > bin/lowdown; chmod +x bin/lowdown
	printf '#!/bin/sh\ncat "$1"\n' > bin/cmark; chmod +x bin/cmark
	make setup >/dev/null 2>&1
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
}

#
# A candidate emitting a whole document is skipped: base.txt
# would otherwise wrap it in a second <html> at exit 0.
#
test_probe_skips_a_whole_document_candidate() {
	sandbox probe_document
	printf '#!/bin/sh\necho "<html><body>x <i>y</i></body></html>"\n' > bin/lowdown; chmod +x bin/lowdown
	make setup >/dev/null 2>&1
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
}

#
# One candidate truncating the probe file must not poison
# the candidates behind it. The file is rewritten per
# candidate for exactly this reason.
#
test_a_truncating_candidate_does_not_poison_the_walk() {
	sandbox probe_truncate
	printf '#!/bin/sh\n: > "$4"\nexit 1\n' > bin/lowdown; chmod +x bin/lowdown
	printf '#!/bin/sh\ncat "$1"\n' > bin/cmark; chmod +x bin/cmark
	make setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"
}

#
# Nothing installed is a legitimate state, not an error.
#
test_setup_with_no_processor_records_empty() {
	sandbox setup_none
	make setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN :="
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
}

#
# The cmp guard: a no-op setup must not bump the mtime, or
# every setup re-stages every post once Task 4 lands.
#
test_noop_setup_leaves_config_mk_untouched() {
	sandbox setup_noop
	local before after
	before=$(stat -c %Y config.mk 2>/dev/null || stat -f %m config.mk)
	sleep 1
	make setup >/dev/null 2>&1
	after=$(stat -c %Y config.mk 2>/dev/null || stat -f %m config.mk)
	assert_eq "config.mk mtime unchanged by a no-op setup" "$before" "$after"
	assert_no_file config.mk.new
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `./tests/run.sh`
Expected: all seven fail — `expected 'DETECTED_MARKDOWN := …' in config.mk`.

- [ ] **Step 3: Add the candidate table**

Insert into `Makefile` after the `-include config.mk` block and its comment (around line 16), before `BUILD_DIR`:

```make
#
# The markdown processors grampa knows how to drive, in
# preference order: tables first, runtime-free first, and
# Markdown.pl last. Field 1 is what setup probes, field 2
# is the command line it records. A field 1 containing a
# slash is probed with [ -x ] rather than run from PATH.
#
# An argv here must not contain # or $, which would
# truncate or misparse the config.mk line it is written
# into.
#
# The --unsafe / --html-no-skiphtml / --html flags are not
# optional extras. cmark, cmark-gfm, lowdown, comrak and
# markdown-it all DISCARD raw HTML in the input without
# them -- lowdown deletes it outright, cmark replaces it
# with <!-- raw HTML omitted --> -- which would silently
# drop an embedded iframe from a post. Grampa already
# copies post bodies through as raw HTML when there is no
# processor at all, so this restores existing behaviour
# rather than relaxing anything.
#
# lowdown and discount also smarten punctuation by
# default, rewriting the author's quotes and dashes; hence
# --out-no-smarty and -smarty, and pandoc's -smart.
#
# comrak and markdown-it are the two rows never executed
# -- their flags are inferred from the family behaviour
# above, not observed. The probe below is what keeps that
# honest.
#
define MARKDOWN_CANDIDATES
lowdown|lowdown --out-no-smarty --html-no-skiphtml --html-no-escapehtml
cmark-gfm|cmark-gfm --unsafe -e table -e strikethrough -e autolink -e tasklist
md2html|md2html --github
comrak|comrak --unsafe -e table
multimarkdown|multimarkdown --snippet
markdown|markdown -f +tables,-smarty
cmark|cmark --unsafe
smu|smu
markdown_py|markdown_py -x tables
markdown-it|markdown-it --html
pandoc|pandoc -f markdown-smart -t html
./Markdown.pl|./Markdown.pl
endef
export MARKDOWN_CANDIDATES
```

- [ ] **Step 4: Rewrite the setup recipe**

Replace the `date`-probe tail of the `setup` recipe (`Makefile:1263-1267`) with:

```make
	@if date -v1d >/dev/null 2>&1; then dialect=bsd; \
	elif date -d 2026-01-15 >/dev/null 2>&1; then dialect=gnu; \
	else echo "grampa: no supported date dialect (need BSD 'date -v' or GNU 'date -d')" >&2; exit 1; fi; \
	winner=$$(printf '%s\n' "$$MARKDOWN_CANDIDATES" | while IFS='|' read -r probe cmd; do \
		[ -n "$$probe" ] || continue; \
		case "$$probe" in \
			*/*) [ -x "$$probe" ] || continue;; \
			*) command -v "$$probe" >/dev/null 2>&1 || continue;; \
		esac; \
		probefile=$$(mktemp); printf 'x <i>y</i>\n' > "$$probefile"; \
		out=$$($$cmd "$$probefile" 2>/dev/null </dev/null); rc=$$?; \
		rm -f "$$probefile"; \
		[ $$rc -eq 0 ] || continue; \
		case "$$out" in *'<html'*|*'<HTML'*|*DOCTYPE*) continue;; esac; \
		case "$$out" in *'<i>'*) ;; *) continue;; esac; \
		echo "$$cmd"; break; \
	done); \
	{ echo "DATE_DIALECT := $$dialect"; \
	  echo "DETECTED_MARKDOWN := $$winner"; } > config.mk.new; \
	if cmp -s config.mk.new config.mk; then rm -f config.mk.new; \
	else mv config.mk.new config.mk; fi; \
	echo "Configured date dialect: $$dialect"; \
	if [ -n "$$winner" ]; then echo "Configured markdown: $$winner"; \
	else echo "Configured markdown: none -- post bodies stay HTML"; fi
```

Three things are load-bearing. The whole thing is **one** `; \`-continued logical line, because each recipe line is its own shell and `dialect` and `winner` would not otherwise survive to the write. The `while` loop runs in a subshell, so the winner is `echo`ed out of the pipeline and captured — assigning it inside the loop produces nothing. And `probefile` is created **inside** the loop, per candidate: a candidate that truncates a shared file makes every candidate behind it fail the `<i>` check on empty input.

- [ ] **Step 5: Add the gitignore entry**

In `.gitignore`, beside `/config.mk`:

```
/config.mk.new
```

- [ ] **Step 6: Run the suite**

Run: `./tests/run.sh`
Expected: all seven new tests pass, `failed: 0`. `test_setup_writes_the_host_date_dialect` must still pass — the dialect half of `config.mk` is unchanged in content, only in how it is written.

- [ ] **Step 7: Verify against the real tools**

Run, in a scratch copy outside the repo:

```bash
make setup && cat config.mk
```

Expected: `DETECTED_MARKDOWN := lowdown --out-no-smarty --html-no-skiphtml --html-no-escapehtml` on a machine with lowdown installed. If a *different* tool wins, the table order or a probe check is wrong — investigate before continuing.

- [ ] **Step 8: Commit**

```bash
git add Makefile .gitignore tests/run.sh
git commit -m "Detect a markdown processor at setup and record it in config.mk."
```

---

### Task 3: BUILD_GOAL and the upgrade guard

An install predating this change has a `config.mk` with only `DATE_DIALECT`. Left alone, `DETECTED_MARKDOWN` is undefined, markdown silently turns off, already-staged posts keep their rendered bodies while newly edited ones go verbatim, and the site goes **mixed** at exit 0.

**Files:**
- Modify: `Makefile` — immediately after the `-include config.mk` block
- Modify: `tests/run.sh`

**Interfaces:**
- Produces: `BUILD_GOAL`, consumed by Task 6's notice as well.

- [ ] **Step 1: Write the failing tests**

```bash
#
# An install from before markdown detection must fail loud
# rather than silently staging verbatim.
#
test_config_mk_without_detected_markdown_fails_the_build() {
	sandbox old_config_mk
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build_expect_fail
	assert_out_grep "config.mk predates markdown detection"
}

#
# ...including for an explicit file goal. An allowlist of
# all/build/deploy leaves this ungated, which reopens the
# silent rot the guard exists to close.
#
test_old_config_mk_fails_for_an_explicit_page_goal() {
	sandbox old_config_mk_explicit
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build_expect_fail build/2026/08/06/hello.html
	assert_out_grep "config.mk predates markdown detection"
}

#
# The guard must not deadlock: it tells you to run setup,
# so setup has to parse and run.
#
test_setup_recovers_an_old_config_mk() {
	sandbox old_config_mk_setup
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build setup
	assert_grep config.mk "DETECTED_MARKDOWN :="
}

#
# A probed-empty config.mk is a legitimate state and must
# not trip the guard. $(origin) is what tells the two
# apart: undefined vs file, though both expand empty.
#
test_probed_empty_config_mk_builds_fine() {
	sandbox empty_detected
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_file build/2026/08/06/hello.html
}

#
# clean must stay usable on an unconverted tree.
#
test_clean_works_with_an_old_config_mk() {
	sandbox old_config_mk_clean
	printf 'DATE_DIALECT := gnu\n' > config.mk
	build clean
}
```

- [ ] **Step 2: Run them and watch the right ones fail**

Run: `./tests/run.sh`
Expected: the first two fail (`make succeeded but should have failed`); the last three already pass.

- [ ] **Step 3: Add BUILD_GOAL and the guard**

Insert in `Makefile` immediately after the `-include config.mk` line and before the candidate table:

```make
#
# Which goals count as "a build is happening". A denylist,
# not an allowlist: make build/index.html and
# make work/X.staged are ordinary builds that an allowlist
# of all/build/deploy scores as non-builds, which would
# leave the guard below and the notice further down silent
# for exactly the targeted invocations someone debugging
# reaches for. A denylist fails loud on an unlisted future
# goal; an allowlist fails silent. It must be kept in sync
# with the phony non-build targets.
#
NONBUILD_GOALS := clean setup test config
BUILD_GOAL := $(if $(MAKECMDGOALS),$(filter-out $(NONBUILD_GOALS),$(MAKECMDGOALS)),default)

#
# An install set up before markdown detection has a
# config.mk holding only DATE_DIALECT. Nothing else would
# notice: DATE_DIALECT is set so the loud date check is
# satisfied, DETECTED_MARKDOWN is merely undefined, and
# markdown silently turns off -- already-staged posts keep
# their rendered bodies while the next edited post stages
# verbatim, so the site goes mixed at exit 0 and deploy
# ships it.
#
# $(origin) is what makes this precise: an old config.mk
# gives "undefined", while a new one where detection found
# nothing gives "file", even though both expand empty. So a
# legitimately processor-less install never trips it.
#
# The BUILD_GOAL gate is load-bearing, not symmetry with
# the notice below. Without it this deadlocks: the error
# says to run `make setup`, and make setup parses this same
# Makefile and dies here before its recipe can rewrite
# config.mk -- the same trap already documented for
# BAD_POST_DATES and date_select.
#
ifeq ($(if $(BUILD_GOAL),$(if $(DATE_DIALECT),$(filter undefined,$(origin DETECTED_MARKDOWN)))),undefined)
$(error grampa: config.mk predates markdown detection -- run `make setup`)
endif
```

- [ ] **Step 4: Run the suite**

Run: `./tests/run.sh`
Expected: all five pass, `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Fail loud on a config.mk that predates markdown detection."
```

---

### Task 4: Drive `%.staged` from the detected processor

**Files:**
- Modify: `Makefile:1165-1181` (the `%.staged` rule and recipe), plus a `MARKDOWN_CMD` definition beside `CONFIG_URL` around `Makefile:180`
- Modify: `tests/run.sh` — adapt the existing markdown tests

**Interfaces:**
- Consumes: `DETECTED_MARKDOWN` from Task 2.
- Produces: `MARKDOWN_CMD`, extended by Task 5.

- [ ] **Step 1: Write the failing test**

```bash
#
# A detected processor is what stages the body now, not
# a hardcoded ./Markdown.pl.
#
test_detected_processor_stages_the_body() {
	sandbox detected_stages
	printf '#!/bin/sh\nsed "s/HELLO/RENDERED/" "$1"\n' > bin/cmark; chmod +x bin/cmark
	make setup >/dev/null 2>&1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "RENDERED"
}

#
# With nothing detected the body is copied verbatim --
# today's behaviour when Markdown.pl is absent.
#
test_no_processor_stages_verbatim() {
	sandbox none_verbatim
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hello *world*
EOF
	build
	assert_grep build/2026/08/06/hello.html "Hello *world*"
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `./tests/run.sh`
Expected: `test_detected_processor_stages_the_body` fails — `expected 'RENDERED'`. The verbatim one already passes.

- [ ] **Step 3: Define MARKDOWN_CMD**

Insert in `Makefile` after the `SITE_URL` block (around line 181):

```make
#
# The markdown command line: the markdown= override from
# config if set, otherwise whatever setup detected.
#
# Lazily expanded for the same reason as CONFIG_NAME and
# CONFIG_URL -- config may not exist when this is parsed.
# $(or) rather than $(if) because it short-circuits and
# names CONFIG_MARKDOWN once instead of twice, which is 5
# shell-outs instead of 9 on a one-post rebuild with
# markdown= set.
#
# Do NOT memoize this with the $(eval) idiom to save the
# remaining expansions. The build notice forces the first
# expansion at parse time, which on a first-ever run is
# before config exists, so the memo would freeze the empty
# answer and stage the whole first build with the wrong
# processor.
#
CONFIG_MARKDOWN = $(shell sed -n 's/^markdown=[[:space:]]*//p' config 2>/dev/null | sed 's/[[:space:]]*$$//' | tail -1)
MARKDOWN_CMD = $(or $(strip $(CONFIG_MARKDOWN)),$(DETECTED_MARKDOWN))
```

- [ ] **Step 4: Rewrite the `%.staged` rule**

Replace `Makefile:1165-1181` — keep the long comment block above it, appending a note about the new prerequisites:

```make
$(WORK_DIR)%.staged: posts/%.txt config $(wildcard config.mk)
	@mkdir -p $(WORK_DIR)

	@$(if $(strip $(MARKDOWN_CMD)),\
		rm -f $(WORK_DIR)$*.head $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody && \
		awk -v head=$(WORK_DIR)$*.head -v body=$(WORK_DIR)$*.body \
			"$$SPLIT_STAGED" $< && \
		$(MARKDOWN_CMD) $(WORK_DIR)$*.body > $(WORK_DIR)$*.mdbody && \
		cat $(WORK_DIR)$*.head .source/splitter.txt $(WORK_DIR)$*.mdbody > $@ && \
		rm -f $(WORK_DIR)$*.head $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody,\
		cp $< $@)
```

The `$(wildcard)` is load-bearing: `config.mk` has no rule that builds it, so a bare prerequisite makes an unconfigured tree die with make's `No rule to make target 'config.mk'` instead of the deliberate `no DATE_DIALECT -- run make setup first`. Commas inside `$(MARKDOWN_CMD)` are safe — `markdown -f +tables,-smarty` has one — because make splits function arguments before expansion.

- [ ] **Step 5: Adapt the existing markdown tests**

Every test using `markdown_stub` currently relies on `./Markdown.pl` being picked up after `sandbox()` already ran setup. Add a `make setup` re-run inside `markdown_stub` itself, after the `chmod +x`:

```bash
markdown_stub() {
	cat > Markdown.pl
	chmod +x Markdown.pl
	make setup >/dev/null 2>&1
}
```

- [ ] **Step 6: Run the suite**

Run: `./tests/run.sh`
Expected: `failed: 0`. Pay particular attention to `test_failing_markdown_fails_the_build`, `test_failed_markdown_leaves_no_stale_chunks`, `test_markdown_branch_is_parallel_safe`, and `test_non_executable_markdown_falls_back_to_verbatim` — all four exercise the branch just rewritten. If `test_non_executable_markdown_falls_back_to_verbatim` fails, check that `[ -x ]` is still what probes a slash-bearing candidate.

- [ ] **Step 7: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Stage post bodies with the detected processor."
```

---

### Task 5: The `markdown=` config override

**Files:**
- Modify: `.source/config.example`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `CONFIG_MARKDOWN` and `MARKDOWN_CMD`, already defined in Task 4.

- [ ] **Step 1: Write the failing tests**

```bash
#
# markdown= beats detection.
#
test_config_markdown_overrides_detection() {
	sandbox override_wins
	printf '#!/bin/sh\nsed "s/HELLO/DETECTED/" "$1"\n' > bin/cmark; chmod +x bin/cmark
	printf '#!/bin/sh\nsed "s/HELLO/OVERRIDDEN/" "$1"\n' > bin/mytool; chmod +x bin/mytool
	make setup >/dev/null 2>&1
	printf 'name=T\nmarkdown=mytool\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "OVERRIDDEN"
}

#
# Editing markdown= re-stages, or switching processors
# would appear to do nothing.
#
test_changing_markdown_restages_posts() {
	sandbox override_restage
	printf '#!/bin/sh\nsed "s/HELLO/FIRST/" "$1"\n' > bin/one; chmod +x bin/one
	printf '#!/bin/sh\nsed "s/HELLO/SECOND/" "$1"\n' > bin/two; chmod +x bin/two
	printf 'name=T\nmarkdown=one\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build
	assert_grep build/2026/08/06/hello.html "FIRST"
	printf 'name=T\nmarkdown=two\n' > config
	build
	assert_grep build/2026/08/06/hello.html "SECOND"
}

#
# An override naming something absent fails loud rather
# than silently falling back to verbatim.
#
test_missing_override_tool_fails_the_build() {
	sandbox override_missing
	printf 'name=T\nmarkdown=no-such-tool-xyz\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
HELLO
EOF
	build_expect_fail
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `./tests/run.sh`
Expected: the first two fail on the wrong marker; the third may already pass — confirm it fails for the right reason by reading `$BUILD_OUT` (`command not found`), not because of an unrelated error.

- [ ] **Step 3: Document the key in config.example**

Append to `.source/config.example`:

```
# markdown= overrides the processor `make setup` detected.
# It is a shell command line, run as: <command> <file>
# It must write an HTML *fragment* to stdout and exit
# non-zero on failure. Like deploy.sh, it is executed --
# only put something here you would run yourself.
#
# markdown=lowdown --out-no-smarty --html-no-skiphtml --html-no-escapehtml
# markdown=cmark-gfm --unsafe -e table -e strikethrough
# markdown=md2html --github
# markdown=comrak --unsafe -e table
# markdown=multimarkdown --snippet
# markdown=markdown -f +tables,-smarty
# markdown=cmark --unsafe
# markdown=smu
# markdown=markdown_py -x tables
# markdown=markdown-it --html
# markdown=pandoc -f markdown-smart -t html
```

- [ ] **Step 4: Run the suite**

Run: `./tests/run.sh`
Expected: `failed: 0`. No Makefile change is needed — Task 4 already defined `CONFIG_MARKDOWN`. If the override tests still fail, the bug is in `MARKDOWN_CMD`'s `$(or)`, not here.

- [ ] **Step 5: Commit**

```bash
git add .source/config.example tests/run.sh
git commit -m "Document the markdown= override in config.example."
```

---

### Task 6: The build notice

**Files:**
- Modify: `Makefile` — after the `MARKDOWN_CMD` definition from Task 4
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `BUILD_GOAL` from Task 3, `MARKDOWN_CMD` from Task 4.

- [ ] **Step 1: Write the failing tests**

```bash
#
# The notice says which processor a build is using, once,
# before any page is built.
#
test_build_announces_the_processor() {
	sandbox notice_detected
	printf '#!/bin/sh\ncat "$1"\n' > bin/cmark; chmod +x bin/cmark
	make setup >/dev/null 2>&1
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_out_grep "grampa: markdown: cmark --unsafe"
}

test_build_announces_no_processor() {
	sandbox notice_none
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_out_grep "grampa: markdown: none -- post bodies stay HTML"
}

test_notice_marks_a_config_override() {
	sandbox notice_override
	printf '#!/bin/sh\ncat "$1"\n' > bin/mytool; chmod +x bin/mytool
	printf 'name=T\nmarkdown=mytool\n' > config
	add_post 2026-08-06-home_hello.txt <<'EOF'
title: Hello
-----------------------------------
Hi.
EOF
	build
	assert_out_grep "grampa: markdown: mytool (from config)"
}

#
# Non-build goals stay quiet.
#
test_clean_and_setup_print_no_notice() {
	sandbox notice_quiet
	build clean
	assert_out_not_grep "grampa: markdown:"
	build setup
	assert_out_not_grep "grampa: markdown:"
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `./tests/run.sh`
Expected: the first three fail; the fourth already passes.

- [ ] **Step 3: Add the notice**

Insert in `Makefile` immediately after the `MARKDOWN_CMD` definition:

```make
#
# Announce the processor once, at the top of a build.
#
# A parse-time $(info) rather than a line in build's
# recipe, because build's recipe runs AFTER its
# prerequisites -- the note would land below every page --
# and because a phony prerequisite ordered first is not
# ordering you can rely on under -j. Parse time runs before
# any recipe, serial or parallel.
#
# Gated on DATE_DIALECT so an unconfigured tree leads with
# the "run make setup first" error rather than a markdown
# note, and on BUILD_GOAL so clean/setup/test stay quiet.
#
# Known wrinkle, same family as the url=/FEED_PAGES gotcha:
# reading markdown= here reads config at parse time, so on
# a first-ever run -- where config does not exist yet --
# this line names the detected tool even if the config
# about to be copied into place sets markdown=. It affects
# only the printed line; the staging recipe expands
# MARKDOWN_CMD lazily at recipe time and gets the right
# answer. Self-corrects on the next make.
#
MARKDOWN_NOTE = $(if $(strip $(MARKDOWN_CMD)),$(MARKDOWN_CMD)$(if $(strip $(CONFIG_MARKDOWN)), (from config)),none -- post bodies stay HTML)
$(if $(and $(BUILD_GOAL),$(DATE_DIALECT)),$(info grampa: markdown: $(MARKDOWN_NOTE)))
```

- [ ] **Step 4: Run the suite**

Run: `./tests/run.sh`
Expected: `failed: 0`.

- [ ] **Step 5: Verify the notice really is first**

```bash
make clean >/dev/null && make | head -3
```

Expected: `grampa: markdown: …` is line 1, above every `Building …`.

- [ ] **Step 6: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Announce the markdown processor once at the top of a build."
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` — the Layout table, a new `config` key, the Gotchas list
- Modify: `README.md:24-26` and `README.md:185-187`

- [ ] **Step 1: Update README's install section**

`README.md:24-26` currently tells the reader to download `Markdown.pl`. Replace with: grampa uses whichever supported processor is installed, `make setup` picks it, `Markdown.pl` is the last resort, and `markdown=` in `config` overrides. List the eleven with their table order. Update `README.md:185-187`'s `Markdown.pl`-has-to-be-executable gotcha to say that **installing or removing any processor needs a `make setup`**, not just a `make`.

- [ ] **Step 2: Update CLAUDE.md**

- **config section:** add `markdown=` as the third key beside `name=` and `url=`, noting it is executed as a shell command line.
- **Layout table:** `config.mk` now carries `DETECTED_MARKDOWN` as well as `DATE_DIALECT`.
- **Gotchas:** replace the existing "adding or removing `Markdown.pl` does not invalidate `.staged`" bullet — that is now **closed** by the `config`/`config.mk` prerequisites, and the replacement bullet should say so and state the new rule (install a processor, run `make setup`). Add: the CommonMark family's raw-HTML default and why the `--unsafe`-family flags are mandatory; the upgrade guard and its `BUILD_GOAL` gate; and the `$(wildcard config.mk)` combined-invocation shadow as the fifth member of the parse-time-vs-recipe-time family.

- [ ] **Step 3: Check the docs against the code**

Run: `./tests/run.sh` (unchanged, still green) and re-read the two files against the Makefile. Every claim in CLAUDE.md is supposed to be checkable against the code; do not add one that isn't.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document markdown processor detection and the markdown= key."
```

---

## Self-review notes

**Spec coverage.** §1 table → Task 2 Step 3. §1 flag rationale → Task 2 Step 3 comments and Task 7. §2 detection, probe, cmp guard, gitignore → Task 2. §2a upgrade guard and `BUILD_GOAL` → Task 3. §3 override → Tasks 4 (variable) and 5 (docs, tests). §4 invalidation and recipe → Task 4. §5 notice → Task 6. §"Behavior changes" → Task 7 Steps 1–2. §Testing determinism → Task 1; the per-case tests are distributed across Tasks 2–6.

**Deliberately not covered.** The three unexecuted candidates (`multimarkdown`, `comrak`, `markdown-it`) get no verification step, by the decision recorded in the spec's Flag Verification section. Their rows still ship; the probe skips them if a flag is wrong.

**Ordering constraint.** Task 1 must land first — every later task's tests assume detection is pinned off by default. Task 3 must precede Task 6, which reuses `BUILD_GOAL`. Task 4 must precede Task 5, which reuses `CONFIG_MARKDOWN`.
