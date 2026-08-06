# Category pages

Date: 2026-08-06

## Problem

`.source/templates/post.txt` contains the line `{{category}}.gif`, added in `5436fa6`
(March 2016) in the same commit that introduced `category:` front matter. It renders as
literal text — a post in category `example` emits ` example.gif` into the page. It was the
start of a per-category icon idea that stopped there, most likely because grampa still has
nowhere to put static files.

Categories are parsed, substituted, and then wasted. Nothing links anywhere.

## Goal

Replace that line with a link to a per-category archive page listing every post in that
category, newest first.

## Post filenames

Category moves out of front matter and into the filename, after the date, separated from
the title slug by an underscore:

```
posts/2026-08-06-home_installing-a-doorbell.txt
posts/2026-07-04-project-ideas_raspberry-pi-backup.txt
posts/2026-01-02-japan-vacation_what-we-did-in-tokyo.txt
```

- Everything left of the `_` is the date and the category
- Everything right of the `_` is the title slug
- Exactly one `_` per filename. Neither the category nor the title may contain one
- Categories may contain hyphens (`project-ideas`)

This keeps the filename as grampa's only metadata store, which is the property that lets
the whole tool work without a database. Front matter shrinks to just `title:`.

Splitting on `_` before splitting on `-` makes every field fall out cleanly, and the title
slug becomes *simpler* to extract than it is today — no more `wordlist 4,$(words …)`:

| Derived value | How |
| --- | --- |
| date | `wordlist 1,3` of the hyphen-split name — unchanged |
| category slug | words `4..end` of the hyphen-split left half, rejoined with hyphens |
| title slug | word 2 of the underscore-split name |
| category display | category slug with hyphens turned to spaces |
| unique categories | `$(sort $(foreach …))` — dedupes and sorts in one call |

Prototyped against all three example names above before adopting.

### Why the date stays in the filename

Considered deriving it instead. It does not work:

- **mtime** — git does not store mtimes and sets them to checkout time. Verified: a fresh
  clone of this repo reports `README.md` as modified today, against a real commit date of
  2016-03-19. A clone would date every post "today", and fixing a typo would re-date an old
  post.
- **git log** — correct and stable, but ~12ms per file, and make needs every date *at parse
  time* to compute the target list and the sort order. That is ~12ms × posts × every `make`
  invocation, including no-op rebuilds. It also leaves uncommitted posts dateless, breaks
  under shallow clones, and silently re-dates the archive on a rebase.
- **front matter `date:`** — works, but only relocates the field.

## Decisions

| Question | Decision |
| --- | --- |
| Page content | Full posts, reusing the existing `.tmp` fragments — the same shape as `index.html` |
| How many posts | All of them, newest first. The main index stays capped at 10 |
| URL | `/category/<slug>.html` |
| Category source | The post filename, not front matter |
| Display name | Slug with hyphens as spaces: `project-ideas` → `project ideas` |
| Rebuild scope | Exact. Each category page depends only on the fragments in that category |
| Multiple categories per post | Out of scope. One category per post |
| A category index listing all categories | Out of scope |

Two decisions from the first draft of this spec are now moot. Validating a missing category
is unnecessary — it is structurally present in the name. And coarse dependencies are no
longer a useful trade: because categories are known to make at parse time, exact
per-category prerequisites cost nothing, so editing one post no longer re-cats every
category page.

## URLs do not change

The URL is built from the date and the title slug only, so the category prefix does not
appear in it:

```
posts/2026-08-06-home_installing-a-doorbell.txt  →  /2026/08/06/installing-a-doorbell.html
```

Existing permalinks survive the migration untouched.

## Template

`{{category}}.gif` is replaced by two placeholders, so the markup stays in the template
where it can be restyled, consistent with how `{{permalink}}` and `{{pub_date}}` already
work:

```html
<h4>{{title}}</h4>
{{body}}
<p>
<a href="{{permalink}}">posted on {{pub_date}}</a> in <a href="{{category_url}}">{{category}}</a>
</p>
```

- `{{category}}` — display name, hyphens as spaces
- `{{category_url}}` — `/category/<slug>.html`

The link moves into the "posted on" paragraph rather than floating after the `<h4>` where
the `.gif` sat, because it is metadata and belongs with the other metadata.

Post fragments are shared by post pages, the index, and now category pages, so the link
appears in all three from this one change.

## Build wiring

```
$(BUILD_DIR)category/%.html: $$(call tmp_files_in_category,$$*) templates/base.txt config
```

`tmp_files_in_category` filters the reversed `TMP_FILES` list by category slug, giving exact
prerequisites and newest-first ordering with no shell involved. The recipe cats those
fragments and wraps them with the existing `WRAP_IN_BASE`, with `PAGE_TITLE` set to
`<display name> - <blog name>`.

`build` gains `$(addprefix $(BUILD_DIR)category/,$(addsuffix .html,$(CATEGORY_SLUGS)))`.

Two pattern rules now match `build/category/notes.html` — this one and `build/%.html`.

**Correction, found during implementation.** This spec originally claimed GNU make picks the
shortest stem. That is wrong, and the test that appeared to confirm it was confounded: the
category rule happened to be defined first *and* have the shorter stem. On make 3.81 what
actually decides is prerequisite satisfiability in definition order. `tmp_for_page` returns
*empty* for a category stem, and an empty prerequisite list is trivially satisfiable, so the
generic `%.html` rule will happily claim `build/category/notes.html` if it is defined first —
emitting a nested HTML document with the wrong title rather than failing.

So the category rule **must be defined above `%.html`**, and that ordering is load-bearing.
Verified by moving it below and watching the output break.

### The fragment lookup

Because the category is in the filename but not in the URL, the existing trick of mapping
`build/2026/08/06/slug.html` to its fragment by turning slashes into hyphens no longer
works — it would look for `work/2026-08-06-slug.tmp` and miss the `home_` part.

A `tmp_for_page` helper resolves it by searching `TMP_FILES` for the fragment whose derived
page path equals the target's stem. This keeps the single `%.html` pattern rule and the
existing "helper functions at the top" style.

It is O(posts) per target, so O(posts²) in make string operations across a build. That is
fine at personal-blog scale; if it ever gets slow, the fix is generating explicit per-post
rules with `$(foreach)` and `$(eval)`, which is O(posts) but harder to read.

## Validation

A filename with no `_`, or with more than one, is a hard parse-time `$(error)` naming the
file. This replaces the front-matter check from the first draft and fails before any recipe
runs.

`.DELETE_ON_ERROR:` is added as general hygiene, so a failed rule cannot leave a truncated
`.tmp` behind for the next build to treat as good.

## Migration

This is a breaking change to post filenames, and the `$(error)` above makes it a loud one.
Existing posts need renaming from `y-m-d-title.txt` to `y-m-d-category_title.txt`, with the
`category:` line dropped from front matter.

That is fully automatable, since the old category is sitting in the front matter of each
post: read it, slugify it, splice it into the name, delete the line. A one-time script does
the whole `posts/` directory. It will be written and run as part of implementation, not left
as a manual chore.

## Known limitation

Renaming or removing a category leaves its old page in `build/`, since nothing records that
the page used to exist. This is the same class of problem as deleting a post, already
documented in CLAUDE.md. `make clean` fixes both. Not solved here.

## Testing

- Single-word category (`home`) and multi-hyphen category (`project-ideas`) → correct slug,
  correct display name, correct URL
- Two posts sharing a category → both on the page, newest first
- Posts in different categories → each appears only on its own page
- Filename with no `_` → parse-time error naming the file, nothing built
- Filename with two `_` → same
- Post URLs identical to before the change, for the same date and title slug
- Category link present on post pages, the index, and category pages
- Category page `<title>` uses the display name and the configured blog name
- Exact rebuild scope: editing a post in category A does not rebuild category B's page
- `make -j8` clean; no-op rebuild after a successful build
- `build/` still contains only publishable HTML
- Migration script: converts a realistic `posts/` directory, leaves front matter valid,
  produces identical post URLs before and after
- Existing suite still passes: date formatting, index ordering and 10-post cap, the
  `Markdown.pl` path, ampersands in titles and bodies, zero posts
