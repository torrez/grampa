# CLAUDE.md

## What this is

Grampa is a static blog generator written entirely as a GNU Makefile driving standard
Unix tools (`awk`, `split`, `cat`, `date`, `tail`). There is no language runtime, no
package manager, and no dependencies to install. The Makefile *is* the program — if a
change can't be expressed in make + awk + coreutils, it doesn't belong here.

## Commands

```sh
make setup     # one-time: create build/ work/ posts/ templates/, copy templates + config + deploy.sh
make           # incremental build into build/  (= `make config build`)
make clean     # wipe build/ and work/
make build     # build, skipping the config check
make deploy    # runs ./deploy.sh build/
make test      # run tests/run.sh in throwaway sandboxes
```

Builds are incremental: `make` only reprocesses posts whose `.txt` changed, plus anything
downstream of a touched template. `make -j` is safe. Use `make clean` when you want to be
sure nothing stale survives — e.g. after deleting a post, whose old HTML is not tracked by
anything and will otherwise linger in `build/`.

`make` must be run from the repo root. The awk scripts read templates via
`getline < "templates/base.txt"` — a relative path — so any other working directory means
the file isn't found. `getline` on a missing file returns `-1`, which is truthy, so an
unguarded `while (getline < "…")` loop spins forever rather than erroring: it hangs, it
does not produce pages with empty bodies. `RENDER_ITEM` and `WRAP_IN_CHANNEL` guard the
read with `> 0`; `RENDER_POST` and `WRAP_IN_BASE` do not yet.

## Layout

Only `Makefile`, `README.md`, and `.source/` are tracked. Everything the build touches
is gitignored and created by `make setup`:

| Path | Tracked | Role |
| --- | --- | --- |
| `.source/` | yes | Pristine templates copied into place by `make setup` |
| `.source/splitter.txt` | yes | The `-----------------------------------` front-matter delimiter |
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
posts/2026-08-06-first-post.txt
  └─ split + (optional) Markdown.pl on the body only → work/2026-08-06-first-post.staged
        ├─ awk + templates/post.txt        → work/2026-08-06-first-post.tmp   (a post fragment)
        │     ├─ awk + templates/base.txt  → build/2026/08/06/first-post.html
        │     └─ cat 10 newest              → work/index.tmp
        │           └─ awk + templates/base.txt → build/index.html
        └─ awk + templates/rss-item.txt    → work/2026-08-06-first-post.rssitem  (only when url= is set)
              └─ cat 10 newest              → work/rss.tmp
                    └─ awk + templates/rss.txt → build/rss.xml
```

`.staged` is the shared staging step: it splits the front matter off the body, runs the body
through `Markdown.pl` if present, and glues them back together. Both `.tmp` and `.rssitem`
are built from the same `.staged` file, so `Markdown.pl` runs once per post no matter how
many consumers read the result.

`.tmp` files are rendered post fragments and are the unit of reuse: the per-post page and
the index are both just a `base.txt` wrapper around one or more `.tmp` files. `.rssitem`
files are the feed's equivalent — one `<item>` per post, wrapped in `rss.txt` the same way
`.tmp` fragments are wrapped in `base.txt`. Both kinds live in
`work/`, and are kept between builds via `.SECONDARY` — without that, make would treat
them as pattern-rule intermediates and delete them, forcing a full rebuild every time.

The `%.html` rule maps a page back to its fragment with `.SECONDEXPANSION`: the stem of
`build/2026/08/06/first-post.html` is `2026/08/06/first-post`, and substituting slashes for
hyphens names `work/2026-08-06-first-post.tmp`. That is what makes per-post incremental
builds possible.

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
fragment by turning slashes into hyphens. `tmp_for_page` searches `TMP_FILES` instead, which
is O(posts) per target and so O(posts²) per build — fine at blog scale, fixable with
`$(eval)`-generated explicit rules if it ever drags.

**`build/category/%.html` must stay defined above the `%.html` rule.** On GNU make 3.81,
when a target's prerequisites are satisfiable under more than one pattern rule, make picks
the first such rule in makefile order, not the shortest stem. `tmp_for_page` returns empty
for a category stem (there is no single fragment a category page maps to), and an empty
prerequisite list is trivially satisfiable — so if `%.html` appeared first, it would claim
`build/category/home.html` and emit a nested `base.txt`-wrapped document with the wrong
title. Verified empirically in both orders. Reordering these two rules breaks the build
silently, so keep `build/category/%.html` first.

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

### awk programs

Four awk programs live in `define` blocks (`RENDER_POST`, `RENDER_ITEM`, `WRAP_IN_BASE`,
`WRAP_IN_CHANNEL`) that are `export`ed and invoked as `awk "$$RENDER_POST"`. They share
`fill()` by interpolating `$(FILL_FN)`. Passing the program through the environment rather
than inlining it means awk source doesn't have to survive shell quoting, and it avoids the
`\`-continuation-per-line style the rest of a Makefile forces. Note that awk's `$0` is still
`$$0` inside a `define`.

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
  `make clean && make` after removing a post. The same is true of the feed: a deleted post's
  `<item>` stays in `build/rss.xml` until the next `make clean && make`.
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
- `templates/index.txt` is an unimplemented stub.

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

Ask for findings split into blocking / recommended / optional, plus a list of what it
actively verified. The verified list is worth as much as the findings: it stops the same
ground being re-checked at the next checkpoint.

## Conventions

- Tabs in the Makefile, obviously. Multi-line awk scripts are written inline with `\`
  continuations and `$$` for awk's `$`.
- Comment blocks above each rule and helper, in the existing `#`-banner style.
- Recipes are prefixed with `@` and echo a short human-readable progress line.
