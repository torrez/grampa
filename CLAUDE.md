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

## Post format

Filename **must** be `posts/<y>-<m>-<d>-<slug-words>.txt`. The first three
hyphen-separated fields are parsed as the date; everything after is the slug. The slug may
contain hyphens; it must be at least one word.

```
title: A text title
category: example
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

Template placeholders are substituted with awk `sub()`, which replaces only the **first**
match per line. A placeholder used twice on one line will only expand once.

- `templates/post.txt` — `{{title}}` `{{body}}` `{{pub_date}}` `{{permalink}}` `{{category}}`
- `templates/base.txt` — `{{main}}` `{{page_title}}`

### Make helper functions

The top of the Makefile defines string helpers because make has no real string library:
`reverse`, `space`, `date_from_filename`, `post_filename`, `html_post_filename`,
`path_from_filename`, `html_post_files`. They all operate on post filenames by
`subst`-ing hyphens into spaces and using `wordlist`. Filenames are the only metadata
store for dates and URLs — there is no index or database.

## Gotchas

- **`POST_NAMES` is sorted with `sort -t- -k1,1n -k2,2n -k3,3n`**, not `$(wildcard)`,
  because wildcard sorts as strings and would put `2026-10-1` before `2026-7-4`. The
  numeric sort makes ordering correct for padded *and* unpadded dates. Zero-padding is
  still worth doing for the URLs' sake — an unpadded post becomes `/2026/7/4/slug.html`.
- **BSD-only.** `date_from_filename` uses `date -v` (BSD/macOS). It fails on GNU
  coreutils, so builds are macOS-only as written.
- **`config` is inert.** `make config` copies it, nothing reads it. `name=` is unused;
  page titles are hardcoded in the Makefile's awk (`Dungeon` for posts, `Grampa` for the
  index). Wiring `name=` through to `{{page_title}}` is the obvious next cleanup.
- **`templates/post.txt` renders `{{category}}.gif`** as literal text, which looks like
  leftover scaffolding rather than an intent.
- **Deleting a post leaves its HTML behind.** Nothing knows the old page existed. Run
  `make clean && make` after removing a post.
- The two `base.txt`-wrapping awk blocks (`%.html` and `index.html`) are now identical
  except for the hardcoded `page_title`. They're worth folding into one.
- `Markdown.pl` is optional and gitignored — get it from
  <https://daringfireball.net/projects/markdown/> and make it executable in the repo
  root. Without it, the post is staged into `work/` verbatim and bodies stay HTML.
- `build/atom.xml` and `templates/atom.txt`/`index.txt` are unimplemented stubs.

## Conventions

- Tabs in the Makefile, obviously. Multi-line awk scripts are written inline with `\`
  continuations and `$$` for awk's `$`.
- Comment blocks above each rule and helper, in the existing `#`-banner style.
- Recipes are prefixed with `@` and echo a short human-readable progress line.
