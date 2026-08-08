# Deletion staleness and setup probe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close backlog items 8, 9 and 10 plus the "setup is quiet about a rejected candidate" Minor bullet — so deleting a post stops leaving stale entries on the index, category pages and feed; so a markdown processor whose smartypants flag is wrong is rejected rather than silently rewriting the author's punctuation; and so setup says why it skipped a candidate and cannot corrupt `config.mk` when run twice at once.

**Architecture:** Four independent changes. Three live in `setup`'s recipe (`Makefile:1440-1471`) and are small. The fourth adds `posts` — the directory — as a prerequisite of the three targets that consume a *window* or a *set* of post fragments, so make notices when the set changes; a directory's mtime updates on entry creation and removal, which is exactly that condition.

**Tech Stack:** GNU make, POSIX `sh`, `awk`, `sed`, coreutils. No runtime, no package manager, no dependencies. `tests/run.sh` is plain bash run by `make test` in throwaway sandboxes.

**Spec:** `docs/superpowers/specs/2026-08-08-deletion-staleness-and-setup-probe-design.md`. Read it before Task 1; it carries the evidence tables that justify several choices below, and Fable's checkpoint-1 review is already folded into it.

## Global Constraints

- **Tabs in the Makefile.** Recipe lines are tab-indented. Multi-line recipes use `\` continuations and `$$` for the shell's `$`.
- **Recipes are prefixed with `@`** and echo a short human-readable progress line.
- **Comment blocks above each rule and helper**, in the existing `#`-banner style.
- **`setup`'s probe loop is ONE `; \`-continued logical line.** `dialect` and `winner` must survive to the write, and each *recipe line* is otherwise its own shell. Do not break the chain.
- **The probe loop runs inside `winner=$$(printf … | while … done)`.** Anything written to **stdout** inside it is captured as the winner. Diagnostics go to **stderr** only.
- **`awk`'s `$0` is `$$0` inside a `define`.** Not needed here, but do not "fix" existing ones.
- **Every new test is watched failing first**, against the specific regression it guards — not merely against nothing. An exit-status assertion that would pass against the bug is a plan failure; assert on the message or the artifact.
- **Every deletion test needs `sleep 1`.** make 3.81 truncates mtimes to whole seconds, so a sub-second-newer prerequisite rebuilds nothing.
- **`assert_grep`/`assert_not_grep` pass `--`.** Do not drop it; the front-matter delimiter is 35 hyphens and grep reads that as a long option.
- **Run the suite from a scratch copy that includes `tools/`** — five tests shell out to `./tools/migrate-categories.sh` and without it you get 18 unrelated failures. `make test` handles this.
- **Never build in the real repo tree.** Sandboxes only.
- Evidence in the spec is **GNU make 4.4.1 on Linux/ext4**. macOS/APFS and make 3.81 are unverified and stay marked so.

## File Structure

| File | Responsibility | Tasks |
| --- | --- | --- |
| `Makefile` | The program. `setup`'s recipe (Tasks 1–3), the three fragment-consuming rules and the new `posts:` rule (Task 4), the `.SECONDARY` comment block (Task 5) | 1,2,3,4,5 |
| `.gitignore` | Anchored ignore patterns | 1 |
| `tests/run.sh` | The suite. New tests appended near their topical neighbours, and each registered in the runner list at the bottom | 2,3,4 |
| `CLAUDE.md` | Docs for Claude. Five separate passages | 1,2,3,5 |
| `docs/backlog.md` | Standing findings | 6 |

---

### Task 1: Item 10 — give setup's scratch file a per-process name

**Files:**
- Modify: `Makefile:1426-1438` (the comment block above `config:`/`setup`), `Makefile:1465-1468` (the write/cmp/mv chain)
- Modify: `.gitignore:13`
- Modify: `CLAUDE.md:155`, `CLAUDE.md:341`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks depend on. Tasks 2 and 3 edit the same recipe but a different part of it (the probe loop, above this chain).

**Why:** Two `make setup` runs at once in one directory share the fixed name `config.mk.new`, so one can truncate the file the other is midway through writing, and the `mv` can promote a half-written `config.mk` — which every subsequent parse `-include`s. No test: reproducing it needs two racing shells and a window inside a `printf`.

- [ ] **Step 1: Read the current recipe chain**

Read `Makefile:1440-1471`. The relevant tail is:

```make
	{ echo "DATE_DIALECT := $$dialect"; \
	  echo "DETECTED_MARKDOWN := $$winner"; } > config.mk.new; \
	if cmp -s config.mk.new config.mk; then rm -f config.mk.new; \
	else mv config.mk.new config.mk; fi; \
```

- [ ] **Step 2: Introduce a per-process scratch name**

The recipe's single logical line begins at `@if date -v1d >/dev/null 2>&1; then dialect=bsd; \`. Add a `scratch` assignment as the new first element of that chain, so it is set in the same shell:

```make
	@scratch=config.mk.$$$$; \
	if date -v1d >/dev/null 2>&1; then dialect=bsd; \
```

`$$$$` in the Makefile becomes `$$` in the shell, which is the PID. Because the whole chain is one shell, `$$` is the same value at every use. Then replace all four occurrences of `config.mk.new` with `"$$scratch"`:

```make
	{ echo "DATE_DIALECT := $$dialect"; \
	  echo "DETECTED_MARKDOWN := $$winner"; } > "$$scratch"; \
	if cmp -s "$$scratch" config.mk; then rm -f "$$scratch"; \
	else mv "$$scratch" config.mk; fi; \
```

- [ ] **Step 3: Update the comment block above the rule**

`Makefile:1435-1438` currently says the rewrite "goes through config.mk.new and a cmp". Replace that paragraph with:

```make
# The rewrite goes through a per-process scratch file and a
# cmp, so a no-op setup leaves the mtime alone. config.mk is
# a prerequisite of %.staged, so an unconditional write would
# re-stage every post on every setup.
#
# The scratch name carries $$ -- the PID -- because two
# setups at once in one directory sharing one fixed name
# means one can truncate the file the other is midway
# through writing, and the mv can promote a half-written
# config.mk that every later parse -includes. mv is atomic,
# so the interleaving has to land inside the write.
#
# The cost: a setup aborted between the write and the mv
# leaks config.mk.<pid> indefinitely, where the old fixed
# name was overwritten by the next setup. It is gitignored
# by /config.mk.* and inert, and make clean does not remove
# it. Accepted rather than cured with a trap ... EXIT, which
# would grow an already-long single logical line for a file
# nothing reads.
```

- [ ] **Step 4: Widen the gitignore pattern**

`.gitignore:13` is `/config.mk.new`. Replace that single line with:

```
/config.mk.*
```

Do **not** delete the `/config.mk` line above it — `/config.mk.*` does not match `config.mk` itself. This is a one-for-one replacement, not a line saved.

- [ ] **Step 5: Verify by hand in a sandbox**

There is no test for this task; verify the sequential paths still work.

```bash
S=/tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/t1
rm -rf "$S" && mkdir -p "$S" && cd "$S"
cp /home/andre/Code/grampa/Makefile . && cp -R /home/andre/Code/grampa/.source .
make setup
echo "--- config.mk ---"; cat config.mk
echo "--- no scratch file left behind (expect no output) ---"; ls config.mk.* 2>/dev/null
before=$(stat -c %Y config.mk); make setup >/dev/null; after=$(stat -c %Y config.mk)
echo "no-op setup left mtime alone: $([ "$before" = "$after" ] && echo yes || echo NO)"
printf 'DATE_DIALECT := bsd\nDETECTED_MARKDOWN :=\n' > config.mk
make setup >/dev/null; echo "--- rewritten on content change ---"; cat config.mk
ls config.mk.* 2>/dev/null; echo "(no scratch leftover above)"
```

Expected: `config.mk` holds `DATE_DIALECT := gnu` and a `DETECTED_MARKDOWN` line; no `config.mk.*` scratch file at any point; the no-op mtime check prints `yes`; the stale-content run rewrites the dialect back to `gnu`.

- [ ] **Step 6: Verify the gitignore pattern**

```bash
S=/tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/t1git
rm -rf "$S" && mkdir -p "$S/docs" && cd "$S" && git init -q .
cp /home/andre/Code/grampa/.gitignore .
for f in config.mk config.mk.new config.mk.12345 docs/config.mk.12345; do
  printf '%-26s %s\n' "$f" "$(git check-ignore -v "$f" 2>/dev/null || echo 'NOT IGNORED')"
done
```

Expected: `config.mk` ignored via its own line; `config.mk.new` and `config.mk.12345` ignored via the `/config.mk.*` line; `docs/config.mk.12345` **NOT IGNORED** (the pattern stays anchored).

- [ ] **Step 7: Run the full suite**

Run: `cd /home/andre/Code/grampa && make test`
Expected: 335 passed, 0 failed. This task adds no tests; the point is that it breaks none.

- [ ] **Step 8: Update CLAUDE.md's two mentions**

`CLAUDE.md:155` (Layout section) and `CLAUDE.md:341` (Markdown detection section) both name `config.mk.new`. Change both to describe a per-process scratch file, and add to the Layout section's sentence that an aborted setup can leak `config.mk.<pid>`, which `/config.mk.*` ignores and `make clean` does not remove.

- [ ] **Step 9: Commit**

```bash
git add Makefile .gitignore CLAUDE.md
git commit -m "Give setup's scratch file a per-process name.

Two make setup runs at once in one directory shared the fixed name
config.mk.new, so one could truncate the file the other was midway through
writing and the mv could promote a half-written config.mk -- which every
later parse -includes. mv is atomic, so the interleaving had to land inside
the write, which is why this is backlog item 10 and not a bug anyone hit.

No test: reproducing it needs two racing shells and a window inside a
printf. Verified instead that every sequential path is intact -- fresh
setup, no-op setup leaving the mtime alone, and the content-differs rewrite
-- and that no scratch file survives any of them.

/config.mk.new in .gitignore becomes /config.mk.*, which is a one-for-one
replacement and not a line saved: it does not match config.mk itself, so
the line above it stays. Checked with git check-ignore, including that
docs/config.mk.12345 is still not ignored.

The cost, recorded rather than discovered later: a setup aborted between
the write and the mv now leaks config.mk.<pid> forever, where the old fixed
name was overwritten by the next setup. Inert and gitignored; make clean
does not remove it."
```

---

### Task 2: Item 9 — reject a candidate that smartens punctuation

**Files:**
- Modify: `Makefile:1457` (the probe file's content), `Makefile:1462` (add one check after it)
- Modify: `tests/run.sh` — two new tests near `test_stub_list_matches_the_candidate_table` (~line 599), each registered in the runner list at the bottom
- Modify: `CLAUDE.md:333-336`

**Interfaces:**
- Consumes: nothing from Task 1 (different part of the recipe).
- Produces: the `--` check that Task 3 attaches a `smartens punctuation` message to. Task 3 edits the exact line this task adds.

**Why:** The probe checks exit status, raw-HTML survival and fragment-vs-document. It says nothing about typography, so a candidate whose smartypants flag is wrong passes detection and quietly rewrites the author's quotes and dashes.

**The critical design point:** check the **dash only**, never the quote. `cmark`, `cmark-gfm` and `md2html` HTML-escape a `"` to `&quot;` in text content — that is escaping, not smartening, and renders identically, but a literal `"` assertion cannot tell the difference and would skip all three good processors. The dash is intact in all seven correctly-flagged candidates and mangled in all three deliberately-wrong-flagged ones. The spec carries both measured tables.

- [ ] **Step 1: Write the first failing test**

Add to `tests/run.sh`, after `test_stub_list_matches_the_candidate_table`:

```bash
#
# A candidate whose smartypants flag is wrong renders the
# author's -- as an en dash. The probe used to check only
# exit status, the surviving <i>, and fragment-vs-document,
# so such a tool won detection and quietly rewrote every
# post's punctuation.
#
# The stub fails ONLY the punctuation check -- it exits 0,
# keeps the <i>, and emits no document -- so this test
# cannot pass for an unrelated reason.
#
test_probe_rejects_a_smartening_candidate() {
	sandbox probe_smarty
	path_stub lowdown 'sed "s/--/\&ndash;/g" "$f"'
	make setup >/dev/null 2>&1
	assert_not_grep config.mk "DETECTED_MARKDOWN := lowdown"
	assert_grep config.mk "DETECTED_MARKDOWN :="
}
```

Register it in the runner list at the bottom of the file, next to the other probe tests.

- [ ] **Step 2: Run it and watch it fail**

Run: `cd /home/andre/Code/grampa && make test 2>&1 | grep -A3 probe_rejects`
Expected: FAIL — `did NOT expect 'DETECTED_MARKDOWN := lowdown' in config.mk`. The unfixed probe accepts the smartening stub, because it exits 0, keeps the `<i>`, and returns a fragment.

- [ ] **Step 3: Write the second test — the false-positive tripwire**

```bash
#
# A TRIPWIRE, not a live guard, and it cannot fail today.
#
# cmark, cmark-gfm and md2html all HTML-escape a " in text
# content to &quot;. That is escaping, not smartening -- it
# renders identically -- but a literal " assertion cannot
# tell the two apart and would skip all three. The probe
# input therefore carries no quote at all, so this stub's
# escaping never fires and the test passes trivially.
#
# It exists to bite the next person who adds a quote to the
# probe input and a literal-" check alongside it. The stub
# escapes CONDITIONALLY for that reason: one that emitted
# &quot; unconditionally would test nothing in either world.
#
test_probe_accepts_escaped_quotes() {
	sandbox probe_escaped_quotes
	path_stub lowdown 'sed "s/\"/\&quot;/g" "$f"'
	make setup >/dev/null 2>&1
	assert_grep config.mk "DETECTED_MARKDOWN := lowdown"
}
```

Register it in the runner list.

- [ ] **Step 4: Run it and confirm it passes now**

Run: `cd /home/andre/Code/grampa && make test 2>&1 | grep -A3 escaped_quotes`
Expected: PASS, both before and after the fix. Its banner says so; that is deliberate, not an oversight.

- [ ] **Step 5: Extend the probe input**

`Makefile:1457`:

```make
		probefile=$$(mktemp); printf 'x <i>y</i>\n' > "$$probefile"; \
```

becomes:

```make
		probefile=$$(mktemp); printf 'x <i>y</i> -- z\n' > "$$probefile"; \
```

No quote character in the input — asserting nothing about it means it earns no place there.

- [ ] **Step 6: Add the dash check**

After the existing `<i>` check at `Makefile:1462`, add:

```make
			case "$$out" in *'--'*) ;; *) continue;; esac; \
```

Keep the `<i>` and whole-document checks. The dash check does **not** subsume them: `cmark` without `--unsafe` renders the input as `<p>x <!-- raw HTML omitted -->y<!-- raw HTML omitted --> -- z</p>`, which *contains* `--`, so the dash check alone would accept a candidate that eats raw HTML. The `<i>` check is what rejects it.

- [ ] **Step 7: Run both tests and the full suite**

Run: `cd /home/andre/Code/grampa && make test`
Expected: 337 passed, 0 failed. Both new tests pass.

- [ ] **Step 8: Confirm the check does not reject a real processor**

The suite hides real tools, so verify separately against the ones installed on this host:

```bash
cd /tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad
printf 'x <i>y</i> -- z\n' > probe.md
while IFS='|' read -r probe cmd; do
  [ -n "$probe" ] || continue
  case "$probe" in */*) [ -x "$probe" ] || continue;; *) command -v "$probe" >/dev/null 2>&1 || continue;; esac
  printf '%-14s %s\n' "$probe" "$($cmd probe.md 2>&1 </dev/null | head -1)"
done < <(sed -n '/^define MARKDOWN_CANDIDATES/,/^endef/p' /home/andre/Code/grampa/Makefile | sed '1d;$d')
```

Expected: every installed candidate outputs `<p>x <i>y</i> -- z</p>` — dash and `<i>` both intact. If any loses the dash, stop: the check would skip a good processor and the plan needs revisiting.

- [ ] **Step 9: Update CLAUDE.md's Markdown detection section**

`CLAUDE.md:333-336` describes the probe as running "against a freshly written `x <i>y</i>`" and requiring exit 0, a kept `<i>`, and no whole document. Update the string to `x <i>y</i> -- z`, add the fourth requirement (the `--` survives), and state why it is the dash and not a quote — naming the three processors that escape `"` to `&quot;`. Also record the residual: a processor that smartens quotes but not dashes would pass, which no row in the table can reach, and note that the Python-Markdown claim behind that is from documentation rather than observed.

- [ ] **Step 10: Commit**

```bash
git add Makefile tests/run.sh CLAUDE.md
git commit -m "Reject a markdown candidate that smartens punctuation.

The probe checked exit status, raw-HTML survival and fragment-vs-document.
It said nothing about typography, so a candidate whose smartypants flag is
wrong passed detection and quietly rewrote the author's quotes and dashes.
multimarkdown --snippet was the named suspect: --snippet controls
document-vs-fragment and says nothing about typography.

The obvious form of this check rejects three good processors. cmark,
cmark-gfm and md2html HTML-escape a double quote in text content to &quot;
-- escaping, not smartening, and it renders identically -- so asserting a
literal \" survives would skip all three. Measured on this host against
every installed candidate with the table's exact argv.

The dash alone discriminates perfectly: intact in all seven correctly
flagged candidates, mangled in all three deliberately wrong-flagged ones
(&#8211;, an en dash, and &ndash;). So the probe input gains ' -- z' and
one case clause, and carries no quote at all -- asserting nothing about it
means it earns no place there.

The <i> check stays and is load-bearing rather than tidy: cmark without
--unsafe emits <!-- raw HTML omitted -->, which contains a dash, so the
new check alone would accept a candidate that eats raw HTML.

test_probe_rejects_a_smartening_candidate watched failing first, with a
stub that fails only the punctuation check so it cannot pass for an
unrelated reason. test_probe_accepts_escaped_quotes is a tripwire that
cannot fail today and says so in its banner -- it exists to bite whoever
next adds a quote to the probe input and a literal-\" check beside it."
```

---

### Task 3: Say why a found candidate was rejected

**Files:**
- Modify: `Makefile:1460-1463` (four `continue`s inside the probe loop)
- Modify: `tests/run.sh` — one new test beside Task 2's, registered in the runner list
- Modify: `CLAUDE.md` — the `--unsafe`-family gotcha

**Interfaces:**
- Consumes: the `--` check added by Task 2 (`Makefile:1462`-ish). This task attaches a message to it, so Task 2 must land first.
- Produces: the stderr line format `grampa: setup: <probe>: <reason>`, which Task 3's test asserts.

**Why:** If you have `lowdown` installed but a build whose flags the probe does not accept, setup skips it silently, falls through, and reports only the winner. The build notice then names a processor you did not expect, with no hint why. Task 2 makes this *more* likely, not less.

- [ ] **Step 1: Write the failing test**

```bash
#
# setup used to fall through a rejected candidate in
# silence, so the build notice named a processor the user
# did not expect and gave no hint why. The punctuation check
# makes that more likely, not less.
#
# The prefix is deliberately NOT "grampa: markdown:" --
# test_clean_and_setup_print_no_notice asserts that string
# is absent from setup's output, because it belongs to the
# build notice and setup must stay quiet about it.
#
test_setup_names_a_rejected_candidate() {
	sandbox setup_reject
	path_stub lowdown 'sed "s/--/\&ndash;/g" "$f"'
	BUILD_OUT=$(make setup 2>&1)
	assert_out_grep "grampa: setup: lowdown: smartens punctuation"
}
```

Register it in the runner list.

- [ ] **Step 2: Run it and watch it fail**

Run: `cd /home/andre/Code/grampa && make test 2>&1 | grep -A3 names_a_rejected`
Expected: FAIL — `expected 'grampa: setup: lowdown: smartens punctuation' in make output`, with the captured output showing only the two `Configured …` lines.

- [ ] **Step 3: Attach a reason to each rejection**

In the probe loop, replace the four post-discovery `continue`s. Before:

```make
			[ $$rc -eq 0 ] || continue; \
			case "$$out" in *'<html'*|*'<HTML'*|*DOCTYPE*) continue;; esac; \
			case "$$out" in *'<i>'*) ;; *) continue;; esac; \
			case "$$out" in *'--'*) ;; *) continue;; esac; \
```

After:

```make
			[ $$rc -eq 0 ] || { echo "grampa: setup: $$probe: not runnable" >&2; continue; }; \
			case "$$out" in *'<html'*|*'<HTML'*|*DOCTYPE*) echo "grampa: setup: $$probe: emits a whole document" >&2; continue;; esac; \
			case "$$out" in *'<i>'*) ;; *) echo "grampa: setup: $$probe: drops raw HTML" >&2; continue;; esac; \
			case "$$out" in *'--'*) ;; *) echo "grampa: setup: $$probe: smartens punctuation" >&2; continue;; esac; \
```

Three constraints, all load-bearing:

1. **stderr, not stdout.** The loop runs inside `winner=$$(… )`; anything on stdout is captured as the winner and written into `config.mk`.
2. **The prefix must not be `grampa: markdown:`** — `test_clean_and_setup_print_no_notice` (`tests/run.sh:669`) asserts that string is absent from `make setup` output.
3. **Leave the `command -v` / `[ -x ]` misses silent.** Those `continue`s are in the `case "$$probe"` block above and must not gain a message, or a machine with one processor prints eleven lines of noise on every setup.

- [ ] **Step 4: Run the test and the full suite**

Run: `cd /home/andre/Code/grampa && make test`
Expected: 338 passed, 0 failed. In particular `test_clean_and_setup_print_no_notice` still passes — that is the constraint the prefix exists to satisfy.

- [ ] **Step 5: Confirm stderr separation under `-s` and `-j`**

```bash
S=/tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/t3
rm -rf "$S" && mkdir -p "$S/bin" && cd "$S"
cp /home/andre/Code/grampa/Makefile . && cp -R /home/andre/Code/grampa/.source .
for t in lowdown cmark cmark-gfm md2html comrak multimarkdown markdown smu markdown_py markdown-it pandoc; do
  printf '#!/bin/sh\nexit 1\n' > "bin/$t"; chmod +x "bin/$t"
done
printf '#!/bin/sh\nfor f; do :; done\nsed "s/--/\\&ndash;/g" "$f"\n' > bin/lowdown; chmod +x bin/lowdown
export PATH="$PWD/bin:$PATH"
for goal in "setup" "-s setup" "-j4 setup"; do
  echo "=== make $goal ==="
  echo "--- stdout only ---"; make $goal 2>/dev/null
  echo "--- stderr only ---"; make $goal 2>&1 >/dev/null | head -3
done
echo "--- config.mk winner uncorrupted ---"; cat config.mk
```

Expected: the `grampa: setup:` lines appear only in the stderr capture, never in the stdout capture, under all three invocations; `config.mk`'s `DETECTED_MARKDOWN` is empty (every stub exits 1 and lowdown is rejected) and contains no diagnostic text.

- [ ] **Step 6: Update CLAUDE.md's `--unsafe`-family gotcha**

Add to that bullet that a found-but-rejected candidate is now named on stderr with its reason, that not-found candidates stay silent so a one-processor machine does not print eleven lines, and that the prefix is `grampa: setup:` rather than `grampa: markdown:` because the latter belongs to the build notice and a test asserts its absence from setup.

Also record the cosmetic consequence for the suite: `hide_markdown_tools` installs executable exit-1 stubs for all eleven candidates, so in every sandbox all eleven are *found*, probed, and rejected — each test emits up to eleven `not runnable` lines on stderr. Harmless (`sandbox()` redirects them; `markdown_stub` shows output only on failure) and worth knowing before someone reads it as a regression.

- [ ] **Step 7: Commit**

```bash
git add Makefile tests/run.sh CLAUDE.md
git commit -m "Say why setup rejected a candidate it found.

With lowdown installed but a build whose flags the probe does not accept,
setup skipped it, fell through in silence, and reported only the winner --
so the build notice named a processor the user did not expect and gave no
hint why. The punctuation check added in the previous commit makes that
outcome more likely, not less.

Each of the four post-discovery rejections now writes one line to stderr
naming the candidate and the reason: not runnable, emits a whole document,
drops raw HTML, smartens punctuation.

Three constraints, all load-bearing. stderr and not stdout, because the
loop runs inside winner=\$(...) and anything on stdout is captured as the
winner and written into config.mk. The prefix is 'grampa: setup:' and not
'grampa: markdown:', because test_clean_and_setup_print_no_notice asserts
the latter is absent from setup's output -- it belongs to the build notice.
And the command -v / [ -x ] misses stay silent, or a machine with one
processor prints eleven lines on every setup.

Verified the stdout/stderr split holds under make setup, make -s setup and
make -j4 setup, with the winner uncorrupted in all three.

One cosmetic consequence in the suite, recorded so nobody reads it as a
regression: hide_markdown_tools installs exit-1 stubs for all eleven
candidates, so every sandbox now emits up to eleven 'not runnable' lines on
stderr. sandbox() redirects them and markdown_stub shows output only on
failure, where they are arguably useful."
```

---

### Task 4: Item 8 — make deletion heal the index, the category page and the feed

**Files:**
- Modify: `Makefile:1198` (`$(BUILD_DIR)category/%.html`), `Makefile:1262` (`$(WORK_DIR)index.tmp`), `Makefile:1401` (`$(WORK_DIR)rss.tmp`)
- Modify: `Makefile:1423` — add a `posts:` rule beside the `config:` rule
- Modify: `tests/run.sh` — four new tests near `test_deleting_a_post_heals_the_feed` (~line 1393), each registered in the runner list

**Interfaces:**
- Consumes: nothing from Tasks 1–3 (different rules entirely).
- Produces: the `posts` prerequisite and the `posts:` rule that Task 5's documentation describes.

**Why:** All three targets take the current window (or the current category's fragments) as *prerequisites*, so make asks "is any prerequisite newer than the target?" — a question that cannot notice the *set* changed. The feed heals only when the incoming `.rssitem` happens to be absent. The index and category page **never** heal, because every post has a `.tmp` (every post has a page), so the incoming fragment is always already on disk. A directory's mtime updates on entry creation and removal, which records exactly the condition needed.

- [ ] **Step 1: Write the index test and watch it fail**

Add to `tests/run.sh`, before `test_deleting_a_post_heals_the_feed`:

```bash
#
# Deleting a post used to leave it on the FRONT PAGE, which
# is worse than the feed case beside it and was undocumented.
#
# index.tmp is a cat of the newest-ten .tmp files, taken as
# prerequisites -- so make asks whether any is newer, never
# whether the set changed. Every post has a .tmp because
# every post has a page, so the incoming fragment is always
# already on disk and older, and index.tmp never re-cats.
# That is why the feed sometimes healed and the index never
# did.
#
test_deleting_a_post_heals_the_index() {
	sandbox delete_index
	local i
	for i in 1 2 3; do
		add_post "2026-01-0$i-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build || return
	assert_grep build/index.html "Post 3"
	# Whole-second mtime resolution: posts/ must come out
	# strictly newer than index.tmp or nothing re-cats.
	sleep 1
	rm posts/2026-01-03-home_post-3.txt
	build || return
	assert_not_grep build/index.html "Post 3"
	assert_grep build/index.html "Post 2"
}
```

Register it, then run: `cd /home/andre/Code/grampa && make test 2>&1 | grep -A4 heals_the_index`
Expected: FAIL — `did NOT expect 'Post 3' in build/index.html`.

- [ ] **Step 2: Write the category test and watch it fail**

```bash
#
# Same mechanism as the index, one target over. A category
# page is an awk pass over every fragment in its category,
# taken as prerequisites -- and it is not even windowed, so
# a deleted post stays on it forever.
#
test_deleting_a_post_heals_the_category_page() {
	sandbox delete_category
	local i
	for i in 1 2 3; do
		add_post "2026-01-0$i-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build || return
	assert_grep build/category/home.html "Post 3"
	sleep 1
	rm posts/2026-01-03-home_post-3.txt
	build || return
	assert_not_grep build/category/home.html "Post 3"
	assert_grep build/category/home.html "Post 2"
}
```

Register it and run it. Expected: FAIL — `did NOT expect 'Post 3' in build/category/home.html`.

- [ ] **Step 3: Write the feed test that covers the case the existing one misses**

```bash
#
# test_deleting_a_post_heals_the_feed builds all twelve
# posts at once, which is the ONE corpus shape where the
# heal already worked -- the eleventh-newest post has no
# .rssitem, so deletion forces one to be built, which makes
# rss.tmp out of date. That test passes against the unfixed
# Makefile and covers none of the bug.
#
# A blog grown a post at a time is the normal shape, and
# there every out-of-window post already has its fragment.
# Nothing rebuilds and the deleted post's <item> survives.
#
test_deleting_a_post_heals_the_feed_after_incremental_growth() {
	sandbox feed_delete_incremental
	printf 'name=My Weblog\nurl=https://example.com\n' > config
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11; do
		add_post "2026-01-$(printf '%02d' $i)-home_post-$i.txt" <<EOF
title: Post $i
-----------------------------------
<p>Body $i.</p>
EOF
	done
	build || return
	sleep 1
	add_post "2026-01-12-home_post-12.txt" <<EOF
title: Post 12
-----------------------------------
<p>Body 12.</p>
EOF
	build || return
	assert_grep build/rss.xml "<title>Post 12</title>"
	sleep 1
	rm posts/2026-01-12-home_post-12.txt
	build || return
	assert_eq "items in feed after delete" "10" "$(grep -c '<item>' build/rss.xml | tr -d ' ')"
	assert_not_grep build/rss.xml "<title>Post 12</title>"
	assert_grep build/rss.xml "<title>Post 2</title>"
}
```

Register it and run it. Expected: FAIL — `did NOT expect '<title>Post 12</title>' in build/rss.xml`.

- [ ] **Step 4: Write the missing-directory test**

This one guards the `posts:` rule, and it fails with a *bare* prerequisite rather than without the change — so write it now and it will go red in Step 6 if the rule is forgotten.

```bash
#
# A tree with no posts/ at all builds an empty site at exit
# 0, and must keep doing so. Adding posts as a prerequisite
# of index.tmp/rss.tmp/category pages would otherwise make
# make die on its own "No rule to make target 'posts'", so
# the posts: rule exists to recreate it.
#
test_build_works_without_a_posts_directory() {
	sandbox no_posts_dir
	rm -rf posts
	build || return
	assert_file build/index.html
	assert_eq "posts/ recreated" "yes" "$([ -d posts ] && echo yes || echo no)"
}
```

Register it and run it. Expected: PASS today (nothing references `posts` yet). It is a regression guard for Step 6, not a red-first test — say so when reporting.

- [ ] **Step 5: Add `posts` as a prerequisite of the three consumers**

`Makefile:1198`:

```make
$(BUILD_DIR)category/%.html: $$(call tmp_files_in_category,$$*) templates/base.txt config posts
```

`Makefile:1262`:

```make
$(WORK_DIR)index.tmp: $(RECENT_FILES) posts
```

`Makefile:1401`:

```make
$(WORK_DIR)rss.tmp: $(RECENT_ITEMS) posts
```

Add a comment block above each in the existing style, explaining that `posts` is there so a *changed set* — not just a changed file — makes the target out of date, since a directory's mtime updates on entry creation and removal.

- [ ] **Step 6: Add the `posts:` rule**

Beside the `config:` rule at `Makefile:1423`:

```make
#
# posts/ is a prerequisite of index.tmp, rss.tmp and every
# category page, so that deleting a post makes them out of
# date -- a directory's mtime moves when an entry is created
# or removed, which is exactly "the set of posts changed".
#
# It needs a rule because a bare prerequisite would make a
# tree with no posts/ die on make's own "No rule to make
# target 'posts'" instead of building an empty site at exit
# 0, which is what it did before and must keep doing. With
# the directory present and no prerequisites of its own,
# make judges it up to date and never runs this recipe, so
# it costs nothing on a normal build.
#
posts:
	@mkdir -p posts
```

- [ ] **Step 7: Run all four tests and the full suite**

Run: `cd /home/andre/Code/grampa && make test`
Expected: 342 passed, 0 failed. Confirm specifically that `test_deleting_a_post_heals_the_feed` — the pre-existing one — still passes unchanged.

- [ ] **Step 8: Verify the properties the tests do not cover**

```bash
S=/tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/t4
rm -rf "$S" && mkdir -p "$S" && cd "$S"
cp /home/andre/Code/grampa/Makefile . && cp -R /home/andre/Code/grampa/.source .
make setup >/dev/null 2>&1; printf 'name=T\nurl=https://example.com\n' > config
for i in 1 2 3; do printf 'title: Post %s\n-----------------------------------\n<p>b%s</p>\n' $i $i > "posts/2026-01-0$i-home_p$i.txt"; done
make >/dev/null 2>&1
echo "--- posts: recipe must NOT fire when the directory exists ---"; make posts
echo "--- no-op rebuild must stay quiet ---"; make 2>&1 | tail -2
echo "--- editing a post in place must not bump posts/ mtime ---"
before=$(stat -c %Y posts); printf '<p>more</p>\n' >> posts/2026-01-01-home_p1.txt; after=$(stat -c %Y posts)
echo "mtime unchanged by in-place append: $([ "$before" = "$after" ] && echo yes || echo NO)"
echo "--- clean rebuild and -j8 ---"; make clean >/dev/null && make -j8 >/dev/null 2>&1 && echo "-j8 exit 0"
echo "--- deleting the last post empties index and feed at exit 0 ---"
rm posts/*.txt; sleep 1; make >/dev/null 2>&1 && echo "exit 0"; grep -c '<item>' build/rss.xml
```

Expected: `make posts` prints `make: 'posts' is up to date.` and runs no recipe; the no-op rebuild prints only `Build completed.` / `All done.`; the in-place append leaves the directory mtime unchanged (so ordinary edits do not over-trigger); `-j8` from clean exits 0; deleting every post leaves 0 `<item>`s at exit 0.

- [ ] **Step 9: Commit**

```bash
git add Makefile tests/run.sh
git commit -m "Make deleting a post heal the index, category page and feed.

Backlog item 8 was filed as a feed bug. It is three consumers, and the feed
is the least bad of them.

index.tmp, rss.tmp and every category page take the current window -- or
the current category's fragments -- as prerequisites, so make asks whether
any prerequisite is newer, never whether the set changed. The feed heals
only when the incoming .rssitem happens to be absent, which is the
fresh-clone corner. The index and category page NEVER heal, because every
post has a .tmp (every post has a page), so the incoming fragment is always
already on disk and older. Reproduced both ways before writing anything: in
an all-at-once corpus the feed healed while the index and category page
still carried the deleted post; in a grown-a-post-at-a-time corpus all
three went stale.

So the front page went on linking to a post the author deleted, which
CLAUDE.md's 'deleting a post leaves its HTML behind' gotcha undersells --
the orphaned page is the part nobody can reach.

The fix is posts/ itself as a prerequisite of all three. Removing a file
updates its parent directory's mtime, so a directory mtime records exactly
'the set of posts changed'. Adding, deleting and renaming all bump it;
editing a post's contents does not, and does not change the set either --
verified, an in-place append leaves the mtime alone. Chosen over the stamp
file the backlog proposed, which is exact where this is merely sufficient
but costs a new work/ file, a new rule, a phony FORCE, and a recipe that
runs every build, against three words.

One behaviour change and its cure: a bare prerequisite made a tree with no
posts/ die on make's own 'No rule to make target', where it used to build
an empty site at exit 0. The posts: rule restores that exactly -- with the
directory present and no prerequisites of its own, make judges it up to
date and never runs the recipe.

Three tests watched failing first, each on the artifact rather than the
exit status. The fourth, test_build_works_without_a_posts_directory, is a
regression guard for the posts: rule and passes before the change; it is
labelled as such rather than claimed as red-first.

test_deleting_a_post_heals_the_feed_after_incremental_growth is the one
that matters: the existing test_deleting_a_post_heals_the_feed builds all
twelve posts at once, which is the single corpus shape where the heal
already worked, and it passes against the unfixed Makefile."
```

---

### Task 5: Correct every claim Task 4 falsified

**Files:**
- Modify: `Makefile:169-185` (the `.SECONDARY` comment block)
- Modify: `CLAUDE.md:353` (build-pipeline, the `.rssitem` paragraph), `CLAUDE.md:373` ("prerequisites are exact"), the feed self-heal gotcha, the "Deleting a post leaves its HTML behind" gotcha

**Interfaces:**
- Consumes: Task 4's `posts` prerequisite and `posts:` rule. This task is prose only and must land after Task 4.
- Produces: nothing.

**Why:** Four passages assert things that Task 4 makes false. This repo's stated identity is documentation checkable against the code, and its backlog's own recurring lesson is a confident, formerly-true, empirically-false claim. Leaving them is the defect this project cares most about.

- [ ] **Step 1: Re-run the `.SECONDARY` mutation to confirm the spec's finding**

The spec records that after Task 4 the mutation is harmless. Confirm it rather than trusting it:

```bash
S=/tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/t5
rm -rf "$S" && mkdir -p "$S" && cd "$S"
cp /home/andre/Code/grampa/Makefile . && cp -R /home/andre/Code/grampa/.source .
sed -i 's|^\.SECONDARY: \$(TMP_FILES) \$(STAGED_FILES)|.SECONDARY: $(TMP_FILES) $(STAGED_FILES) $(RSSITEM_FILES)|' Makefile
grep -n '^\.SECONDARY' Makefile
make setup >/dev/null 2>&1; printf 'name=T\nurl=https://example.com\n' > config
for i in 1 2 3 4 5 6 7 8 9 10 11; do printf 'title: Post %s\n-----------------------------------\n<p>b%s</p>\n' $i $i > "posts/2026-01-$(printf '%02d' $i)-home_p$i.txt"; done
make >/dev/null 2>&1; sleep 1
printf 'title: Post 12\n-----------------------------------\n<p>b12</p>\n' > posts/2026-01-12-home_p12.txt
make >/dev/null 2>&1; sleep 1
rm posts/2026-01-12-home_p12.txt; make >/dev/null 2>&1
echo -n "items: "; grep -c '<item>' build/rss.xml
echo -n "Post 12 still present (want 0): "; grep -c '<title>Post 12</title>' build/rss.xml
echo -n "Post 2 pulled in (want 1): "; grep -c '<title>Post 2</title>' build/rss.xml
echo -n ".rssitem on disk: "; ls work/*.rssitem | wc -l
```

Expected: 10 items, Post 12 absent, Post 2 present, 11 `.rssitem` files. That is the mutation being *harmless*. If it instead reproduces the old breakage, stop — the comment block's existing claim is still true and this task's premise is wrong.

- [ ] **Step 2: Also confirm the existing test no longer distinguishes the mutation**

```bash
cd /home/andre/Code/grampa && cp Makefile /tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/Makefile.orig
sed -i 's|^\.SECONDARY: \$(TMP_FILES) \$(STAGED_FILES)|.SECONDARY: $(TMP_FILES) $(STAGED_FILES) $(RSSITEM_FILES)|' Makefile
make test 2>&1 | tail -5
cp /tmp/claude-1000/-home-andre-Code-grampa/eea74005-4867-4cfb-99f4-04c1ee64d486/scratchpad/Makefile.orig Makefile
git diff --stat Makefile
```

Expected: the suite passes in full **with** the mutation applied, including `test_deleting_a_post_heals_the_feed`. Then the restore leaves `git diff --stat` empty. That is the evidence for deleting the comment's citation of that test as its guard.

- [ ] **Step 3: Rewrite the `.SECONDARY` comment block**

`Makefile:169-185` currently says listing `RSSITEM_FILES` "would be actively harmful", that this was "verified empirically both ways", and names `test_deleting_a_post_heals_the_feed` as the guard. All three are now false. Replace with a block saying:

- `.rssitem` files still do not need `.SECONDARY`: they are explicit prerequisites of the explicit target `work/rss.tmp`, and make only reaps files it never sees mentioned.
- Listing them is now **unnecessary rather than harmful**. It used to suppress the feed's self-heal, because the heal depended on the incoming `.rssitem` being *missing*. Since `posts` became a prerequisite of `rss.tmp`, the target is out of date on any set change and make builds its missing secondary prerequisites anyway.
- Verified by mutation on GNU make 4.4.1, and flag that `.SECONDARY` and intermediate-file semantics are where 3.81 and 4.x have historically differed most, so this is the claim to re-check if that floor is still real.

- [ ] **Step 4: Rewrite CLAUDE.md's duplicate of the same claim**

`CLAUDE.md:353` carries "listing them in `.SECONDARY` anyway would be actively harmful — see the comment above `.SECONDARY` in the Makefile". Give it the same correction. The spec's first draft named only the Makefile comment and missed this copy; Fable's review found it.

- [ ] **Step 5: Correct the category-page "exact prerequisites" claim**

`CLAUDE.md:373` says "Its prerequisites are exact, because `CATEGORY_SLUGS` is derived from filenames at parse time." With `posts` a prerequisite of every category page that is no longer true — deleting a `home` post rebuilds `build/category/work.html` too. Reword to say the category fragments are still exact, and that `posts` is an additional, deliberately coarse prerequisite that over-triggers across categories so that a *deleted* post leaves the page.

- [ ] **Step 6: Rewrite the feed self-heal gotcha**

That gotcha currently spends a long paragraph on the narrow condition under which the heal fires, names the incremental-history case as where it does not, and points at `make clean && make`. All of that is now obsolete: deletion heals the feed in every case, including the ten-or-fewer-posts case the gotcha says never heals. Replace it with a short statement of the new behaviour and the mechanism (`posts` is a prerequisite; a directory mtime records a changed set).

- [ ] **Step 7: Shrink the "Deleting a post leaves its HTML behind" gotcha**

It should now say only what remains true: the deleted post's **own page** lingers in `build/`, because nothing knows the old page existed — an untracked *output*, which is the same shape as the deleted-category gotcha beside it. Add that the index, its category page and the feed all now drop it, so nothing links to the orphan, and that `make clean` is still what removes the file itself.

- [ ] **Step 8: Run the full suite**

Run: `cd /home/andre/Code/grampa && make test`
Expected: 342 passed, 0 failed. This task is prose only; it must change nothing.

- [ ] **Step 9: Commit**

```bash
git add Makefile CLAUDE.md
git commit -m "Correct every claim the posts prerequisite falsified.

Four passages asserted things that are no longer true. This repo's stated
identity is documentation checkable against the code, and its backlog's own
recurring lesson is the confident, formerly-true, empirically-false claim.

The .SECONDARY comment block said listing RSSITEM_FILES would be 'actively
harmful', that this was 'verified empirically both ways', and named
test_deleting_a_post_heals_the_feed as the guard. All three are now false.
Re-ran the mutation to be sure rather than reasoning about it: with
\$(RSSITEM_FILES) appended to .SECONDARY on top of the fix, both corpus
shapes heal completely -- ten items, Post 2 pulled in, Post 12 gone, and
the newly-in-window .rssitem built. The full suite passes WITH the mutation
applied, which is what retires the citation. The mechanism: posts makes
rss.tmp out of date on any set change, and once a target must be remade
make builds its missing secondary prerequisites anyway.

So it becomes unnecessary rather than harmful -- .rssitem files are
explicit prerequisites of an explicit target and are never reaped either
way. Flagged that this is a make 4.4.1 result and that .SECONDARY is
exactly where 3.81 and 4.x have historically differed.

CLAUDE.md carried a second copy of the 'actively harmful' claim in its
build-pipeline section, which the spec's first draft missed.

CLAUDE.md's 'Its prerequisites are exact' for category pages stops being
true: deleting a home post now rebuilds build/category/work.html too.

The feed self-heal gotcha loses its narrow condition entirely -- deletion
heals in every case now, including the ten-or-fewer-posts case that gotcha
says never heals -- and the 'deleting a post leaves its HTML behind' gotcha
shrinks to what is genuinely unfixable: the orphaned page itself, an
untracked output nothing can know about. Nothing links to it any more."
```

---

### Task 6: Close the backlog entries and run the whole-branch review

**Files:**
- Modify: `docs/backlog.md`

**Interfaces:**
- Consumes: Tasks 1–5, all landed.
- Produces: the branch, ready to merge.

- [ ] **Step 1: Run the full suite one more time from a clean tree**

Run: `cd /home/andre/Code/grampa && make clean && make test`
Expected: 342 passed, 0 failed. Record the exact number; the backlog entries cite it.

- [ ] **Step 2: Mark items 8, 9, 10 and the Minor bullet done**

In `docs/backlog.md`, following the file's established style — the entry is rewritten with what was actually found, the original finding is kept below under "Original finding follows", and anything the entry got wrong about itself is stated plainly:

- **Item 8** → DONE, and record that the entry was **two consumers short**. It was filed as a feed bug; the index and category page never healed at all, for a structural reason the entry did not have (every post has a `.tmp` because every post has a page). Record that the stamp file it proposed was not needed — a directory mtime is the same signal for three words — and that the behaviour half was the last of the two "open questions" the file's summary named.
- **Item 9** → DONE by the probe extension, which the file itself ranked as the better half. Record the false positive the obvious form would have caused (`cmark`/`cmark-gfm`/`md2html` escaping `"` to `&quot;`), since the entry predicted the *risk* of an over-strict probe without knowing it was already realised. The three unrun rows stay unrun and the item's other half — installing them to correct the table — stays open and unranked.
- **Item 10** → DONE, one line as predicted, with the leaked-scratch-file cost recorded.
- **The "setup is quiet about a rejected candidate" Minor bullet** → DONE, with the prefix constraint noted.

- [ ] **Step 3: Update the summary sections**

The file's "If only three get done" section ends by saying the list "has stopped being a pile of small things and become two open questions" — ranked item 2 (the feed self-heal) and ranked item 6 (the single-pass `fill()`). One of those two is now closed. Update that paragraph and the ranked list so a reader is not told there are two.

Also update the "What has been verified by running it" section with a subsection for this branch, in the style of the existing "Branch review, 2026-08-08" one: what was executed, and — separately and plainly — what was not. The not-verified list is make 3.81, macOS/APFS directory-mtime semantics, the concurrent-setup interleaving itself, and the dash behaviour of the four candidates not installed on any review host (`smu`, `comrak`, `multimarkdown`, `markdown-it`).

- [ ] **Step 4: Commit**

```bash
git add docs/backlog.md
git commit -m "Backlog: close items 8, 9, 10 and the rejected-candidate bullet.

Item 8's entry was two consumers short. It was filed as a feed bug; the
index and the category page never healed at all, for a structural reason
the entry did not have. The stamp file it proposed was not needed.

Item 9's entry predicted the risk of an over-strict probe without knowing
it was already realised: the obvious form of the check rejects cmark,
cmark-gfm and md2html, which escape a double quote to &quot;.

That leaves ranked item 6, the single-pass fill(), as the only open
question -- the summary said there were two."
```

- [ ] **Step 5: Dispatch the whole-branch Fable review**

This is the fourth CLAUDE.md checkpoint. Dispatch with the `Agent` tool using `model: "fable"`. Give it: the branch diff (`git diff main...HEAD`), the spec, the plan, and the framing that this is a Makefile — pattern-rule ambiguity, `=` vs `:=` timing, parse-time vs recipe-time, `.SECONDARY` and intermediate reaping, shell quoting, `$$` escaping. Tell it what is already settled with the user (the four decisions in the spec's "settled" list) so it does not relitigate. Tell it to prove claims by running commands in scratch sandboxes that include `tools/`, never in the real tree. Ask for blocking / recommended / optional plus a list of what it actively verified.

- [ ] **Step 6: Fold the review in, then report**

Address every finding or argue it down in writing. Then report to the user: what landed, the final suite count, and the three things that remain unverified by any automated run (make 3.81, macOS/APFS, the four uninstalled candidates).

---

## Self-Review

**Spec coverage:** §1 (item 8 mechanism) → Task 4. §1's `.SECONDARY` subsection → Task 5. §2 (punctuation probe) → Task 2. §3 (rejection notice) → Task 3. §4 (item 10) → Task 1. Spec's Tests table → Tasks 2, 3, 4 (all seven tests placed). Spec's Documentation section → Tasks 1, 2, 3, 5 (all six passages placed: `CLAUDE.md:155`, `:333`, `:341`, `:353`, `:373`, plus the two gotchas). Spec's Provenance section → Task 6 Step 3. No gaps.

**Placeholder scan:** No TBD/TODO. Every test step carries its actual code; every verification step carries its actual commands and expected output; every commit step carries its actual message.

**Consistency:** The stderr line format `grampa: setup: <probe>: <reason>` is defined in Task 3 Step 3 and asserted verbatim in Task 3 Step 1. The `posts` prerequisite spelling is identical in Task 4 Steps 5–6 and Task 5. Test names match between the steps that write them, the steps that run them, and the counts (335 → 337 → 338 → 342).

**One deliberate deviation from strict TDD, flagged rather than hidden:** `test_build_works_without_a_posts_directory` (Task 4 Step 4) passes before the change. It guards the `posts:` rule against being forgotten in Step 6, and Step 4 says so explicitly rather than claiming a red-first run it cannot have.
