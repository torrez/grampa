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
`getline < "templates/base.txt"` — a relative path — so any other working directory
silently produces pages with empty bodies rather than an error.

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
| `work/` | no | Intermediates (`.tmp` fragments, Markdown scratch) |
| `config`, `deploy.sh` | no | Per-install, copied from `.source/*.example` |

`make setup` copies with `yes n | cp -i`, so it never clobbers existing files. It is safe
to re-run.

## config

```
name=My Weblog
```

`name=` sets `{{page_title}}`: the index gets `My Weblog`, a post page gets
`Post Title - My Weblog`. Blank lines and `#` comments are ignored, the last `name=` wins,
and surrounding whitespace is trimmed. It is the only key anything reads.

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
  └─ (optional) Markdown.pl on the body only
  └─ awk + templates/post.txt        → work/2026-08-06-first-post.tmp   (a post fragment)
        ├─ awk + templates/base.txt  → build/2026/08/06/first-post.html
        └─ cat 10 newest              → work/index.tmp
              └─ awk + templates/base.txt → build/index.html
```

`.tmp` files are rendered post fragments and are the unit of reuse: the per-post page and
the index are both just a `base.txt` wrapper around one or more `.tmp` files. They live in
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

- `templates/post.txt` — `{{title}}` `{{body}}` `{{pub_date}}` `{{permalink}}` `{{category}}`
  `{{category_url}}`
- `templates/base.txt` — `{{main}}` `{{page_title}}`

Substitution goes through the awk `fill()` helper, **not** `sub()`. `sub()` treats `&` in
the replacement as "the matched text", so a post titled `Tom & Jerry` rendered as
`Tom {{title}} Jerry`. `fill()` uses `index()`/`substr()` and has no such magic. Like
`sub()` it replaces only the **first** `{{key}}` on a line, so a placeholder used twice on
one line expands once.

### awk programs

The two awk programs live in `define` blocks (`RENDER_POST`, `WRAP_IN_BASE`) that are
`export`ed and invoked as `awk "$$RENDER_POST"`. They share `fill()` by interpolating
`$(FILL_FN)`. Passing the program through the environment rather than inlining it means
awk source doesn't have to survive shell quoting, and it avoids the `\`-continuation-per-line
style the rest of a Makefile forces. Note that awk's `$0` is still `$$0` inside a `define`.

The blog name reaches awk the same way: `BLOG_NAME` is `export`ed by make and each recipe
composes `PAGE_TITLE` in the environment, which `WRAP_IN_BASE` reads via
`ENVIRON["PAGE_TITLE"]`. Nothing is interpolated into a shell string, so a blog name or post
title containing `"`, `'`, `$`, or `&` can't break the build.

### Make helper functions

The top of the Makefile defines string helpers because make has no real string library:
`reverse`, `space`, `date_from_filename`, `underscore_split`, `date_and_category`,
`title_slug`, `post_slug`, `dc_words`, `category_slug`, `category_display`,
`category_url`, `check_post_name`, `path_from_filename`, `page_for`, `files_for_page`,
`check_page_collisions`, `tmp_for_page`, `post_for_page`, `html_post_files`,
`tmp_files_in_category`. They all operate on post
filenames by `subst`-ing hyphens (and, since categories moved into the name, underscores)
into spaces and using `wordlist`. Filenames are the only metadata store for dates,
categories, and URLs — there is no index or database.

## Gotchas

- **`POST_NAMES` is sorted with `sort -t- -k1,1n -k2,2n -k3,3n`**, not `$(wildcard)`,
  because wildcard sorts as strings and would put `2026-10-1` before `2026-7-4`. The
  numeric sort makes ordering correct for padded *and* unpadded dates. Zero-padding is
  still worth doing for the URLs' sake — an unpadded post becomes `/2026/7/4/slug.html`.
- **BSD-only.** `date_from_filename` uses `date -v` (BSD/macOS). It fails on GNU
  coreutils, so builds are macOS-only as written.
- **`config` is read lazily, not at parse time.** `CONFIG_NAME` uses `=`, not `:=`, because
  on a first-ever run the `config` target hasn't copied the file into place yet when the
  Makefile is parsed. `config` is also a prerequisite of both HTML rules, so changing the
  name rebuilds every page. `name=` is the only key anything reads; the last one wins, and
  an absent or empty value falls back to `Grampa`.
- **Categories come from filenames, not front matter.** `CATEGORY_SLUGS` is
  `$(sort $(foreach …))` over `POST_NAMES`, so discovering them needs no shell and no
  reading of post contents. Renaming a category means renaming files — see
  `tools/migrate-categories.sh` for the pattern.
- **Renaming or deleting a category leaves its old page in `build/`**, same as deleting a
  post. `make clean` fixes it.
- **Deleting a post leaves its HTML behind.** Nothing knows the old page existed. Run
  `make clean && make` after removing a post.
- `Markdown.pl` is optional and gitignored — get it from
  <https://daringfireball.net/projects/markdown/> and make it executable in the repo
  root. Without it, the post is staged into `work/` verbatim and bodies stay HTML.
- `build/atom.xml` and `templates/atom.txt`/`index.txt` are unimplemented stubs.

## Conventions

- Tabs in the Makefile, obviously. Multi-line awk scripts are written inline with `\`
  continuations and `$$` for awk's `$`.
- Comment blocks above each rule and helper, in the existing `#`-banner style.
- Recipes are prefixed with `@` and echo a short human-readable progress line.
