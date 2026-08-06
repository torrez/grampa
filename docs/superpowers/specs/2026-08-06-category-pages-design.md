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

## Decisions

| Question | Decision |
| --- | --- |
| Page content | Full posts, reusing the existing `.tmp` fragments — the same shape as `index.html` |
| How many posts | All of them, newest first. The main index stays capped at 10 |
| URL | `/category/<slug>.html` |
| Post with no `category:` | Fail the build with a message naming the file |
| Rebuild scope | Category pages depend on every fragment; editing any post rebuilds all of them |
| Multiple categories per post | Out of scope. Front matter stays a single `category:` line |
| A category index listing all categories | Out of scope |

## Slugs

The category value is free text, so it needs slugifying for the filename: lowercase,
spaces to hyphens, drop anything outside `[a-z0-9-]`, collapse runs of hyphens, trim
leading and trailing hyphens.

`category: Web Stuff` → `/category/web-stuff.html`

Slugifying happens in exactly one place, a `SLUGIFY` make variable holding a shell
pipeline. Two callers need it — the parse-time category list and the `%.tmp` recipe — and
two implementations would drift.

The *display* text stays as written. `Web Stuff` renders as `Web Stuff`, links to
`web-stuff.html`.

Two spellings can slugify to the same page — `Web Stuff` and `web-stuff` both give
`web-stuff`. They share one page, which is the useful behaviour. The page's display name is
taken from the newest post in the group, so it is deterministic rather than dependent on
filesystem order.

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

- `{{category}}` — display text, as written in the front matter
- `{{category_url}}` — `/category/<slug>.html`

The link moves into the "posted on" paragraph rather than floating after the `<h4>` where
the `.gif` sat, because it is metadata and belongs with the other metadata.

Post fragments are shared by post pages, the index, and now category pages, so the link
appears in all three from this one change.

## Discovering categories

`CATEGORY_SLUGS` is computed at parse time by one awk pass over `posts/*.txt`, reading only
front matter — it stops at the delimiter, so a line beginning `category:` in a post *body*
is not picked up. Output is slugified and deduped.

This is the first time the Makefile reads post *contents* to decide what to build, rather
than deriving everything from filenames. It is a real departure from the existing design
and worth calling out, but there is no alternative: categories live inside posts, and a
sidecar file written during the build would not exist on the first parse of a clean tree.

`build` gains `$(addprefix $(BUILD_DIR)category/,$(addsuffix .html,$(CATEGORY_SLUGS)))`.

## Build rule

```
$(BUILD_DIR)category/%.html: $(TMP_FILES) templates/base.txt config
```

The recipe walks posts newest-first, keeps those whose slugified category equals the stem,
cats their fragments, and wraps the result with the existing `WRAP_IN_BASE`, with
`PAGE_TITLE` set to `<Display Name> - <Blog Name>`. The display name comes from the first
matching post.

Ordering is free: `POST_FILES` is already numerically sorted by date, so reversing it gives
newest-first.

Two pattern rules now match `build/category/notes.html` — this one and `build/%.html`. GNU
make picks the rule with the shortest stem, which is this one (`notes`, versus
`category/notes`). Verified on make 3.81 before adopting the approach.

The dependency on every `.tmp` file is deliberately coarse. Editing one post re-cats every
category page. The precise alternative is a `$(shell)` grep per category at parse time; for
a personal blog the extra `cat` and `awk` runs are not worth that.

## Failing on a missing category

Validation lives in the `%.tmp` recipe, which is per-post and can name the offending file:

```
posts/2026-08-06-a-post.txt: missing a category: line
```

`README.md` already documents `category:` as required, so this turns a documented
requirement into an enforced one instead of emitting `in <a href="/category/.html"></a>`.

`.DELETE_ON_ERROR:` is added at the same time, so a failed rule cannot leave a truncated
`.tmp` behind for the next build to treat as good.

## Known limitation

Renaming or removing a category leaves its old page in `build/`, since nothing records that
the page used to exist. This is the same class of problem as deleting a post, already
documented in CLAUDE.md. `make clean` fixes both. Not solved here.

## Testing

- Category with spaces and mixed case → correct slug, display text preserved
- Category with punctuation → punctuation dropped from the slug
- Two posts sharing a category → both on the page, newest first
- Post with no `category:` line → build fails, message names the file, no partial output
- A body line beginning `category:` → not mistaken for front matter
- Category link present on post pages, the index, and category pages
- Category page `<title>` uses the display name and the configured blog name
- `make -j8` clean; no-op rebuild after a successful build
- `build/` still contains only publishable HTML
- Existing suite still passes: date formatting, index ordering and 10-post cap, the
  `Markdown.pl` path, ampersands in titles and bodies, zero posts
