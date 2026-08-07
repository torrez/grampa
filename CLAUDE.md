# CLAUDE.md

## What this is

Grampa is a static blog generator written entirely as a GNU Makefile driving standard
Unix tools (`awk`, `sed`, `cat`, `date`, `tail`). There is no language runtime, no
package manager, and no dependencies to install. The Makefile *is* the program — if a
change can't be expressed in make + awk + coreutils, it doesn't belong here.

## Commands

```sh
make setup     # one-time: create build/ work/ posts/ templates/, copy templates + config + deploy.sh
make           # incremental build into build/  (= `make config build`)
make clean     # wipe build/ and work/
make build     # the build half of the default target (see below — it no longer skips anything)
make deploy    # runs ./deploy.sh build/
make test      # run tests/run.sh in throwaway sandboxes
```

Builds are incremental: `make` only reprocesses posts whose `.txt` changed, plus anything
downstream of a touched template. `make -j` is safe. Use `make clean` when you want to be
sure nothing stale survives — e.g. after deleting a post, whose old HTML is not tracked by
anything and will otherwise linger in `build/`.

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

`make setup` copies with `yes n | cp -i`, so it never clobbers existing files. It is safe
to re-run.

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
slash is stripped so `url=` with or without one produces identical links. These are the only
two keys anything reads.

## Post format

Filename **must** be `posts/<y>-<m>-<d>-<category>_<slug-words>.txt`. Everything left of
the `_` is the date and the category; everything right of it is the title slug. Exactly one
`_` per filename — neither the category nor the title may contain one. Categories may
contain hyphens (`project-ideas`). A malformed name is a parse-time `$(error)`.

So is a duplicate permalink. Because the category is not in the URL, two posts sharing a
date and title slug in different categories — `2026-08-06-home_dup.txt` and
`2026-08-06-work_dup.txt` — both want `/2026/08/06/dup.html`. `CHECKED_POST_PAGES` errors
naming both files rather than letting filename sort order pick a winner.

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
copied through as-is (HTML), unless `Markdown.pl` is present.

## Build pipeline

```
posts/2026-08-06-home_first-post.txt
  └─ awk split + (optional) Markdown.pl on the body only → work/2026-08-06-home_first-post.staged
        ├─ awk + templates/post.txt        → work/2026-08-06-home_first-post.tmp   (a post fragment)
        │     ├─ awk + templates/base.txt  → build/2026/08/06/first-post.html
        │     └─ cat 10 newest             → work/index.tmp
        │           └─ awk + templates/base.txt → build/index.html
        └─ awk + templates/rss-item.txt    → work/2026-08-06-home_first-post.rssitem  (only when url= is set)
              └─ cat 10 newest             → work/rss.tmp
                    └─ awk + templates/rss.txt → build/rss.xml
```

`.staged` is the shared staging step: it splits the front matter off the body, runs the body
through `Markdown.pl` if present, and glues them back together. Both `.tmp` and `.rssitem`
are built from the same `.staged` file, so `Markdown.pl` runs once per post no matter how
many consumers read the result.

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
rather than tidy: awk creates a redirect's file on first write, so without it a post with no
body would leave no body file for `Markdown.pl` to be handed. It replaced `split -p` and a
pair of globs, which is the subject of the two closed glob items in `docs/backlog.md`.

The blog name reaches awk the same way: `BLOG_NAME` is `export`ed by make and each recipe
composes `PAGE_TITLE` in the environment, which `WRAP_IN_BASE` reads via
`ENVIRON["PAGE_TITLE"]`. Nothing is interpolated into a shell string, so a blog name or post
title containing `"`, `'`, `$`, or `&` can't break the build. `SITE_URL` is exported the same
way, and `WRAP_IN_CHANNEL` and `RENDER_ITEM` read it via `ENVIRON["SITE_URL"]` to build the
feed's `<link>` elements.

### Make helper functions

The top of the Makefile defines string helpers because make has no real string library:
`reverse`, `space`, `date_from_filename`, `rfc822_from_filename`, `underscore_split`,
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
- **BSD-only.** `date_from_filename` uses `date -v` (BSD/macOS). It fails on GNU
  coreutils, so builds are macOS-only as written.
- **`config` is read lazily, not at parse time.** `CONFIG_NAME` and `CONFIG_URL` both use
  `=`, not `:=`, because on a first-ever run the `config` target hasn't copied the file into
  place yet when the Makefile is parsed. `config` is also a prerequisite of the HTML rules
  and of `%.rssitem`, so changing `name=` or `url=` rebuilds every page or every feed item.
  `name=` and `url=` are the only keys anything reads; the last of each wins, and an absent
  or empty `name=` falls back to `Grampa`.
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
- `Markdown.pl` is optional and gitignored — get it from
  <https://daringfireball.net/projects/markdown/> and make it executable in the repo
  root. Without it, the post is staged into `work/` verbatim and bodies stay HTML. Adding or
  removing `Markdown.pl` does not invalidate `.staged`, whose only prerequisite is the post
  itself — the same behaviour the old `.tmp` rule had before staging was split out, just more
  visible now that `.staged` is a named, inspectable file instead of a step inside `.tmp`.
- **`rfc822_from_filename` runs under `LC_ALL=C`.** RFC 822 day and month names are literal
  English tokens (`Thu`, `Aug`), and `$(shell …)` inherits the user's locale; without pinning
  it, a non-English locale emits something like `jeu., 06 aout 2026`, which is silently
  invalid RSS.
- **`rfc822_from_filename` pins the time to midnight with `-v0H -v0M -v0S`.** `date -v` with
  only `y`/`m`/`d` keeps the current wall-clock time, so without pinning, every build would
  stamp a different `<pubDate>` on the same post and `rss.xml` would look changed on every
  deploy even when no post did.
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
