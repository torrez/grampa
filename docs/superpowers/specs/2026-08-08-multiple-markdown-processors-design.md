# Multiple markdown processors

**Date:** 2026-08-08
**Status:** approved, not yet implemented

## Problem

`Markdown.pl` is the only markdown processor grampa can use, and it is the worst one
available. It is a 2004 Perl script that has to be downloaded by hand from Daring Fireball,
`chmod +x`'d, and dropped in the repo root; it predates CommonMark; and it cannot do tables.
Meanwhile every platform ships two or three small, fast, dependency-free markdown binaries
that can.

The build should use whichever of those is already installed, fall back to `Markdown.pl`
last, and let the author override the choice when the automatic answer is wrong.

## Decisions already settled with the user

These are not open for relitigation:

- **Both a fixed list and a config override**, not one or the other.
- **All eleven listed tools are supported**, not a curated subset.
- **Detection happens at `make setup`**, written into the generated `config.mk` — the
  `DATE_DIALECT` precedent — not at build time.
- **Switching processors re-stages every post.** `%.staged` gains `config` and `config.mk`
  as prerequisites.
- **Ordering principle: tables first, runtime-free first**, `Markdown.pl` last.
- **`Markdown.pl` is candidate 12 in the same table as everything else**, not a special case.
  This changes existing behavior; see "Behavior changes" below.
- **A build announces which processor it is using, once, at the top of the output.**

## Design

### 1. The candidate table

A `define` block near the top of the Makefile, beside the other data. Pairs of `probe|argv`,
one per line, in preference order:

```make
define MARKDOWN_CANDIDATES
lowdown|lowdown
cmark-gfm|cmark-gfm -e table -e strikethrough -e autolink -e tasklist
md2html|md2html --github
comrak|comrak -e table
multimarkdown|multimarkdown --snippet
markdown|markdown -f +tables
cmark|cmark
smu|smu
markdown_py|markdown_py -x tables
markdown-it|markdown-it
pandoc|pandoc -f markdown-smart -t html
./Markdown.pl|./Markdown.pl
endef
export MARKDOWN_CANDIDATES
```

Field 1 is what gets probed; field 2 is the command line. **A field 1 containing `/` is
probed with `[ -x ]`; everything else with `command -v`.** That one rule is what lets
`./Markdown.pl` — a repo-root file, not a PATH binary — live in the same table as the rest
instead of needing a branch of its own.

Every candidate must satisfy the contract `Markdown.pl` already satisfies, which is the only
reason a single table works: **take a file argument, write an HTML fragment to stdout, exit
non-zero on failure.** Two flags exist purely to hold tools to the "fragment" half —
`multimarkdown --snippet`, and pandoc's *absence* of `-s` — because without them those two
emit a complete `<html><head>` document, which `base.txt` would then wrap in a second one.

The table is data. Adding or dropping a tool is a one-line edit.

#### Two flag choices that are deliberate

- **cmark-gfm's `tagfilter` extension is left off.** It escapes `<script>`, `<iframe>`,
  `<style>`, and friends into visible text. Grampa's post bodies are HTML by default, so a
  post embedding a video would silently publish the tag as source. The four extensions that
  are on — `table`, `strikethrough`, `autolink`, `tasklist` — only add syntax.
- **pandoc's `smart` extension is turned off** via `-f markdown-smart`. It is on by default
  for markdown input and rewrites the author's punctuation: straight quotes become curly,
  `---` becomes an em dash. Correct for a document converter, a surprise for a blog that did
  not ask to be typeset.

### 2. Detection at `make setup`

`setup`'s recipe walks the table top to bottom and records the first hit in `config.mk`,
beside the dialect it already writes. **What gets recorded is field 2, the whole command
line** — not the probe name:

```
DATE_DIALECT := gnu
DETECTED_MARKDOWN := cmark-gfm -e table -e strikethrough -e autolink -e tasklist
```

`lowdown` would make a misleadingly tidy example here, since its two fields are identical.
Recording field 1 for a candidate whose fields differ would drop every flag — `cmark-gfm`
without `-e table` renders tables as paragraphs, at exit 0. A test asserts the exact
`cmark-gfm` line above.

Nothing found writes `DETECTED_MARKDOWN :=` empty, which means post bodies stay verbatim
HTML — today's no-`Markdown.pl` behavior, unchanged.

**Each candidate is probed by *running* it, not by `command -v`.** `command -v` proves a name
is on `PATH`; it says nothing about whether the thing wearing that name speaks the interface
in field 2. `markdown` is the sharp case — it is discount's binary name, but also a perl
wrapper's and an npm shim's, and a non-discount `markdown` sitting above a working `cmark`
gets `markdown -f +tables` recorded and then **fails every build**, with a working candidate
one row down. So:

```sh
printf 'x\n' > "$$probefile"
out=$$($$cmd "$$probefile" 2>/dev/null </dev/null) || continue
case "$$out" in *'<html'*|*'<HTML'*|*'DOCTYPE'*) continue;; esac
```

Exit zero means the candidate runs; the `case` is what holds it to the *fragment* half of the
contract. A candidate that emits a complete `<html><head>` document exits 0 perfectly happily,
and grampa would then wrap it in `base.txt` for a second `<html>` — a silently malformed page
at exit 0. This is the failure mode `multimarkdown --snippet` and pandoc's missing `-s` exist
to prevent, and the `case` makes the whole table robust to getting one of those flags wrong
rather than trusting eleven remembered argv strings. A candidate that trips it is skipped, not
fatal, so the next row still gets its turn. The `case` cannot false-positive: the probe input
is the single character `x`, so any `<html` in the output is the tool's own scaffolding and
never the author's text. The
`</dev/null` matters: a candidate that ignores its file argument and waits on stdin would
otherwise hang `make setup` forever. `./Markdown.pl` keeps its `[ -x ]` test *in addition*,
since a non-executable one must not be run at all.

Setup echoes what it picked, next to its existing `Configured date dialect:` line, so the
choice is visible when it is made rather than something to go find in a generated file. This
is setup's own message and is unrelated to §5's build notice, which setup does not print.

The walk reads `MARKDOWN_CANDIDATES` from the environment (`export`ed like the awk programs).
`echo "$$MARKDOWN_CANDIDATES" | while IFS='|' read -r probe cmd` puts the loop in a subshell,
so the winner must be `echo`ed out of the pipeline and captured, not assigned to a variable
that will not survive it.

**`config.mk` is written only when its content actually changes.** The recipe composes the
whole file into a temp, `cmp -s`, then `mv` or discard. This is load-bearing, not hygiene:
§4 makes `config.mk` a prerequisite of every `.staged` file, so an unconditional rewrite
would make every `make setup` re-stage every post. The current recipe's unconditional
`echo … > config.mk` must change even though the dialect half of it did not care.

`config.mk.new` goes in `.gitignore` beside `/config.mk`. `setup` is `.PHONY`, so
`.DELETE_ON_ERROR` will not reap the temp if setup is killed mid-write, and an untracked
temp showing up in `git status` is exactly the kind of litter this repo doesn't leave.

The dialect probe, the candidate walk, and the `cmp`/`mv` are one `; \`-continued logical
line: each recipe line is its own shell, so `dialect` and the walk's winner do not otherwise
survive to the write.

### 2a. The upgrade guard

An install set up before this change has a `config.mk` containing only `DATE_DIALECT := gnu`.
Pull the new Makefile and nothing fails: `DATE_DIALECT` is set, so the existing loud check is
satisfied, `DETECTED_MARKDOWN` is merely undefined, `MARKDOWN_CMD` is empty, and **markdown
silently turns off**. The rot is worse than it first looks and was reproduced: already-staged
posts are up to date and keep their rendered bodies, while the next post you *edit* re-stages
verbatim — a **mixed site**, rendered HTML on one page and literal `*asterisks*` on its
neighbour, at exit 0, which `make deploy` then ships.

Silent wrong output is the failure class this repo treats as its worst, so it gets the same
loud upgrade path `DATE_DIALECT` itself got:

```make
ifeq ($(if $(BUILD_GOAL),$(if $(DATE_DIALECT),$(filter undefined,$(origin DETECTED_MARKDOWN)))),undefined)
$(error grampa: config.mk predates markdown detection -- run `make setup`)
endif
```

`$(origin)` is what makes this precise, and the distinction is verified: an old-style
`config.mk` gives `undefined`, while a new one where detection found *nothing* gives `file`
even though both expand empty. So a probed-empty install — a legitimate state — never trips it.

**The `$(BUILD_GOAL)` gate is load-bearing, not symmetry with §5.** Without it the check is a
deadlock, and this was verified rather than reasoned about: the error instructs you to run
`make setup`, and `make setup` parses the same Makefile, hits the same parse-time `$(error)`,
and dies before its recipe can rewrite `config.mk`. That is the identical trap CLAUDE.md
documents for `BAD_POST_DATES` and `date_select` — can't build without it, can't setup to make
it — arriving through a different door. Gated on the goal, `make setup` parses clean and
bootstraps, `make clean` stays quiet, and a build on an unconverted install fails loud. All
four states verified.

`BUILD_GOAL` is therefore shared by the guard and §5's notice and should be defined once,
immediately after `-include config.mk`:

```make
BUILD_GOAL := $(if $(MAKECMDGOALS),$(filter all build deploy,$(MAKECMDGOALS)),default)
```

### 3. The `config` override

A third key beside `name=` and `url=`:

```
markdown=cmark-gfm -e table -e footnotes
```

Read lazily, exactly as the other two are and for the same first-ever-run reason:

```make
CONFIG_MARKDOWN = $(shell sed -n 's/^markdown=[[:space:]]*//p' config 2>/dev/null | sed 's/[[:space:]]*$$//' | tail -1)
MARKDOWN_CMD = $(if $(strip $(CONFIG_MARKDOWN)),$(strip $(CONFIG_MARKDOWN)),$(DETECTED_MARKDOWN))
```

The override has to live in `config` and not in `config.mk`: setup rewrites `config.mk`
unconditionally by design, so a hand-edit there would evaporate at the next `make setup`.

`.source/config.example` gains a commented `markdown=` line and a short list of the eleven
candidates, so the override is discoverable without reading the Makefile.

**The value is a shell command line and is executed unquoted.** That is inherent — it must
word-split into argv — and it is the same trust already extended to `deploy.sh`. It gets
documented as such rather than defended against. A `markdown=` naming something not
installed fails loudly at build time, which is the right shape for an explicit override.

### 4. Invalidation

```make
$(WORK_DIR)%.staged: posts/%.txt config $(wildcard config.mk)
```

The recipe's two `[ -x Markdown.pl ]` / `[ ! -x Markdown.pl ]` shell branches collapse into a
single shell, with **make** choosing the branch at recipe-expansion time rather than the shell
choosing it at run time:

```make
$(if $(strip $(MARKDOWN_CMD)),<split, run $(MARKDOWN_CMD), reassemble>,cp $< $@)
```

Two reasons, and the second is the one that matters. A shell `[ -n "$(MARKDOWN_CMD)" ]` test
breaks outright on a `markdown=` value containing an unbalanced quote — verified, it produces
`` bash: syntax error near unexpected token `fi' `` naming the *recipe*, so the failure is loud
but points at grampa rather than at the config line that caused it. And `MARKDOWN_CMD` is lazy
and shells out through `sed | sed | tail` every time it expands: the two-branch shell form
expands it three times per staged post, this form once, saving roughly nine forks per changed
post. This repo counts forks — see the `POST_NAMES` bullet in CLAUDE.md's gotchas.

The *exec* site stays interpolated unquoted, which is the settled trust decision. There is no
path by which a post filename or the blog name reaches that command line: `BAD_CHARS` rejects
every glob and quoting metacharacter, space/tab/newline names die at parse time before any
recipe runs, and `BLOG_NAME` never enters the staging recipe at all. Confirmed under review.

**The `$(wildcard)` is doing real work and must not be simplified away.** `config.mk` has no
rule that builds it. Named as a bare prerequisite on an unconfigured tree, make would die
with its own `No rule to make target 'config.mk'`, pre-empting the deliberately-worded
recipe-time ``grampa: no DATE_DIALECT -- run `make setup` first``. Wrapped in `$(wildcard)`
the prerequisite is simply absent when the file is, and the good error still wins. It is
expanded at parse time, which has one visible shadow rather than none. In a single invocation
that both recreates `config.mk` and builds — `rm config.mk; make setup work/X.staged` — the
wildcard already expanded empty, so the staged file reports "up to date" against a `config.mk`
that same run just wrote with a newer mtime. It self-heals on the next invocation. This is a
**fifth member of the parse-time-vs-recipe-time family**, after `FEED_PAGES`/`url=`, the
`BAD_POST_DATES` gate, `make -j setup all`, and §5's notice; combined setup-and-build
invocations are exactly where that family lives, and it belongs in the gotchas rather than
being claimed away.

Adding `config` as a prerequisite means editing `name=` also re-stages every post. That is
accepted: staging is an awk split plus one processor run, and `config` is already a
prerequisite of every HTML rule for the same reason.

### 5. The build-time notice

The natural home would be `build`'s recipe, where the feed skip note lives. It does not work:
`build`'s recipe runs *after* its prerequisites, so the note would print below every page.
Listing a phony `markdown-note` first among `build`'s prerequisites does not work either —
that is the trap CLAUDE.md already documents for `build: | setup`, where an order-only
prerequisite sequences the recipe rather than make's walk, and where `-j` removes the
ordering guarantee entirely.

So: a parse-time `$(info)`, which runs before any recipe and is therefore genuinely first,
serial or `-j`.

```
grampa: markdown: lowdown
grampa: markdown: cmark-gfm -e table -e footnotes (from config)
grampa: markdown: none -- post bodies stay HTML
```

Gated twice. On `$(DATE_DIALECT)` being non-empty, so an unconfigured tree leads with the
`run make setup first` error instead of a markdown note. And on `$(BUILD_GOAL)` from §2a — the
same variable, defined once — so `make clean`, `make setup`, and `make test` stay quiet.

**Known wrinkle, documented not fixed.** Reading `markdown=` for the note means reading
`config` at parse time, and on a first-ever run `config` does not exist yet — so that one
build's note shows the detected tool even if the `config.example` about to be copied into
place sets `markdown=`. This is the fourth instance of the parse-time-vs-recipe-time family
already in the gotchas. It is tolerable because it affects only the printed line: the
`.staged` recipe still expands `MARKDOWN_CMD` lazily at recipe time and gets the right
answer, so the build is correct and only the announcement is stale, self-correcting on the
next `make`.

## Behavior changes

One thing is taken away, deliberately.

**Dropping `Markdown.pl` into the repo root and running `make` will no longer pick it up.**
It is now a probe candidate like the other eleven, so it needs a `make setup`. The rule
becomes uniform — *install a processor, run `make setup`* — at the cost of a habit the
README currently teaches. `README.md`'s install section and the CLAUDE.md gotcha about
`Markdown.pl` not invalidating `.staged` both have to be rewritten; the latter is not merely
reworded but **closed**, since §4 makes the invalidation real.

## Testing

All new tests use stub processors written into a sandbox `bin/` prepended to `PATH`, so
nothing in the suite depends on what is installed on the machine running it. The existing
`markdown_stub` helper stays for the `Markdown.pl` cases and gains a sibling for PATH tools.

**Every markdown test needs a `make setup` re-run after its stub is installed, and the stub
helpers should do it themselves rather than leaving it to each test.** `sandbox()` runs
`make setup` *before* the test body executes, so detection happens before any stub exists.
This is not an incidental detail: a prototype of this design run against the current suite
produced 260 passes and 11 failures, and all eleven were markdown tests failing for exactly
this reason. That number is the expected cost of the §"Behavior changes" habit break, not a
regression, and anyone implementing this should expect to see it before adapting the helpers.

- Detection picks the first available candidate and skips absent ones — stub `cmark` only,
  assert `DETECTED_MARKDOWN := cmark`; add a stub `lowdown`, re-run setup, assert it wins.
- `markdown=` in `config` beats detection.
- Editing `markdown=` re-stages every post.
- A no-op `make setup` re-stages **nothing** — the `cmp` guard. Assert `.staged` mtimes are
  unchanged.
- No processor anywhere means verbatim passthrough at exit 0, with the `none` notice.
- A failing processor still fails the build (the existing `test_failing_markdown_fails_the_build`,
  adapted off `Markdown.pl`).
- An unconfigured tree still dies with the `DATE_DIALECT` message, not make's
  `No rule to make target 'config.mk'` — the `$(wildcard)` guard.
- The notice appears once, before any `Building …` line, and is absent for `clean`, `setup`,
  and `test`.
- `Markdown.pl` alone is still found, as candidate 12; `chmod 644` plus a re-setup drops it,
  preserving today's executable-bit behavior.
- The recorded value is the full argv — stub `cmark-gfm`, assert the `config.mk` line carries
  all four `-e` flags.
- A squatting `markdown` that rejects `-f` is skipped in favour of a working `cmark` below it
  (the §2 running probe).
- The §2a upgrade guard: an old-style `config.mk` fails a build loud, permits `make setup`,
  stays quiet for `clean`, and does **not** fire on a `DETECTED_MARKDOWN :=` empty file.
- `config.mk.new` never survives a successful setup, on either the `mv` or the discard branch.

## Flag verification

The eleven command lines above are the part of this design most likely to be wrong, since
they are eleven other projects' interfaces. Before implementation they get executed, not
trusted:

- **Installable on Arch and therefore verified by running:** `lowdown`, `cmark`, `cmark-gfm`,
  `discount` (`markdown`), `md4c` (`md2html`), `pandoc`, `python-markdown` (`markdown_py`),
  `comrak`.
- **Verified by building from source:** `smu` (plain C, no toolchain beyond `cc`). Confirmed
  fragment output, no table support as documented, raw HTML preserved, punctuation untouched.
- **Taken from documentation, deliberately not executed:** `multimarkdown` (needs `cmake`),
  `comrak` (needs the Rust toolchain), `markdown-it` (needs Node). A decision, not an
  oversight: roughly a gigabyte of toolchain to confirm three argv strings, against a
  fragment-checking probe that now catches the failure mode those flags guard. They stay
  marked unverified rather than passing as checked.

For each, confirm two things specifically: that output is a fragment rather than a whole
document, and that a table in the input produces a `<table>` in the output.

`discount`'s `-f` syntax and `multimarkdown`'s fragment flag are the two the author is least
confident of from memory and should be checked first. The §2 running probe reduces the blast
radius of a wrong flag from "every build fails" to "that candidate is skipped", but it does
not make a wrong flag correct — a flag that is accepted yet does the wrong thing, like a
tables switch that silently isn't, still passes the probe.

A comment above the table warns that a future candidate's argv must not contain `#` or `$`,
which would truncate or misparse the `config.mk` line it gets written into. None of the twelve
do.

## Verification residue

Under review, the design was prototyped against the real Makefile and the full suite run
against it. Two things were **not** established and should not be treated as settled:

- **Everything was verified on GNU make 4.4.1, not 3.81.** Nothing here adds a pattern rule or
  depends on the rule-ordering behavior CLAUDE.md pins to 3.81, but the `$(wildcard)`
  prerequisite timing in §4 is asserted from the manual on that version rather than observed.
- **None of the eleven tools were executed**, since none is installed on this machine — which
  is what the Flag Verification section above exists to fix before implementation starts.

## Out of scope

- Per-post processor selection. One processor per site.
- Any attempt to normalize dialect differences between processors.
- Validating that a `markdown=` override exists at setup time. It fails at build time,
  loudly, which is enough.
