# Grampa

A static blog generator that is one GNU Makefile driving `awk`, `sed`, and coreutils. There
is no runtime, no package manager, and nothing to install. The Makefile *is* the program.

It started as a question — can you build a reasonably okay blogging tool out of common shell
commands? Turns out: yes. Write posts as text files, run `make`, and get a site with
permalinks, category pages, and an RSS feed. Builds are incremental, so only the posts you
touched are reprocessed.

All of this is still in flux. It works, and the test suite says so, but the format is not
frozen yet.

## Requirements

- **GNU make** (3.81 or newer)
- **`bash`** at `/bin/bash` — the Makefile sets `SHELL` to it explicitly
- **`awk`, `sed`, `date`, `cat`, `tail`, `grep`, `sort`** — whatever your system already ships

Both BSD/macOS and GNU userlands work. The only real difference between them is `date`, and
`make setup` probes for the dialect you have and records it in a generated `config.mk`. The
`bash` requirement is the one to check on a stock BSD, which doesn't ship it at that path.

Optional: [`Markdown.pl`](https://daringfireball.net/projects/markdown/) in the repo root, to
write post bodies in Markdown instead of HTML. It has to be **executable** — `chmod +x
Markdown.pl` — because the build tests for an executable file and silently skips a copy that
isn't one.

## Install

```sh
git clone https://github.com/torrez/grampa && cd grampa
make setup
```

`make setup` creates `posts/`, `templates/`, `build/`, and `work/`, copies the stock templates
and an example `config` and `deploy.sh` into place, and detects your `date` dialect. It never
overwrites a file you already have, so it is safe to re-run — with one deliberate exception,
the generated `config.mk`, which is re-probed and rewritten every time. That's what re-fixes
the `date` dialect if a checkout ever moves between machines.

It is a one-time step and wants its own invocation. Run `make setup`, *then* `make` — see
Known issues below for why you can't combine them.

`make` must be run from the repo root; the awk programs read templates by relative path.

## Usage

```sh
make            # incremental build into build/
make clean      # wipe build/ and work/
make deploy     # build, then run ./deploy.sh build/
make test       # run the test suite in throwaway sandboxes
```

`make` only reprocesses posts whose `.txt` changed, plus anything downstream of a template you
edited. `make -j` is safe. Reach for `make clean` when you want to be certain nothing stale
survived — most often after deleting a post.

`build/` is publishable verbatim: it holds the finished pages and nothing else. Intermediates
live in `work/`. The stock `deploy.sh` just echoes its argument; replace it with your `rsync`,
`scp`, or whatever ships your site. `make deploy` builds first, so a failing build stops the
ship.

## Writing a post

A post is one text file in `posts/`, and its **filename is its metadata** — there is no index
and no database. The format is strict:

```
posts/<year>-<month>-<day>-<category>_<title-slug>.txt
```

```
posts/2026-08-06-home_installing-a-doorbell.txt
posts/2026-07-04-project-ideas_raspberry-pi-backup.txt
```

Everything left of the `_` is the date and the category; everything right of it is the title
slug. Exactly one `_` per filename — neither the category nor the title may contain one.
Categories may contain hyphens, so `project-ideas` is fine.

**The category never appears in the URL.** The first post above is published at
`/2026/08/06/installing-a-doorbell.html`. Because of that, two posts can't share a date and
title slug even in different categories — they'd both want the same page, and `make` stops and
names the two files for you.

Zero-padding the date is optional; posts sort correctly either way. It just gives you a tidier
URL: `/2026/08/06/…` rather than `/2026/8/6/…`.

A filename may contain letters, digits, and `-`, `_`, `.` — and nothing else. Every other
ASCII punctuation character is rejected, so `2026-01-02-home_what's-up.txt` is a build error
that names the file and the offending character. Non-ASCII is fine, so accents, CJK, and emoji
all work.

The contents of the file are a title line, a delimiter of 35 hyphens, and the body:

```
title: Installing a doorbell
-----------------------------------
<p>
Body of your post.
</p>
```

The body is copied through as-is, so it's HTML — unless `Markdown.pl` is present, in which
case every body is run through it first.

## Configuration

`make setup` copies an example `config` into the repo root. It has two keys, both optional:

```
name=My Weblog
url=https://example.com
```

`name=` goes in the title tags: the front page gets `My Weblog`, a post page gets
`Post Title - My Weblog`. Unset, it falls back to `Grampa`.

`url=` is the absolute address of your site. Setting it turns on the RSS feed; leaving it out
means no feed is built, and no error either. It has to be absolute because a feed reader has
no page to resolve a relative link against. A trailing slash is fine — it gets stripped.

Blank lines and lines starting with `#` are ignored, and if you set a key twice the last one
wins. These are the only two keys anything reads.

## What it builds

- **`build/index.html`** — the ten newest posts, full bodies, newest first.
- **`build/<y>/<m>/<d>/<slug>.html`** — a permalink page per post.
- **`build/category/<slug>.html`** — a page per category, listing every post in it with full
  bodies. The front page stops at ten, but category pages don't, so nothing ever falls off the
  end of the site. Each post links to its own category page from its posted-on line. You don't
  have to do anything to get these: the categories come out of your filenames. Renaming a
  category means renaming the files that use it.
- **`build/rss.xml`** — an RSS 2.0 feed of the ten newest posts, full bodies, same window as
  the front page. Only built when `url=` is set.

Every page advertises the feed with a `<link rel="alternate">` tag, whether or not you've set
`url=` — so a site with no feed advertises one that 404s. Set `url=`, or delete the line from
`templates/base.txt`.

Edit the files in `templates/`, not the pristine copies in `.source/`.

## How it works

Each post is staged once — front matter split off, body run through `Markdown.pl` if it's
there, the two glued back together — and then rendered into a **fragment**. The fragment is
the unit of reuse: the permalink page, the front page, the category page, and the feed are all
just different wrappers around the same rendered fragments, which is what makes incremental
builds possible.

```
posts/2026-08-06-home_first-post.txt
  └─ awk split + (optional) Markdown.pl → work/2026-08-06-home_first-post.staged
        ├─ awk + templates/post.txt      → work/….tmp        (a post fragment)
        │     ├─ awk + templates/base.txt → build/2026/08/06/first-post.html
        │     ├─ cat 10 newest            → work/index.tmp → build/index.html
        │     └─ awk over the category    → build/category/home.html
        └─ awk + templates/rss-item.txt  → work/….rssitem   (only when url= is set)
              └─ cat 10 newest            → work/rss.tmp → build/rss.xml
```

There are four templates, each a plain file with `{{placeholder}}` markers: `base.txt` wraps a
page, `post.txt` renders a post fragment, and `rss.txt` / `rss-item.txt` are the feed's
equivalents.

`CLAUDE.md` is the full technical reference — every rule, helper, and gotcha, at length.

## Known issues

- **Deleting a post leaves its HTML behind**, and usually its feed item too. Nothing knows the
  old page existed. Same for renaming or deleting a category, and for removing `url=` from
  `config`, which leaves a stale `build/rss.xml`. `make clean && make` fixes all of it.
- **`make setup` can't share an invocation with a build.** `make -j setup all` dies with
  `No rule to make target 'templates/…'`, because make resolves the whole prerequisite graph
  before running any recipe, so it looks for the templates the build needs before `setup` has
  copied any of them. On a first-ever setup with dated posts already in `posts/`, even the
  serial `make setup all` fails. `make setup` on its own always works; run it, then run `make`.
- **A first-ever build that creates `config` with `url=` already set produces no feed, and
  says nothing about it.** Whether the feed is built is decided when the Makefile is parsed,
  which is before `config` exists on that first run. It only bites if you've customized
  `.source/config.example` with a `url=`; the second `make` picks it up.
- **`Markdown.pl` has to be executable.** A non-executable copy is skipped silently and your
  bodies stay verbatim HTML. After `chmod +x`, run `make clean && make` — already-staged posts
  aren't rebuilt just because `Markdown.pl` turned up, so the fix looks like it did nothing.

## Not done yet

- Better deployment examples
- A home for static files (CSS, images) that aren't generated from posts
