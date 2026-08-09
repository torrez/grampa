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

- **GNU make 4.2 or newer** — checked at startup, so if yours is too old you get one clear
  line saying so rather than a strange failure later. See below if you are on a Mac.
- **`bash`** at `/bin/bash` — the Makefile sets `SHELL` to it explicitly
- **`awk`, `sed`, `date`, `cat`, `tail`, `grep`, `sort`** — whatever your system already ships

Both BSD/macOS and GNU userlands work. The only real difference between them is `date`, and
`make setup` probes for the dialect you have and records it in a generated `config.mk`. The
`bash` requirement is the one to check on a stock BSD, which doesn't ship it at that path.

### On a Mac, you need a newer make

macOS ships **GNU make 3.81**, from 2006 — the last release before make moved to GPLv3, which
is why Apple has never updated it. Grampa does not run on it. Install a current one:

```sh
brew install make
```

Homebrew installs it as **`gmake`**, leaving Apple's `make` alone. So every command in this
README is `gmake` on a Mac:

```sh
gmake setup
gmake
gmake deploy
```

If you would rather just type `make`, put Homebrew's version first on your `PATH`:

```sh
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
```

**3.81 is not merely old here.** It has a bug that lets a failed build silently publish a post
with an empty body on the next run — a wrong page shipped at exit 0, which is the one failure
this project works hardest to prevent. Make 4.0 is rejected too, for an unrelated reason: it
crashes on an emoji in a post filename. `tools/probe-platform.sh` will tell you what your
machine has.

Optional: a **markdown processor**, to write post bodies in Markdown instead of HTML. You do
not have to pick one — `make setup` looks for these, in this order, and uses the first it
finds working:

`lowdown`, `cmark-gfm`, `md2html`, `comrak`, `multimarkdown`, `markdown` (discount), `cmark`,
`smu`, `markdown_py`, `markdown-it`, `pandoc`, and finally
[`Markdown.pl`](https://daringfireball.net/projects/markdown/) in the repo root.

The order prefers processors that support tables and that need no language runtime.
`Markdown.pl` is last because it is the slowest and the least maintained; it is still
supported, and still has to be **executable** (`chmod +x Markdown.pl`) to be found. Install
none of them and post bodies stay verbatim HTML, which is what grampa has always done.

Each is run with flags meant to keep raw HTML in your post intact and to leave your quotes and
dashes alone — the CommonMark family drops or escapes embedded HTML by default, which would
silently delete an `<iframe>` from a post. That is checked, not assumed: `make setup` only
accepts a processor whose output on a test snippet still contains the raw HTML it was given,
so a wrong flag on your version means the processor is skipped rather than quietly mangling
your posts. Every build prints which processor it is using on its first
line. To pin a specific one, set `markdown=` in `config`; it overrides detection and is run as
a shell command line, so it takes flags.

## Install

```sh
git clone https://github.com/torrez/grampa && cd grampa
make setup
```

`make setup` creates `posts/`, `templates/`, `static/`, `build/`, and `work/`, copies the stock
templates, a stock stylesheet, and an example `config` and `deploy.sh` into place, and detects
your `date` dialect and your markdown processor. It never overwrites a file you already have,
so it is safe to re-run — with one deliberate exception, the generated `config.mk`, which is
re-probed every time and
rewritten whenever the answer changed. That's what re-fixes the `date` dialect if a checkout
moves between machines, and what picks up a markdown processor you installed later.

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

On a Mac these are `gmake`, not `make` — see [above](#on-a-mac-you-need-a-newer-make).
`gmake test` tests whichever make ran it, so it exercises the one you will actually build
with.

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
URL: `/2026/08/06/…` rather than `/2026/8/6/…`. The date does have to be a real one, though —
`2026-02-30`, or February 29th in a non-leap year, stops the build and names the file.

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

The body is copied through as-is, so it's HTML — unless a markdown processor was found, in
which case every body is run through it first. The front matter never is: a title keeps its
asterisks.

## Static files

Anything in `static/` is copied into `build/` with its path preserved, so `static/style.css`
publishes at `/style.css` and `static/img/logo.png` at `/img/logo.png`. That mirroring at the
root is what lets you serve `/favicon.ico`, `/robots.txt`, or a `CNAME`. `make setup` creates
the directory and puts a stock stylesheet in it, which the stock `templates/base.txt` links.

A static file may not have the same path as a page grampa builds. `static/index.html`, and a
`static/2026/08/06/hello.html` twin of a real post, both stop the build and name the page the
two of them want, rather than one silently winning. So does a file named for a directory pages
live in, like `static/2026` or `static/category`. `static/rss.xml` is refused whether or not
you have set `url=`, so turning the feed on later can't break a site that built yesterday.

Static filenames are checked, but less strictly than post filenames: no whitespace, no control
characters, and none of ``: % $ # \ * ? [ ] ` ( ) & ' " | ; < > =``. Everything else is fine,
so `logo@2x.png` and `style,min.css` both work, as do accents and emoji.

It is a copy, not a filter — `style.css~`, `.DS_Store` and editor swap files in `static/` get
published along with everything else.

## Configuration

`make setup` copies an example `config` into the repo root. It has three keys, all optional:

```
name=My Weblog
url=https://example.com
markdown=cmark --unsafe
```

`name=` goes in the title tags: the front page gets `My Weblog`, a post page gets
`Post Title - My Weblog`. Unset, it falls back to `Grampa`.

`url=` is the absolute address of your site. Setting it turns on the RSS feed; leaving it out
means no feed is built, and no error either. It has to be absolute because a feed reader has
no page to resolve a relative link against. A trailing slash is fine — it gets stripped.

`markdown=` pins the processor, overriding whatever `make setup` detected. It is a command
*line*, not a command name — flags belong here — and it is run as `<command> <file>`, so it
must write an HTML fragment to standard output and exit non-zero if it fails. Naming something
that isn't installed fails the build rather than quietly falling back to verbatim HTML. Like
`deploy.sh`, it is executed: only put something here you'd run yourself. `.source/config.example`
lists a ready-made line for each supported processor.

Blank lines and lines starting with `#` are ignored, and if you set a key twice the last one
wins. A `#` *after* `markdown=` is not a comment, though — the rest of the line is part of the
command, and the shell will treat the `#` as starting a comment of its own, which truncates
the build step. That is caught deliberately and fails the build with a shell syntax error, so
don't be alarmed by the wording: move the `#` and whatever follows it out of the value.

These are the only three keys anything reads.

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
- **Anything in `static/`** — copied to the matching path under `build/`, so `static/style.css`
  becomes `build/style.css`.

Every page advertises the feed with a `<link rel="alternate">` tag, whether or not you've set
`url=` — so a site with no feed advertises one that 404s. Set `url=`, or delete the line from
`templates/base.txt`.

Edit the files in `templates/`, not the pristine copies in `.source/`.

## How it works

Each post is staged once — front matter split off, body run through the markdown processor if
there is one, the two glued back together — and then rendered into a **fragment**. The fragment is
the unit of reuse: the permalink page, the front page, the category page, and the feed are all
just different wrappers around the same rendered fragments, which is what makes incremental
builds possible.

```
posts/2026-08-06-home_first-post.txt
  └─ awk split + (optional) markdown   → work/2026-08-06-home_first-post.staged
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

- **Deleting a post leaves its own HTML page behind.** Nothing knows the old page existed.
  Everything that *links* to it — the front page, its category page, the feed — drops it on the
  next `make`. The orphaned page itself needs `make clean && make`, as does a category page
  whose **last** post you deleted, and a stale `build/rss.xml` left by removing `url=`.
- **Deleting a static file leaves its copy behind in `build/`**, the same as deleting a post,
  and for the same reason: nothing tracks an output whose source is gone. `make clean && make`
  clears it.
- **`make setup` can't share an invocation with a build.** `make -j setup all` dies with
  `No rule to make target 'templates/…'`, because make resolves the whole prerequisite graph
  before running any recipe, so it looks for the templates the build needs before `setup` has
  copied any of them. On a first-ever setup with dated posts already in `posts/`, even the
  serial `make setup all` fails. `make setup` on its own always works; run it, then run `make`.
  Even where the combined form does run — an empty `posts/` — its build publishes pages that
  link a `/style.css` it has not copied yet, because the list of static files is read before
  `setup` puts the stylesheet there. The next `make` copies it.
- **A first-ever build that creates `config` with `url=` already set produces no feed, and
  says nothing about it.** Whether the feed is built is decided when the Makefile is parsed,
  which is before `config` exists on that first run. It only bites if you've customized
  `.source/config.example` with a `url=`; the second `make` picks it up.
- **Installing or removing a markdown processor needs a `make setup`, not just a `make`.**
  Detection happens once, at setup, and is recorded in `config.mk`; a plain `make` never looks
  at your `PATH` again. So a newly installed processor appears to do nothing until you re-run
  `make setup` — after which a plain `make` re-stages every post by itself, because `config.mk`
  is a prerequisite of the staging step. No `make clean` needed. The same applies to
  `Markdown.pl`, which still has to be **executable** to be detected: a non-executable copy is
  skipped, silently, and your bodies stay verbatim HTML.

## Not done yet

- Better deployment examples
