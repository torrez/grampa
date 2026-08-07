# Rejecting degenerate post filenames at parse time

Date: 2026-08-07

## Problem

Two entries in `docs/backlog.md` describe post filenames that the build accepts and then
mishandles. Both are in the same family — the filename is the only metadata store, and
`check_post_name` (`Makefile:221-225`) checks its *shape* but nothing about its *characters*
or the validity of its date.

**1. A slug containing shell glob characters publishes a sibling's post.** Reproduced in a
sandbox: `posts/2026-01-02-home_a[b]c.txt` beside `posts/2026-01-02-home_abc.txt` builds at
exit 0, and `/2026/01/02/a[b]c.html` ships `abc`'s body. The cause is the unquoted `$<` in
the `%.staged` recipe: the shell glob-expands `[b]` onto the neighbour before awk sees the
file. `%.tmp` and `%.rssitem` interpolate stems unquoted the same way.

This is the only remaining path in the repo from a healthy source tree to silently wrong
published output.

**2. Out-of-range and non-numeric dates build successfully.** `2026-13-40-home_bad.txt` and
`20xx-ab-cd-home_x.txt` both exit 0, spew `date` usage text mid-build, and publish
`/2026/13/40/bad.html` and `/20xx/ab/cd/x.html` with an empty posted-on line and an empty
`<pubDate>`.

The important thing about this one is that **`date` already rejects these dates** — it exits
1 and prints `Cannot apply date adjustment`. Nothing hears it. `date_from_filename`
(`Makefile:170`) and `rfc822_from_filename` (`Makefile:186`) are both `$(shell …)` calls, and
`$(shell)` keeps the output and discards the exit status; for a failed `date` the output is
the empty string, which is exactly what lands in the page. Make 3.81 has no `.SHELLSTATUS`,
so there is nowhere downstream to notice either.

So the fix below is not a second implementation of `date`'s judgement. It is the only way to
*hear* a verdict `date` already reaches, delivered at parse time where a non-zero exit can
still become an `$(error)`.

## Goal

Reject both classes of filename at parse time, before any recipe runs, in the style of the
errors `check_post_name` and `check_page_collisions` already produce.

The two are specified and implemented together for a reason given in full under **Ordering
is load-bearing** below: the date check interpolates filenames into a shell command line, so
it is only safe behind the character check.

## Survey: what actually breaks today

Every row verified by building it in a sandbox, before designing anything. The table is here
because two of its rows moved the design: `%` and non-ASCII slugs work correctly today, which
rules out the obvious `[a-z0-9-]` whitelist.

| filename | today |
| --- | --- |
| `…home_a[b]c.txt` beside `…home_abc.txt` | exit 0, ships the **sibling's** body — the bug |
| `…home_a*c.txt`, `…home_a?c.txt` beside a sibling | exit 2, loud |
| `…home_it's.txt` | exit 2, but the message is `usage: cp` |
| `…home_a%c.txt` beside a sibling | exit 0, **correct** content |
| `…home_café.txt` | exit 0, **correct** content |
| `2026-13-40-home_bad.txt` | exit 0, garbage URL, empty date fields |
| `20xx-ab-cd-home_x.txt` | exit 0, garbage URL, empty date fields |
| `2026-02-30-home_feb.txt` | exit 0, garbage URL, empty date fields |

The apostrophe row is worth noting separately: it already fails, so it is not a correctness
fix, but `usage: cp` names neither the post nor the problem. It becomes a clear message for
free under the character check.

## Approach 1: the character check, in pure make

A fourth clause in `check_post_name`, driven by a list of forbidden characters:

```make
BAD_CHARS := ! " \# $$ % & ' ( ) * + , / : ; < = > ? @ [ \ ] ^ ` { | } ~
bad_chars_in = $(strip $(foreach c,$(BAD_CHARS),$(findstring $(c),$(1))))
```

29 characters: **every ASCII punctuation character except the three the format needs** —
`-`, `_`, and `.`. The set is closed by enumeration rather than by judgement about which
characters are "dangerous", which is the property that makes it trustworthy; a blacklist of
characters someone thought looked risky would leave the next one silently wrong.

Alphanumerics and every non-ASCII byte are allowed, which is what keeps `café` building.

Verified on GNU make 3.81 that all three awkward characters survive being list elements:
`\#` for `#`, `$$` for `$`, and a bare `\`. Verified that a `#` arriving from
`$(shell ls posts …)` is detected — `$(shell)` output is not re-parsed for comments.

Cost is O(29 × posts) string operations at parse time, no shell and no locale.

### Two characters the list cannot hold

**Space** cannot be an element of a make list, and neither can tab or a control character.
This is not a hole in practice: a filename containing a space splits `POST_NAMES` into two
words, and the second word fails the existing "no category in filename" check — verified,
exit 2. The message names a fragment of the filename rather than the filename, which is
worth a sentence in the comment block but not worth a second mechanism.

## Approach 2: the date check, in make first and `date` second

Two stages. Make proves the ordinary case valid without spawning anything; `date` is asked
only about the names make cannot clear.

```make
date_words = $(wordlist 1, 3, $(subst -, , $(notdir $(1))))
date_args  = $(join $(addprefix -v, $(call date_words,$(1))), y m d)

digits_to_plus = $(subst 0,+,$(subst 1,+,… $(subst 9,+,$(1)) …))
YEAR_SHAPES    := + ++ +++ ++++ +++++
DATE_OK_MONTHS := 1 2 3 4 5 6 7 8 9 10 11 12 01 02 03 04 05 06 07 08 09
DATE_OK_DAYS   := 1 2 … 28 01 02 … 09

date_is_sound = $(strip \
	$(if $(filter $(call digits_to_plus,$(word 1,$(call date_words,$(1)))),$(YEAR_SHAPES)),\
	$(if $(filter $(word 2,$(call date_words,$(1))),$(DATE_OK_MONTHS)),\
	$(if $(filter $(word 3,$(call date_words,$(1))),$(DATE_OK_DAYS)),x))))

SUSPECT_POST_DATES := $(foreach n,$(POST_NAMES),$(if $(call date_is_sound,$(n)),,$(n)))
BAD_POST_DATES := $(shell $(foreach n,$(SUSPECT_POST_DATES),\
	LC_ALL=C date $(call date_args,$(n)) -v0H -v0M -v0S >/dev/null 2>&1 || echo $(n);) true)
CHECKED_POST_DATES := $(if $(BAD_POST_DATES),$(error …))
```

Two mechanical notes on that block. It is nested `$(if)` rather than `$(and)` — `$(and)`
exists in 3.81, but its arguments here would arrive carrying the whitespace that
`\`-continuations leave behind, and `$(if)` treats a whitespace-only expansion as *true*.
The outer `$(strip)` is the belt to that braces: without it `date_is_sound` can return a
string of spaces, which every caller would read as "sound".

**Stage one proves, it does not judge.** `date_is_sound` returns non-empty only for a name it
can show `date` will accept: a year of **one to five digits**, a month in 1–12, and a day in
1–28. Verified across years 0, 1, 26, 99, 999, 2026, 9999, and 99999, padded and unpadded,
that every such combination exits 0 — day ≤ 28 is valid in every month of every year, so no
calendar knowledge is needed to clear it. Anything it cannot prove is a *suspect*, not a
reject.

**The year's upper bound is load-bearing, and an earlier draft did not have it.** The plan
review found that `date -v` accepts absurdly long years up to about eleven digits and then
starts rejecting them, so an "all digits, any length" year clears `999999999999-01-02`,
never sends it to `date`, and publishes `/999999999999/01/02/x.html` with an empty posted-on
line — the exact failure this change exists to close, reintroduced by the optimisation meant
to make it cheap. Five digits keeps `99999` building without a fork and sends anything longer
to `date`, which is the right answer either way. This is the invariant to protect when
touching stage one: **it must never clear something `date` would reject.** Guarded by
`test_absurdly_long_year_is_rejected`.

The year is checked twice, and the whole-branch review is why. The first clause is one
`$(filter)` against an enumerated list of shapes, with each digit mapped to a `+`: `2026`
becomes `++++` and matches, `20xx` becomes `++xx` and does not. That gives non-empty and
bounded-length in one expression.

On its own it has a subtle dependency: it is only sound because no filename can contain the
marker character, which is true only because `BAD_CHARS` rejects `+`. The review mutated the
marker to a letter — the edit the comment warns against — and **all 34 tests passed** while
`2q26-01-02-home_x.txt` built at exit 0 with empty date fields. The mutation is reachable only
through a filename containing the new marker, and every letter is legal, so no fixed test name
pins it: the reviewer's suggested test (`20xx-01-02`) catches *deletion* of the year clause,
which is a different mutant, but not this one. Verified both ways.

So the second clause checks the digits directly, `strip_digits`-style, making the marker's
identity irrelevant to correctness rather than load-bearing. Ten substitutions to turn a
subtle coupling into no coupling. `20xx-01-02-home_x.txt` is in the suite anyway, since it is
the only name that isolates the year clause at all — `20xx-ab-cd` is caught by the month.

**Stage two is the authority.** Suspects — days 29, 30, 31, and every malformed field — go to
`date` itself. `date_from_filename` and `rfc822_from_filename` build their arguments with the
same `$(join $(addprefix -v, $(wordlist 1,3,…)), y m d)` expression, so asking `date` whether
it accepts them answers exactly the question the build cares about — "will this filename
produce a date?" — rather than approximating it.

The two stages divide by what each is good at. Make is good at "is this in a list", which
covers every well-formed post and costs no process. Calendar arithmetic — month lengths and
leap years — is what make would have to *approximate*, and it is precisely what `date`
already knows. Verified that the result is leap-year exact: `2028-02-29` builds, `2026-02-29`
and `2026-02-30` and `2026-04-31` are all rejected.

An earlier draft asked `date` about every post and skipped stage one. It was correct but
measured at roughly double the no-op rebuild time (see **Cost**); stage one removes about
nine forks in ten without weakening the verdict, because it never clears anything `date`
would have rejected.

`date_args` is a new helper factoring that shared expression out of all three call sites,
which means this change edits two working functions on the feed's and every page's critical
path. It is worth doing because the check's correctness rests on the three staying identical:
if the check builds its arguments a second, independently-written way, it can drift from what
the build actually runs, and a check that answers a slightly different question is the same
class of defect as no check. `date_args` covers only the `-v<y>y -v<m>m -v<d>d` triple —
`LC_ALL=C` and `-v0H -v0M -v0S` stay at the call sites that need them.

The backlog proposed range-checking in pure make and stopping there — "~6 lines of
range-checking in `check_post_name`". That is stage one, and on its own it is an
approximation: a 1–31 day range passes `2026-02-30`, which still publishes a page with empty
date fields, leaving the item half closed and reading as done. Stage two closes the gap for
what stage one deliberately declines to rule on. The design is the backlog's own proposal
with its known hole plugged, not a heavier alternative to it.

Verified `date` accepts what the repo documents as valid — `2026-7-4` unpadded and `26-7-4`
two-digit both exit 0 — and rejects `2026-13-40`, `20xx-ab-cd`, `2026-02-30`, `2026-00-01`,
`2026-01-00`, and `2026-02-29`.

### Cost

One shell invocation per build, whatever the post count, running one `date` call per
*suspect*. Measured on the real Makefile, 60 posts, 8-run averages:

| | no-op rebuild |
| --- | --- |
| today | 0.150s |
| character check only | 0.120s — free, inside the noise |
| both checks, `date` for every post | 0.285s |
| both checks, stage one first | ~0.135s expected |

The middle row is why stage one exists: 60 bare `date` calls measure 0.13s on their own, so
the whole delta is forks and it scales linearly — roughly a second added to every `make` at
500 posts. Stage one clears every post dated on the 1st–28th, which is about nine in ten, and
the fork cost falls with it.

The last row is projected from the other three and **must be measured during implementation**
rather than taken on trust. The repo has already spent a commit taking a no-op rebuild from
0.79s to 0.12s; if the real number lands materially above it, say so in the commit rather
than shipping it quietly.

### Ordering is load-bearing

That `$(shell)` interpolates post filenames into a shell command line **unquoted**, in both
the `date` arguments and the `|| echo $(n)`. A filename containing a backtick, `$(`, or `;`
therefore *executes* during the parse. This was demonstrated, not reasoned about: a post
named `20xx-01-02-home_x$(>PWN).txt` created the marker file when the date check ran with no
character check above it, and the payload was consumed by the shell, so the filename in the
resulting error looked clean. The backtick spelling `` `>PWN` `` behaves the same way.

**Use that payload and not a friendlier-looking one.** The plan review caught a draft probe
using `$(shell touch PWNED)`, which creates nothing even with the ordering deliberately
reversed — the shell looks for a program named `shell` and fails — so the probe reported "no
leak" regardless of order and could not have failed. Verified all three spellings:
`$(>PWN)` and `` `>PWN` `` execute, `$(shell touch PWN)` does not.

It needs a *failing* date to reach the shell — the payload rides in on the `|| echo $(n)`
branch — so a well-dated filename with a metacharacter does not get there. That narrows the
hazard; it does not close it, since a name with a bad date is exactly what this check exists
to find.

The character check forbids all three characters, so the hazard is closed — but only if it
runs first. `$(error)` fires the moment it is expanded, so "first" means the immediate
assignment `CHECKED_POST_NAMES :=` must sit **above** `BAD_POST_DATES :=` in the file. Both
are `:=`, so this is a textual-order guarantee, not a dependency-order one. Verified in both
orders on the integrated Makefile: correct order gives a character error and no marker file,
reversed order leaks.

This is the same class of parse-time-versus-recipe-time reasoning as the `config` and
`FEED_PAGES` gotchas, and it wants the same treatment: a comment block saying the order is
required and what breaks without it.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Where to fix the glob bug | Reject the filename | Quoting `$<` fixes one rule of three and reads as closed. A slug with brackets in it produces `/2026/01/02/a[b]c.html` — the name is degenerate, and the honest answer is to say so at parse time. |
| Character policy | All ASCII punctuation except `- _ .` | Closed by enumeration. Keeps `café` and uppercase slugs, both of which build correctly today. |
| Character mechanism | Pure make | No shell, no locale, no process. The `foreach`/`findstring` fold is one line and was verified against `\`, `$`, and `#`. |
| Date mechanism | Prove in make, then ask `date` about the rest | Exact rather than approximate — catches `2026-02-30` and non-leap `2026-02-29`, which enumerated ranges do not — without a fork per post. |
| Prefilter boundary | Day ≤ 28 | The largest day valid in every month of every year, so clearing it needs no calendar knowledge. 29–31 is where month length and leap years start to matter, and that is exactly what `date` is asked. |
| Date error granularity | One error naming all bad files | Matches `check_page_collisions`, which names both colliding files in one `$(error)`. A batched shell call cannot produce a per-file error anyway. |
| Ordering | Characters checked above dates | The date check's `$(shell)` interpolates filenames unquoted. |
| Recipe quoting | Unchanged | Out of scope, argued below. |

## Behaviour changes

Four, listed rather than left to be discovered. The first is deliberate, the next two are
collateral, and the fourth is on a platform the repo does not support.

**1. `%` in a filename is rejected**, though `…home_a%c.txt` builds correctly today even
beside a sibling — verified. `%` is make's pattern-rule wildcard and appears in the stem of
every pattern rule in the file; that it survives today is luck rather than design. Rejecting
it is the intended reading of "all ASCII punctuation".

**2. `+`, `@`, `=`, `,`, and the rest of ASCII punctuation are rejected**, and are harmless
today. This is the price of a set closed by enumeration, and it is the right price: the
alternative is a list of characters someone judged dangerous, which is exactly the shape of
mistake that produced the glob bug.

**3. An impossible calendar date is rejected**, not only an out-of-range one. `2026-02-30`
publishes a page with empty date fields today; it will now fail at parse time. The check is
leap-year exact — `2026-02-29` is rejected and `2028-02-29` builds — which is a larger
closure than the backlog item asked for and comes free with asking `date`.

**4. On GNU coreutils, posts dated 29–31 now fail at parse time.** `date -v` is a BSD flag;
the repo is already documented as macOS-only for exactly this reason, and on GNU every
`date_from_filename` call already fails and publishes empty date fields. What changes is
*which* posts break and *how*: stage one clears the 1st–28th without consulting `date` at
all, so they build as before, while a post dated the 31st becomes a suspect, `date -v` fails
for the wrong reason, and the post is rejected as having a bad date.

This is a confusing error on a platform the repo does not claim to support, and it is not
worth engineering around — but it should be written down rather than discovered. Arguably it
is a small improvement: a loud parse-time failure beats silently publishing empty dates,
which is what GNU gets today. The BSD-only gotcha in `CLAUDE.md` is where it belongs.

Nothing changes for any well-formed post on macOS. `posts/` is untouched; both checks are
read-only and produce `$(error)` or nothing.

## Tests

Ten new tests in `tests/run.sh`, each watched failing against the current Makefile before
the fix goes in, per the house rule that a test that has never failed guards nothing. **Three
of the ten cannot fail before the change** — tests 3, 9, and 10 — and are marked as such;
they guard the new checks' false-positive surface rather than the bug, which is a real job
but a different one.

1. **`test_glob_character_slug_is_rejected`** — `2026-01-02-home_a[b]c.txt` beside
   `2026-01-02-home_abc.txt`. Asserts the build fails, the error names the file, and — the
   assertion that pins the actual bug — that no page carrying `abc`'s body was published
   under the bracket name. Fails today at exit 0 with the sibling's content shipped.

2. **`test_shell_metacharacter_slug_is_rejected`** — one post per representative character,
   `'`, `*`, `$`, `;`, each in its own sandbox, each asserting a build failure **naming the
   file**.

   **Three of the four need a message assertion, not an exit-status one.** Verified against
   today's Makefile, each character alone in its own sandbox:

   | slug | today |
   | --- | --- |
   | `a'c` | exit 2, `usage: cp …` |
   | `a*c` | **exit 0** — builds; the unmatched glob passes through literally |
   | `a$c` | exit 2, `build/2026/01/02/a.html: no post in posts/ builds this page` |
   | `a;c` | exit 2, `No rule to make target 'build/2026/01/02/a'` |

   Only `*` alone is distinguishable by exit status. For `'`, `$`, and `;` an exit-only
   assertion passes against today's buggy code and guards nothing — the house rule's exact
   failure mode. Assert the new error text for all four and the question does not arise.

3. **`test_unusual_but_safe_slug_still_builds`** — `café`, an uppercase slug, and a dotted
   slug in one sandbox. Asserts exit 0 and each body on its own page. Cannot fail before the
   change; it is the guard on the character list, and the test most likely to catch a
   too-eager edit to `BAD_CHARS` later.

4. **`test_out_of_range_date_is_rejected`** — `2026-13-40-home_bad.txt`. Fails today at
   exit 0.

5. **`test_non_numeric_date_is_rejected`** — `20xx-ab-cd-home_x.txt`. Fails today at exit 0.

6. **`test_impossible_calendar_date_is_rejected`** — `2026-02-30-home_feb.txt`. Fails today
   at exit 0. Kept separate from test 4 because it is the case stage one alone would have
   missed: a future contributor who deletes stage two as a fork-saving tidy-up should be told
   so by a test rather than by this spec.

7. **`test_non_leap_february_29_is_rejected`** — `2026-02-29-home_feb.txt`. Fails today at
   exit 0. Pins leap-year exactness, which is the sharpest thing distinguishing stage two
   from a day-range check.

8. **`test_absurdly_long_year_is_rejected`** — `999999999999-01-02-home_x.txt`. Fails today
   at exit 0. Guards stage one's five-digit upper bound on the year; see the paragraph on it
   under Approach 2.

9. **`test_unpadded_date_still_builds`** — `2026-7-4-home_unpadded.txt` and
   `99999-1-1-home_faryear.txt`. Asserts exit 0 and both pages. Cannot fail before the
   change. Unpadded dates are documented as supported and are the likeliest thing an
   over-strict date check would break; the five-digit year is there because `YEAR_SHAPES`
   stops at five and must still *clear* it rather than merely tolerate it.

10. **`test_month_end_dates_still_build`** — `2026-01-31`, `2026-04-30`, and `2028-02-29` in
   one sandbox. Asserts exit 0 and all three pages. Cannot fail before the change. This is
   the guard on the **prefilter boundary**: all three are suspects that stage one declines to
   clear, so it is the only test exercising stage two's accept path. Without it, a stage two
   that rejected everything it was asked about would pass the whole suite.

The suite must be run in full behind this: the character check runs against every post
filename in every sandbox, and the date check against every date, so a mistake in either
breaks tests unrelated to this work. Fable's review confirmed the current suite is 223
passing against an implementation of this design.

## Documentation updates

- **`Makefile`** — a comment block above `BAD_CHARS` in the existing `#`-banner style, saying
  what the set is (all ASCII punctuation but three) and why it is a closed set rather than a
  judgement call; a note that space and control characters cannot be list elements and that
  they fail on the existing category check instead, naming a fragment of the filename rather
  than the filename (verified: `…home_a b.txt` → `posts/b.txt: no category in filename`).
  A comment block above the date check saying what each stage is for, that stage one proves
  rather than judges and must therefore never clear anything `date` would reject, and that
  the whole check's position below `CHECKED_POST_NAMES` is required because it interpolates
  filenames into a shell — with the demonstrated `$(>PWN)` case named, so the next person
  does not read it as paranoia.

  The trailing `true` in the `$(shell)` is **not** load-bearing — verified byte-identical
  output with and without it at 0, 1, 2, and 60 posts, since nothing reads the exit status
  and 3.81 has no `.SHELLSTATUS`. Keep it for intent, but the comment must not claim it is
  required.
- **`CLAUDE.md`** — the Post format section gains the character rule and the date rule
  alongside the existing "exactly one `_`" and duplicate-permalink paragraphs, since those
  are the two other parse-time `$(error)`s and a reader looking for "what makes a filename
  legal" should find all four in one place. The BSD-only gotcha should gain a sentence: the
  same `date -v` that makes the build macOS-only is now also what decides whether a filename
  is legal, so a GNU-coreutils machine fails at parse time rather than at render time.
- **`docs/backlog.md`** — the glob-character-slug bullet and the out-of-range-dates bullet
  both marked DONE in the established "**DONE**, then the original finding" shape. Ranked
  remaining-work item 3 struck through, and the sentence in item 1's DONE note that calls the
  glob-character slug the last remaining silently-wrong-output case updated, since it stops
  being true.

## Not changed, and deliberately so

**The unquoted `$<` and `$*` in the recipes.** Every recipe that interpolates a stem has this
property, and quoting the `%.staged` rule alone would half-fix the glob bug while reading as
if it were closed — the backlog's own argument. With the filenames rejected at parse time
there is no reachable input left that reaches those recipes, so quoting them buys defence in
depth against a case that can no longer occur. If it is ever wanted, it is a separate change
covering all three rules at once.

**`check_post_name`'s existing shape checks.** Untouched.

## Out of scope

- Quoting recipes, per above.
- The behaviour half of backlog item 8 (the feed's post-deletion self-heal).
- The residual placeholder-expansion hole, `make deploy`'s missing prerequisite, the trailing
  blank line in `.source/splitter.txt`, and `make -j setup all`.
- Any change to what a *well-formed* filename means: the date/category/slug shape, the single
  underscore, and the category-not-in-URL rule are all unchanged.
