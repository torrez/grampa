# Refusing a decorated date in a post filename

Date: 2026-08-24

Closes `docs/backlog.md` item 15.

## Problem

A post filename whose date carries a doubled hyphen builds a page path with a doubled
slash, which the kernel collapses onto another post's permalink. `CHECKED_POST_PAGES`
compares the two path *strings* byte-exactly and sees nothing wrong, so one post silently
overwrites the other at exit 0 — and `make deploy` ships it.

Reproduced against a plain checkout with `make setup` run and nothing else changed:

```sh
printf 'title: Real\n-----------------------------------\n<p>REAL BODY</p>\n' \
  > posts/2026-01-02-home_x.txt
make                                            # publishes build/2026/01/02/x.html, "REAL BODY"
printf 'title: Evil\n-----------------------------------\n<p>EVIL BODY</p>\n' \
  > posts/2026-01--02-evil_x.txt                # note the doubled hyphen before "02"
make                                            # exit 0; prints Building build/2026/01//02/x.html
cat build/2026/01/02/x.html                     # EVIL BODY
```

`find build -name x.html` returns **one** file. The real post's page is gone.

This is reachable on `main` today by typing the filename by hand. It predates `make new`
entirely — that branch's `date_shape_bad` work stopped the *generator* from writing such a
name, and this entry is the other half.

## Mechanism

`$(wordlist)` does not rejoin the words it selects. It returns the **substring of the
original text** running from the first selected word to the last, so any internal spacing
survives intact. Verified in a two-line makefile:

```
X := 2026 01  02 evil
$(wordlist 1,3,$(X))                      ->  [2026 01  02]
$(word 1,$(X))/$(word 2,$(X))/$(word 3,$(X))  ->  [2026/01/02]
```

`path_from_filename` is `$(subst $(space),/,$(wordlist 1, 3, $(subst -,$(space), …)))`, so
the preserved double space becomes `2026/01//02`.

The same property is why a doubled hyphen in a *category* survives into
`build/category/a--b.html` — `category_slug` selects its words with `$(wordlist)` too. That
is documented, legal, and producible by `make new CATEGORY='a--b'`, which matters for scoping
the fix below.

## Survey: which decorations actually evade the collision check

Every row built in a sandbox against unmodified `main`, alongside a plain
`posts/2026-01-02-home_x.txt` twin. This table is here because three of its rows moved the
design.

| filename | today, with a twin present |
| --- | --- |
| `2026-01--02-evil_x.txt` | **exit 0, clobbers the twin** — the bug |
| `2026--01-02-evil_x.txt` | **exit 0, clobbers the twin** — the bug |
| `-2026-01-02-evil_x.txt` | exit 2, `two posts build the same page /2026/01/02/x.html` |
| `2026-01-02--evil_x.txt` | exit 2, `two posts build the same page /2026/01/02/x.html` |
| `2026-01-02-evil_x.txt` | exit 2, the ordinary duplicate-permalink error |

So the hole is **exactly** a hyphen run interior to the y-m-d span. A leading hyphen is
skipped by make's tokenizer and a run after the day falls outside `$(wordlist 1,3,…)`; both
produce a page string byte-identical to the twin's, which the existing check already catches
loudly. The residual is two shapes, `Y--M-D` and `Y-M--D`, plus longer runs of the same.

## Goal

Refuse a decorated date at parse time, in the style of the five filename errors
`check_post_name` and `check_page_collisions` already produce, without making any currently
legal filename illegal beyond the collateral named below.

Normalizing the path instead — three `$(word)` calls in `path_from_filename`, letting the
existing collision check fire — was considered and rejected. It is one line cheaper and
fixes the ugly URL, but it *accepts* the malformed filename whenever nothing collides with
it. Refusing is symmetric with `make new`, which already refuses `DATE=2026-01--02`; a
filename the generator will not write should not be one the build silently accepts.

## Design

A sixth clause in `check_post_name`, built on the existing `dc_words`:

```make
date_prefix = $(word 1,$(call dc_words,$(1)))-$(word 2,$(call dc_words,$(1)))-$(word 3,$(call dc_words,$(1)))-
filter_date_prefix = $(filter $(call date_prefix,$(1))%,$(call date_and_category,$(1)))
```

and, as the last clause:

```make
$(if $(call filter_date_prefix,$(1)),,$(error posts/$(1): repeated or leading hyphen in date; expected y-m-d-category_title.txt))
```

The rule in one sentence: **the date-and-category segment must begin with its own three date
fields joined by single hyphens.** `$(word)` normalizes where `$(wordlist)` preserves, so
building the prefix from `$(word)` and matching it against the raw segment detects exactly
the decoration `$(wordlist)` would have carried into the path.

It reuses `dc_words` rather than re-splitting the filename, which is what lets the clause sit
inside `check_post_name` (defined at line 845) rather than needing its own `:=` block below
`path_from_filename` (line 1005), the way `CHECKED_POST_PAGES` does.

## Where the line falls

Probed as a table of filenames through the detector before any of it was written into the
Makefile:

| refused | accepted |
| --- | --- |
| `2026--01-02-evil_x.txt` | `2026-01-02-home_x.txt` |
| `2026-01--02-evil_x.txt` | `2026-01-02-a--b_x.txt` |
| `2026---01-02-evil_x.txt` | `2026-01-02--evil_x.txt` |
| `-2026-01-02-evil_x.txt` | `2026-01-02-evil--_x.txt` |
| `--2026-01-02-evil_x.txt` | `2026-7-4-home_x.txt`, `26-7-4-home_x.txt` |
| | `2026-01-02-._x.txt`, `2026-01-02-home_v2.0.txt` |
| | `2026-01-02-project-ideas_x.txt` |

The asymmetry between a leading hyphen (refused) and a run after the day (accepted) is one
sentence: **decoration before the day is date territory; decoration after it is category
territory**, where doubled hyphens are legal, `make new`-producible, and — because
`category_slug` collapses them out of the page path — already caught by the existing
collision check in the only case that can clobber anything.

## Collateral

`posts/-2026-01-02-home_q.txt` builds correctly today, alone, and stops building. Verified
both before and after.

This is accepted rather than worked around, on the precedent already recorded in `CLAUDE.md`
for `BAD_CHARS`: `%` and `+` also built correctly before they were enumerated out. A rule
closed by enumeration is worth more than one closed by judging which shapes look dangerous,
which is how `[` and `]` got through in the first place.

## Ordering is load-bearing

Two dependencies, both real, both inside `check_post_name`'s clause sequence rather than
between `:=` blocks. Make expands the clauses left to right and `$(error)` stops at the
first, so this is a guarantee about clause order in the function.

**Below the character clause — for the message, not for safety, and the distinction matters.**
Unlike `BAD_POST_DATES`, which interpolates filenames into a shell command line, this detector
reaches no shell at all: `$(filter)` is pure text. What goes wrong with the clause placed first
is a *worse message*, not an execution. A `%` in a date field builds a two-`%` pattern, which
make matches against nothing rather than erroring, so the name is refused for a reason that is
not the reason. Verified by mutation, two fixtures each bad in both ways:

| filename | clause first | clause last (shipping) |
| --- | --- | --- |
| `2026-%1-02-home_x.txt` | `repeated or leading hyphen in date` | `illegal character in filename: %` |
| `2026-01--02-home_a$(>PWN).txt` | `repeated or leading hyphen in date` | `illegal character in filename: $ ( ) >` |

**No payload executes in either order.** An earlier draft of this section cited the `$(>PWN)`
fixture as evidence for the ordering; it is evidence for the message only. `$(filter)` cannot
run a command, so the execution hazard that justifies `BAD_CHARS` sitting above
`BAD_POST_DATES` has no counterpart here, and stating it as though it did would have been this
file's own recurring defect — a confident, checkable, false claim — in the spec that fixes it.

**Below the empty-category clause.** `posts/2026-01_x.txt` has no third field, so
`$(word 3,…)` is empty and the detector refuses it for a reason that is not the reason.
Verified by mutation: placed first it reports `repeated or leading hyphen in date`; placed
last, `empty category in filename`, which is accurate.

Both want pinning by test, on the precedent of `test_character_error_precedes_the_date_error`
— which exists because the Task 2 review of that feature found the same property guarded by a
comment and nothing else, with every other test using a name bad in exactly one way.

## What closes the item

A checkable claim rather than a story: **no post page path can contain a repeated slash.**
A `//` in a page can only come from a preserved double space inside `$(wordlist 1, 3, …)`;
the slug half cannot contribute one, since `/` is in `BAD_CHARS`. Measured: `find build -name
'*.html' | grep -c '//'` is 0 against a prototype corpus containing every accepted shape in
the table above.

## Testing

Five tests, each watched failing first against the unmodified Makefile.

- `test_repeated_hyphen_in_date_is_rejected` — both `Y--M-D` and `Y-M--D`. The load-bearing
  assertion is that the **twin's** page still holds the real body, not merely that the build
  failed, mirroring `test_glob_character_slug_is_rejected`, whose own load-bearing assertion
  is the sibling's page rather than the exit status.
- `test_leading_hyphen_in_date_is_rejected` — the collateral, asserted deliberately so a
  future reader finds it intended rather than incidental.
- `test_date_shape_error_follows_the_character_error` — the `$(>PWN)` name bad in both ways,
  asserting the character message and the absence of the payload file.
- `test_date_shape_error_follows_the_empty_category_error` — `2026-01_x.txt` asserting
  `empty category`, so the message cannot silently regress to the shape error.
- `test_doubled_hyphen_category_still_builds` — pins the scope line, so a future tightening
  of the rule to the whole segment fails loudly here instead of quietly breaking a documented
  `make new` output.

Baseline before the change is **526 passed, 0 failed**; a prototype carrying the clause is
also **526 passed, 0 failed**, which establishes both that nothing regresses and that no
existing test covers the new behaviour.

## Documentation

- `CLAUDE.md`'s Post format section says there are five parse-time filename rules and that it
  is "the one place to find them". It becomes six, with the scope line and the collateral
  stated.
- `docs/backlog.md` item 15 is marked DONE, keeping the original finding below the closure the
  way every other closed item in that file does.

## Not in scope

The two siblings item 15 names as the same root cause — byte-exact comparison where the
filesystem disagrees — are untouched and stay open: a case-insensitive filesystem folding
`static/Index.html` onto `build/index.html`, and two post slugs differing only in case. Both
are documented decisions with their costs written down, and neither is a repeated-separator
problem. Closing them means a case-folding comparison that would reject names which are legal
and collide with nothing on Linux.
