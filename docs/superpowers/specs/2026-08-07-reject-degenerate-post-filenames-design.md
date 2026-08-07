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
`<pubDate>`. `date_from_filename` (`Makefile:170`) and `rfc822_from_filename`
(`Makefile:186`) both fail, and `$(shell)` swallows the exit status — make 3.81 has no
`.SHELLSTATUS`, so there is nowhere downstream to notice.

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

## Approach 2: the date check, in one `$(shell)`

```make
BAD_POST_DATES := $(shell $(foreach n,$(POST_NAMES),\
	LC_ALL=C date $(call date_args,$(n)) -v0H -v0M -v0S >/dev/null 2>&1 || echo $(n);) true)
CHECKED_POST_DATES := $(if $(BAD_POST_DATES),$(error …))
```

**The check is the computation.** `date_from_filename` and `rfc822_from_filename` both build
their arguments with the same `$(join $(addprefix -v, $(wordlist 1,3,…)), y m d)` expression,
so asking `date` whether it accepts them answers exactly the question the build cares about —
"will this filename produce a date?" — rather than approximating it.

`date_args` is a new helper factoring that shared expression out of all three call sites,
which means this change edits two working functions on the feed's and every page's critical
path. It is worth doing because the check's correctness rests on the three staying identical:
if the check builds its arguments a second, independently-written way, it can drift from what
the build actually runs, and a check that answers a slightly different question is the same
class of defect as no check. `date_args` covers only the `-v<y>y -v<m>m -v<d>d` triple —
`LC_ALL=C` and `-v0H -v0M -v0S` stay at the call sites that need them.

The alternative considered and rejected was range-checking in pure make: strip digits with a
`$(subst)` chain, then `$(filter $(month),1 2 … 12)` against enumerated lists. It costs no
processes, but it is an approximation — verified that BSD `date` rejects `2026-02-30` with
`Cannot apply date adjustment`, exit 1, so an impossible calendar date would pass a 1–31 day
range and still publish a page with empty date fields. That leaves the backlog item half
closed, which is worse than not closing it, because the entry would read as done.

Verified `date` accepts what the repo documents as valid — `2026-7-4` unpadded and `26-7-4`
two-digit both exit 0 — and rejects `2026-13-40`, `20xx-ab-cd`, and `2026-02-30`.

### Cost

One shell invocation per build, whatever the post count, running N `date` calls inside it.
Measured on a 60-name probe: **+0.06s** against the 0.12s no-op rebuild the backlog's
`POST_NAMES :=` entry records. To be re-measured against the real Makefile during
implementation; if it lands materially worse than the probe, say so in the commit rather than
quietly shipping it. The repo has already spent a commit taking a no-op rebuild from 0.79s to
0.12s, so a regression here is not free.

### Ordering is load-bearing

That `$(shell)` interpolates post filenames into a shell command line **unquoted**, in both
the `date` arguments and the `|| echo $(n)`. A filename containing a backtick, `$(`, or `;`
would therefore *execute* during the parse.

The character check forbids all three, so the hazard is closed — but only if it runs first.
`$(error)` fires the moment it is expanded, so "first" means the immediate assignment
`CHECKED_POST_NAMES :=` must sit **above** `BAD_POST_DATES :=` in the file. Both are `:=`,
so this is a textual-order guarantee, not a dependency-order one.

This is the same class of parse-time-versus-recipe-time reasoning as the `config` and
`FEED_PAGES` gotchas, and it wants the same treatment: a comment block saying the order is
required and what breaks without it.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Where to fix the glob bug | Reject the filename | Quoting `$<` fixes one rule of three and reads as closed. A slug with brackets in it produces `/2026/01/02/a[b]c.html` — the name is degenerate, and the honest answer is to say so at parse time. |
| Character policy | All ASCII punctuation except `- _ .` | Closed by enumeration. Keeps `café` and uppercase slugs, both of which build correctly today. |
| Character mechanism | Pure make | No shell, no locale, no process. The `foreach`/`findstring` fold is one line and was verified against `\`, `$`, and `#`. |
| Date mechanism | Ask `date`, once, for all posts | Exact rather than approximate; catches `2026-02-30`, which enumerated ranges do not. |
| Date error granularity | One error naming all bad files | Matches `check_page_collisions`, which names both colliding files in one `$(error)`. A batched shell call cannot produce a per-file error anyway. |
| Ordering | Characters checked above dates | The date check's `$(shell)` interpolates filenames unquoted. |
| Recipe quoting | Unchanged | Out of scope, argued below. |

## Behaviour changes

Three filenames that build today stop building. All three are degenerate; the first is
deliberate and the other two are collateral, and they are listed rather than left to be
discovered.

**1. `%` in a filename is rejected**, though `…home_a%c.txt` builds correctly today even
beside a sibling — verified. `%` is make's pattern-rule wildcard and appears in the stem of
every pattern rule in the file; that it survives today is luck rather than design. Rejecting
it is the intended reading of "all ASCII punctuation".

**2. `+`, `@`, `=`, `,`, and the rest of ASCII punctuation are rejected**, and are harmless
today. This is the price of a set closed by enumeration, and it is the right price: the
alternative is a list of characters someone judged dangerous, which is exactly the shape of
mistake that produced the glob bug.

**3. An impossible calendar date is rejected**, not only an out-of-range one. `2026-02-30`
publishes a page with empty date fields today; it will now fail at parse time. This is a
larger closure than the backlog item asked for, and it comes free with asking `date`.

Nothing changes for any well-formed post. `posts/` is untouched; both checks are read-only
and produce `$(error)` or nothing.

## Tests

Seven new tests in `tests/run.sh`, each watched failing against the current Makefile before
the fix goes in, per the house rule that a test that has never failed guards nothing. Three
of the seven can only fail *after* the change and are marked as such — they are regression
guards on the new checks' false-positive surface, not on the bug.

1. **`test_glob_character_slug_is_rejected`** — `2026-01-02-home_a[b]c.txt` beside
   `2026-01-02-home_abc.txt`. Asserts the build fails, the error names the file, and — the
   assertion that pins the actual bug — that no page carrying `abc`'s body was published
   under the bracket name. Fails today at exit 0 with the sibling's content shipped.

2. **`test_shell_metacharacter_slug_is_rejected`** — one post per representative character,
   `'`, `*`, `$`, `;`, each in its own sandbox, each asserting a build failure naming the
   file. The apostrophe case must assert on the *message*, not merely on the exit status:
   it already fails today with `usage: cp`, so exit status alone cannot distinguish the fix
   from the bug.

3. **`test_unusual_but_safe_slug_still_builds`** — `café`, an uppercase slug, and a dotted
   slug in one sandbox. Asserts exit 0 and each body on its own page. Cannot fail before the
   change; it is the guard on the character list, and the test most likely to catch a
   too-eager edit to `BAD_CHARS` later.

4. **`test_out_of_range_date_is_rejected`** — `2026-13-40-home_bad.txt`. Fails today at
   exit 0.

5. **`test_non_numeric_date_is_rejected`** — `20xx-ab-cd-home_x.txt`. Fails today at exit 0.

6. **`test_impossible_calendar_date_is_rejected`** — `2026-02-30-home_feb.txt`. Fails today
   at exit 0. Kept separate from test 4 because it is the case the rejected pure-make
   approach would have missed, and a future rewrite of the check deserves to be told so by a
   test rather than by the spec.

7. **`test_unpadded_date_still_builds`** — `2026-7-4-home_unpadded.txt`. Asserts exit 0 and
   `/2026/7/4/unpadded.html`. Cannot fail before the change. Unpadded dates are documented as
   supported and are the likeliest thing an over-strict date check would break.

The suite must be run in full behind this: the character check runs against every post
filename in every sandbox, so a mistake in `BAD_CHARS` breaks tests unrelated to this work.

## Documentation updates

- **`Makefile`** — a comment block above `BAD_CHARS` in the existing `#`-banner style, saying
  what the set is (all ASCII punctuation but three) and why it is a closed set rather than a
  judgement call; a note that space and control characters cannot be list elements and where
  they fail instead. A comment block above `BAD_POST_DATES` saying that the check is the same
  `date` call the build makes, and that its position below `CHECKED_POST_NAMES` is required
  because it interpolates filenames into a shell.
- **`CLAUDE.md`** — the Post format section gains the character rule and the date rule
  alongside the existing "exactly one `_`" and duplicate-permalink paragraphs. The Gotchas
  section's "Out-of-range dates build successfully" is not currently there — but the
  `date -v` / BSD-only bullet should mention that filenames are now validated against `date`
  at parse time.
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
