# CLAUDE.md

## What this is

Grampa is a static blog generator written entirely as a GNU Makefile driving standard
Unix tools (`awk`, `sed`, `cat`, `date`, `tail`). There is no language runtime, no
package manager, and no dependencies to install. The Makefile *is* the program — if a
change can't be expressed in make + awk + coreutils, it doesn't belong here.

## Commands

```sh
make setup     # one-time: create build/ work/ posts/ templates/, copy templates + config + deploy.sh,
               #           and probe the host for its date dialect and a markdown processor
make           # incremental build into build/  (= `make config build`)
make clean     # wipe build/ and work/
make build     # the build half of the default target (see below — it no longer skips anything)
make deploy    # builds, then runs ./deploy.sh build/
make test      # run tests/run.sh in throwaway sandboxes
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
| `.source/` | yes | Pristine templates copied into place by `make setup` |
| `.source/splitter.txt` | yes | The `-----------------------------------` front-matter delimiter |
| `README.md`, `CLAUDE.md` | yes | Docs for humans and for Claude |
| `tests/run.sh` | yes | The suite, run by `make test` in throwaway sandboxes |
| `tools/` | yes | One-off maintenance scripts (`migrate-categories.sh`) |
| `docs/` | yes | Specs, plans, and `backlog.md` — the standing review findings |
| `posts/` | no | Source posts, one `.txt` per post |
| `templates/` | no | Working templates (edit these, not `.source/`) |
| `build/` | no | Publishable output, and nothing else — deploy this verbatim |
| `work/` | no | Intermediates (`.staged`, `.tmp`, and `.rssitem` fragments) |
| `config`, `deploy.sh` | no | Per-install, copied from `.source/*.example` |
| `config.mk` | no | Per-install, **generated** by `make setup` probing the host: `DATE_DIALECT := bsd\|gnu` and `DETECTED_MARKDOWN := <argv>`. No `.source` twin — it is derived, not copied |

`make setup` copies with `yes n | cp -i`, so it never clobbers existing files. It is safe
to re-run. The one exception is `config.mk`, which is *generated* rather than copied: setup
probes `date(1)` and the markdown candidates and rewrites it, which is what re-fixes the
dialect if a checkout ever moves between OSes and what picks up a newly installed markdown
processor. The rewrite is conditional on the content actually differing — setup writes
`config.mk.new` and `cmp`s it — because `config.mk` is a prerequisite of `%.staged`, and an
unconditional touch would re-stage every post on every setup.

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

**The date must be a real one.** `2026-13-40`, `20xx-ab-cd`, `2026-02-30`, and non-leap
`2026-02-29` are all rejected; `2026-7-4` unpadded, `26-7-4` two-digit (rendered year `0026`
under BSD, `2026` under GNU — see the portable-date gotcha), and `2028-02-29` build.
`date` already rejected these dates and exited 1 — nothing heard it, because
`date_from_filename` is a `$(shell)` call, which keeps the output and discards the status, and
make 3.81 has no `.SHELLSTATUS`. The result was a page with an empty posted-on line and an
empty `<pubDate>`.

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
against a freshly written `x <i>y</i>` and has to exit 0, keep the `<i>`, and *not* return a
whole `<html>` document. That is what catches a flag that turns out to be wrong on the host —
including for `comrak`, `multimarkdown` and `markdown-it`, whose rows were never executed
during development and whose flags are inferred from family behaviour rather than observed.
The probe file is rewritten **inside** the loop, per candidate: a candidate that truncates a
shared file would make every candidate behind it fail the `<i>` check on empty input.

`setup` writes `config.mk.new` and `mv`s it only when `cmp` says the content changed, so a
no-op `make setup` does not bump the mtime — without that, every setup would re-stage every
post, `config.mk` being a staging prerequisite.

`.tmp` files are rendered post fragments and are the unit of reuse: the per-post page and
the index are both just a `base.txt` wrapper around one or more `.tmp` files. `.rssitem`
files are the feed's equivalent — one `<item>` per post, wrapped in `rss.txt` the same way
`.tmp` fragments are wrapped in `base.txt`. Both kinds live in `work/`. `.tmp` and `.staged`
are kept between builds via `.SECONDARY` — without that, make would treat them as
pattern-rule intermediates and delete them, forcing a full rebuild every time. `.rssitem`
files need no such entry: `RECENT_ITEMS` names them as explicit prerequisites of the
explicit target `work/rss.tmp`, and make only reaps files it never sees mentioned. Listing
them in `.SECONDARY` anyway would be actively harmful — see the comment above `.SECONDARY`
in the Makefile.

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
intermediate `.tmp` the way the index does. Its prerequisites are exact, because
`CATEGORY_SLUGS` is derived from filenames at parse time.

Because the category is in the filename but not the URL, a page cannot be mapped back to its
fragment by turning slashes into hyphens — the stem `2026/08/06/first-post` has no way to
know the fragment is `2026-08-06-home_first-post.tmp`. That substitution *was* the mechanism
before categories moved into filenames. `tmp_for_page` searches `TMP_FILES` instead, which
is O(posts) per target and so O(posts²) per build — fine at blog scale, fixable with
`$(eval)`-generated explicit rules if it ever drags.

**`build/category/%.html` must stay defined above the `%.html` rule.** On GNU make 3.81,
when a target's prerequisites are satisfiable under more than one pattern rule, make picks
the first such rule in makefile order, not the shortest stem. `tmp_for_page` returns empty
for a category stem (there is no single fragment a category page maps to), and an empty
prerequisite list is trivially satisfiable — so if `%.html` appeared first, it would claim
`build/category/home.html`. Verified empirically in both orders.

That claim used to produce a nested `base.txt`-wrapped document with the wrong title and no
error. It no longer does: the unknown-page guard added in `d96a855` fires first, and the
wrong order now fails loudly —

```
build/category/home.html: no post in posts/ builds this page
make: *** [build/category/home.html] Error 1
```

The ordering constraint is still real — category pages will not build in the wrong order —
but the failure is caught, not silent. Keep `build/category/%.html` first.

`build/rss.xml` is a fourth consumer, gated on `SITE_URL`: `FEED_PAGES` is
`$(BUILD_DIR)rss.xml` when `url=` is set in config and empty otherwise, so with no `url=`
the feed — fragments included — simply is not built, and `build`'s recipe prints a skip
note. `RECENT_ITEMS` takes the same newest-ten window of `.rssitem` files that
`RECENT_FILES` takes of `.tmp` files for the index, concatenated into `work/rss.tmp` and
wrapped in `templates/rss.txt`.

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
  build's feedless output.
- **Categories come from filenames, not front matter.** `CATEGORY_SLUGS` is
  `$(sort $(foreach …))` over `POST_NAMES`, so discovering them needs no shell and no
  reading of post contents. Renaming a category means renaming files — see
  `tools/migrate-categories.sh` for the pattern.
- **Renaming or deleting a category leaves its old page in `build/`**, same as deleting a
  post. `make clean` fixes it.
- **Deleting a post leaves its HTML behind.** Nothing knows the old page existed. Run
  `make clean && make` after removing a post. The feed is only sometimes as forgiving, and
  the condition is narrower than it looks: deleting a post heals the feed on a plain `make`
  only when the post that becomes newly in-window has **no `.rssitem` on disk**. Then the
  missing fragment must be built, which makes it newer than `work/rss.tmp`, which re-cats and
  re-wraps. If that fragment already exists — because the post was in the window once before,
  which is the case on any blog grown a post at a time past ten with the feed on — then every
  prerequisite of `rss.tmp` exists and is older than it, nothing rebuilds, and the deleted
  post's `<item>` stays in `build/rss.xml`. With ten or fewer posts there is no window edge to
  cross at all and the stale `<item>` likewise persists. Verified all three ways;
  `test_deleting_a_post_heals_the_feed` covers the healing case. `make clean && make` is the
  reliable answer in every case.
- **Removing `url=` from `config` leaves a stale `build/rss.xml` behind**, same class as the
  two gotchas above — nothing deletes a page whose config went away, and `make deploy` would
  happily ship the stale feed. `make clean` fixes it.
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
  into.
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
  `date_select`. `BUILD_GOAL` is a **denylist** (`NONBUILD_GOALS := clean setup test config`),
  not an allowlist: `make build/index.html` and `make work/X.staged` are ordinary builds that
  an allowlist of `all`/`build`/`deploy` would score as non-builds, leaving both the guard and
  the notice silent for exactly the targeted invocations someone debugging reaches for. A
  denylist fails loud on an unlisted future goal; an allowlist fails silent. The combined
  `make setup all` on such an install is the fifth state of the family documented at the top
  of this file: it dies at this guard, during the parse, before `setup`'s recipe can rewrite
  `config.mk` — so the answer there is the same as everywhere else, `make setup` on its own
  and then `make`. Verified.
- **`$(wildcard config.mk)` in `%.staged`'s prerequisites is the fifth member of the
  parse-time-vs-recipe-time family.** `config.mk` has no rule that builds it, so a bare
  prerequisite makes an unconfigured tree die with make's own
  `No rule to make target 'config.mk', needed by 'work/….staged'` instead of the deliberate
  `grampa: no DATE_DIALECT -- run make setup first`. Verified both messages. The cost is that
  the prerequisite is only *there* when `config.mk` existed at parse time: in an invocation
  that starts without one, staging carries no `config.mk` dependency at all. That shadow is
  currently unreachable in a way that could produce wrong output — such an invocation either
  has nothing to stage, or dies at `date_select` before any staging recipe runs (verified: a
  virgin tree with a dated post fails `make setup all` exactly there, and one with an empty
  `posts/` exits 0) — but it is the same lazy-parse-vs-recipe split as the `url=`/`FEED_PAGES`
  and `-include config.mk` bullets, and it is worth knowing before someone relies on that
  prerequisite for something new.
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
`./tools/migrate-categories.sh`, and without it the suite reports 18 failures that are
nothing to do with the change under review.

Ask for findings split into blocking / recommended / optional, plus a list of what it
actively verified. The verified list is worth as much as the findings: it stops the same
ground being re-checked at the next checkpoint.

## Conventions

- Tabs in the Makefile, obviously. Multi-line awk scripts are written inline with `\`
  continuations and `$$` for awk's `$`.
- Comment blocks above each rule and helper, in the existing `#`-banner style.
- Recipes are prefixed with `@` and echo a short human-readable progress line.
