# RSS feed

Date: 2026-08-06

## Problem

`build/atom.xml` has been a stub since the beginning — a rule that echoes `"Making
atom.xml"` and produces no file (`Makefile:432-436`). `.source/templates/atom.txt` is a
zero-byte file. README still lists "Atom feed" as a thing to do.

Meanwhile the build has no feed of any kind. A weblog without one is not really publishing.

## Goal

Delete the Atom stub. Ship a working RSS 2.0 feed at `build/rss.xml`, built from the same
post fragments everything else is built from.

## Sequencing decision: feed first, templating engine later

The question that started this design was whether to build a general templating engine
first and write the feed on top of it. The answer is no, for three reasons:

1. **Nothing hurts yet.** `fill()` plus `RENDER_POST` and `WRAP_IN_BASE` cover all three
   existing page types without friction. An engine built now solves a problem nobody has.

2. **Repetition is already solved without templating loops.** The feed's `<item>` list
   looks like it needs a loop construct. It does not — grampa has never templated
   repetition, it concatenates fragments. `work/index.tmp` is ten fragments `cat`ed
   together; category pages hand N fragments to awk as multiple input files. The feed uses
   the identical shape.

3. **The generalization we would get wrong is escaping.** RSS must XML-escape titles and
   bodies; the HTML pages must not escape bodies. That is a per-consumer policy, and
   guessing at how a general renderer expresses it — before a second consumer exists — is
   how the abstraction comes out wrong.

The cost of this order is some duplicated awk. That cost is accepted deliberately: the
duplication is the evidence a future engine gets designed from, and it is cheaper to
collapse two concrete programs later than to un-bake a wrong abstraction from the build
pipeline. See "Duplication we are keeping on purpose" below.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Item contents | Full post body in `<description>` | What a personal weblog feed is for. No summary field exists in front matter, and truncating HTML mid-tag is its own bug farm. |
| Missing `url=` | Skip the feed, build succeeds | A feed is opt-in in a way a post page is not. Making a new key retroactively mandatory would break builds that work today. |
| Item count | Newest 10 | Same window as the index; reuses the existing `reverse`/`wordlist` idiom. Full bodies make "all posts" grow without bound. |
| Autodiscovery `<link>` | Hardcoded `/rss.xml` in `.source/templates/base.txt` | One line in a tracked file, zero Makefile changes. A `{{feed_url}}` placeholder would need threading through all three page recipes for one `<head>` line. |
| `<lastBuildDate>` | Omitted | Optional, and it would make the feed differ on every rebuild even when no post changed. |
| Channel `<description>` | Reuse the blog name | RSS requires the element. A third config key for it is a knob nobody asked for. |

## Removing Atom

- Delete the `$(BUILD_DIR)atom.xml` rule (`Makefile:432-436`).
- Delete `.source/templates/atom.txt`.
- Remove `1. Atom feed` from the README todo list; add the feed to the feature prose.

CLAUDE.md needs more than the stub sentence — see "Documentation updates" below.

Existing installs have a `templates/atom.txt` in their gitignored working copy. `make
setup` will not remove it and nothing reads it, so it is inert. Note it in the README
rather than writing cleanup code for a zero-byte file.

## The `url=` config key

`config` gains a second key, read exactly like `name=` — last one wins, whitespace
trimmed, `#` comments ignored:

```make
CONFIG_URL = $(shell sed -n 's/^url=[[:space:]]*//p' config 2>/dev/null | sed 's/[[:space:]]*$$//' | tail -1)
SITE_URL   = $(patsubst %/,%,$(strip $(CONFIG_URL)))
export SITE_URL
```

Lazily expanded with `=`, not `:=`, for the same reason as `CONFIG_NAME`: on a first-ever
run the `config` target has not copied the file into place when the Makefile is parsed.

`patsubst %/,%` strips a trailing slash so `https://torrez.org/` plus `/2026/08/06/x.html`
does not produce `//2026`.

`SITE_URL` is exported rather than interpolated into recipes, so a URL containing a quote
or a `$` cannot break the build — the same rule `BLOG_NAME` follows.

`config.example` gains a commented-out `#url=https://example.com` explaining that leaving
it unset means no feed is built.

### Conditional target

```make
FEED_PAGES = $(if $(SITE_URL),$(BUILD_DIR)rss.xml)
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html $(CATEGORY_PAGES) $(FEED_PAGES)
```

With no `url=`, nothing feed-related is built — not the fragments, not the XML. When
`FEED_PAGES` is empty, `build`'s recipe echoes a one-line note saying the feed was skipped
and why.

**Known edge, accepted.** `build`'s prerequisites expand at parse time, but the `config`
target creates `config` later in the same run. So on a truly first-ever `make` in a fresh
checkout, `SITE_URL` is empty regardless of anything. This is harmless: the freshly copied
`config.example` has `url=` commented out anyway, so a first run should skip the feed. It
only surfaces if someone hand-writes a `config` containing `url=` before ever running
`make`, and their second `make` picks it up.

## Build pipeline

```
posts/2026-08-06-home_a-post.txt
  └─ work/2026-08-06-home_a-post.staged        (front matter + Markdown'd body)
        ├─ awk RENDER_POST    → work/….tmp     → post page, index, category page
        └─ awk RENDER_ITEM    → work/….rssitem
              └─ cat 10 newest → work/rss.tmp
                    └─ awk WRAP_IN_CHANNEL → build/rss.xml
```

### `.staged` becomes a real target

Today the Markdown `split` / `cat` / `Markdown.pl` sequence runs inside the `%.tmp` recipe
and `rm`s its output on the way out (`Makefile:404-429`). The feed needs the same rendered
body *and* the post's individual fields — title, body, date — which `work/%.tmp` has
already dissolved into HTML. So the staging step is promoted:

```make
STAGED_FILES = $(addprefix $(WORK_DIR),$(POST_NAMES:.txt=.staged))

$(WORK_DIR)%.staged: posts/%.txt
	@mkdir -p $(WORK_DIR)
	@# Markdown.pl branch: the existing split / Markdown.pl /
	@# reassemble block from Makefile:410-417, writing to $@
	@# rather than to $(WORK_DIR)$*.staged, and without the
	@# trailing rm at Makefile:429.
	@# No-Markdown.pl branch: cp $< $@, as at Makefile:419-422.

$(WORK_DIR)%.tmp: $(WORK_DIR)%.staged templates/post.txt
	@echo "Building $@"
	@mkdir -p $(WORK_DIR)
	@awk -v pub_date="$(call date_from_filename, $@)" \
		-v permalink="/$(call page_for,$@).html" \
		-v category="$(call category_display,$(call category_slug,$@))" \
		-v category_url="$(call category_url,$@)" \
		"$$RENDER_POST" $< > $@;
	@echo "Done";
```

The `%.tmp` rule is written out in full deliberately. Its recipe is the existing one from
`Makefile:400-430` with the whole Markdown block lifted out, the prerequisite changed from
`posts/%.txt` to `work/%.staged`, `$<` now naming the staged file, and the trailing `rm -f`
dropped.

**Do not express this as a bare dependency line.** For an *explicit* target, a recipe-less
`target: prereq` line adds prerequisites to the existing rule. For a *pattern* rule it does
not — it declares a separate, recipe-less pattern rule, and the template dependency
silently evaporates. Verified on this machine's make 3.81: with a recipe-less
`work/%.tmp: work/%.staged templates/post.txt` alongside the recipe-bearing rule, touching
`templates/post.txt` rebuilt nothing at all. Every pattern rule below carries its own
complete prerequisite list and recipe.

`.staged` joins `.SECONDARY` alongside `.tmp` so make keeps it between builds.

Two improvements fall out: `Markdown.pl` runs once per post instead of twice, and editing
`templates/post.txt` no longer re-runs Markdown at all. One cost: `work/` keeps a staged
copy of every post. It is gitignored and `make clean` wipes it.

The alternative — duplicating the Markdown block into the item recipe — would run
`Markdown.pl` twice per post and leave two copies of a fiddly `split` / `tail -n +2`
sequence to keep in sync.

The `split` prefix is `$(WORK_DIR)$*.` and cleanup globs `$(WORK_DIR)$*.a[a-z]*`, which
cannot match `$*.staged`.

### New rules

```make
RSSITEM_FILES = $(addprefix $(WORK_DIR),$(POST_NAMES:.txt=.rssitem))
RECENT_ITEMS  = $(wordlist 1, 10, $(call reverse, $(RSSITEM_FILES)))

$(WORK_DIR)%.rssitem: $(WORK_DIR)%.staged templates/rss-item.txt config
	@echo "Building $@"
	@mkdir -p $(WORK_DIR)
	@awk -v pub_date="$(call rfc822_from_filename,$@)" \
		-v item_path="/$(call page_for,$@).html" \
		-v category="$(call category_display,$(call category_slug,$@))" \
		"$$RENDER_ITEM" $< > $@;

$(WORK_DIR)rss.tmp: $(RECENT_ITEMS)
	@mkdir -p $(WORK_DIR)
	@cat /dev/null $(RECENT_ITEMS) > $@

$(BUILD_DIR)rss.xml: $(WORK_DIR)rss.tmp templates/rss.txt config
	@echo "Building rss.xml"
	@mkdir -p $(dir $@)
	@awk "$$WRAP_IN_CHANNEL" $< > $@;
```

`cat` keeps its `/dev/null` operand for the same reason `work/index.tmp`'s does: with no
files to read it would sit on stdin.

**`.rssitem` files must join `.SECONDARY`.** They are produced by a pattern rule and
consumed only as prerequisites of `work/rss.tmp`, so make would classify them as
intermediates and delete them on the way out — forcing a full feed rebuild every time, the
exact problem `.SECONDARY` already solves for `.tmp`. The declaration becomes:

```make
.SECONDARY: $(TMP_FILES) $(STAGED_FILES) $(RSSITEM_FILES)
```

**`config` is a prerequisite of `%.rssitem`.** Items bake the absolute URL in, so changing
`url=` must rebuild every item. This is the same reason `config` is already a prerequisite
of both HTML rules.

**No new pattern-rule ambiguity.** `build/rss.xml` and `work/rss.tmp` are explicit targets,
which beat pattern rules outright — the same reason `work/index.tmp` is not claimed by
`$(WORK_DIR)%.tmp`. The `build/category/%.html`-before-`%.html` ordering hazard documented
in CLAUDE.md is untouched: neither new target ends in `.html`.

### How values reach awk

Follows the rule the Makefile already established:

- **Config-derived values go through the environment** — `SITE_URL`, like `BLOG_NAME` and
  `PAGE_TITLE`.
- **Filename-derived values go through `-v`** — `pub_date`, `category`, `item_path`, like
  `RENDER_POST`'s existing `-v permalink`.

## awk programs

### `xml_escape`

A new helper interpolated the way `$(FILL_FN)` already is:

```awk
function xml_escape(s) {
    gsub(/&/, "\\&amp;", s);
    gsub(/</, "\\&lt;", s);
    gsub(/>/, "\\&gt;", s);
    return s;
}
```

`&` must be replaced first, or `<` → `&lt;` gets a second pass into `&amp;lt;`.

The `"\\&amp;"` matters: in a gsub *replacement* a bare `&` means "the matched text" — the
same trap that made `fill()` necessary instead of `sub()`, and that once rendered a post
titled `Tom & Jerry` as `Tom {{title}} Jerry`.

On the first line a bare `&` would come out right by accident. On the other two it is
actively wrong, because the matched text is no longer an ampersand:

```
input:                Tom & Jerry <p>a=1&b=2</p>
with "\\&amp;" etc:   Tom &amp; Jerry &lt;p&gt;a=1&amp;b=2&lt;/p&gt;      correct
with bare "&lt;" etc: Tom &amp; Jerry <lt;p>gt;a=1&amp;b=2<lt;/p>gt;   garbage
```

All three get the explicit escape, and a comment points at the `fill()` one — so nobody
later "simplifies" two-thirds of the function on the strength of the first line working.

Applied to: item title, body, category, link; channel title, link, and description.
**Not** applied to `{{items}}` in the channel template — those are already-escaped XML.

### `RENDER_ITEM`

Parses front matter the same way `RENDER_POST` does — `title:` line, 35-hyphen delimiter,
everything after is body — then reads `templates/rss-item.txt` through `fill()`, escaping
each value with `xml_escape` on the way in. Builds `{{link}}` by concatenating
`ENVIRON["SITE_URL"]` with the `-v item_path` make supplies.

### `WRAP_IN_CHANNEL`

Reads the concatenated items from its input file — `work/rss.tmp`, passed as `$<`, exactly
as `WRAP_IN_BASE` receives `work/index.tmp` — then reads `templates/rss.txt` through
`fill()`.
Fills `{{title}}` and `{{description}}` from `xml_escape(ENVIRON["BLOG_NAME"])`, `{{link}}`
from `xml_escape(ENVIRON["SITE_URL"])`, and `{{items}}` from the accumulated input,
unescaped.

Both are `export`ed like `RENDER_POST` and `WRAP_IN_BASE`, and interpolate `$(FILL_FN)` and
the new escape helper.

### Guarding the template read

Both new programs read their template as `while ((getline line < "templates/rss.txt") > 0)`,
with the explicit `> 0`. The existing programs write `while (getline < "…")`, which is a
latent hang: `getline` on a missing file returns `-1`, and `-1` is truthy. Verified:

```
$ awk 'BEGIN{ n=0; while ((r = (getline line < "nope.txt"))) { n++; if (n>3) { print "LOOPS FOREVER, getline returns " r; exit } } }'
LOOPS FOREVER, getline returns -1
```

This matters because the two new templates arrive only via `make setup`. A new install gets
them; an **existing** install has a populated `templates/` and no reason to re-run setup, so
it would spin on a missing `templates/rss.txt` the moment it set `url=`. The guard turns
that into an empty feed instead of a hang, and the rollout note below turns it into neither.

Note this also contradicts CLAUDE.md, which says running from the wrong working directory
"silently produces pages with empty bodies rather than an error." It hangs. Correcting that
sentence is part of the doc updates below. The existing `RENDER_POST` and `WRAP_IN_BASE`
carry the same latent bug; fixing them is out of scope here and belongs in the full-repo
review, but it should not be forgotten.

### Duplication we are keeping on purpose

`WRAP_IN_CHANNEL` is nearly `WRAP_IN_BASE` with a different `getline` path, and
`RENDER_ITEM` repeats `RENDER_POST`'s front-matter parse loop. Both are tempting to
collapse.

`WRAP_IN_BASE` must **not** escape its page title; `WRAP_IN_CHANNEL` must. Sharing one
program means adding an escape flag to it — a policy switch inside a general renderer,
which is the thing this design deliberately defers. Roughly twelve lines of duplicated
boilerplate is the cheaper mistake, and it is the concrete input a future templating engine
gets designed from.

## Dates

RSS 2.0 requires RFC-822:

```make
rfc822_from_filename = $(shell LC_ALL=C date $(join $(addprefix -v, $(wordlist 1, 3, $(subst -, , $(notdir $(1))))), y m d) -v0H -v0M -v0S "+%a, %d %b %Y %H:%M:%S %z")
```

Verified: `2026-08-06` produces `Thu, 06 Aug 2026 00:00:00 -0700`.

**`LC_ALL=C` is not optional.** RFC 822 day and month names are literal English tokens, and
`$(shell)` inherits the user's locale. Verified on this machine:

```
$ LC_ALL=fr_FR.UTF-8 date -v2026y -v8m -v6d -v0H -v0M -v0S "+%a, %d %b %Y %H:%M:%S %z"
jeu., 06 août 2026 00:00:00 -0700
```

That is an invalid `pubDate`, and it would ship silently from any non-English machine.
`date_from_filename` has the same sensitivity but not the same problem — there the output is
prose for a human, so every locale is correct. Here it is a protocol violation, so only this
helper gets the `LC_ALL=C`.

**`-v0H -v0M -v0S` is load-bearing.** `date -v2026y -v8m -v6d` keeps the *current* clock
time, so without pinning to midnight every build emits different `pubDate`s and `rss.xml`
shows as changed on every deploy.

Posts carry a date and no time, so midnight local — `%z` giving the machine's offset — is
the honest reading, and it is what `date_from_filename` already implies. BSD-only, the same
constraint the existing helper has.

## Templates

Both land in `.source/templates/` and are picked up by `make setup`, which globs
`.source/templates/*`.

`rss-item.txt`:

```xml
<item>
	<title>{{title}}</title>
	<link>{{link}}</link>
	<guid isPermaLink="true">{{link}}</guid>
	<pubDate>{{pub_date}}</pubDate>
	<category>{{category}}</category>
	<description>{{body}}</description>
</item>
```

`{{link}}` appears twice but on separate lines, so `fill()`'s first-match-per-line limit is
not a problem. The `<guid>` is how readers tell a re-fetched item from a new one.

`rss.txt`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
	<title>{{title}}</title>
	<link>{{link}}</link>
	<description>{{description}}</description>
{{items}}
</channel>
</rss>
```

`.source/templates/base.txt` gains one line in `<head>`:

```html
<link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml">
```

Because `make setup` copies with `yes n | cp -i` and never clobbers, this reaches new
installs only. Existing installs edit `templates/base.txt` by hand. The README documents
the snippet.

### Rollout for existing installs

**Existing installs must re-run `make setup`** to pick up `rss.txt` and `rss-item.txt`. It
is safe — `yes n | cp -i` never clobbers, so it copies only the two files that are missing.
Without it, setting `url=` points the build at templates that do not exist. The README's
`url=` documentation says this explicitly.

The `base.txt` autodiscovery line is the one thing setup cannot deliver to an existing
install, since their `templates/base.txt` already exists. That is a hand-edit, and the
README carries the snippet.

**The autodiscovery link dangles when `url=` is unset.** Two settled decisions interact:
`base.txt` advertises `/rss.xml` unconditionally, and no `url=` means no feed is built — so
an install without `url=` serves pages pointing at a 404. Neither decision changes; the
README's `url=` section notes the interaction so the fix (set `url=`, or delete the line) is
obvious to anyone who trips on it.

## Testing

All in `tests/run.sh`, in the existing style — `sandbox`, `add_post`, `build`, `assert_*`,
plus a line in the runner list at the bottom. Turning the feed on means overwriting
`config` the way `test_blog_name_from_config` already does:
`printf 'name=…\nurl=https://example.com\n' > config`.

| Test | Guards |
| --- | --- |
| `test_no_url_means_no_feed` | Default config builds fine and produces no `build/rss.xml` |
| `test_feed_is_built_when_url_is_set` | `<rss version="2.0">`, one `<item>`, absolute `<link>https://example.com/2026/08/06/hello.html</link>` |
| `test_feed_escapes_titles_and_bodies` | The `Tom & Jerry` post: `<title>Tom &amp; Jerry</title>`, `&lt;p&gt;`, `a=1&amp;b=2`, and `assert_not_grep` for a raw `<p>` |
| `test_feed_is_capped_at_ten_newest` | 12 posts → exactly 10 `<item>`s, newest first, oldest absent |
| `test_feed_pubdate_is_rfc822` | `<pubDate>Thu, 06 Aug 2026 00:00:00` — prefix only, since `%z` varies by machine and DST |
| `test_feed_is_byte_stable_across_rebuilds` | `make clean && make` twice, `cmp` the two feeds |
| `test_changing_url_rebuilds_the_feed` | Build with one `url=`, rewrite config, rebuild, links use the new host |
| `test_feed_link_omits_the_category` | Same invariant as `test_url_omits_the_category`, on the feed |
| `test_feed_with_zero_posts` | `url=` set, no posts: build succeeds, does not hang, feed is a valid empty channel |
| `test_base_template_advertises_the_feed` | `application/rss+xml` in `build/index.html` |

Three of these carry more weight than the rest.

`test_feed_is_byte_stable_across_rebuilds` is the only check that catches a regression in
the `-v0H -v0M -v0S` pinning, or someone adding `<lastBuildDate>` back. Both produce a feed
that looks perfectly correct in isolation and churns on every deploy.

`test_feed_escapes_titles_and_bodies` deliberately shadows the existing
`test_ampersands_are_not_mangled`, which asserts the opposite for HTML — that
`/search?a=1&b=2` passes through raw. Both, on the same input, in the same file, is what
pins escaping down as a per-consumer policy rather than something a later change "fixes"
into shared code.

`test_changing_url_rebuilds_the_feed` is the only check on `config` being a prerequisite of
`%.rssitem`. Drop that prerequisite and every other test still passes, while real installs
get a feed full of stale hostnames that no rebuild ever corrects.

`test_feed_with_zero_posts` exists because the feed path re-derives every piece of
machinery that made `test_zero_posts_does_not_hang` (`tests/run.sh:190`) necessary in the
first place. The design handles it — `cat /dev/null` keeps `work/rss.tmp` off stdin, and
awk's `END` block runs on empty input, so `WRAP_IN_CHANNEL` still emits a well-formed
channel with no items — but nothing currently pins that.

`test_feed_is_byte_stable_across_rebuilds` has to copy the first `rss.xml` somewhere outside
`build/` before the second `make clean` wipes it.

### Existing tests

**`test_parallel_build_is_clean` (`tests/run.sh:248`) must be updated.** It asserts:

```sh
assert_eq "no stray intermediates" "" "$(ls work/ | grep -v '\.tmp$' | tr '\n' ' ' | sed 's/ *$//')"
```

Persisting `.staged` files — the deliberate consequence of the `.SECONDARY` change — turn
that red immediately, and on default config, so no `url=` is needed to trip it. The grep
becomes `grep -vE '\.(tmp|staged|rssitem)$'`, which preserves the assertion's actual intent:
no leftover `.aa` / `.body` / `.mdbody` scratch from the `split` dance.

This is the one existing test the change breaks, and it is worth being precise about why the
first pass missed it: the audit checked the two "only `.html` under `build/`" tests, which
is an assertion about the *output* directory, and did not check the one assertion about
`work/`. The refactor's whole point is that it changes what lives in `work/`.

`test_build_contains_only_html` (`tests/run.sh:179`) and
`test_category_pages_are_html_only_in_build` (`tests/run.sh:519`) do stay green unmodified.
Both use the default config, which has no `url=`, so no `rss.xml` is ever built.

### Deliberately not tested

That `build/atom.xml` is gone. Asserting the absence of a file a passing build never
created is a test that cannot fail, and the suite has none of those.

## Documentation updates

CLAUDE.md has more surface affected than the atom stub sentence. All of the following are
false or incomplete once this ships:

| Location | Change |
| --- | --- |
| Build pipeline section | Stub sentence: drop `atom.xml` and `templates/atom.txt`; `index.txt` stays a stub and keeps its mention |
| `## config` section | "It is the only key anything reads" — now `name=` and `url=` |
| Gotchas, `config` bullet | Same claim, stated a second time |
| Build pipeline diagram | No `.staged` step, no feed branch |
| Layout table, `work/` row | "`.tmp` fragments, Markdown scratch" — now also `.staged` and `.rssitem` |
| Make helper functions list | Add `rfc822_from_filename` |
| Commands section | The missing-template claim is wrong: it hangs, it does not produce empty bodies (see "Guarding the template read") |
| Gotchas | Add the stale-`rss.xml`-after-removing-`url=` item from Known limitations below |

README gains: the `url=` key and what unsetting it means, the re-run-`make setup` note for
existing installs, the `base.txt` autodiscovery snippet, and the dangling-link interaction.

## Known limitations

- **Removing `url=` leaves a stale `build/rss.xml`.** Same class as the existing "deleting
  a post leaves its HTML behind" and "renaming a category leaves its old page" gotchas.
  `make clean` fixes it.
- **Deleting a post leaves it in the feed.** `work/rss.tmp` is newer than every surviving
  `.rssitem`, so nothing re-`cat`s it and the deleted post's `<item>` persists. Exactly the
  existing index/HTML gotcha, and `make clean` fixes it the same way.
- **Adding or removing `Markdown.pl` does not invalidate `.staged`**, whose only
  prerequisite is `posts/%.txt`. Bodies keep their previous rendering until a post is
  touched or `make clean` runs. This is byte-for-byte the current `.tmp` behaviour — the
  refactor changes nothing — but promoting `.staged` to a real file makes the staleness
  easier to notice, so it is written down.
- **The feed is BSD-only**, like the rest of the build, because of `date -v`.
