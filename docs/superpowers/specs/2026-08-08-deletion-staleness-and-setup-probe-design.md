# Deletion staleness, the punctuation probe, and two setup fixes

Four backlog items, taken together because three of them live in `setup`'s recipe and the
fourth is the last ranked item anyone asked for. Ranked backlog item 8 (the feed's
post-deletion self-heal), residual item 9 (the punctuation gap in the markdown probe),
residual item 10 (two concurrent setups sharing `config.mk.new`), and the Minor bullet about
setup being quiet about a candidate it rejected.

Not in scope: ranked item 6, the single-pass `fill()`. It is a separate decision and a
separate branch.

## 1. Item 8 is three consumers, not one

The backlog and CLAUDE.md both describe this as a property of the **feed**. It is not. The
same mechanism leaves the deleted post on the **index** and on its **category page**, and it
is worse there.

`work/rss.tmp` and `work/index.tmp` are `cat`s of a newest-ten window; a category page is an
awk pass over every fragment in its category. All three take the current window as
*prerequisites*, so make asks "is any prerequisite newer than the target?" — a question that
cannot notice that the *set* changed. Delete a post and the window loses a member and gains
another; if the incoming member's fragment is already on disk and older than the target,
nothing rebuilds and the deleted post stays in the output.

The asymmetry between the feed and the other two is the reason the feed looked healthier:

- **`.rssitem` files are built only for the window.** In a fresh corpus the eleventh-newest
  post has no `.rssitem`, so deletion forces one to be built, which makes `rss.tmp` out of
  date, which re-`cat`s. That is the documented heal.
- **`.tmp` files exist for every post**, because every post gets its own page and that page
  names its fragment as a prerequisite. So the incoming fragment is *always* already on disk
  and `index.tmp` **never** re-`cat`s. The category page has the same property and is not even
  windowed.

Reproduced in two sandboxes:

| corpus | deleted | `rss.xml` | `index.html` | `category/home.html` |
| --- | --- | --- | --- | --- |
| 12 posts built at once | newest | healed | **stale** | **stale** |
| 11 posts, then a 12th, then delete it | newest | **stale** | **stale** | **stale** |

So CLAUDE.md's "Deleting a post leaves its HTML behind" gotcha undersells the problem: the
orphaned page is the part a visitor cannot reach, and the front page goes on linking to it.

### The fix

Add `posts` — the directory — as a prerequisite of `work/index.tmp`, `work/rss.tmp`, and
`build/category/%.html`.

Removing a file updates its parent directory's mtime, so a directory mtime records exactly the
condition we need: *the set of posts changed*. Adding, deleting, and renaming all bump it;
editing a post's contents does not, and does not change the set either. There is no
under-trigger. The over-trigger is anything that changes a directory entry: an unrelated file
appearing in `posts/`, and also any editor that saves by **rename-into-place** rather than
in-place write (`sed -i`, vim under `backupcopy=auto`). Verified both ways — an in-place
append does not bump the directory mtime, a rename-into-place save does. Each costs one
re-`cat` and one re-wrap.

It also over-triggers *across* categories: deleting a `home` post rebuilds
`build/category/work.html` too, since `posts` is now a prerequisite of every category page.
Cheap and correct, but it falsifies a CLAUDE.md sentence — see Documentation below.

Verified on Linux/ext4. POSIX requires a parent directory's mtime to update on entry creation
and removal, and APFS complies by specification, but that half is **guaranteed by spec, not
observed** — no macOS host was available. It belongs in the same bucket as the BSD `date`
dialect, which the owner exercised by hand and no automated run covers.

This is preferred over the stamp file the backlog proposed (`work/rss.list` holding
`RECENT_ITEMS`, rewritten under `cmp`, plus a `FORCE` target to make it checked every build).
The stamp is exact where the directory is merely sufficient, but it costs a new file in
`work/`, a new rule, a phony `FORCE`, and a recipe that runs on every build — against three
words. Grampa's whole argument is that make's own primitives are enough; a directory mtime is
one of them.

### The one behaviour change, and its cure

A tree with **no `posts/` directory at all** currently builds an empty site at exit 0. With a
bare prerequisite it would die on make's own `No rule to make target 'posts'`. Verified.

Cured by giving `posts` a rule:

```make
posts:
	@mkdir -p posts
```

With no prerequisites and the directory present, make judges it up to date and never runs the
recipe, so this costs nothing on every normal build. With the directory absent it is created
and the empty site builds at exit 0, exactly as before. Verified in both states, including
that a following no-op rebuild stays quiet.

### The `.SECONDARY` argument stops being load-bearing, and the mutation has been run

The `.SECONDARY` comment block argues at length that keeping `RSSITEM_FILES` *out* of
`.SECONDARY` is what lets the feed self-heal, calls listing them "actively harmful", says it
was "verified empirically both ways", and names `test_deleting_a_post_heals_the_feed` as the
guard. The spec's first draft left this as a task to be settled by mutation rather than
reasoning. It has now been settled by mutation.

**Result: after fix D the mutation is harmless, and no test distinguishes it.** With
`$(RSSITEM_FILES)` appended to `.SECONDARY` on top of D, both corpus shapes heal completely —
ten items, Post 2 pulled in, Post 12 gone, and the newly-in-window `.rssitem` built (11 on
disk after the delete). The mechanism: the `posts` prerequisite makes `work/rss.tmp`
unconditionally out of date on any set change, and once a target must be remade make builds
its missing secondary prerequisites anyway.

So the rewrite must say **unnecessary, not harmful**: `.rssitem` files are explicit
prerequisites of an explicit target and are therefore never reaped, and `.SECONDARY`
membership no longer changes any observable behaviour. Three specific sentences become false
and must go: "actively harmful", "verified empirically both ways", and the citation of
`test_deleting_a_post_heals_the_feed` as the guard — that test now passes *with* the mutation.

The same claim is duplicated in CLAUDE.md's build-pipeline section, in the paragraph about
`.rssitem` files ("listing them in `.SECONDARY` anyway would be actively harmful"). Both
copies get rewritten; see Documentation.

**One caveat, stated because it is exactly the kind of claim this repo does not let stand
unqualified.** Intermediate-file and `.SECONDARY` semantics are the area where make 3.81 and
4.x have historically differed most, and this mutation result was obtained on GNU make 4.4.1.
If the 3.81 floor is still real, this is the finding to re-confirm there first.

## 2. Item 9 — the punctuation probe, and the false positive it nearly caused

`setup`'s probe renders `x <i>y</i>` and requires exit 0, a surviving `<i>`, and no whole
document. It says nothing about typography, so a candidate whose smartypants flag is wrong
passes detection and quietly rewrites the author's quotes and dashes.

The obvious extension — assert that a `"` and a `--` both survive — **rejects three good
processors**. Measured on this host against every installed candidate, using the exact argv in
`MARKDOWN_CANDIDATES`, input `x <i>y</i> "q" -- z`:

| candidate | output |
| --- | --- |
| `lowdown --out-no-smarty …` | `x <i>y</i> "q" -- z` |
| `cmark-gfm --unsafe …` | `x <i>y</i> &quot;q&quot; -- z` |
| `md2html --github` | `x <i>y</i> &quot;q&quot; -- z` |
| `markdown -f +tables,-smarty` | `x <i>y</i> "q" -- z` |
| `cmark --unsafe` | `x <i>y</i> &quot;q&quot; -- z` |
| `markdown_py -x tables` | `x <i>y</i> "q" -- z` |
| `pandoc -f markdown-smart -t html` | `x <i>y</i> "q" -- z` |

`cmark`, `cmark-gfm` and `md2html` HTML-escape a double quote in text content. That is
escaping, not smartening — it renders identically — but a literal `"` assertion cannot tell the
difference and would skip all three. This is precisely the "probe so strict a perfectly good
processor gets skipped" risk the backlog named.

The same three candidates with their smartypants flag deliberately removed:

| candidate | output |
| --- | --- |
| `lowdown --html-no-skiphtml --html-no-escapehtml` | `x <i>y</i> &#8220;q&#8221; &#8211; z` |
| `pandoc -f markdown -t html` | `x <i>y</i> “q” – z` |
| `markdown -f +tables` | `x <i>y</i> &ldquo;q&rdquo; &ndash; z` |

**The dash alone is a perfect discriminator**: intact in all seven correct configurations,
mangled in all three wrong ones, and immune to the escaping confound. So:

- Probe input becomes `x <i>y</i> -- z`.
- One new check: reject any candidate whose output does not contain `--`.
- No quote check, and no quote in the probe input — asserting nothing about it means it earns
  no place there.

The `<i>` and whole-document checks stay, and **that sentence is load-bearing rather than
tidy**: `cmark` without `--unsafe` renders the dash input as
`<p>x <!-- raw HTML omitted -->y<!-- raw HTML omitted --> -- z</p>`, which *contains* `--`, so
the dash check alone would accept a candidate that eats raw HTML. The `<i>` check is what
rejects it. Either order works and both report the truer reason.

**Residual, deliberately.** A processor that smartens quotes but *not* dashes passes. No row in
the table can reach that state — every candidate gates both behind a single switch.
Python-Markdown is the only one whose smarty extension separates `smart_dashes` from
`smart_quotes`, and our row (`markdown_py -x tables`) never enables smarty at all. That last
claim is **from documentation, not observed** — the same standing the three unrun candidate
rows have — since three of the four relevant tools are not installed on any review host.

## 3. Setup is quiet about a candidate it rejected

If you have `lowdown` installed but a build whose flags the probe does not accept, setup skips
it silently, falls through, and reports only the winner. The build notice then names a
processor you did not expect, with no hint why. The punctuation check above makes this more
likely, not less.

Each rejection inside the probe loop gains one line on stderr naming the candidate and the
reason: `not runnable`, `emits a whole document`, `drops raw HTML`, `smartens punctuation`.

Three constraints:

- **The prefix must not be `grampa: markdown:`.** `test_clean_and_setup_print_no_notice`
  (`tests/run.sh:669`) captures `make setup` with `2>&1` and asserts `grampa: markdown:` is
  absent, because that is the build notice's prefix and setup must stay quiet about it. The
  line is therefore `grampa: setup: <probe>: <reason>`. Confirmed against the test, and a
  Makefile using that wording passes the full suite.
- **Only for candidates actually found.** The `command -v` / `[ -x ]` misses keep their silent
  `continue`, or a machine with one processor prints eleven lines of noise every setup.
- **stderr, not stdout.** The loop runs inside `winner=$(… )`, so anything on stdout would be
  captured as the winner. Verified under `make setup`, `make -s setup` and `make -j4 setup`:
  notices on stderr only, winner uncorrupted.

**Known cosmetic consequence in the suite.** `hide_markdown_tools` installs executable exit-1
stubs for all eleven PATH candidates, so in every sandbox all eleven are *found*, probed, and
rejected — each test setup will emit up to eleven `not runnable` lines on stderr. Harmless:
`sandbox()` redirects them and `markdown_stub` shows output only on failure, where the lines
are arguably useful. Recording it so nobody reads it as a regression. The "only for candidates
actually found" rule keeps real machines quiet; it does not keep the suite quiet.

## 4. Item 10 — two concurrent setups share one scratch name

`setup` writes probe results to the fixed name `config.mk.new`, then `mv`s it over `config.mk`
if `cmp` says the content differs. Two setups at once in one directory share that name, so one
can truncate the file the other is midway through writing and the `mv` can promote a
half-written `config.mk` — which every subsequent parse `-include`s. `mv` is atomic, so the
interleaving has to land inside the write rather than the rename.

`config.mk.new` becomes `config.mk.$$$$` — Makefile `$$$$` expands to shell `$$`, the PID.

`.gitignore`'s `/config.mk.new` becomes `/config.mk.*`, which covers the PID form and the old
name both. It is a one-for-one replacement, **not** a line saved — `/config.mk.*` does not
match `config.mk` itself, so the `/config.mk` line above it stays. Verified with
`git check-ignore -v` in a scratch repo: `config.mk.new`, `config.mk.12345` and
`config.mk.orig` all match the new pattern, `config.mk` matches its own line, and
`docs/config.mk.12345` matches neither — still anchored.

No test. Reproducing it needs two racing shells and a window inside a `printf`; the backlog's
judgement was that no test is worth writing and that is right.

**One consequence recorded rather than discovered later.** With a fixed name, a setup aborted
between the write and the `mv` left a file the next setup overwrote. With a PID name it leaks
`config.mk.<pid>` indefinitely — gitignored, inert, and not removed by `make clean`. Accepted
rather than cured with a `trap … EXIT`, which would grow an already-long single logical line
for a file nothing reads.

## Tests

All watched failing first, each against the specific regression it guards.

| test | guards |
| --- | --- |
| `test_deleting_a_post_heals_the_index` | index staleness — the case nothing covered |
| `test_deleting_a_post_heals_the_category_page` | category staleness |
| `test_deleting_a_post_heals_the_feed_after_incremental_growth` | the feed case that was *actually* broken; distinct from the existing all-at-once test, which passed against the bug |
| `test_build_works_without_a_posts_directory` | the `posts:` rule; fails with a bare prerequisite |
| `test_probe_rejects_a_smartening_candidate` | the new dash check |
| `test_probe_accepts_escaped_quotes` | the false positive above — a stub that escapes a quote must still win |
| `test_setup_names_a_rejected_candidate` | the stderr notice |

`test_probe_accepts_escaped_quotes` is a **tripwire, not a live guard**, and its banner must
say so. With no quote in the probe input a cmark-like stub escapes nothing, so it passes
trivially today; it only bites if someone later adds a quote to the probe input *and* a
literal-`"` check, which is exactly the mistake this spec avoided. For it to bite at all the
stub must escape *conditionally* (`sed 's/"/\&quot;/g'`) rather than emit `&quot;`
unconditionally — an unconditional stub would test nothing in either world.

`test_deleting_a_post_heals_the_feed_after_incremental_growth` is confirmed distinct: the
existing `test_deleting_a_post_heals_the_feed` **passes against the unfixed Makefile**, because
its all-at-once sandbox is the one shape where the heal already worked. The new test covers
what the old one never did.

`test_deleting_a_post_heals_the_feed` stays as-is; its sandbox builds all twelve posts at once,
which is the corner where the heal already worked, and it should keep passing unchanged.

Every deletion test needs the `sleep 1` the suite already uses: make 3.81 truncates mtimes to
whole seconds, so a sub-second-newer prerequisite rebuilds nothing.

## Documentation

- CLAUDE.md's feed-self-heal gotcha loses its narrow condition entirely — deletion now heals
  the feed in every case, including the ten-or-fewer-posts case it currently says never heals.
- CLAUDE.md's "Deleting a post leaves its HTML behind" gotcha shrinks to what is genuinely
  unfixable: the deleted post's own page lingers in `build/`. The front page no longer links to
  it. Same for the deleted-category gotcha, which is unchanged — a removed category's page is
  still an untracked output nothing can know about.
- The `.SECONDARY` comment block (`Makefile:169-185`), per §1: "actively harmful" becomes
  "unnecessary", the "verified empirically both ways" sentence goes, and the citation of
  `test_deleting_a_post_heals_the_feed` as its guard goes with it.
- **CLAUDE.md:353**, the build-pipeline paragraph about `.rssitem` files, carries the same
  "listing them in `.SECONDARY` anyway would be actively harmful" claim and gets the same
  rewrite. The spec's first draft named only the Makefile comment and missed this copy.
- **CLAUDE.md:373**, "Its prerequisites are exact, because `CATEGORY_SLUGS` is derived from
  filenames at parse time" — no longer true once `posts` is a prerequisite of every category
  page. Verified: deleting a `home` post rebuilds `build/category/work.html` too.
- The markdown-detection section gains the dash check and the reason it is not a quote check;
  the `--unsafe`-family gotcha gains the rejection notice.
- `docs/backlog.md`: items 8, 9, 10 and the rejected-candidate bullet marked done, with the
  index/category widening recorded as a finding the entry itself did not have.

## Out of scope

- **Ranked item 6**, the single-pass `fill()`. A separate decision.
- **Correcting the three unrun candidate rows by hand** (`multimarkdown`, `comrak`,
  `markdown-it`). The probe extension closes the punctuation class for every present and future
  row without installing anything, which the backlog already argued is the better half of item
  9. Installing three toolchains to correct today's table remains available and remains
  unranked.
- **make 3.81.** Whether that floor is still real is a decision, not work.

## Provenance of the evidence in this spec

Everything measured here was run on **GNU make 4.4.1 on Linux/ext4**, in scratch sandboxes
seeded from `Makefile`, `.source/`, `tests/` and `tools/` the way `tests/run.sh` seeds them.
The real tree was never built in. A Makefile carrying all four changes passes the existing
suite at **335 passed, 0 failed**.

Three things are **not** verified and are marked as such where they appear: anything about make
3.81 (the `.SECONDARY` mutation result is the one that could plausibly differ), anything about
macOS/APFS (directory-mtime semantics), and the dash behaviour of the four candidates not
installed on any review host — `smu`, `comrak`, `multimarkdown`, `markdown-it`. The last is
unchanged from today's position: the probe is what keeps those rows honest, and extending it is
the whole point of §2.
