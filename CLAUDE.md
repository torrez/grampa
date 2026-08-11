# CLAUDE.md

## What this is

Grampa is a static blog generator written entirely as a GNU Makefile driving standard
Unix tools (`awk`, `sed`, `cat`, `date`, `tail`). There is no language runtime, no
package manager, and no dependencies to install. The Makefile *is* the program — if a
change can't be expressed in make + awk + coreutils, it doesn't belong here.

## Commands

```sh
make setup     # one-time: create build/ work/ posts/ templates/ static/, copy templates +
               #           the stock stylesheet + config + deploy.sh, and probe the host for
               #           its date dialect and a markdown processor
make           # incremental build into build/  (= `make config build`)
make clean     # wipe build/ and work/
make build     # the build half of the default target (see below — it no longer skips anything)
make deploy    # builds, then runs ./deploy.sh build/
make test      # run tests/run.sh in throwaway sandboxes
make new TITLE="A title" CATEGORY=home [DATE=2026-07-04]
               # write posts/<date>-<category>_<slug>.txt and stop
```

Builds are incremental: `make` only reprocesses posts whose `.txt` changed, plus anything
downstream of a touched template. `make -j` is safe. Use `make clean` when you want to be
sure nothing stale survives — e.g. after deleting a post, whose old HTML is not tracked by
anything and will otherwise linger in `build/`.

**`setup` is a one-time step, and wants its own invocation.** Do not combine it with a build
goal under `-j`: in a directory that has no `templates/` yet, `make -j setup all` stops with
`No rule to make target 'templates/…'`. `make -j setup deploy` does the same, since `deploy`
became a build goal. Serial `make setup all` is fine **only when `config.mk` already exists or
`posts/` is empty**; on a tree that already has dated posts it fails, because `-include
config.mk` runs once at parse time (empty on a virgin tree) and make does not re-include a
fileless-rule include after `setup`'s recipe writes it, so the `build` half of the same process
still has `DATE_DIALECT` empty and fires `date_select`'s `$(error)` at recipe time. But `make
setup` alone always succeeds and writes `config.mk` — the parse-time date check is gated on
`$(DATE_DIALECT)` (see the portable-date gotcha) precisely so an unconfigured `setup` never
trips the error before writing the file — so a second `make` then succeeds. This is the same
lazy-parse-vs-recipe split already documented for `config`/`FEED_PAGES`, reaching an `-include`
this time. The documented `make setup` then `make` is unaffected and remains the primary flow.

**It is not actually a race, which is worth knowing because the name suggests a fix that does
not work.** Make resolves the whole prerequisite graph before running any recipe, so
`build`'s prerequisites are looked up while `setup`'s recipe has not copied anything yet — on
a first run `templates/` is still *empty* when make dies, so no template lost anything.
Verified: after a failed `make -j4 setup all`, `config` exists and `templates/` has zero
entries.

**Which template the message names is deterministic, and is a function of your directory, not
of luck.** Make names the first missing template in its dependency walk. With posts present
that is `templates/post.txt`, needed by the first post's fragment; with `posts/` empty it is
`templates/base.txt`, needed by `build/index.html`. Verified across `-j2`, `-j4`, and `-j8`,
both goals — no within-state variation at all. This is why the paragraph quotes no filename:
not because the name is unpredictable, but because it is predictable *from something the
reader has and this document does not*. Two reproductions of this once disagreed and were
taken as evidence of nondeterminism; they had different `posts/` directories.

It is documented rather than fixed because the mechanical fix does not work — and it fails for
a better reason than cost. An order-only `build: | setup` does make `setup` remake on *every*
build, since `setup` is `.PHONY` (verified with `make --debug=b`), but that is the lesser
problem: **it does not close the failure either**, because an order-only prerequisite sequences
the target's *recipe* against `setup`, not make's walk of `build`'s other prerequisites — and
the error fires during that walk. Verified: with it added, `make -j4 setup all` fails
identically, 3 of 3. Making `setup` non-phony means inventing a stamp file for a step you run
once.

`deploy` depends on `all`, so it builds before it ships. It used to not, and
`make clean && make deploy` therefore handed `deploy.sh` an empty `build/` at exit 0 with no
warning — which, given the example `deploy.sh` is an `rsync`, is one `--delete` away from
unpublishing the site. The cost of the prerequisite is one quiet no-op build. It builds first
but does not *set up* first: a directory where `make setup` has never run still fails on the
missing templates.

**It does not sanitize `build/`, and the obvious guess about that is wrong.** A page you
*deleted* is regenerated before shipping, and a page whose source is newer is rebuilt — but a
page you hand-*edited* is now newer than its prerequisites, so make considers it up to date and
`make deploy` ships your edit. Make cannot tell an edit from a build. `./deploy.sh build/` and
`make deploy` send the same bytes in that case, and `build/` is no safer a scratchpad than it
was before.

A failing build now stops the ship. That sounds like a loss of the old form's ability to
re-ship the last good `build/`, but that last good `build/` is mostly a myth:
`.DELETE_ON_ERROR` takes away a half-written page, so a build that fails partway leaves a site
with a page *missing*, and the old `deploy` shipped precisely that at exit 0.

`make build` is what `make` runs after `config`; it is not a way to skip the config check.
`config` is a prerequisite of every page rule, so `make build` recreates a missing `config`
just as `make` does. The two are equivalent in every reachable state.

`make` must be run from the repo root. The awk scripts read templates via
`getline < "templates/base.txt"` — a relative path — so any other working directory means
the file isn't found.

`getline` on a file it cannot read returns `-1`, which is truthy, so an unguarded
`while (getline < "…")` loop spins forever rather than erroring. All four awk programs now
guard the read with `> 0` **and** report the `-1` case and `exit 1`:

```
grampa: cannot read templates/base.txt
make: *** [build/2026/08/06/hello.html] Error 1
```

The `exit 1` is the load-bearing half. A guard alone would turn the hang into a clean
`exit 0` and a fully rendered page with an empty body — the same silently-deployable wrong
output the `.staged` recipe's `&&` chain exists to prevent. Exiting non-zero lets
`.DELETE_ON_ERROR` take the half-written file away instead.

The reachable path here is a template that is **present but unreadable** — one `chmod 000`,
or a careless `cp`/`rsync` that drops the mode. Make sees the prerequisite satisfied and awk
runs. A *missing* template never reaches awk, and neither does running from the wrong
directory, since the template prerequisite is a relative path too. A *missing* template
errors rather than serving stale output: `post.txt` and `rss-item.txt` always error,
`base.txt` always did, and `rss.txt` errors whenever the feed is being built — with `url=`
unset nothing references it and deleting it builds clean, since `build/rss.xml` is not in
`FEED_PAGES`.

`post.txt` and `rss-item.txt` get that standing from being named as prerequisites of
`build`. Named only in pattern rules they were not files make thought ought to exist, so
deleting one made the `%.tmp`/`%.rssitem` rule inapplicable and the stale fragment in
`work/` was reused with exit 0. The prerequisite is unconditional, which means
`rss-item.txt` must exist even with the feed off — an asymmetry with `rss.txt`, and the
deliberate price of not gating a prerequisite list on `SITE_URL`, which would land straight
back in the parse-time-vs-recipe-time gotcha below. All verified, and guarded by the four
`test_unreadable_*_template_fails_the_build` tests plus
`test_deleted_post_template_fails_the_build` and
`test_deleted_rss_item_template_fails_the_build`.

## Layout

The program and its documentation are tracked; everything the build touches is gitignored
and created by `make setup`. `git ls-files` is the authority — as of this writing it is the
Makefile, `.source/`, `README.md`, `CLAUDE.md`, `.gitignore`, `tests/`, `tools/`, and
`docs/`:

| Path | Tracked | Role |
| --- | --- | --- |
| `Makefile` | yes | The program |
| `.source/` | yes | Pristine templates and assets copied into place by `make setup` |
| `.source/splitter.txt` | yes | The `-----------------------------------` front-matter delimiter |
| `.source/static/` | yes | Pristine static assets — today just `style.css`, the stock stylesheet |
| `README.md`, `CLAUDE.md` | yes | Docs for humans and for Claude |
| `tests/run.sh` | yes | The suite, run by `make test` in throwaway sandboxes |
| `tools/` | yes | One-off maintenance scripts (`migrate-categories.sh`, `probe-platform.sh`) |
| `docs/` | yes | Specs, plans, and `backlog.md` — the standing review findings |
| `posts/` | no | Source posts, one `.txt` per post |
| `templates/` | no | Working templates (edit these, not `.source/`) |
| `static/` | no | Per-install static assets, copied verbatim into `build/` |
| `build/` | no | Publishable output, and nothing else — deploy this verbatim |
| `work/` | no | Intermediates (`.staged`, `.tmp`, and `.rssitem` fragments) |
| `config`, `deploy.sh` | no | Per-install, copied from `.source/*.example` |
| `config.mk` | no | Per-install, **generated** by `make setup` probing the host: `DATE_DIALECT := bsd\|gnu` and `DETECTED_MARKDOWN := <argv>`. No `.source` twin — it is derived, not copied |

`make setup` copies with `yes n | cp -i`, so it never clobbers existing files. It is safe
to re-run. The one exception is `config.mk`, which is *generated* rather than copied: setup
probes `date(1)` and the markdown candidates and rewrites it, which is what re-fixes the
dialect if a checkout ever moves between OSes and what picks up a newly installed markdown
processor. The rewrite is conditional on the content actually differing — setup writes
a per-process scratch file (`config.mk.$$$$` in the Makefile, which the shell receives as
`config.mk.$$` and expands with its PID) and `cmp`s it — because `config.mk`
is a prerequisite of `%.staged`, and an unconditional touch would re-stage every post on
every setup. The per-process name is what keeps two concurrent setups from truncating each
other's scratch file and promoting a half-written `config.mk`; the cost is that a setup
aborted between the write and the `mv` leaks `config.mk.<pid>` indefinitely, which
`/config.mk.*` ignores and `make clean` does not remove.

**An existing install that upgrades and re-runs `make setup` gets the stylesheet file but not
the link.** `cp -i` will not clobber the `templates/base.txt` it already has, so no
`<link rel="stylesheet">` appears — but `static/style.css` does not exist yet on such a tree,
and `cp -i` only guards files that are already there, so it lands. That install therefore ships
an unreferenced `/style.css` until the owner adds the line to their own `base.txt` or deletes
the file. The invariant that does hold is the one worth having: **nobody acquires a stylesheet
*link* pointing at a file they lack.** Reproduced against a real pre-feature install — set up
at `974c186`, built, then given the new `Makefile` and `.source/` and re-`setup` — where
`templates/base.txt` still had zero stylesheet lines, `static/style.css` was present, and the
build published `build/style.css` with no page referring to it. (An earlier version of this
paragraph said such an install gets neither the file nor the link. That is false.)

## config

```
name=My Weblog
url=https://example.com
```

`name=` sets `{{page_title}}`: the index gets `My Weblog`, a post page gets
`Post Title - My Weblog`. Blank lines and `#` comments are ignored, the last `name=` (or
`url=`) wins, and surrounding whitespace is trimmed. An absent or empty `name=` falls back
to `Grampa`.

`url=` is the site's absolute base URL. Setting it is what turns `FEED_PAGES` non-empty and
gets `build/rss.xml` built; leaving it unset or empty means no feed and no error. A trailing
slash is stripped so `url=` with or without one produces identical links.

`markdown=` overrides the processor `make setup` detected. It is a shell **command line**,
not a command name — flags are expected, and it is run as `<command> <file>` with the body
file as its last argument. Like `deploy.sh`, it is executed, so it is exactly as trusted as
the person who edits `config`. `MARKDOWN_CMD` is `$(or $(strip $(CONFIG_MARKDOWN)),$(DETECTED_MARKDOWN))`,
so an override always beats detection, and a name that doesn't exist fails the build at
exit 127 rather than falling back to verbatim.

A `#` in the value does not start a *config* comment — the rest of the line goes to the shell,
which has its own opinion about `#`. The whole `.staged` recipe is **one shell line**, so
`markdown=cat #--flag` comments out the `> .mdbody` redirect and the `&& cat … > $@` that
follows it, and the recipe exits 0 having never written its target. It is caught now, and the
thing that catches it is the parentheses around `$(MARKDOWN_CMD)` in that recipe: the closing
`)` is swallowed by the same comment, which makes it a shell syntax error and fails the build.

That guard is there because the uncaught version was the worst failure this program has had.
On a *first* build it at least died one rule later, at `awk: fatal: cannot open file
'work/….staged'` — a missing-file error naming a file whose own rule had reported success. But
on a **rebuild** the previous `.staged` was still on disk with its old mtime, so make judged
every downstream page up to date, printed `Build completed.`, and exited **0** while silently
dropping the edit the author had just made — and `make deploy` ships exactly that. It needs a
processor that succeeds when handed no file, which is to say `cat` and every markdown CLI that
falls back to stdin. Both halves verified before and after the fix, and guarded by
`test_hash_in_markdown_value_fails_the_rebuild`, whose stub must exit 0 on no arguments or the
test passes against the unfixed Makefile — checked by mutation.

These three are the only keys anything reads.

## Post format

Filename **must** be `posts/<y>-<m>-<d>-<category>_<slug-words>.txt`. Everything left of
the `_` is the date and the category; everything right of it is the title slug. Exactly one
`_` per filename — neither the category nor the title may contain one. Categories may
contain hyphens (`project-ideas`). A malformed name is a parse-time `$(error)`.

So is a duplicate permalink. Because the category is not in the URL, two posts sharing a
date and title slug in different categories — `2026-08-06-home_dup.txt` and
`2026-08-06-work_dup.txt` — both want `/2026/08/06/dup.html`. `CHECKED_POST_PAGES` errors
naming both files rather than letting filename sort order pick a winner.

Three more parse-time errors guard the filename itself, so there are five rules in all and
this is the one place to find them.

**A filename may contain letters, digits, and only `-`, `_`, and `.`.** Every other ASCII
punctuation character is rejected by `BAD_CHARS`. Non-ASCII is fine, so
`2026-01-02-home_café.txt` builds, as do CJK, emoji, and uppercase slugs. This exists because
a slug containing glob characters used to publish a *different post*: `_a[b]c.txt` beside
`_abc.txt` built at exit 0 and shipped `abc`'s body, since `$<` is unquoted in the `%.staged`
recipe and the shell expanded the glob onto the neighbour before awk saw it. The set is every
ASCII punctuation character but three, closed by enumeration rather than by judging which look
dangerous — which is how `[` and `]` got through in the first place. `%` and `+` are collateral;
both built correctly before, and `%` is make's pattern-rule wildcard, so it was a landmine that
happened not to have gone off. An empty title slug (`2026-01-02-home_.txt`, which published
`build/2026/01/02/.html`) is rejected too, by the sibling of the empty-category clause.

**A filename may not contain a control character.** `CONTROL_CHAR_NAMES` greps the posts
directory under `LC_ALL=C` for `[[:cntrl:]]` — `0x00`–`0x1F` and `0x7F` — and errors naming
every offender, rendered through `cat -vt` so the bytes show as `^A`, `^?`, `^I` rather than
reaching your terminal raw. It is a separate check and not a `BAD_CHARS` clause because a
control byte cannot be an element of a make list at all, which is the same reason space and
tab are absent from that set. Before it, `_a<0x01>c.txt` built at exit 0 and published
`/2026/01/02/a\001c.html`, control byte and all.

It re-reads the directory rather than interpolating `POST_NAMES`, so unlike the date check it
has no ordering hazard, and its position above `CHECKED_POST_NAMES` is a free choice spent on
the message: a **tab** word-splits `POST_NAMES`, so checked second it died on the category
clause naming `posts/c.txt` — a file that does not exist, for a reason that is not the reason.
Checked first it names the whole file.

"Control character" here means the **bytes** `0x00`–`0x1F` and `0x7F`, not Unicode's category:
U+0085 NEL arrives as the two bytes `C2 85`, is not `[[:cntrl:]]` under `LC_ALL=C`, and builds.
That is the same line non-ASCII is already on — `café` builds — so it is consistent rather than
an oversight.

Three things still get through, and the first two share one failure mode: they die with the
fragment message the tab fix exists to cure. A **`0x0A`** — a newline inside a filename — is
invisible to a line-based grep, since `ls` prints such a name as two lines and neither matches.
A **space** is caught by no rule at all: it is not `[[:cntrl:]]`, and it cannot be a `BAD_CHARS`
element for the same reason a control byte cannot. Within the control-character class the
residual really is one byte and not a category — CR is caught and renders `^M` — but the
ruleset as a whole still has these two. Third, a **`:`** dies earlier and less helpfully, at
`.SECONDARY`'s prerequisite list, with make's own `target pattern contains no '%'`.

**`make new` writes a filename none of these rules can reject**, which is the whole reason it
exists. `make new TITLE="Installing a doorbell" CATEGORY=home` writes
`posts/<today>-home_installing-a-doorbell.txt` — a `title:` line and the delimiter `cat`ted
from `.source/splitter.txt`, nothing else — prints the path, and stops. `DATE=` backdates.
`TITLE` and `CATEGORY` are required; there is no default category and no `SLUG=` override.

Slugification is bytewise under `LC_ALL=C`: control characters and every `BAD_CHARS` member
plus `_` become spaces (`'` and `"` are deleted instead, so `Tom's` is `toms`), `A-Z` is
lowercased, runs of spaces collapse, and spaces become hyphens. The `tr` sets are derived from
`$(BAD_CHARS)` rather than retyped, so the generator strips exactly what the checker rejects.
Non-ASCII survives — `Café notes` becomes `café-notes` and `日記` stays — because the grammar
accepts it. So does `.`, so `Version 2.0 notes` keeps its dot. `CATEGORY` goes through the same
pipeline and then has its edge hyphens trimmed — `CATEGORY='-x'` writes category `x`, because
`category_slug` re-parses the filename by splitting on hyphens and a leading or trailing empty
field drops out the same way `a-`.split(`-`) drops its trailing empty string; an *interior* run
survives, so `CATEGORY='a--b'` keeps `a--b`.

It refuses, before writing anything, on: a missing `TITLE` or `CATEGORY`, a title or category
that slugifies to nothing (`!!!`), an existing file at that path, a post in another category
that already builds the same permalink, and a `DATE` that is not three runs of digits or not a
real calendar date.

Seven things to know:

- **A pre-existing malformed post blocks it.** `make new` parses the whole Makefile, so a bad
  filename already in `posts/` kills the invocation before it can write a good one. The tool
  that prevents bad names cannot run in a directory that already has one.
- **`$(…)` in `TITLE` or `DATE` is expanded by make before the recipe runs.** `make new
  TITLE='$(shell echo PWNED)' CATEGORY=home DATE=2026-05-04` runs `echo PWNED` during make's
  expansion of the recipe line — before any recipe text exists for a shell to read — and the
  *result* of that command becomes the title: `Created posts/2026-05-04-home_pwned.txt`, with
  `title: PWNED` in the front matter and `pwned` in the slug. Nothing separate is printed to
  the terminal; `$(shell …)`'s captured stdout **is** the value `TITLE` takes on. Command-line
  variables are expanded when make exports them, so no quoting in the recipe can help; it is
  the same trust level as `markdown=` in `config`. `DATE` carries the identical hole for the
  identical
  reason — `DATE='$(shell touch pwned)'` creates `./pwned` too, since `$(DATE)` is expanded by
  make inside `$(if)`/`$(call)` before any shape check runs, and the post still gets written
  dated today, because `$(shell …)` prints nothing so `$(DATE)` expands empty and the recipe's
  own `day="$${DATE:-$$(date +%Y-%m-%d)}"` falls back exactly as it would for an unset `DATE`.
  A literal `$(` in a title or date is typed by hand.
- **`DATE` is also the one input that reaches the shell as recipe text, which is a second and
  different hole from the one above.** `date_select` interpolates it, so unlike `TITLE` — which
  is read from the environment as `$$TITLE` and is safe with `"`, `'`, `` ` `` and `&` — it
  needs the `date_shape_bad` check, which runs in the `$(if)` branch that decides whether
  `date_select` is expanded at all. Before that check existed, a `DATE` of `x";>PWNED;"`
  created `PWNED` under the GNU dialect, where `date_select`'s text is `-d "<date> 00:00:00"`
  and the `"` escapes the quoted string. (A space-bearing payload does not work as a demo here:
  `date_select` rejoins whatever it split on `-` with a literal hyphen, so
  `DATE='x";touch PWNED;"'` becomes the single token `touch-PWNED` — a command that does not
  exist — regardless of the shape check. `>` needs no space to redirect, which is why the
  working payload above uses it instead.)
- **An unconfigured tree is asymmetric, and correctly so.** The default date is
  `date +%Y-%m-%d` and expands no date helper, so `make new` works with no `config.mk`;
  `DATE=` goes through `date_select` and says ``run `make setup` first``.
- **A `TITLE` long enough to overflow the filesystem's name limit fails loud, but not in this
  project's own voice.** A ~300-character `TITLE` dies with bash's own `File name too long` and
  a `make: *** [Makefile:…: new] Error 1` — safe (nothing is written) but not a
  `grampa: new:` refusal, because nothing here checks length before handing the composed name
  to the shell.
- **`CATEGORY='.'` is legal and builds a dot-hidden category page**, `build/category/..html` —
  invisible to a bare `ls` of that directory. This is not new to `make new`: a hand-written
  `posts/2026-01-02-._x.txt` builds the identical page today, on `main`, with no generator
  involved — `.` is simply a legal category slug. `CATEGORY='-.-'` reaches the same state once
  its edge hyphens are trimmed.
- **A `DATE` with an edge or doubled hyphen, an all-hyphen field, or any whitespace byte
  anywhere in it is refused, and getting that right took three tries, the third caught only by
  a scoped re-review after the second had already shipped.** `date_shape_bad` word-counts on
  hyphen boundaries, and make's word-splitting collapses a run of separators the same way
  `$(words "a  b")` is 2 not 3 — so `2026-01-02-`, `-2026-01-02`, `2026-01--02` and
  `2026--01-02` all count 3 words, indistinguishable from a clean date at that stage. Stage two
  used to erase the decoration along with the count (`$(subst -,,...)`), so all four wrote
  their raw, decorated string straight into the filename at exit 0 — one of them collided with
  an existing post's permalink and then wedged every later `make new` in the directory at parse
  time. Try one compared the digit-stripped string against the word `--` with `$(filter-out)`
  rather than erasing hyphens outright — but `$(filter-out)` is itself word-based, so on its own
  it swaps one collapse for another: a *trailing* space in `DATE` survives digit-stripping as
  `-- ` (two hyphens, one space), and `$(filter-out --,...)` treats that as the bare word `--`
  and removes it, wrongly accepting the space. Try two added `$(findstring $(space),$(1))`, a
  plain substring search against the *unstripped* `DATE` — this shipped, and was the
  regression: `$(space)` is only the literal byte `0x20`, but `$(filter-out)`'s word-splitting
  treats **every** whitespace byte as a separator — tab, CR, LF, VT, FF too — and
  `$(findstring $(space),...)` tests for none of them, so a trailing tab still slipped through
  exactly the way a trailing space had, and the write-then-wedge sequence repeated through a new
  door: a tab in a filename is a control character, which fails `CHECKED_POST_NAMES` at parse
  time on every later `make` and `make new`. The fix that actually closes it concatenates
  `$(subst -,,$(call strip_digits,$(1)))` alongside `$(filter-out)` rather than either one
  alone: `$(subst)` removes only hyphens, byte by byte, so *any* leftover byte that is neither a
  digit nor a hyphen — every whitespace flavor, or a stray letter — survives it and forces a
  non-empty (refused) result on its own, independent of what `$(filter-out)` does with the
  hyphens. (`$(subst -,,...)` alone has its own hole — `-2026-01-02-`, decorated on *both*
  edges, digit-strips to `----`, and `$(subst)` removes all non-overlapping `--` pairs in one
  pass, collapsing it straight to empty — which is why both terms run, not one in place of the
  other.) `$(findstring)` turned out to be fully redundant once `$(subst -,,...)` was in place —
  an A-B comparison across 426 mutated `DATE` shapes showed zero behavioural difference with or
  without it — and was removed. The word-count wrapper this whole check opens with is *not*
  redundant: strip an all-hyphen `DATE` like `--` of its digits and both stage-two terms already
  agree on empty, so only the wrapper's own else-branch (return `$(1)` unchanged) refuses it; a
  mutant that deletes the wrapper wrote `posts/---home_x.txt`. Leading whitespace never reaches
  any of this — make strips it from a command-line variable before the check ever runs. See the
  comment above `date_shape_bad` in the Makefile for the full derivation and the fuzz counts.

Some legal slugs are ugly and stay legal: `TITLE='.'` builds `..html`, a leading or trailing
hyphen survives, `'- - -'` gives `-----.html`. All five checks accept them.

**The date must be a real one.** `2026-13-40`, `20xx-ab-cd`, `2026-02-30`, and non-leap
`2026-02-29` are all rejected; `2026-7-4` unpadded, `26-7-4` two-digit (rendered year `0026`
under BSD, `2026` under GNU — see the portable-date gotcha), and `2028-02-29` build.
`date` already rejected these dates and exited 1 — nothing heard it, because
`date_from_filename` is a `$(shell)` call, which keeps the output and discards the status, and
the floor at the time was make 3.81, which has no `.SHELLSTATUS`. The result was a page with
an empty posted-on line and an empty `<pubDate>`. The floor is 4.2 now, which is exactly where
`.SHELLSTATUS` arrives, so a more direct rewrite has become possible — it has not been done,
and the two-stage check below is the form the suite covers.

The check is two stages. Make clears any year of one to five digits with month 1–12 and day
1–28 — valid in every month of every year, so no calendar knowledge is needed — and only days
29–31 and malformed fields are handed to `date` itself, one batched `$(shell)` per build. That
keeps it near-free: a 60-post corpus dated the 1st–28th forks zero times and costs nothing
measurable, and one deliberately loaded with month-ends (18 suspects of 66, about triple a real
calendar's share) took a no-op rebuild from 0.130s to 0.181s. Stage one *proves* rather than
judges: it must never clear anything `date` would reject, which is what the five-digit year
bound is for.

**The date check must stay below `CHECKED_POST_NAMES` in the Makefile.** Its `$(shell)`
interpolates filenames into a shell command line unquoted, so a post named
`20xx-01-02-home_x$(>PWN).txt` executes during the parse — verified, and the payload is
consumed by the shell, so even the resulting error message looks clean. The character check
rejects `$`, `(`, `)`, and the backtick first, which is the only reason that is safe. Both are
`:=`, so it is a guarantee about textual order in the file and nothing else, and it is guarded
by `test_character_error_precedes_the_date_error` rather than by the comment alone.

**`static/` filenames are checked against a different and much shorter denylist, and the
asymmetry is deliberate.** The two directories answer different questions. A post filename *is*
the metadata — it is parsed into a date, a category, and a URL slug — so it is checked as a
grammar, and every ASCII punctuation character but `-`, `_`, `.` is rejected by enumeration. A
static filename is parsed into nothing; it is a path that gets copied. So `BAD_STATIC_NAMES`
rejects only what breaks make's list or an unquoted shell word: whitespace, a control
character, and ``: % $ # \ * ? [ ] ` ( ) & ' " | ; < > =``. Everything else is legal, which is
the point — `logo@2x.png` and `style,min.css` are real asset names that break nothing, and
`!`, `+`, `,`, `@`, `^`, `{`, `}`, `~` all build (verified by creating one file per ASCII
punctuation character and running the build against each). `{`, `}` and `,` being legal is safe
only because the copy recipe single-quotes `$<` and `$@`: `static/x{1,2}y.css` publishes under
its own name rather than brace-expanding. That is true on **every** host, not only where
`/bin/sh` is bash — make runs recipes with `$(SHELL)`, and this Makefile sets
`SHELL := /bin/bash` unconditionally, so `/bin/sh` never enters it. Verified with a probe recipe
printing `$0`/`$BASH_VERSION` and by repointing `SHELL` and watching `$0` follow.

In the two places posts are *weaker*, static is stronger. A space and a `0x0A` both get through
the post rules and die later with the fragment message documented above; in `static/` a space is
a `BAD_STATIC_NAMES` element and a newline is caught by `CHECKED_STATIC_SPLIT`, a positive
existence test over `STATIC_SRC` — a denylist structurally cannot see a newline, since `find`
prints such a name as two lines and neither matches. Verified all four: `static/a b.css` and
`static/a<LF>b.css` are named by their own checks, while `posts/a b.txt` dies at
`posts/a: no category in filename` and `posts/a<LF>b.txt` at
`posts/b.txt: no category in filename` — two different fragments of the same shape of name, and
neither is the name.

The two differ because they are mangled at different stages, which is worth one sentence since a
reader who reproduces only one will otherwise write the other down wrong. `POST_LS` is
`ls posts 2>/dev/null | grep '\.txt$'`. A newline makes `ls` print the name as **two lines**, and the `grep`
then **drops the `a` line outright** — `POST_NAMES` holds `b.txt` alone, so `b.txt` is the only
thing the check ever sees. A space keeps the name one line all the way through `ls`, `grep` and
`sort` (`POST_NAMES := a b.txt`) and splits only at make's word-splitting, where `a` comes
first. Verified by reading `POST_NAMES` out of `make -p`, and confirmed from the other side: a
newline whose **both** halves end in `.txt` survives the grep intact, giving
`POST_NAMES := x.txt y.txt` and an error naming `posts/x.txt`. It is not a sort-order effect.

**Where the static checks sit in the file is load-bearing, and it is not the same constraint
posts have.** Everything in this family is `:=`, so the ordering is a guarantee about textual
order in the file and nothing else. Two rules:

The **character check must be above the first rule that expands `STATIC_PAGES`** — `build`'s
prerequisite list, then the copy rule's target list. A name carrying a space word-splits
`STATIC_PAGES`, and the copy rule is a static pattern rule, so those fragments become *targets*
of it. Verified by moving the whole check-and-guard block below the copy rule with an
`index.html x` in `static/`: make prints its own
`Makefile:…: target 'x' doesn't match the target pattern` before the real error ever arrives —
naming the fragment it was handed. The other fragment, `build/index.html`, does match the
pattern and would have been accepted as a target of the copy rule in silence; that it is in
`STATIC_PAGES` is what the guard experiment below shows independently. Above the rules none of
this is reachable: on the real Makefile no `target … doesn't match the target pattern` line
appears at all, because the `$(error)` fires while the rules are still unread. (The character
error is not the *only* output — the parse-time `grampa: markdown:` notice prints above it, as
it does on every build. The contrast is the absent make diagnostic, not an empty screen.)

The **three collision guards must be below the character check**, and this one is about the
message. That same `index.html x` contributes the word `build/index.html` to `STATIC_PAGES`, so
guards reached first report a collision on a page nothing actually claims. Verified by moving
the `GENERATED_PAGES`-and-guards block above the character check, which turns the correct
`bad character in static filename: static/index.html x` into
`static file and a generated page both build build/index.html`. A `%` corrupts the guards the
other way and more quietly: `$(s)/%` becomes a two-`%` pattern, and `$(filter build/2026%/%,…)`
matches nothing where `$(filter build/2026/%,…)` matches the post pages — a silent hole rather
than a false message. A `,` would empty the filter outright — `$(filter a,b c,a b c)` is empty,
since the comma ends the first argument — but that one is unreachable, because `$(s)` and
`$(g)` are never arbitrary: they are `build/<y>[/<m>[/<d>]]`, `build/category`, or a generated
page path, none of which can hold a comma. (An earlier claim that the *guards* had to be above
the first expanding rule was disproven by moving the block; that is not a constraint. Only the
character check has it.)

Both constraints are pinned by `test_static_character_error_precedes_the_collision_error`, and
the second one only became pinned in this fix wave: the test shipped with a `static/index:x.html`
fixture, which is bad in one way only — nothing generates `build/index:x.html`, so there was no
collision to lose the race — and it therefore passed under both orderings. With
`static/index.html x` the mutation is caught. Proved both directions.

```
posts/2026-08-06-home_installing-a-doorbell.txt   →  /2026/08/06/installing-a-doorbell.html
posts/2026-07-04-project-ideas_raspberry-pi-backup.txt
```

The category never appears in a URL.

```
title: A text title
-----------------------------------
<p>
Body of your post.
</p>
```

The delimiter line is matched by awk on the literal 35-hyphen string. Body content is
copied through as-is (HTML) unless a markdown processor was detected at `make setup` or
named by `markdown=` in `config`.

## Build pipeline

```
posts/2026-08-06-home_first-post.txt
  └─ awk split + (optional) markdown on the body only → work/2026-08-06-home_first-post.staged
        ├─ awk + templates/post.txt        → work/2026-08-06-home_first-post.tmp   (a post fragment)
        │     ├─ awk + templates/base.txt  → build/2026/08/06/first-post.html
        │     └─ cat 10 newest             → work/index.tmp
        │           └─ awk + templates/base.txt → build/index.html
        └─ awk + templates/rss-item.txt    → work/2026-08-06-home_first-post.rssitem  (only when url= is set)
              └─ cat 10 newest             → work/rss.tmp
                    └─ awk + templates/rss.txt → build/rss.xml
```

`.staged` is the shared staging step: it splits the front matter off the body, runs the body
through `$(MARKDOWN_CMD)` if there is one, and glues them back together. Both `.tmp` and
`.rssitem` are built from the same `.staged` file, so the processor runs once per post no
matter how many consumers read the result. Its prerequisites are the post, `config`, and
`$(wildcard config.mk)` — the last two are what make a changed `markdown=` or a re-detected
processor re-stage everything, instead of the old "looks like it did nothing" behaviour.

### Markdown detection

`MARKDOWN_CANDIDATES` is a `define` block of `probe|argv` lines — twelve of them, in
preference order: tables first, runtime-free first, `Markdown.pl` last. Field 1 is what
`setup` probes (a name found via `command -v`, or, if it contains a slash, a path tested with
`[ -x ]`), field 2 is the whole command line recorded on success. Recording field 1 would
lose the flags, and the flags are not decoration — see the raw-HTML gotcha below.

`setup`'s recipe walks the table and writes the winner to `config.mk` as
`DETECTED_MARKDOWN := <argv>`. It is one `; \`-continued logical line, because each recipe
line is its own shell and `dialect` and `winner` have to survive to the write; the `while`
loop runs in a subshell, so the winner is `echo`ed out of the pipeline and captured rather
than assigned. The probe is a real render, not a `--version` check: each candidate is run
against a freshly written `x <i>y</i> -- z` and has to exit 0, keep the `<i>`, keep the `--`,
and *not* return a whole `<html>` document. That is what catches a flag that turns out to be
wrong on the host — including for `comrak`, `multimarkdown` and `markdown-it`, whose rows were
never executed during development and whose flags are inferred from family behaviour rather
than observed. The probe file is rewritten **inside** the loop, per candidate: a candidate
that truncates a shared file would make every candidate behind it fail the `<i>` check on
empty input.

The `--` check exists because the `<i>`/document checks say nothing about typography: a
candidate whose smartypants flag is wrong passes both and quietly rewrites every post's `--`
into an en dash. It checks the **dash only**, never the quote. `cmark`, `cmark-gfm` and
`md2html` HTML-escape a `"` to `&quot;` in text content — that is escaping, not smartening,
and it renders identically — so a literal `"` assertion would reject all three of those good
processors. The dash has no such false positive among the candidates measured. The residual:
a processor that smartens quotes but leaves `--` alone would still pass. No row in the table
is known to do this — the claim that Python-Markdown's `smarty` extension behaves this way is
from its documentation, not from an observed probe run, since the table's `markdown_py` row
does not enable that extension.

`setup` writes a per-process scratch file (`config.mk.$$$$`) and `mv`s it only when `cmp`
says the content changed, so a no-op `make setup` does not bump the mtime — without that,
every setup would re-stage every post, `config.mk` being a staging prerequisite.

`.tmp` files are rendered post fragments and are the unit of reuse: the per-post page and
the index are both just a `base.txt` wrapper around one or more `.tmp` files. `.rssitem`
files are the feed's equivalent — one `<item>` per post, wrapped in `rss.txt` the same way
`.tmp` fragments are wrapped in `base.txt`. Both kinds live in `work/`. `.tmp` and `.staged`
are kept between builds via `.SECONDARY` — without that, make would treat them as
pattern-rule intermediates and delete them, forcing a full rebuild every time. `.rssitem`
files need no such entry: `RECENT_ITEMS` names them as explicit prerequisites of the
explicit target `work/rss.tmp`, and make only reaps files it never sees mentioned. Listing
them in `.SECONDARY` anyway is now unnecessary rather than harmful — see the comment above
`.SECONDARY` in the Makefile for why that changed.

The `%.html` rule names each page's own fragment as a prerequisite via `.SECONDEXPANSION`:
the stem of `build/2026/08/06/first-post.html` is `2026/08/06/first-post`, and
`$$(call tmp_for_page,$$*)` resolves that to `work/2026-08-06-home_first-post.tmp`. One page
depends on one fragment, which is what makes per-post incremental builds possible. Why that
resolution is a search rather than a substitution is covered below, after the category
pages.

Category pages are a third consumer of the same fragments:

```
work/2026-08-06-home_installing-a-doorbell.tmp
  ├─ awk + templates/base.txt → build/2026/08/06/installing-a-doorbell.html
  ├─ cat 10 newest            → work/index.tmp → build/index.html
  └─ awk over all fragments in the category → build/category/home.html
```

The category page rule takes its fragments as multiple awk input files, so it needs no
intermediate `.tmp` the way the index does. Its fragment prerequisites are exact, because
`CATEGORY_SLUGS` is derived from filenames at parse time. `posts` (the directory) is an
additional prerequisite on top of those exact fragments, and it is deliberately coarse: any
change to the post set is a change to `posts`'s mtime, so deleting a `home` post rebuilds
`build/category/work.html` too, not just `build/category/home.html`. That over-triggering is
what lets a deleted post's fragment disappear from its own category page — **unless the
deleted post was that category's last one**, in which case `CATEGORY_SLUGS` no longer names
the category at parse time, `build/category/home.html` is not a target at all, and nothing
rebuilds it; the page fossilises with the deleted post's body and link still in it. See the
"Deleting a post" and "Renaming or deleting a category" gotchas below.

Because the category is in the filename but not the URL, a page cannot be mapped back to its
fragment by turning slashes into hyphens — the stem `2026/08/06/first-post` has no way to
know the fragment is `2026-08-06-home_first-post.tmp`. That substitution *was* the mechanism
before categories moved into filenames. `tmp_for_page` searches `TMP_FILES` instead, which
is O(posts) per target and so O(posts²) per build — fine at blog scale, fixable with
`$(eval)`-generated explicit rules if it ever drags.

**`build/category/%.html` is defined above the `%.html` rule, and that used to be
load-bearing.** Both rules match `build/category/home.html`: `tmp_for_page` returns empty for
a category stem (there is no single fragment a category page maps to), and an empty
prerequisite list is trivially satisfiable. On GNU make 3.81 the winner was the first
matching rule in makefile order, not the shortest stem, so a `%.html` defined first claimed
the category page and produced a nested `base.txt`-wrapped document with the wrong title and
no error.

**Make 3.82 changed the choice to shortest stem first**, and the competing stems are `home`
against `category/home`. Since the floor moved to 4.2 (see the requirement gotcha below) the
category rule wins from either position — verified by moving it below `%.html`, where 3.81
fails the build and 4.4.1 renders the category page correctly. The order is kept because
specific-before-generic reads better, not because it is required.

Do not generalise "shortest stem first" into a containment argument for anything else. Stem
length only *orders* make's trial of implicit rules; which candidate is accepted is decided by
its prerequisites. The `static/` copy rule is where that difference bites — see the
static-pattern-rule gotcha below.

Two things backstop it regardless: the version guard keeps 3.81 out entirely, and **each of
the two rules carries its own unknown-page guard**, so a stem no post maps to is a loud
failure whichever rule claims it —

```
build/category/typo.html: no post in posts/ builds this page
make: *** [build/category/typo.html] Error 1
```

The category rule's copy is not redundant with the `%.html` one added in `d96a855`, which is
the mistake that left it missing for so long: shortest-stem selection means this rule *always*
claims a `build/category/…` target above the floor, so the `%.html` guard is never the one
asked about a category path. Without its own, `tmp_files_in_category` came back empty, the
prerequisite list was trivially satisfiable, and `awk` ran with **zero file operands** — an
empty `base.txt`-wrapped page at exit 0, or a wait on stdin when stdin was a terminal. Guarded
now by `test_unknown_category_page_target_fails_cleanly`, which is a separate test from
`test_unknown_page_target_fails_cleanly` for exactly the reason above.

`build/rss.xml` is a fourth consumer, gated on `SITE_URL`: `FEED_PAGES` is
`$(BUILD_DIR)rss.xml` when `url=` is set in config and empty otherwise, so with no `url=`
the feed — fragments included — simply is not built, and `build`'s recipe prints a skip
note. `RECENT_ITEMS` takes the same newest-ten window of `.rssitem` files that
`RECENT_FILES` takes of `.tmp` files for the index, concatenated into `work/rss.tmp` and
wrapped in `templates/rss.txt`.

`static/` is a fifth thing `build` names, and the one output with no fragment behind it — the
only page in `build/` grampa did not generate. It has no pipeline to draw:

```
static/style.css      → build/style.css
static/img/logo.png   → build/img/logo.png
```

`STATIC_LS` is `find static/ \( -type f -o -type l \) 2>/dev/null | sort`, `STATIC_SRC` is that
shell call, and `STATIC_PAGES` is `$(patsubst static/%,$(BUILD_DIR)%,$(STATIC_SRC))` — all `:=`,
since nothing here needs a recipe to have run first. `STATIC_SRC` is read by exactly two things:
`STATIC_PAGES`, from which the prerequisite list and all three collision guards descend, and
`CHECKED_STATIC_SPLIT`. The character and type checks read the *listing*, not the list, because a
name containing a space cannot be an element of a make list at all.

The trailing slash on `find static/` is load-bearing: it traverses a `static` that is itself a
symlink to a directory. Without it `find` prints the symlink and `patsubst` leaves that word
alone, so `STATIC_PAGES` acquires the literal word `static` and the build copies nothing at exit
0 — not quite silently, since `static` does not match the copy rule's `$(BUILD_DIR)%` target
pattern and make prints one `target 'static' doesn't match the target pattern` line before
carrying on. That line names neither `static/` nor the assets that vanished. (It *was* silent
under the plain pattern rule the first two drafts used; both forms reproduced, and the stale
"and said nothing" claim is item 14's shape again.)

`\( -type f -o -type l \)` rather than `-type f`, so a symlinked *file* is still copied — and
rather than the `! -type d` this shipped with through Task 5, which admitted every other file
type there is. A FIFO in `static/` made `cp static/pipe build/pipe` block on a writer that never
comes and **the build hung forever**, serially and under `-j8`. Anything the predicate now drops
is named by `CHECKED_STATIC_TYPES`, a parse-time error, rather than skipped in silence; that
check uses `find -L`, so a symlink *to* a FIFO — which hangs `cp` identically — is caught too.
The other two symlink shapes are left alone and both still fail loud: a symlink to a directory
at `cp: -r not specified`, and a dangling one at make's own `No rule to make target
'static/dangle.css'`, before `cp` runs. Pinned by `test_fifo_in_static_does_not_hang`.

`2>/dev/null` is what lets a tree with no `static/` at all build clean — verified: `rm -rf
static && make` exits 0. `static/` has no rule that creates it, unlike `posts`; nothing
downstream requires it to exist.

There is no reverse map and none is needed: the copy rule is a **static pattern rule** over
`STATIC_PAGES`, so each target's one prerequisite comes straight from the stem. Deleting a
static file leaves its copy in `build/` — an untracked output, exactly the deleted-post case,
and `make clean` is what removes it. Verified: `rm static/robots.txt && make` exits 0 with
`build/robots.txt` still there; `make clean && make` clears it.

- `templates/post.txt` — `{{title}}` `{{body}}` `{{pub_date}}` `{{permalink}}` `{{category}}`
  `{{category_url}}`
- `templates/base.txt` — `{{main}}` `{{page_title}}`
- `templates/rss.txt` — `{{title}}` `{{link}}` `{{description}}` `{{items}}`
- `templates/rss-item.txt` — `{{title}}` `{{link}}` `{{pub_date}}` `{{category}}` `{{body}}`

Substitution goes through the awk `fill()` helper, **not** `sub()`. `sub()` treats `&` in
the replacement as "the matched text", so a post titled `Tom & Jerry` rendered as
`Tom {{title}} Jerry`. `fill()` uses `index()`/`substr()` and has no such magic. Like
`sub()` it replaces only the **first** `{{key}}` on a line, so a placeholder used twice on
one line expands once.

**`fill()` rescans the line it just composed, so the order of the calls is load-bearing.**
Anything substituted early is itself searched for the placeholders substituted after it, so
author-supplied text goes in **last** in all four programs: derived values first, then
`title`, then `body`/`main`/`items`. Before this, a post whose body mentioned
`{{permalink}}` — a post about grampa's own template syntax — published the real URL in
place of the example, and a `name=` containing `{{link}}` took the site URL.

What the ordering does **not** close: whatever is filled last is still injectable into
everything filled before it. This needs no template line carrying both markers — every
`fill()` runs on every line, so the `title` fill puts `{{body}}` into the `<h4>` line and the
`body` fill consumes it there. Verified against the stock `post.txt`, where `{{title}}` and
`{{body}}` are on different lines. Reproduced siblings, same class: a title containing
`{{main}}` puts the whole rendered fragment in the page's `<title>`; the same title/`{{body}}`
leak fires in the feed via `RENDER_ITEM`; and a `url=` containing `{{title}}` puts the post
title inside every *item's* `<link>` and `<guid>` — but not the channel `<link>`, which
`WRAP_IN_CHANNEL` fills first and which therefore takes the blog name instead. Closing these needs a single-pass fill that never
rescans a substituted value, which would also drop the first-`{{key}}`-only behaviour above;
deferred, since the body is the large author-controlled blob and is now closed. Guarded by
the four `test_placeholders_*` tests.

### awk programs

Five awk programs live in `define` blocks (`RENDER_POST`, `RENDER_ITEM`, `WRAP_IN_BASE`,
`WRAP_IN_CHANNEL`, `SPLIT_STAGED`) that are `export`ed and invoked as `awk "$$RENDER_POST"`.
The first four share `fill()` by interpolating `$(FILL_FN)`. Passing the program through the
environment rather than inlining it means awk source doesn't have to survive shell quoting,
and it avoids the `\`-continuation-per-line style the rest of a Makefile forces. Note that
awk's `$0` is still `$$0` inside a `define`.

`RENDER_ITEM` is `RENDER_POST`'s counterpart for `templates/rss-item.txt`, and
`WRAP_IN_CHANNEL` is `WRAP_IN_BASE`'s for `templates/rss.txt`. `RENDER_POST` and
`RENDER_ITEM` share the same front-matter parse (`PARSE_FRONT_MATTER`, interpolated into
both), since both read the same post format; `WRAP_IN_BASE` and `WRAP_IN_CHANNEL` have no
such shared piece to factor out, since wrapping a fragment in a template has nothing left to
parse. In neither pair does rendering/wrapping and escaping merge into one generic program
with an escape flag: HTML pages must not escape a post's body or title and the feed must, and
a general templating engine is deliberately deferred until there is more than this one
duplication to design it from. `xml_escape()` (`$(XML_ESCAPE_FN)`) does the escaping and is
interpolated into `RENDER_ITEM` and `WRAP_IN_CHANNEL` only — `fill()` itself never escapes.

`SPLIT_STAGED` is the odd one out twice over: it is the only program that writes files rather
than stdout, taking `-v head=` and `-v body=` and routing each line of a post to one or the
other, and the only one that neither fills a template nor is passed one. It recognises the
same delimiter as `PARSE_FRONT_MATTER` and shares no code with it — that one accumulates a
title and a body into variables for a renderer, this one keeps no state but `seen` — and
factoring the two together would couple the staging step to the renderers to save one regex.
Only the *first* delimiter splits; later ones are body text. Its `END` block is load-bearing
rather than tidy, and in both directions: awk creates a redirect's file on first write, so
without it a post with no body leaves no body file for the processor to be handed, and a post
whose delimiter is on line 1 leaves no head file for the reassembly `cat`. It replaced `split -p` and a
pair of globs, which is the subject of the two closed glob items in `docs/backlog.md`.

The blog name reaches awk the same way: `BLOG_NAME` is `export`ed by make and each recipe
composes `PAGE_TITLE` in the environment, which `WRAP_IN_BASE` reads via
`ENVIRON["PAGE_TITLE"]`. Nothing is interpolated into a shell string, so a blog name or post
title containing `"`, `'`, `$`, or `&` can't break the build. `SITE_URL` is exported the same
way, and `WRAP_IN_CHANNEL` and `RENDER_ITEM` read it via `ENVIRON["SITE_URL"]` to build the
feed's `<link>` elements.

### Make helper functions

The top of the Makefile defines string helpers because make has no real string library:
`reverse`, `space`, `date_words`, `date_select`, `date_from_filename`,
`rfc822_from_filename`, `underscore_split`,
`date_and_category`, `title_slug`, `post_slug`, `dc_words`, `category_slug`,
`category_display`, `category_url`, `check_post_name`, `path_from_filename`, `page_for`,
`files_for_page`, `check_page_collisions`, `tmp_for_page`, `post_for_page`,
`html_post_files`, `tmp_files_in_category`. They all operate on post
filenames by `subst`-ing hyphens (and, since categories moved into the name, underscores)
into spaces and using `wordlist`. Filenames are the only metadata store for dates,
categories, and URLs — there is no index or database.

`rfc822_from_filename` is `date_from_filename`'s counterpart for the feed's `<pubDate>`,
which RFC 822 requires in a specific format (`date`'s `%a, %d %b %Y %H:%M:%S %z`, e.g.
`Thu, 06 Aug 2026 00:00:00 -0700`). See the Gotchas below for the two things that make it
more than a format-string swap.

## Gotchas

- **The floor is GNU make 4.2, enforced by a `$(MAKE_VERSION)` guard at the top of the
  Makefile.** It was 3.81 — what macOS ships, being the last release before the license
  change — and that claim was false rather than merely conservative: the suite fails on 3.81.
  **3.81 silently voids `.DELETE_ON_ERROR` for any target named in `.SECONDARY`,** which here
  is every `.tmp` and `.staged` file, so a failed awk pass leaves its half-written fragment on
  disk, newer than its prerequisites, and the *next* build wraps that empty fragment in
  `base.txt` and exits 0. Verified end to end: after one unreadable `templates/post.txt`, 3.81
  publishes a post page with an empty body where 4.4.1 rebuilds it correctly. Isolated to
  `.SECONDARY` in a six-line makefile and fixed in 3.82. **Make 4.0 is excluded separately** —
  it hangs or segfaults during the parse on a post filename containing a 4-byte UTF-8
  character, which is to say an emoji slug, of the kind the character check deliberately
  allows; fixed in 4.1. 4.2 rather than 4.1 because 4.2 is where `.SHELLSTATUS` arrives and
  nothing between them is a floor anyone ships. The suite *as it stood before the guard*
  was run against builds of 3.81, 3.82, 4.0, 4.1, 4.2, 4.2.1 and 4.3: 353/353 everywhere
  except 3.81 (352, one `.DELETE_ON_ERROR` failure) and 4.0 (the crash). That run is recorded
  rather than repeatable — every binary below the floor now dies at the guard before a test
  can run. The guard is **not** gated on `BUILD_GOAL`, unlike the `config.mk` guards it sits
  above, because there is no deadlock to avoid: the fix is a newer make rather than a recipe
  in this file, so `clean`, `setup` and `test` have nothing to offer an old make either. Do
  not add that gate later — `BUILD_GOAL` is defined *below* the guard, so an
  `$(if $(BUILD_GOAL),…)` there reads it empty and disables the guard outright instead of
  narrowing it. The filter also carries `4.0.%` and `4.1.%` for prereleases like `4.0.90`,
  which predate the emoji fix; no release ever used a third component below 4.2. Three tests
  pin all of this by overriding `MAKE_VERSION` on the command line, which needs no old binary
  on the host.
- **The suite drives `$MAKE`, not a bare `make`, and `make test` passes `$(MAKE)` in.** Make
  does not export `MAKE`, so without that the suite would ignore which make invoked it. On a
  Mac that is the difference between `gmake test` testing gmake and it testing Apple's 3.81 —
  which, since the floor moved, would not mean "the suite runs on 3.81" but "every single test
  dies at the version guard". `tests/run.sh` checks the floor up front by running the real
  Makefile's own guard (no second copy to drift) and exits after one line rather than several
  hundred. `MAKE=/path/to/make ./tests/run.sh` is also how you run the suite against a
  specific build.
- **`POST_NAMES` is sorted with `sort -t- -k1,1n -k2,2n -k3,3n`**, not `$(wildcard)`,
  because wildcard sorts as strings and would put `2026-10-1` before `2026-7-4`. The
  numeric sort makes ordering correct for padded *and* unpadded dates. Zero-padding is
  still worth doing for the URLs' sake — an unpadded post becomes `/2026/7/4/slug.html`.
  It is `:=`, so that pipeline runs once per build rather than once per expansion — the
  `%.html` rule's second-expanded prerequisites reach `tmp_for_page` twice per page, once
  directly and once through `post_for_page`, which had it shelling out O(posts) times:
  counted at 131 runs for a 60-post no-op rebuild, against 1 now.
  The lazy-`config` reasoning in the bullet below does *not* apply to it: a missing
  `posts/` is already handled by `2>/dev/null`. Measured on a 60-post no-op rebuild:
  0.79s → 0.12s, with `build/` and `work/` byte-identical either way.
- **Portable across BSD and GNU, chosen at `make setup`.** `date_select` has one twin per
  dialect — BSD's `-v<y>y -v<m>m -v<d>d` selectors, GNU's `-d "<y-m-d> 00:00:00"` — and `make
  setup` probes `date(1)` once and writes the winner to a generated `config.mk` (`DATE_DIALECT
  := bsd|gnu`) that the Makefile `-include`s. All three date sites (`date_from_filename`,
  `rfc822_from_filename`, the parse-time `BAD_POST_DATES` check) share `date_select`, so the
  check still runs the exact args the build runs. A build on a tree with no `config.mk` fails
  loud — see the "unconfigured build" bullet below. The one behavioural difference between
  dialects: a two-digit-year filename like `26-7-4-home_x.txt` renders its *displayed* date as
  year `0026` under BSD but `2026` under GNU; the URL is `/26/7/4/x.html` either way, since
  paths come from the raw filename, not `date`. Edge case, documented not fixed.
- **An unconfigured build fails loud at recipe time, and `make setup` always bootstraps.** With
  no `config.mk`, `$(DATE_DIALECT)` is empty and `date_select`'s else branch is an `$(error)`
  whose message reads, backticks and all: grampa: no DATE_DIALECT -- run `make setup` first.
  Two things keep this loud
  without deadlocking `setup`: `setup`'s own recipe writes `config.mk` without expanding any
  date helper, and the parse-time `BAD_POST_DATES` check is gated `$(if $(DATE_DIALECT),...)` so
  it does not run — and so does not expand `date_select` — while unconfigured. The `:=` check
  would otherwise expand `date_select` at parse time on a month-end post during `make setup`
  itself, `$(error)`ing before the recipe writes `config.mk`: a deadlock (can't build without
  it, can't `setup` to make it). Gated, the failure is uniform — every unconfigured build dies
  at recipe time on the first dated page's `date_from_filename`, before any page is written —
  and `make setup` succeeds for any corpus. The gate skips the check, it does not disable it: a
  configured build runs it exactly as before. This is the upgrade path for an existing BSD
  install: pull the new Makefile → first `make` says "run `make setup` first" → `make setup`
  (which only *adds* `config.mk`, clobbering nothing else, and now never deadlocks) → builds
  resume.
- **`config` is read lazily, not at parse time.** `CONFIG_NAME`, `CONFIG_URL` and
  `CONFIG_MARKDOWN` all use `=`, not `:=`, because on a first-ever run the `config` target
  hasn't copied the file into place yet when the Makefile is parsed. `config` is also a
  prerequisite of the HTML rules, of `%.rssitem`, and of `%.staged`, so changing `name=` or
  `url=` rebuilds every page or every feed item, and changing `markdown=` re-stages every
  post. `name=`, `url=` and `markdown=` are the only keys anything reads; the last of each
  wins, and an absent or empty `name=` falls back to `Grampa`.
- **A `url=` that only exists by the time `config`'s recipe runs is one build too late for
  the feed.** `FEED_PAGES` gates `build/rss.xml` and is expanded when `build`'s prerequisite
  list is read — during the initial parse, before any recipe (including `config`) has run.
  So on a first-ever `make` where `config` doesn't exist yet and gets created with `url=`
  already set as part of that same invocation, `FEED_PAGES` was already fixed at empty and
  no feed gets built. The skip note doesn't print either: it is a recipe-time shell test
  (`if [ -z "$$SITE_URL" ]`) that runs after `config` exists, so by then `SITE_URL` is
  non-empty and the "no url=" condition looks false. One silent run with neither a feed nor
  a message; the next `make` re-parses the Makefile with `config` already in place and picks
  it up. This is the same lazy-parse-time-vs-recipe-time split as the bullet above, just
  landing on a prerequisite list instead of a recipe body.

  Since `deploy: all`, that first-ever invocation can now be `make deploy`, which **ships** the
  feedless site — still at exit 0 and still with no skip note. It is the same gotcha through a
  new front door rather than a new one: the old two-command `make && make deploy` shipped the
  identical feedless output. It needs a `.source/config.example` customized with `url=`, so it
  is narrow. The second `make deploy` re-parses with `config` present and ships the feed — and
  that is an improvement on the old form, where a bare second `deploy` re-shipped the first
  build's feedless output. `STATIC_PAGES` has since joined this family through the same door —
  see the stock-stylesheet bullet below, where `make setup deploy` on a virgin tree ships pages
  linking a `/style.css` that the same invocation had not yet copied.
- **Categories come from filenames, not front matter.** `CATEGORY_SLUGS` is
  `$(sort $(foreach …))` over `POST_NAMES`, so discovering them needs no shell and no
  reading of post contents. Renaming a category means renaming files — see
  `tools/migrate-categories.sh` for the pattern. That script's slug filter is `a-z0-9-`, which
  is narrower than what the Makefile accepts: a non-ASCII category like `Café` is a legal
  filename here but would slugify to `caf`, so the script **refuses** it and says to rename by
  hand rather than silently dropping the character. Stripping ASCII punctuation is intended and
  stays silent — the filename rules reject it anyway.
- **Renaming or deleting a category leaves its old page in `build/`**, same as deleting a
  post. This happens whenever a category's *last* post goes away — `CATEGORY_SLUGS` is
  derived from the filenames that exist at parse time, so a category with no posts left is
  simply not in the target list, and nothing rebuilds or removes its page. The fossil is not
  inert, and deletion and renaming leave it pointing at two different things. Delete that
  last post and the fossil's link goes to a page that is itself now orphaned — the same dead
  end described in the "Deleting a post" gotcha below. Rename it instead — the
  `tools/migrate-categories.sh` pattern — and the post keeps the exact same URL, since the
  category is not part of it: the fossil's link points at a page that still exists, still
  renders, and is live, just filed under its new category now. `make clean` clears the
  fossil in either case.

  That is the case where the category empties out. Renaming a single post out of a category
  that still has others left in it is a different case and no longer stays wrong indefinitely:
  the same `posts` prerequisite that heals deletion (below) makes both the old and the new
  category page correct themselves on the very next `make` — verified against a pre-`posts`-
  prerequisite tree, where neither ever healed, across any number of rebuilds. One page still
  lags: after an `mv`/`git mv` rename the post's own permalink page takes one extra `make` to
  notice its new category. `tools/migrate-categories.sh` does not have that lag. The mechanism
  is written up in `docs/backlog.md` item 13 and deliberately not repeated here — three
  attempts to compress it into this bullet each produced a claim that turned out to be false.
- **Deleting a post still leaves its own page behind in `build/`.** Nothing knows the old
  page existed — an untracked output, the same shape as the deleted-category gotcha above —
  and `make clean` is still what removes the file itself. What usually no longer lingers is
  everything that *links* to it: the index, the post's own category page, and the feed all
  drop a deleted post on the very next `make`, because `posts` (the directory) is a
  prerequisite of `work/index.tmp`, every `build/category/%.html`, and `work/rss.tmp` — and
  that prerequisite is coarse on purpose: **any** entry created or removed in `posts/` moves
  the directory's mtime, not only a `.txt` post, so an editor's swap file or any other
  unrelated entry appearing or disappearing there triggers the same rebuild of all three
  targets, regardless of window position or `.rssitem` history, each rebuilding from the post
  set actually on disk. It is one cheap, self-healing rebuild and the next build is quiet
  again. The one exception is the post's own category page when the post was that category's
  **last** one: `build/category/%.html` is only a target for a category `CATEGORY_SLUGS`
  still names, so deleting a category down to zero posts is the "leaves its old page in
  `build/`" case just above, not this one — the category page fossilises with the deleted
  post's body and link intact, and only `make clean` clears it. Barring that case, this
  closes the old feed condition entirely: it used to heal only when the newly-in-window
  post's `.rssitem` was missing, and never with ten or fewer posts; it now heals every time,
  including both of those cases.
- **Removing `url=` from `config` leaves a stale `build/rss.xml` behind**, same class as the
  two gotchas above — nothing deletes a page whose config went away, and `make deploy` would
  happily ship the stale feed. `make clean` fixes it.
- **The copy rule is a static pattern rule, and the reason is not style.** A static pattern rule
  is an **explicit** rule for exactly its listed targets, and an explicit rule beats a pattern
  rule on every version of make. A plain `$(BUILD_DIR)%` pattern rule is not explicit, and on at
  least one supported version it loses a page to a static twin — silently, at exit 0. So: **the
  three collision guards are the sole containment on every supported version**, 4.2 through 4.4
  alike. They are not a backstop to a rule-selection argument; there is no rule-selection
  argument to back up.

  The **mechanism** behind that is version-dependent even though the conclusion is not: which
  candidate make's first implicit-rule pass accepts is decided by the candidate's
  prerequisites, and where make draws that line moved in 4.4, which inverts the winner for
  grampa's own rules. The full argument — the four-case table probed on 4.2.1, 4.3 and 4.4.1, a
  description of the two-rule reproduction, and the end-to-end confirmation that 4.4.1 ships the
  impostor while 4.3 renders the real page — is written up in the comment above the copy rule
  in the `Makefile`, and deliberately not repeated here. That comment is the copy nearest the
  code; this one had been the second of three, and R-1 of the branch review is what a
  three-copy argument costs — one copy re-run, two left asserting something that had stopped
  being true. (The third copy is in the design spec, which is a record of its moment and stays
  as written.)

  One consequence is worth having here rather than only there, because it is about this
  repo and not about make: the plain form also broke a legal, non-colliding
  `static/about.html`, which `%.html` claimed and then failed with a message about posts —
  `/about.html` and the `/404.html` GitHub Pages wants both died that way. That half is
  version-independent, reproduced identically on 4.3 and 4.4.1, and both pages publish fine
  under the static pattern rule.
- **`GENERATED_PAGES` is hand-maintained, and a future page type that forgets to join it
  silently reopens every collision the three guards close.** It is written out longhand —
  `index.html`, `rss.xml`, the post pages, the category pages — because nothing in the Makefile
  enumerates "what `build` produces". Verified by dropping `$(CATEGORY_PAGES)` from it: a
  `static/category/home.html` impostor then overwrote the real category page at exit 0, and put
  the error back the moment the term was restored. `rss.xml` is listed **unconditionally**,
  not through `FEED_PAGES`, so `static/rss.xml` is refused even with `url=` unset — a gated
  check would accept the file today and break the build on the day `url=` gets set, weeks after
  the cause. Verified both.
- **The guards compare byte-exactly, and on a case-insensitive filesystem that is a hole.**
  `$(filter)` is neither case-folding nor Unicode-normalizing. On a case-sensitive filesystem
  that is exactly right. On APFS's default — and this project treats macOS as first-class, via
  its BSD `date` dialect — `static/Index.html` does not match `build/index.html` here, so no
  guard fires, yet the two paths name **one** inode: two rules write the same file and which
  content survives is order-dependent, at exit 0. An NFD/NFC twin of a non-ASCII name
  (`café.html` spelled two ways) is the same hole through the same mechanism. **It is not
  new.** Two post slugs differing only in case already evade `CHECKED_POST_PAGES` identically —
  verified on Linux: `2026-08-07-home_dup.txt` and `2026-08-07-work_Dup.txt` both build and
  publish, as `dup.html` and `Dup.html`. Documented rather than cured, because a case-folding or
  normalizing comparison would reject `static/Index.html` on Linux, where it is a legal filename
  that collides with nothing — verified there too: it publishes as `build/Index.html` beside
  `build/index.html`.
- **The stock stylesheet is one build late when `setup` shares an invocation with a build.**
  `STATIC_SRC` is a `:=` `$(shell find static/ …)` snapshotted during the parse, before
  `setup`'s recipe has copied `.source/static/style.css` into place — so `STATIC_PAGES` is
  already fixed at empty for that run. The newly-copied `templates/base.txt` *does* carry the
  `<link rel="stylesheet">`, so the pages of that first build reference a `/style.css` that was
  not published. The next plain `make` re-parses and copies it. Verified on a virgin tree for
  both `make setup all` and `make setup deploy`: exit 0, `build/` holding `index.html` alone
  with one `style.css` reference in it, and `build/style.css` appearing on the following `make`.
  Through `deploy` that means a shipped site whose pages link a stylesheet that is not there —
  the same lazy-parse-time-vs-recipe-time family as the `url=`/`FEED_PAGES` bullet above,
  reaching a different variable through the same `deploy: all` front door, and self-healing on
  the next build the same way.
- **A markdown processor is optional, and installing one needs a `make setup`.** Detection
  runs once, at setup, and is recorded in `config.mk`; no build ever looks at `PATH` again.
  So a newly installed processor does nothing until `make setup` re-probes — but once it has,
  a plain `make` re-stages every post, because `config.mk` and `config` are prerequisites of
  `%.staged`. That **closes** the old gotcha here, which was that adding `Markdown.pl` did not
  invalidate `.staged` and the fix looked like it did nothing until `make clean`. Verified
  both halves: a plain `make` after installing a processor still stages verbatim; `make setup`
  then a plain `make` re-stages, with no `clean`. `Markdown.pl` itself is still optional and
  gitignored, is still the last candidate in the table, and still has to be executable — it is
  probed with `[ -x ]`, being the one row with a slash in it.
- **The `--unsafe`-family flags in the candidate table are load-bearing, not tuning.**
  `cmark`, `cmark-gfm`, `lowdown`, `comrak` and `markdown-it` all **refuse to pass raw HTML
  through** by default — verified on this host, `lowdown` deletes it outright and
  `cmark`/`cmark-gfm` replace it with `<!-- raw HTML omitted -->`; `markdown-it`'s CLI
  escapes it into visible text instead, a different symptom of the same default — which would
  silently drop, or expose the source of, an embedded `<iframe>` in a post. Grampa copies bodies through
  as raw HTML when there is no processor at all, so these flags restore existing behaviour
  rather than relaxing anything. `lowdown` and `discount` also smarten punctuation by default,
  rewriting the author's quotes and dashes; hence `--out-no-smarty`, `-smarty`, and pandoc's
  `-smart`. This is why the table records field 2 and not field 1, and why the probe checks
  the `<i>` survives rather than just checking the exit status. An argv in the table must
  contain no `#` or `$`, which would truncate or misparse the `config.mk` line it is written
  into. A candidate that is *found* but then rejected by one of these checks is now named on
  stderr with its reason — `grampa: setup: lowdown: smartens punctuation`, or `not runnable`,
  `emits a whole document`, `drops raw HTML` for the other three — instead of falling through
  in silence to a winner the user did not expect. A candidate not found at all (`command -v`
  or `[ -x ]` miss) stays silent, on purpose: those misses are the common case, and naming all
  eleven on a machine with one processor installed would print eleven lines on every setup. The
  prefix is `grampa: setup:` and deliberately not `grampa: markdown:` — that prefix belongs to
  the build notice, and `test_clean_and_setup_print_no_notice` asserts it is absent from
  `make setup`'s output. One cosmetic consequence for the suite: `hide_markdown_tools` installs
  executable exit-1 stubs for all eleven candidates, and `sandbox()` itself runs `make setup`
  once against them (output discarded), so in every test that call finds, probes, and rejects
  all eleven as `not runnable` — up to eleven such lines on stderr, just not printed anywhere.
  Two tests, `test_probe_rejects_a_smartening_candidate` and
  `test_setup_names_a_rejected_candidate`, then overwrite the `lowdown` stub with `path_stub`
  and run `make setup` a **second** time, with the stub now exiting 0 and rewriting `--` to
  an en dash — a real (if narrow) markdown processor rather than a non-runnable one. (Only
  `test_setup_names_a_rejected_candidate` captures that second run's output for assertion;
  the other test's second run is discarded too, same as the first.) It is only that second
  setup run, and only for `lowdown`, that reads `smartens punctuation`; the other ten
  candidates, and `lowdown` itself on the first, hidden run, still read
  `not runnable` throughout. Harmless either way (`sandbox()` redirects
  them, and `markdown_stub` only surfaces output on failure) and worth knowing before someone
  reads it as a regression.
- **An install that predates detection fails loud, and the guard is gated on `BUILD_GOAL`.**
  Such a tree has a `config.mk` holding only `DATE_DIALECT`. Nothing else would notice:
  `DATE_DIALECT` is set, so the loud date check is satisfied, and `DETECTED_MARKDOWN` is
  merely *undefined* — markdown silently turns off, already-staged posts keep their rendered
  bodies while the next edited post stages verbatim, and the site goes **mixed** at exit 0.
  `$(origin DETECTED_MARKDOWN)` is what makes the check precise: an old `config.mk` gives
  `undefined` while a new one where detection found nothing gives `file`, though both expand
  empty — so a legitimately processor-less install never trips it. The `BUILD_GOAL` gate is
  load-bearing rather than symmetry with the build notice: the error says to run `make setup`,
  and `setup` parses this same Makefile, so without the gate it dies before its recipe can
  rewrite `config.mk` — the same deadlock already documented for `BAD_POST_DATES` and
  `date_select`. `BUILD_GOAL` is a **denylist** (`NONBUILD_GOALS := clean setup test config new`),
  not an allowlist: `make build/index.html` and `make work/X.staged` are ordinary builds that
  an allowlist of `all`/`build`/`deploy` would score as non-builds, leaving both the guard and
  the notice silent for exactly the targeted invocations someone debugging reaches for. A
  denylist fails loud on an unlisted future goal; an allowlist fails silent. The combined
  `make setup all` on such an install is the fifth state of the family documented at the top
  of this file: it dies at this guard, during the parse, before `setup`'s recipe can rewrite
  `config.mk` — so the answer there is the same as everywhere else, `make setup` on its own
  and then `make`. Verified.

  `new` is the first goal added to that list since it was written, and it is the case the
  "fails loud on an unlisted future goal" line was describing: unlisted, `make new` prints the
  markdown notice above `Created …` and dies on this very guard on an install predating
  detection. Verified both halves by removing `new` from the list: on an ordinary install the
  notice prints above `Created posts/…` at exit 0; on a `config.mk` holding only `DATE_DIALECT`
  it dies at this `$(error)` before printing anything at all.
- **`$(wildcard config.mk)` in `%.staged`'s prerequisites is the fifth member of the
  parse-time-vs-recipe-time family.** `config.mk` has no rule that builds it, so a bare
  prerequisite makes an unconfigured tree die with make's own
  `No rule to make target 'config.mk', needed by 'work/….staged'` instead of the deliberate
  `grampa: no DATE_DIALECT -- run make setup first`. Verified both messages. The cost is that
  the prerequisite is only *there* when `config.mk` existed at parse time: in an invocation
  that starts without one, staging carries no `config.mk` dependency at all. That shadow **is**
  reachable: on a virgin tree with a dated post, `make work/<post>.staged` exits 0 and stages
  verbatim, because staging expands no date helper and neither guard fires — `BAD_POST_DATES`
  is gated off and the `origin` guard needs `DATE_DIALECT`. (An earlier version of this bullet
  claimed such an invocation must either have nothing to stage or die at `date_select`; that
  dichotomy is false, and naming a `.staged` target directly is the counterexample.) It
  produces no *persistent* wrong output, because `make setup` then writes a newer `config.mk`
  and the next full `make` re-parses, picks the prerequisite up, and re-stages — verified with
  a body whose markdown rendering visibly changes. The residual is a whole-second-mtime
  filesystem, where a
  same-second `.staged`/`config.mk` tie would skip that re-stage; the same granularity the
  suite's `sleep 1`s exist for. It is the same lazy-parse-vs-recipe split as the
  `url=`/`FEED_PAGES` and `-include config.mk` bullets.
- **The build notice is a parse-time `$(info)`, and it costs one `$(shell)`.** It prints
  `grampa: markdown: …` as the first line of every build, above every `Building …` line, in
  serial and under `-j` alike — a line in `build`'s recipe could not, since a recipe runs
  *after* its prerequisites and phony-prerequisite ordering is not reliable under `-j`. It is
  gated on `BUILD_GOAL` so `clean`/`setup`/`test`/`config` stay quiet and on `DATE_DIALECT` so an
  unconfigured tree leads with the "run `make setup` first" error instead. Being parse-time,
  it also prints under `-n`, `-q` and `-s`. It is written as an `ifneq` around two `:=`
  snapshots rather than one `$(if)` naming `MARKDOWN_CMD` and `CONFIG_MARKDOWN`: that form
  ran the `config` sed **three** times per parse (`$(or)`'s condition, the value, the suffix
  test), measured at +48ms on a 60-post no-op rebuild. Counted 3 → 1 with a counting `sed`
  wrapper. The `:=` is safe here precisely because a parse-time reading is what the note is
  documented to be — and that documented wrinkle is the `url=`/`FEED_PAGES` one again: on a
  first-ever run, where `config` does not exist yet, the printed line names the *detected*
  tool even if the `config` about to be copied into place sets `markdown=`. Only the line is
  wrong; the staging recipe expands `MARKDOWN_CMD` at recipe time and stages correctly.
  Verified end to end, and it self-corrects on the next `make`.
- **`rfc822_from_filename` runs under `LC_ALL=C`.** RFC 822 day and month names are literal
  English tokens (`Thu`, `Aug`), and `$(shell …)` inherits the user's locale; without pinning
  it, a non-English locale emits something like `jeu., 06 aout 2026`, which is silently
  invalid RSS.
- **`date_select` pins the time to midnight** — BSD's `-v0H -v0M -v0S`, GNU's literal `00:00:00`
  in the `-d` string. `date` with only `y`/`m`/`d` keeps the current wall-clock time, so without
  the pin every build would stamp a different `<pubDate>` on the same post and `rss.xml` would
  look changed on every deploy even when no post did. The long form `%B %d, %Y` prints no time,
  so the pin is invisible there; it is `rfc822_from_filename` and the parse-time check that need
  it.
- **An install set up before the stub was removed (2026-08-07) has a leftover
  `templates/index.txt`.** It was a
  0-byte stub for a feature the index does not need — `build/index.html` is fragments wrapped
  in `base.txt` — and it is no longer in `.source/`, so new installs never get one. Nothing
  reads it; deleting it from `templates/` is safe and optional.

## Review cycle

Every piece of work in this repo gets reviewed by the **Fable model** before it moves on.
Dispatch it with the `Agent` tool using `model: "fable"`. Fold its recommendations in — this
is not an advisory read, findings get addressed or explicitly argued down in writing.

Four checkpoints, no exceptions:

| When | What Fable reviews |
| --- | --- |
| Spec written | The design doc, against the Makefile and the test suite |
| Plan written | The implementation plan, against the approved spec |
| Each task finished | That task's diff, before starting the next task |
| Before merging | The whole branch, end to end |

Give the reviewer real context, not just a diff: this is a Makefile, so the failure modes
are pattern-rule ambiguity, `=` versus `:=` expansion timing, `.SECONDARY` and intermediate
reaping, awk `&`-in-replacement semantics, and shell quoting. A reviewer without that
framing will comment on prose and miss the build breaking. Tell it which decisions are
already settled with the user so it doesn't relitigate them, and tell it to prove claims by
running commands in a sandbox — copying `Makefile` and `.source/` into a scratch directory
the way `tests/run.sh` does — rather than asserting from inspection.

To run the suite itself from a scratch copy, copy `tools/` too: five tests shell out to
`./tools/migrate-categories.sh` (six call sites — `test_migration_converts_old_posts` runs it
twice), and without it the suite reports 15 assertion failures that are nothing to do with the
change under review. That count is from a Linux host, where `test_migration_reports_error_when_rm_fails`
skips for want of `chflags`; on macOS it runs and fails too. Re-count both numbers when adding
a migration test — the sentence has been wrong twice, most recently by being corrected against
the tree as it stood *before* the diff that added a fifth such test.

Ask for findings split into blocking / recommended / optional, plus a list of what it
actively verified. The verified list is worth as much as the findings: it stops the same
ground being re-checked at the next checkpoint.

## Conventions

- Tabs in the Makefile, obviously. Multi-line awk scripts are written inline with `\`
  continuations and `$$` for awk's `$`.
- Comment blocks above each rule and helper, in the existing `#`-banner style.
- Recipes are prefixed with `@` and echo a short human-readable progress line.
