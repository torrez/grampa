# `make new` — generate a post stub

Design, 2026-08-09. Branch `make-new`.

## The problem

Creating a post today means typing a filename by hand into a grammar with five parse-time
`$(error)`s guarding it: the `<y>-<m>-<d>-<category>_<slug>.txt` shape (`check_post_name`,
which is also what rejects an empty category or an empty title slug), the ASCII-punctuation
denylist, the control-character check, the real-calendar-date check, and the
duplicate-permalink check. Each of those errors is well written and each one is a build you
have to fail before you learn something you could have been told up front.

## The invariant

**`make new` must be incapable of emitting a name that any of those five checks rejects.** The
generator's output set is a subset of the grammar's accepted set. Everything below exists to
hold that line. Where the generator refuses, it refuses *before* writing, so a refusal leaves
`posts/` byte-identical.

This is the whole value of the feature. A generator that can produce a rejected name is worth
less than no generator, because it moves the error from the moment you typed the name to the
moment you next build.

## Interface

```sh
make new TITLE="Installing a doorbell" CATEGORY=home
make new TITLE="Old news" CATEGORY=home DATE=2026-07-04
```

Writes `posts/2026-08-09-home_installing-a-doorbell.txt`, echoes `Created posts/…`, and stops.

- `TITLE` — required. Goes into the front matter verbatim; slugified for the filename.
- `CATEGORY` — required, no default. Slugified by the same rules as the title.
- `DATE` — optional, `YYYY-MM-DD`, defaults to today.

Make variables rather than positional goals: no `MAKECMDGOALS` catch-all rule, quoting is the
shell's job, and it is the form every other make-driven generator uses. Not interactive: a
recipe that reads stdin behaves differently under `-j`, in a pipe, and over ssh.

It prints the path and stops. No `$EDITOR` launch and no `EDIT=1` knob — a make recipe that
seizes the terminal is a different kind of program, and `$(EDITOR) $(make new …)` is not a
thing the user needs help spelling.

### The stub

```
title: Installing a doorbell
-----------------------------------
```

Front-matter line, delimiter, empty body. The delimiter is `cat`ted from
`.source/splitter.txt` — already the single authority on those 35 hyphens, read by the
`%.staged` recipe — rather than retyped into a `printf`. An empty body is an exercised path,
not an edge case: `SPLIT_STAGED`'s `END` block exists precisely so a bodiless post still
stages.

No placeholder body text, because the right placeholder depends on something the stub cannot
know: `<p>…</p>` is wrong under a markdown processor and bare prose is wrong without one.

## Slugification

Applied identically to `TITLE` and `CATEGORY`, entirely under `LC_ALL=C` so every step is
bytewise. Bytewise is what makes it UTF-8-safe: a multi-byte character's continuation bytes
are all `>= 0x80` and can never collide with the ASCII punctuation being stripped.

1. **Translate to a space** every `[[:cntrl:]]` byte — `0x00`–`0x1F` and `0x7F` under
   `LC_ALL=C`, which is exactly the set `CONTROL_CHAR_NAMES` rejects. This is a separate step
   from step 3 and not a `BAD_CHARS` clause, mirroring the Makefile's own split between
   `bad_chars_in` and `CONTROL_CHAR_NAMES`, and for the same reason: a control byte cannot be
   an element of a make list. Translated to a space rather than deleted, so a pasted
   `Two<LF>lines` becomes `two-lines` and not `twolines`.
2. **Delete** `'` and `"`. Deleted rather than translated so `Tom's doorbell` becomes
   `toms-doorbell` and not `tom-s-doorbell`.
3. **Translate to a space** every `BAD_CHARS` member, plus `_`.
4. **Lowercase `A-Z` only.** Non-ASCII bytes pass through untouched — `Café` → `café`, and
   `É` stays `É`, since a bytewise `tr` cannot case-fold multi-byte characters. Consistent
   rather than clever, and consistent with a filename grammar that accepts both.
5. **Squeeze** runs of spaces, **trim** the ends, **translate** spaces to `-`.

Worked examples, all run:

| `TITLE` | slug |
| --- | --- |
| `Installing a Doorbell` | `installing-a-doorbell` |
| `Tom & Jerry: part 2` | `tom-jerry-part-2` |
| `Tom's doorbell` | `toms-doorbell` |
| `Café_notes` | `café-notes` |
| `日記 #1` | `日記-1` |
| `Version 2.0 notes` | `version-2.0-notes` |
| `A/B testing` | `a-b-testing` |
| `Two<LF>lines<TAB>here` | `two-lines-here` |
| `!!!` | *(empty — refused)* |

**Step 1 is the one the first review caught missing, and it is worth saying why.** Without it
the invariant is simply false: control bytes are not in `BAD_CHARS`, nothing else in the
pipeline touches them, and a lone tab is not an empty slug — so `make new` wrote
`posts/2026-08-09-home_a<TAB>b.txt` at exit 0, and a title with a newline in it wrote a file
that **poisons the tree**. Every subsequent build, and every subsequent `make new`, dies at
parse time on `posts/lines.txt: no category in filename` — the fragment message CLAUDE.md
documents for a `0x0A`, naming a file that does not exist. The generator built the one name
its own successor cannot survive. Reproduced end to end.

`.` is not in `BAD_CHARS` and is not stripped, so `2.0` survives into the URL. A non-ASCII
dash or an emoji survives too. Both follow from matching the grammar rather than second-
guessing it, and both were chosen knowing what they look like in a URL.

### The character set comes from `BAD_CHARS`

The `tr` sets are derived from `$(BAD_CHARS)` by `filter-out` and `subst`, not retyped. A
second, independently written copy of that list is exactly the drift the Makefile already
refuses for `date_select`: a generator that strips a slightly different set than the checker
rejects is the same class of defect as no generator. `BAD_CHARS` is the authority; `make new`
reads it.

Three mechanical hazards, all found by running `tr` rather than by reading about it:

- **A literal `\` in a `tr` set is an escape introducer.** With the set spelled `…[\]^…`,
  `tr` consumes the backslash as an escape for `]`, and a backslash in the *title* is then
  left untranslated. Verified: `a\b^c]d` came through as `a\b c d`. The backslash must be
  doubled in the derived set. With it doubled, all of `\`, `]`, `[` and `^` translate
  correctly.
- **`tr set1 ' '` relies on set2 being padded** with its last character. GNU `tr` does this;
  POSIX leaves a short set2 to the implementation. The portable spelling `tr 'set1' '[ *]'`
  is used instead. Verified on GNU 4.4.1 — **not** verified on BSD `tr`, there being no macOS
  host in reach for this work. Flagged for the plan, and a real candidate for the branch
  review to run somewhere else.
- **Quoting the two sets.** The translate set contains `` ` ``, `$` and `\` but no `'`, so it
  is single-quoted in the recipe and reaches `tr` literally. The delete set is the two quote
  characters themselves, which no single shell quoting handles, so it is written as `tr`'s own
  octal escapes: `\047\042`.
- **`[:cntrl:]` composes with the padding form.** Step 1 is `tr '[:cntrl:]' '[ *]'`, a
  character class in set1 against the padded set2, which is the one combination worth checking
  rather than assuming. Verified on GNU.

## Refusals

All of these are checked before anything is written, so a refused `make new` leaves `posts/`
untouched.

| Condition | The check it stands in for |
| --- | --- |
| `TITLE` unset or empty | — |
| `CATEGORY` unset or empty | — |
| title slug empty after slugification (`TITLE="!!!"`) | `check_post_name`'s empty-title-slug clause |
| category slug empty after slugification | `check_post_name`'s empty-category clause |
| `posts/<date>-<category>_<slug>.txt` already exists | never clobber — the rule `yes n \| cp -i` follows everywhere else in this Makefile |
| `posts/<date>-*_<slug>.txt` exists in another category | `CHECKED_POST_PAGES`'s duplicate-permalink error |
| `DATE` is not three hyphen-separated runs of digits | *(new — see below)* |
| `DATE` is not a real calendar date | `BAD_POST_DATES` |

Two grammar checks need no refusal of their own, because slugification cannot produce what
they reject: control characters are removed by step 1, and the `_` separator is the one the
recipe writes itself.

### `DATE` is validated twice, and the shape check is not decoration

`DATE` is validated by running `date $(call date_select,$(DATE))` — the same arguments the
build will run, from the same shared helper, for the same reason the parse-time check shares
it. A check that answers a slightly different question than the build asks is not a check.

But `date_select` interpolates its argument into **recipe text**, not into the environment,
so unlike `TITLE` it is not protected by the export discipline above. Under the GNU dialect
that text is `-d "<date> 00:00:00"`, and one `"` escapes it. Verified:
`make new DATE='x";touch PWNED;"'` created `PWNED`. So `DATE` gets a **pure-make shape check
that runs before `date_select` is ever expanded**: split on `-`, require exactly three words,
and require that stripping the ten digit characters from the value leaves nothing but the
hyphens. Verified accepting `2026-07-04` and `2026-7-4` (unpadded, which the grammar allows)
and rejecting `2026-02`, `2026-07-04-05`, `20xx-ab-cd`, and the injection payload above with
no leak.

That the check is written in make rather than shell is **not stylistic**. Make expands the
whole recipe line before the shell sees any of it, so a shell-level `if [ -n "$$DATE" ]`
guard around `date $(call date_select,$(DATE))` is too late twice over: the injected text is
already in the line, and on an unconfigured tree `date_select`'s `$(error)` branch fires even
when no `DATE` was given — which would break the default-date path this spec says works.
Verified both: the shell-guard form dies on an unconfigured tree with no `DATE` set; the
make-level `$(if $(DATE),…)` form prints and proceeds.

## Recipe shape

`.PHONY: new`, with `posts` as its only prerequisite — the existing rule whose `mkdir -p`
already exists for exactly this reason. Not `config`: no config key is read here.

One `; \`-continued logical shell line, in the style of `setup`'s recipe, because each recipe
line is its own shell and the slug and the path have to survive from validation to write.

**`TITLE` reaches the recipe through the environment, never through the recipe text.** Make
exports command-line variables to recipe shells automatically, so `"$$TITLE"` reads it with no
interpolation. Verified with a title carrying a double quote, a backtick `whoami`, and a
literal `$(boom)`: all three reached the recipe intact and none executed. This is the same
discipline `BLOG_NAME` and `SITE_URL` already use to reach awk through `ENVIRON[]`.

### `new` joins `NONBUILD_GOALS`

`NONBUILD_GOALS := clean setup test config new`.

Not cosmetic. Without it, `BUILD_GOAL` is non-empty for a `make new` invocation, and two
things follow: the parse-time `grampa: markdown: …` notice prints above `Created …` on every
run, and on an install predating markdown detection the `$(origin DETECTED_MARKDOWN)` guard
fires — so `make new` dies telling you to run `make setup`, on the one goal that has nothing
to do with markdown.

This is the maintenance point the denylist was documented to have: CLAUDE.md says a denylist
"fails loud on an unlisted future goal", and `new` is the first unlisted future goal. The
sentence naming those four goals gains a fifth.

## Known limits, documented rather than fixed

- **A pre-existing malformed post blocks it.** `make new` parses the whole Makefile, so a bad
  filename already sitting in `posts/` kills the invocation before it can write a good one.
  The tool that prevents bad names cannot run in a directory that already has one. Fixing this
  would mean gating every filename check on `BUILD_GOAL`, which trades a narrow annoyance for
  a broad hole.
- **`$(…)` in `TITLE` is expanded by make before the recipe runs.** `make new TITLE='$(shell
  echo PWNED)'` prints `PWNED` and titles the post `x`. Verified. It is not fixable by quoting
  in the recipe — command-line variables are expanded when make exports them, before any
  recipe text is considered. It is also self-inflicted at the same trust level as `markdown=`
  in `config`, which is documented as being "exactly as trusted as the person who edits it".
  A title containing a literal `$(` is written by hand.
- **Unconfigured trees are asymmetric.** The default date is `date +%Y-%m-%d` and needs no
  dialect, so `make new` works on a tree with no `config.mk`. `DATE=` validation goes through
  `date_select`, whose else branch is the `$(error)`, so that form says
  ``grampa: no DATE_DIALECT -- run `make setup` first``. Both behaviours are correct and both
  get a test; the asymmetry is recorded so the next reader does not file it as a bug.
- **Case and Unicode-normalization collisions are not detected**, the same hole the guards
  already have: the duplicate-permalink pre-check uses a shell glob, which is byte-exact, so
  `Doorbell` and `doorbell` do not collide on Linux and do on APFS. Step 4 lowercases ASCII,
  which removes the common case of this by construction; the residual is non-ASCII.
- **Some legal slugs are ugly, and they are legal.** `TITLE='.'` builds `..html`;
  `TITLE='- - -'` builds `-----.html`; a leading or trailing hyphen survives into
  `-hello.html` and `hello-.html`. All five checks accept every one of these — verified — so
  the invariant holds and nothing is broken. They are listed here for the same reason `2.0`
  and emoji are: matching the grammar means matching its ugly corners too. A slug of `.` or
  `..` stays inside its own date directory and escapes nothing.

## Tests

In `tests/run.sh`, following the existing sandbox pattern. Ordered by what they are worth.

1. **Round trip.** `make new TITLE=… CATEGORY=…` then `make`, and the permalink the filename
   predicts is published with the title in it. The one test that proves the invariant end to
   end rather than in pieces.
2. **Refuses an existing file, and the original bytes survive.** Written so it fails against a
   clobbering recipe — assert the old content, not just the exit status.
3. **Refuses a same-date, same-slug post in a different category**, and `posts/` is unchanged.
4. **Each refusal leaves `posts/` unchanged**: empty slug, missing `TITLE`, missing
   `CATEGORY`, bad `DATE`.
5. **The slug table above**, as one test per interesting class: uppercase, `&`/`:`,
   apostrophe, `_`, `café`, `日記`, `2.0`, `A/B`.
6. **A hostile title** — `"` `'` `$` `&` and a backtick — lands verbatim in the front matter
   and the post builds. The backslash case is included, since the doubled-`\` set is the fix
   it pins.
7. **A title containing a tab, and a title containing a newline**, each produce a clean
   hyphenated slug and a post that builds. This is the B1 test: it fails against any
   implementation whose slugifier skips step 1, and the newline case fails *loudly*, since a
   wrong implementation leaves behind a file that breaks the sandbox's every later `make`.
8. **A hostile `DATE`** — `DATE='x";touch PWNED;"'` — is refused, creates no file, and
   executes nothing. Assert the absence of `PWNED`, not just the exit status.
9. **`make new` prints no `grampa: markdown:` line.** Pins the `NONBUILD_GOALS` entry;
   catchable by mutation (drop `new` from the list and this fails).
10. **`DATE=2026-07-04` backdates**; `DATE=2026-02-30` and `DATE=2026-02` are refused;
    `DATE=2026-7-4` is accepted, matching the grammar.
11. **Unconfigured tree**: the default-date form succeeds, the `DATE=` form says
    ``run `make setup` first``. The first half is the R2 test — it fails against a
    shell-guarded `date_select`.

## Documentation

- `CLAUDE.md` — the Commands block; the sentence naming the four `NONBUILD_GOALS`; a short
  subsection under Post format covering the slug rules and the four known limits above.
- `README.md` — one entry beside `make setup`.
- `docs/backlog.md` — nothing unless the branch review leaves a residual.

## Review record

The first draft of this spec went to a Fable review at the "Spec written" checkpoint. It
found three things, all folded in above and all reproduced independently before being
accepted:

- **Blocking** — slugification did not handle control characters, so the central invariant
  was false. A tab wrote a rejected filename; a newline wrote one that breaks every later
  build. Fixed by step 1.
- **Recommended** — `DATE` reaches `date_select` as recipe text and was injectable with a
  single `"`. Fixed by the pure-make shape check.
- **Recommended** — that shape check, and the `date_select` call it guards, must be
  make-level rather than shell-level, or the unconfigured default-date path this spec
  promises does not work.

It also verified, so the next checkpoint need not re-run them: the `BAD_CHARS` derivation
reaching `tr` intact with the backslash doubled, the whole slug table, the command-line
variable export and its `$(…)` limit, the hostile-title round trip through `fill()`, that
`date_words` works on a bare `YYYY-MM-DD`, that the `NONBUILD_GOALS` entry is both necessary
and sufficient and that no other `BUILD_GOAL`-gated site breaks, that `posts` is a sufficient
prerequisite, and that a range of ugly-but-legal slugs are accepted by all five checks.

The BSD `tr` padding question remains unverified for want of a macOS host, at both the design
and the review. It is the standing item for the branch review.

## Corrections, 2026-08-10

**The `DATE` injection payload asserted twice above — in "`DATE` is validated twice" and in
Tests item 8 — is false.** Both say `make new DATE='x";touch PWNED;"'` created `PWNED`. It does
not: `date_select` rejoins whatever it split on `-` with a literal hyphen regardless of what
whitespace originally separated the pieces, so the payload's shell text becomes
`touch-PWNED` — a command that does not exist — and no file is created. The escape through the
GNU dialect's `-d "<date> 00:00:00"` is still real; it needs a **space-free** payload to
demonstrate. `DATE='x";>PWNED;"'` does create `PWNED` against a build with the shape check
removed, since `>` needs no space to redirect and survives the rejoin intact. This is what
`test_new_does_not_execute_an_injected_date` in `tests/run.sh` now uses, and what the Task 6
documentation cites. The original false claim traced back to a scratch reproduction run against
a broken local redefinition of `space`, not against this Makefile's own.

**This spec also never mentions `SANITIZE_TITLE`, and it should have.** The front-matter line
`make new` writes is `printf 'title: %s\n' "$$TITLE"` — one line — so a title containing a
newline would split the front matter in two, and `PARSE_FRONT_MATTER` would read the second
line as something it is not (a stray body line preceding the real delimiter, or worse, text
indistinguishable from a second `title:`). Step 1 of Slugification above removes control
characters from the *slug*, but says nothing about the *front matter*, which is a separate
string built from the raw `$$TITLE`. The implementation plan caught this gap and added
`SANITIZE_TITLE` — the same `tr '[:cntrl:]' '[ *]'` translation as slug step 1, followed by a
squeeze-and-trim of the resulting spaces, applied to the title as it is written into
`title: …`, independent of and in addition to the slugification pipeline. It is pinned by
`test_new_keeps_the_front_matter_on_one_line`. Recorded here because the plan's self-review
already flagged it as "one thing the spec missed," and this is that fold-back.

## Out of scope

Deliberately not built, to keep this one target: a `SLUG=` override, a `category=` config key
or any other default for `CATEGORY`, `$EDITOR` integration, and `make new` doing anything at
all to `build/`.
