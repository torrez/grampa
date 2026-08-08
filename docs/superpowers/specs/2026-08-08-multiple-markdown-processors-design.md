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
beside the dialect it already writes:

```
DATE_DIALECT := gnu
DETECTED_MARKDOWN := lowdown
```

Nothing found writes `DETECTED_MARKDOWN :=` empty, which means post bodies stay verbatim
HTML — today's no-`Markdown.pl` behavior, unchanged.

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

and the recipe's two `[ -x Markdown.pl ]` / `[ ! -x Markdown.pl ]` branches become
`[ -n "$(MARKDOWN_CMD)" ]` / `[ -z "$(MARKDOWN_CMD)" ]`, with `./Markdown.pl $(WORK_DIR)$*.body`
becoming `$(MARKDOWN_CMD) $(WORK_DIR)$*.body`.

**The `$(wildcard)` is doing real work and must not be simplified away.** `config.mk` has no
rule that builds it. Named as a bare prerequisite on an unconfigured tree, make would die
with its own `No rule to make target 'config.mk'`, pre-empting the deliberately-worded
recipe-time ``grampa: no DATE_DIALECT -- run `make setup` first``. Wrapped in `$(wildcard)`
the prerequisite is simply absent when the file is, and the good error still wins. It is
expanded at parse time, but the case it guards — `config.mk` absent — is exactly the case
where the build is going to fail anyway, so nothing depends on it noticing a mid-build
appearance.

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
`run make setup first` error instead of a markdown note. And on the goal being a build —
`all`, `build`, `deploy`, or the default — derived from `MAKECMDGOALS`, so `make clean`,
`make setup`, and `make test` stay quiet.

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
- `Markdown.pl` alone is still found, as candidate 12.

## Flag verification

The eleven command lines above are the part of this design most likely to be wrong, since
they are eleven other projects' interfaces. Before implementation they get executed, not
trusted:

- **Installable on Arch and therefore verified by running:** `lowdown`, `cmark`, `cmark-gfm`,
  `discount` (`markdown`), `md4c` (`md2html`), `pandoc`, `python-markdown` (`markdown_py`),
  `comrak`.
- **Not readily installable here and taken from documentation:** `smu`, `multimarkdown`,
  `markdown-it`. These are marked as unverified in the implementation notes rather than
  allowed to pass as checked.

For each, confirm two things specifically: that output is a fragment rather than a whole
document, and that a table in the input produces a `<table>` in the output.

`discount`'s `-f` syntax and `multimarkdown`'s fragment flag are the two the author is least
confident of from memory and should be checked first.

## Out of scope

- Per-post processor selection. One processor per site.
- Any attempt to normalize dialect differences between processors.
- Validating that a `markdown=` override exists at setup time. It fails at build time,
  loudly, which is enough.
