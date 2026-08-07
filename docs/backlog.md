# Backlog

Findings from full-repo reviews. Two sweeps so far, both on 2026-08-06:

- **First sweep**, after the RSS feed landed (`2c0c57d`).
- **Second sweep**, after the Markdown failure fix (`b0971a2`). Every item from the first
  sweep was re-checked. New items are numbered from 6.

Statuses below are current as of **this commit**, not as of the sweep: the sweep's CLAUDE.md
findings were fixed in the same commit that records them, so several items read "CLAUDE.md
FIXED, Makefile comment STILL OPEN". Line anchors into `CLAUDE.md` are post-fix; anchors into
`Makefile` are as of `b0971a2`, which left it untouched.

Nothing here is a regression from a recent branch unless noted — most of it predates both
the feed and the category features.

Every item is marked with how it was established:

- **verified** — reproduced by running the build in a sandbox
- **read** — established by reading the code, not executed

Nothing found endangers `posts/`. There have been no critical or blocking findings in
either sweep.

---

## Is the spirit of the tool intact?

**Yes.** Judged over the category pages, the RSS feed, the staging split, and the Markdown
failure fix, the Makefile has grown by symmetry rather than by abstraction. Every new piece
is a visible twin of an existing one: `RENDER_ITEM`/`RENDER_POST`,
`WRAP_IN_CHANNEL`/`WRAP_IN_BASE`, `work/rss.tmp`/`work/index.tmp`,
`RECENT_ITEMS`/`RECENT_FILES`, `rfc822_from_filename`/`date_from_filename`. Someone who
could read the index pipeline before the feed landed can read the feed pipeline by analogy
in one pass. The single factoring that did happen — `PARSE_FRONT_MATTER`, shared by the two
renderers — removes real duplication without becoming an engine, and the refusal to merge
rendering and escaping into one flagged generic program is written down as a deliberate
deferral rather than left for the next contributor to "improve". Complexity has tracked
capability roughly one-to-one. Nothing has drifted toward a framework.

The operational claims hold under execution, not just on paper: `build/` holds only `.html`
and `rss.xml`; `work/` holds only `.tmp`/`.staged`/`.rssitem` even under `-j8` with a
Markdown stub and the feed on; a no-op rebuild is quiet; editing `url=` rebuilds only feed
items; editing one category's post does not rebuild another category's page. The
incremental story is true and the tracked/untracked split is clean in the tree.

**The drift was in `CLAUDE.md`, not in the code.** At the time of the sweep it was 312 lines
— nearly half the length of the program it describes — and was carrying four stale or
contradictory claims (items 4, 6, and two Minor bullets). A document whose stated identity is
"checkable against the code" was accumulating debt faster than the code was. That pass has
since been made: the CLAUDE.md halves of those items are marked fixed below, in the same
commit that records this sweep. What remains of items 4 and 6 is the same two claims still
sitting in the Makefile's own comments.

**Subtractions worth making:** delete `.source/templates/index.txt` (item 7 — since done).
Nothing in the Makefile itself was
found removable — every rule, helper, and comment block is load-bearing. `tests/run.sh` is
longer than the program at 1108 lines, but it is plain bash with no framework and it buys
the 149 assertions that make claims like these checkable; that is the tool's spirit, not a
violation of it.

---

## Important

### 1. The Markdown staging branch swallows every failure — DONE

Fixed: the branch's steps are chained with `&&`, so a failing step fails the recipe.
Guarded by `test_failing_markdown_fails_the_build`.

Review caught a second-order bug the `&&` introduced: a failed run now stops before its
trailing `rm -f` and leaves split chunks in `work/`. Since the reassembly collects chunks
by glob, a post that later split into *fewer* chunks swept the stale ones back in — so
recovering from a Markdown failure republished text the author had deleted. Reproduced,
then closed by clearing the scratch namespace at the head of the chain too. Guarded by
`test_failed_markdown_leaves_no_stale_chunks`.

Note the fix catches a failing *step*, not a failing stage of a pipeline — `cat … | tail`
still reports `tail`'s status, so the unmatched-glob half of the last Minor item below is
still open.

`Makefile:596-603` — **verified**

The `if [ -x Markdown.pl ]` branch chains `split`, `cat | tail`, `./Markdown.pl`, and the
reassembly `cat` with `;`. The compound's exit status is therefore `rm -f`'s, which
essentially always succeeds. Any earlier step failing is invisible: the recipe reports
success, `.DELETE_ON_ERROR` never fires, and the half-written `.staged` file is trusted by
everything downstream.

Reproduced with a `Markdown.pl` that exits 1:

```
make exit code: 0
work/2026-08-06-home_hello.staged   →  front matter, delimiter, and nothing else
build/2026/08/06/hello.html         →  fully rendered page, empty body
grep -rc "Real body content" build/ →  0 in every file
```

This is the only path in the repo from a healthy source tree to silently deployable wrong
output. It matters more than its size suggests because it is also the only code the test
suite structurally cannot reach — `Markdown.pl` is optional and gitignored, so sandboxes
never have one (see item 5).

**Fix:** chain the branch with `&&`, or put `set -e;` at the top of the then-body, so a
failing step fails the recipe and `.DELETE_ON_ERROR` removes the partial file.
**Cost:** a few characters per line. No happy-path behaviour change.

### 2. Nothing guards the feed's post-deletion self-heal — DONE

Fixed: `test_deleting_a_post_heals_the_feed` — 12 posts, build, `sleep 1`, `rm` the newest,
rebuild, assert the window is still ten and Post 2 has been pulled in.

Watched fail first, against a `Makefile` with `$(RSSITEM_FILES)` appended to `.SECONDARY` —
the tidy-up this item predicts. It fails exactly as described: the feed freezes with Post 12
still in it and Post 2 never pulled in.

Worth recording what the RED run showed: **the item count stays at 10 in the broken case.**
A test that only counted `<item>` would have passed against the regression it exists to
catch. The title assertions — Post 2 present, Post 12 gone — are the whole test; the count is
decoration. (`test_feed_is_capped_at_ten_newest` does assert titles as well as counts; the
point is only that for *this* behaviour the count carries no information at all.)

The `.SECONDARY` comment block in the Makefile now names the test, so the next person to
consider the tidy-up finds out it is enforced without going looking.

**The review found the guarded behaviour is narrower than this item and CLAUDE.md both said**
— see item 8. The test is unaffected: its sandbox builds all twelve posts at once, which is
exactly the history the heal needs, and its docstring now says so.

Full suite: **164 passed, 0 failed.**

Original finding follows.

`tests/run.sh` — **verified** (the behaviour works; the gap is that no test covers it)

Re-verified in the second sweep: 12 posts, build (10 items, Post 02 absent), `rm` the
newest, `sleep 1`, rebuild → 10 items, Post 02 pulled in, Post 12 gone. And
`grep -c 'rm posts/' tests/run.sh` → 0 — the suite still never deletes a post.

`RSSITEM_FILES` is deliberately kept out of `.SECONDARY` (`Makefile:44-59`) so that
deleting a post rebuilds the newly-in-window `.rssitem`, re-cats `rss.tmp`, and lets the
feed heal itself. Confirmed by hand: 12 posts, delete the newest, rebuild — item count
stays 10 and the next-oldest post is pulled in.

No test exercises this. The suite never deletes a post at all. Adding `RSSITEM_FILES` back
to `.SECONDARY` looks like an obvious tidy-up, passes all 140 assertions, and silently
breaks the self-heal.

**This is the most likely regression in the repo today.**

**Fix:** one test — 12 posts, build, `rm` the newest, `sleep 1`, rebuild, assert 10 items
and the newly-in-window title present.
**Cost:** ~15 lines and one `sleep`.

### 3. `RENDER_POST` and `WRAP_IN_BASE` hang on an unreadable template — DONE

Fixed, and the fix went further than this item asked. All four awk programs now guard the
template read with `> 0` **and** report the `-1` case and `exit 1`.

The prescribed fix — mirror `RENDER_ITEM`'s bare `> 0` guard — turns out to trade the hang
for something worse. Writing the tests first showed it: `chmod 000 templates/rss-item.txt`
and `chmod 000 templates/rss.txt` against the *already-guarded* programs both exited 0 and
published an empty `rss.xml`. So the two "safe" programs had a silent-wrong-output hole of
exactly the kind item 1 was about, and copying their guard would have given the other two
the same hole. `exit 1` closes all four and lets `.DELETE_ON_ERROR` remove the partial file.

Guarded by `test_unreadable_post_template_fails_the_build`,
`test_unreadable_base_template_fails_the_build`,
`test_unreadable_rss_item_template_fails_the_build`, and
`test_unreadable_rss_template_fails_the_build`. Because an unguarded loop hangs rather than
failing, they run through a new `build_expect_fail_within` helper — macOS has no
`timeout(1)`, so it backgrounds make under `set -m` and kills the process group, since it is
awk and not make that spins. Watched fail against the old code (two hung, two exited 0),
then pass. Full suite: **159 passed, 0 failed**.

The CLAUDE.md paragraph is rewritten again to describe the guard-plus-exit and why the
`exit 1` is the load-bearing half.

Original finding follows.

`Makefile:350`, `Makefile:417`, and `CLAUDE.md:34-44` — **verified**

Re-verified in the second sweep: `chmod 000 templates/base.txt; make` was still running
after 5 seconds and had to be killed. `RENDER_ITEM` and `WRAP_IN_CHANNEL` remain guarded;
these two do not.

The documentation half is now fixed: CLAUDE.md describes the unreadable-template path as
the reachable one and says explicitly that the wrong-working-directory path cannot reach the
hang, because make errors on the relative template prerequisite first. **The four-line awk
fix itself is still open.**

`getline` on a file it cannot read returns `-1`, which is truthy, so an unguarded
`while (getline < "…")` loop never terminates. `RENDER_ITEM` and `WRAP_IN_CHANNEL` guard
with `> 0`; these two do not.

This was deferred out of the RSS branch on the argument that templates are prerequisites of
every rule that invokes these programs, so make errors out before awk runs. That argument
is half right:

- Template **deleted** → make errors on the missing prerequisite. Argument holds.
- Template **present but unreadable** (`chmod 000`, one careless `cp` or `rsync` away) →
  prerequisite satisfied, awk runs, build hangs indefinitely. `WRAP_IN_BASE` also appends
  the stale `$0` each iteration, so it consumes memory while spinning.

`CLAUDE.md:26-31` currently attributes the hang to running make from the wrong working
directory — but that path cannot reach it, because the template prerequisite is relative
too and make errors first. So the documented cause is unreachable and the reachable cause
is undocumented.

Worth closing for a second reason: `RENDER_POST` is the program the next new renderer gets
copied from.

**Fix:** four lines, mirroring `RENDER_ITEM` — `while ((getline line < "…") > 0)`. Plus
rewriting that CLAUDE.md paragraph to describe the real path.
**Cost:** minimal, but it touches two working programs on the critical path for every page,
so it wants the full suite run behind it.

### 4. Two documents claim the rule-order breakage is silent. It is not — an earlier fix made it loud — DONE

Fixed. The comment block above `$(BUILD_DIR)category/%.html` now says the `%.html` rule
would still claim the target in the wrong order, but that the unknown-page guard stops it
loudly, and quotes the error. The ordering requirement is stated as still real, because it
is. Done in one commit with items 6 and 7.

Original finding follows.

`Makefile:506-524` — **verified**, was still open. `CLAUDE.md` — fixed earlier.

Re-verified in the second sweep after `b0971a2`: swapping the two rules in a sandbox gives
`build/category/home.html: no post in posts/ builds this page` and `make: *** Error 1`.
Loud.

The CLAUDE.md half is now corrected — it says the ordering is still required but the
breakage is caught by the unknown-page guard, and quotes the real error. The comment block
above `$(BUILD_DIR)category/%.html` in the Makefile still says "No error, just a wrong page"
and "breaks the build silently". Same one-paragraph fix, not yet made.

Both warn at length that defining `build/category/%.html` below the `%.html` rule "breaks
the build silently" and emits a wrong page with no error. Moving the rule and building
shows the unknown-page guard added in `d96a855` fires instead:

```
build/category/home.html: no post in posts/ builds this page
exit 2
```

Loud, immediate, and the message points near enough at the cause. The ordering constraint
is still real — category pages genuinely will not build in the wrong order — but the
failure mode that justifies the emphasis is stale.

This repo's stated identity is documentation that is checkable against the code, so a
confident, formerly-true, empirically-false claim is worth more here than elsewhere.

**Fix:** reword both to say the ordering is still required but the breakage is now caught
loudly by the unknown-page guard.
**Cost:** prose only.

### 5. The Markdown branch has no test coverage at all — DONE

Fixed alongside item 1: `markdown_stub` writes a suite-owned `Markdown.pl` into the
sandbox, and two tests use it —
`test_markdown_transforms_the_body_not_the_front_matter` and
`test_failing_markdown_fails_the_build`.

`tests/run.sh` — **verified** (a stub was built and shown to exercise the branch correctly)

`Markdown.pl` is optional and gitignored, so sandboxes never have one and the entire
`if [ -x Markdown.pl ]` branch — the fiddliest code in the Makefile — is never executed by
the suite. A three-line bash stub exercises it faithfully: front matter untouched, body
transformed, inner delimiter lines preserved in the body, no stray `split` chunks left in
`work/`.

**Fix:** two tests with a suite-owned stub — one transforming stub asserting the body is
transformed and the title is not, one failing stub asserting the build *fails*. The second
only passes once item 1 is fixed, so the two verify each other.
**Cost:** ~30 lines in `run.sh`. No new dependency, and a bash stub is in the same spirit as
the rest of the tool.

### 6. The slash-for-hyphen fragment mapping is documented in two places and is dead in both — DONE

Fixed. The comment above `$(BUILD_DIR)%.html` now says `tmp_for_page` searches `TMP_FILES`,
says why it has to be a search — the category is in the filename but not the URL — and keeps
the slash-for-hyphen mapping only as the historical note it is. Done in one commit with items
4 and 7.

Original finding follows.

`CLAUDE.md` — fixed earlier. The comment block above `$(BUILD_DIR)%.html` in the Makefile
(~line 534) — **read**, was still open.

CLAUDE.md said the `%.html` stem's slashes are substituted to hyphens to name the `.tmp`
file, then twenty lines later correctly said that is impossible and `tmp_for_page` searches
instead. The substitution died when categories moved into filenames —
`work/2026-08-06-home_first-post.tmp` cannot be named from the stem
`2026/08/06/first-post` — and the rule uses `$$(call tmp_for_page,$$*)`.

Fixed in CLAUDE.md: the paragraph now describes `tmp_for_page` and forward-references the
explanation below the category section, which in turn now says what the mechanism used to
be. The pipeline diagrams also used `posts/2026-08-06-first-post.txt` — a filename with no
`_` and no category, which today's `check_post_name` rejects at parse time with an
`$(error)`, so the documented example input could not build. Now `…-home_first-post.txt`.

**Still open:** the Makefile's own comment above the `%.html` rule repeats the dead claim —
"turning the slashes back into hyphens names the one .tmp file this page is built from".
**Fix:** one sentence, in the same pass as item 4's Makefile half. **Cost:** prose only.

### 7. Delete `.source/templates/index.txt` — DONE

Deleted. `make setup` copies with `cp .source/templates/*`, a glob, so it simply copies four
files now instead of five; no recipe named the stub. The CLAUDE.md line that called it an
unimplemented stub is replaced by a gotcha noting that installs created before 2026-08-07
still have a copy in their `templates/`, that nothing reads it, and that removing it is safe
and optional.

Original finding follows.

`.source/templates/index.txt` and `CLAUDE.md:312` — **verified** (0 bytes; `make setup`
copies it into `templates/` in every install; nothing in the Makefile or the suite
references it)

It is the one tracked file in the repo with no function — a stub for a feature the index
does not need, since `index.html` is fragments wrapped in `base.txt`. The cheapest available
subtraction.

**Fix:** `git rm .source/templates/index.txt`, drop the CLAUDE.md line. Existing installs
keep their already-copied stub harmlessly.
**Cost:** one commit, two lines of doc.

### 8. The feed's post-deletion self-heal barely ever fires — CLAUDE.md FIXED, behaviour STILL OPEN

Found by the item 2 review. **verified** twice — once by the reviewer, once by hand.

The heal needs the newly-in-window post to have **no `.rssitem` on disk**: building the
missing fragment is the only thing that makes `work/rss.tmp` out of date. Delete a post whose
successor already has a fragment and every prerequisite of `rss.tmp` exists and is older than
it, so nothing rebuilds and the deleted post's `<item>` survives.

That "already has a fragment" case is the normal one. A post that is out of the window today
was in it when it was published, so on any blog grown a post at a time past ten with the feed
on, **every** out-of-window post already has its fragment. Reproduced against the unmodified
Makefile: 11 posts, build; add post 12, build; delete post 12, rebuild → `rss.xml` still
carries Post 12 and never pulls Post 2 in. The heal only shows up when `work/` is missing the
incoming fragment — a fresh clone, a `make clean`, or the all-at-once sandbox item 2's test
uses.

So item 2's test is honest but the behaviour it guards is a corner. What made this worth
finding is that CLAUDE.md stated the broad version as fact — "with more than ten posts …
the feed self-heals on a plain `make`" — in a repo whose stated identity is documentation
checkable against the code.

The CLAUDE.md gotcha is now rewritten to state the real condition, name the incremental
history as the case where it does not fire, and point at `make clean && make` as the reliable
answer. The `.SECONDARY` comment block in the Makefile is unaffected: its claim is about what
listing `RSSITEM_FILES` would suppress, which is true in the case where the heal fires at all.

**Still open: the behaviour.** Making deletion reliably heal the feed means giving `rss.tmp` a
dependency on the *set* of posts rather than on the current ten fragments — a stamp file
holding `RECENT_ITEMS`, rewritten only when the list changes, then made a prerequisite. That
is real design, and it overlaps the deleted-post and deleted-category gotchas, which have the
same shape and no fix either. **Cost:** ~10 lines of make plus a test; not obviously worth it
against `make clean && make`, which is already the documented answer for its two siblings.

---

## Minor

Every bullet below was re-checked in the second sweep. Line anchors are current as of
`b0971a2`. New bullets are marked NEW; bullets closed since the sweep are marked DONE.

- **`all` and `clean` are not `.PHONY` — DONE**, but the finding was half wrong and the
  half that was right is the one that mattered. `clean` breaks exactly as described:
  `touch clean && make clean` prints `'clean' is up to date` and wipes nothing. **`all`
  does not** — verified in a sandbox after the fact: `touch all && make` builds normally,
  because `all`'s prerequisite `build` is phony and therefore always out of date, which
  drags `all` along with it. So `.PHONY: all` is hygiene against `build` ever losing its
  own declaration, not a live bug. Both are now declared, in the per-rule style the file
  already used for `build`/`setup`/`deploy`/`test` rather than one shared line. Guarded by
  `test_clean_works_with_a_file_named_clean` (watched failing) and
  `test_default_build_works_with_a_file_named_all` (passes with and without the fix; both
  the test's banner and the `.PHONY: all` comment in the Makefile say so).

- **Template placeholders in post bodies get expanded — DONE**. Fixed by the prescribed
  ordering, and the finding turned out to be half the size of the bug: it named
  `RENDER_POST` and `WRAP_IN_BASE`, but `RENDER_ITEM` and `WRAP_IN_CHANNEL` have the same
  defect. `RENDER_ITEM` filled `title` before `link`/`pub_date`/`category`, and
  `WRAP_IN_CHANNEL` filled the blog name before `<link>` — so a `name=` holding `{{link}}`
  took the site URL. `xml_escape` leaves braces alone, so escaping never hid either.
  All four now fill derived values first, then `title`, then the big author-controlled blob
  (`body`/`main`/`items`). Watched failing first: 11 assertions across all four programs.
  Guarded by `test_placeholders_in_a_body_are_not_expanded`,
  `test_placeholders_in_a_title_are_not_expanded`,
  `test_placeholders_in_the_feed_are_not_expanded`, and
  `test_placeholders_in_the_blog_name_are_not_expanded`.

  **Still open, deliberately:** whatever is filled last is injectable into everything filled
  before it. The review corrected the first write-up of this, which claimed the leak needed a
  template line carrying both markers — it does not, since every `fill()` runs on every line,
  so the `title` fill puts `{{body}}` into the `<h4>` line and the `body` fill consumes it
  there. Reproduced against the stock `post.txt`, where the two are on different lines. Also
  broader than one case: a title containing `{{main}}` puts the whole rendered fragment in the
  page's `<title>`, the title/`{{body}}` leak fires in the feed too, and a `url=` containing
  `{{title}}` puts the post title inside every `<link>` and `<guid>`. The single-pass fill
  that closes all of them changes `fill()`'s signature and all four call sites, and drops the
  documented first-`{{key}}`-per-line behaviour. Not worth it against a closed body case, but
  the entry should say what it is deferring.

  Original finding: `Makefile:351-356,418-419`, **verified**. `fill()` rescans the composed
  line, so a body containing a literal `{{permalink}}` or `{{page_title}}` renders as the
  real value. For a blog whose README invites people to read the Makefile, a post *about
  grampa's template syntax* is not hypothetical.

- **`PAGE_TITLE`'s `sed` reads `title:` from anywhere in the file — DONE**. The delimiter
  stop is in, matching the pattern `tools/migrate-categories.sh` already used for
  `category:`. Guarded by `test_body_title_line_is_not_the_page_title`, watched failing
  first: a post whose front matter is empty and whose body contains `title: Sneaky`
  rendered `<title>Sneaky - My Weblog</title>` over an empty `<h4>`; it now renders
  `<title>My Weblog</title>`.

  Original finding: `Makefile:562`, **verified**. `PARSE_FRONT_MATTER` stops at the
  delimiter; this `sed` did not.

- **Out-of-range dates build successfully** — **verified**. `2026-13-40-home_bad-date.txt`
  exits 0, spews `date` usage text mid-build, and publishes `/2026/13/40/bad-date.html`
  with an empty posted-on line and an empty `<pubDate>`. `check_post_name` could range-check
  month and day at parse time, consistent with the checks already there (~6 lines of make),
  or this can stay garbage-in-garbage-out.

- **CLAUDE.md's tracked-files claim is false — DONE**. The Layout section now names
  `git ls-files` as the authority, and the table has rows for `Makefile`,
  `README.md`/`CLAUDE.md`, `tests/`, `tools/`, and `docs/`.

- **`make build` no longer skips anything — DONE**. The command list no longer claims it
  skips the config check, and a short paragraph under it says why `make build` and `make`
  are equivalent in every reachable state: `config` is a prerequisite of every page rule.

- **README nits — DONE**. All three fixed: "resonably", the inside-out
  `(this zip file)[https://…]` link, and the omission that mattered — the README never said
  `Markdown.pl` must be *executable*, though the Makefile tests `[ -x ]` and a
  non-executable copy falls back to verbatim HTML with no warning. Review turned up a
  fourth, adjacent trap and it is folded into the same paragraph: `chmod +x` alone appears
  to do nothing, because `.staged` files depend only on the post, so an already-staged post
  is not restaged when `Markdown.pl` turns up. The README now says to
  `make clean && make` after fixing the bit.

- **`make deploy` does not depend on `build`** — `Makefile:708-710`, **read**. So
  `make clean && make deploy` ships an empty directory. `deploy: all` would make it safe at
  the cost of an incremental no-op build. Arguably the current form is more honest about
  doing exactly what it says.

- **`POST_NAMES` uses `=` — DONE**. Now `:=`. Filed as "pure polish at blog scale", and it
  is more than that: **verified** by measurement rather than by reading, a 60-post no-op
  rebuild goes from 0.79s to 0.12s, since `tmp_for_page` searches `TMP_FILES` once per page
  and so re-ran the `ls | grep | sort` once per page. `build/` and `work/` are byte-identical
  under both forms (`diff -r`, 12 posts across three categories with `url=` set), and the
  suite is unchanged at 179 passing. The lazy-`config` rationale does not apply, and
  `2>/dev/null` already covers a missing `posts/`.

- **The `split` cleanup glob stops at `az`** — `Makefile:621-626`, **read**. The masking is
  at least documented now, in the rule's own comment at `Makefile:612-614`. `$*.a[b-z]*` misses
  chunks past `az`, so a body containing more than 25 delimiter lines would silently
  truncate. Also, a post with no delimiter at all leaves the glob unmatched and `cat` errors
  into the pipeline. This item originally predicted that fixing item 1 would make the second
  case loud. It does not — **verified** after the fix: `cat … | tail` reports `tail`'s
  status, so a `cat` that finds nothing to read is still masked and the build exits 0. Item
  1's `&&` catches a failing *step*, never a failing stage of a pipe. Closing this one needs
  the pipeline broken up (or `pipefail`, which is not POSIX `sh`).

- **The staging branch's scratch glob can eat a same-date sibling's fragments** —
  `Makefile`, the `%.staged` rule, **verified**. `rm -f $(WORK_DIR)$*.a[a-z]*` over-matches
  when two posts share a date and one slug extends the other with `.a<letter>`:
  `2026-01-01-home_x.txt` alongside `2026-01-01-home_x.ab.txt` means stem `x`'s glob deletes
  stem `x.ab`'s `.staged` and `.tmp` mid-build. Fails loudly (`cat: … No such file or
  directory`, exit 2, serial and `-j8`) and is pre-existing — `git show HEAD:Makefile` fails
  identically, and both the head and tail `rm` have it. Differing dates don't collide, since
  the stem carries the date. Dotted slugs are degenerate anyway (`/2026/01/01/x.ab.html`).
  Same family as the `az` glob item below; whoever fixes that should fix this.

- **Markdown-branch test gaps that remain — DONE**. All three added, each watched failing
  against the specific regression it guards rather than against nothing:
  `test_markdown_branch_is_parallel_safe` (collapsing the branch's per-post scratch
  namespace to a shared one fails 5 of 6 posts under `-j8`; one wins the race),
  `test_markdown_body_reaches_the_feed` (repointing `%.rssitem` at `posts/%.txt` instead of
  the `.staged` file fails exactly the transformed-body assertion), and
  `test_non_executable_markdown_falls_back_to_verbatim` (relaxing `[ -x ]` to `[ -f ]`
  fails). That last is the behaviour README.md now tells people to check first.

  Original finding: **verified** by manual runs rather than by the suite. No test ran the
  Markdown branch under `-j` (`test_parallel_build_is_clean` installs no stub); no test
  asserted a Markdown-staged body reaches `rss.xml` (all three stub sandboxes left `url=`
  unset); and the "present but not executable → verbatim" path was untested.

- **`.source/splitter.txt` ends with a blank line** — **verified harmless**. Markdown-staged
  bodies gain a leading blank line that the verbatim branch does not have. Cosmetic.
  Re-confirmed with `od -c`: 35 hyphens, `\n`, `\n`.

- **NEW — a deleted `templates/post.txt` or `rss-item.txt` silently rebuilds from stale
  fragments — DONE**. Fixed as predicted, with one line: `build: templates/post.txt
  templates/rss-item.txt`. Guarded by `test_deleted_post_template_fails_the_build` and
  `test_deleted_rss_item_template_fails_the_build`, both watched failing first — each edits
  a post, deletes the template, rebuilds, and the old code reported success while serving
  the previous body. CLAUDE.md's unreadable-template paragraph carried the old claim as
  fact and is corrected in the same commit.

  Original finding follows. **verified** (found by the item 3 review). Both are named
  only in *pattern* rules, so under make 3.81's pattern search they are not "ought to exist"
  files: delete one and the `%.tmp`/`%.rssitem` rule simply becomes inapplicable, the
  existing `work/` fragment is taken as-is with no dependency check, and the build exits 0
  serving the old body — reproduced by editing a post, deleting `templates/post.txt`, and
  rebuilding. `templates/base.txt` and `templates/rss.txt` hard-error in the same state,
  because they are also prerequisites of the explicit `build/index.html` and
  `build/rss.xml` rules. Note this does **not** weaken item 3's fix: awk still never runs
  against a missing template. **Fix (verified since):** one line —
  `build: templates/post.txt templates/rss-item.txt` — gives them the same "ought to exist"
  standing the other two already have, and the silent-stale case becomes
  `No rule to make target 'templates/post.txt'`, exit 2. Reads as silent-stale-output family
  with the deleted-post and deleted-category gotchas, but it is not: those are untracked
  outputs make cannot know about, this is a nameable input.

- **NEW — `.gitignore` leaves `posts/` and `config` unanchored — DONE**. All six anchored:
  `/posts/`, `/config`, `/build/`, `/work/`, `/deploy.sh`, `/Markdown.pl`. Upgraded from
  **read** to **verified**: `git check-ignore` confirmed `tools/config`,
  `docs/posts/notes.md`, `docs/build/x.md`, `tools/work/x.sh`, `src/deploy.sh`, and
  `docs/Markdown.pl` were all ignored before and none is now, while every real target still
  is and `git ls-files` is unchanged at 18. `*.swp` and `.superpowers/` are left unanchored
  on purpose — editor droppings and tool state are worth ignoring at any depth — and
  `tests/tmp/` and `.claude/worktrees/` needed nothing, since a pattern with a slash
  anywhere but the end is already relative to the `.gitignore`. The file now says which
  group each pattern is in and why.

  The suite cannot guard this one: its sandboxes are plain directories, not git
  repositories, so there is nothing for `git check-ignore` to run against.

- **NEW — CLAUDE.md's tool list omits `sed` — DONE**. `sed` is load-bearing in three places
  (config parsing at `Makefile:116,140`, the `PAGE_TITLE` extraction at `Makefile:562`) and
  is now listed in the opening sentence.

- **NEW — a third stale Makefile comment, same family as items 4 and 6 — DONE**. The
  `RENDER_ITEM` comment claimed the unguarded-`getline` trap was unreachable because "the
  template is a prerequisite, so make stops first" — true for a *missing* template, false
  for the present-but-unreadable one. Fixed with item 3: the full explanation now lives
  above `RENDER_POST` and the other three programs point at it, so there is one place to
  keep true instead of three.

- **NEW — `make -j setup all` in a fresh directory fails** — **verified**, and
  **pre-existing**: found by the review of the `.PHONY`/`:=`/`.gitignore` commit, reproduced
  identically against that commit's Makefile and against `HEAD`'s, so it is not a
  regression from it. In a directory with no `templates/` yet, `make -j4 setup all` races
  `setup`'s template-copying against the build rules and stops with
  `No rule to make target 'templates/base.txt', needed by 'build/index.html'`. Serial
  `make setup all` is fine, and so is the documented `make setup` followed by `make`. Fix
  would be an order-only prerequisite or simply documenting that `setup` wants its own
  invocation — which `README.md` and `CLAUDE.md` already show it having, so this is close to
  a non-problem. Cheapest honest option: a line in the Commands section saying `setup` is a
  one-time step and not to combine it with a build goal under `-j`.

- **NEW — no test covers editing `templates/base.txt` — DONE**.
  `test_editing_base_template_rebuilds_every_page`, watched failing three times, once per
  rule: dropping the `base.txt` prerequisite from `%.html`, `category/%.html`, or
  `index.html` each fails exactly one of the test's three assertions and leaves the other
  two passing, which is what makes asserting all three in one test worth doing — the
  realistic mistake is fixing one rule and forgetting its siblings. Review independently
  reproduced all three and additionally established that the `sleep 1` is load-bearing
  rather than superstition: on APFS, make 3.81 truncates mtimes to whole seconds, so a
  sub-second-newer prerequisite rebuilds nothing (3 tries out of 3).

  Original finding: **verified** (`grep -c 'touch templates/base.txt' tests/run.sh` → 0).
  `test_editing_post_template_rebuilds_fragments` guards the bare-dependency-line trap for
  `post.txt`; the identical trap existed for `base.txt` in three rules and nothing guarded
  it.

---

## If only three get done

1. ~~**Item 1 + item 5 together, as one commit.**~~ Done. The failing-stub test was written
   first and watched fail against the `;`-chained recipe, then passed against the `&&` one.
2. ~~**Item 3.**~~ Done, along with the stale `RENDER_ITEM` comment from Minor. It was not
   the two-minute fix it looked like: the prescribed cure was itself a bug, and finding that
   out cost four tests and a `timeout(1)` substitute. Worth it — the trap it removes was one
   copy-paste from the next renderer.
3. ~~**Items 4, 6, and the CLAUDE.md prose fixes from Minor, as one documentation pass.**~~
   Done for CLAUDE.md. What remains of items 4 and 6 is two stale comment blocks in the
   Makefile itself, saying the same two things the doc no longer says: "breaks the build
   silently" above `build/category/%.html`, and the slash-for-hyphen fragment mapping above
   `%.html`. Both are prose-only, and both should go in one commit.

All three are now done, and so is item 2 — what was the most likely regression in the repo
is now guarded by a test that was watched failing against the exact edit that would cause it.
Writing that test turned up item 8, whose documentation half is fixed in the same commit and
whose behaviour half is new work nobody has asked for yet.

Items 4, 6, and 7 followed in one commit, which closes every Important item except the
behaviour half of item 8. What was left was the Minor list, and the two worth ranking above
the rest were both silent-wrong-output: a deleted `templates/post.txt` or `rss-item.txt`
rebuilding from stale fragments with exit 0, and `PAGE_TITLE`'s `sed` reading `title:` from
the body. **Both are now done**, in one commit, and both cost what they were predicted to —
an address-and-quit `sed`, and one line naming the two templates as prerequisites of
`build`, which is the same mechanism that already made `base.txt` and `rss.txt` hard-error.
Unlike item 8 and the deleted-post gotcha — which are about untracked *outputs* make cannot
know it should remove — the deleted template was a nameable *input*, which is why it was
cheap and they are not.

**What is left is the rest of the Minor list.** The cheapest were `.PHONY: all clean`,
anchoring `.gitignore`, and `POST_NAMES` to `:=`, **all three done** in one commit.

A later pass then took four more: the README nits, both test gaps (`templates/base.txt`
edits, and the three Markdown-branch gaps), and the placeholder-expansion mitigation. Two of
those four grew on contact with the code, which is the recurring lesson of this list —
`fill()`'s ordering bug was in all four awk programs rather than the two the finding named,
and the README's missing "must be executable" note needed a second sentence about `.staged`
staleness to actually work as advice.

**What is left, in rough order of how much a reader would care:**

1. **The two staging-branch glob items** — the `az` ceiling and the same-date sibling
   over-match. They want doing together, and they need the `cat … | tail` pipeline broken up
   rather than a one-liner, because `&&` catches a failing *step* and never a failing stage
   of a pipe. This is the only remaining bullet that produces silently wrong output on a
   strange post: a body with more than 25 delimiter lines truncates.
2. **The behaviour half of item 8** — the feed's post-deletion self-heal. Real design, shares
   its shape with the deleted-post and deleted-category gotchas, and `make clean && make` is
   already the documented answer for all three.
3. **Out-of-range dates build successfully** — ~6 lines of range-checking in
   `check_post_name`, or leave as garbage-in-garbage-out.
4. **`make deploy` does not depend on `build`** — arguably more honest as it is.
5. **The residual half of the placeholder fix** — a *title* containing a literal `{{body}}`.
   Needs the single-pass fill, deliberately deferred.
6. **The trailing blank line in `.source/splitter.txt`** — verified harmless, cosmetic.
7. **`make -j setup all` in a fresh directory** — close to a non-problem; the cheapest honest
   option is a line in the Commands section.

---

## What has been verified by running it

Both sweeps ran in throwaway sandboxes built the way `tests/run.sh` builds them — `Makefile`
and `.source/` copied into a scratch directory, `make setup`, posts written by hand. The
real repo was never built in.

Second sweep, all **verified** by execution:

1. Full suite from a copied tree: **149 passed, 0 failed**.
2. `chmod 000 templates/base.txt` hangs the build — still spinning at 5s, killed (item 3).
3. `touch clean && make clean` is a no-op; `build/` and `work/` survive (Minor `.PHONY`).
4. Swapping the two `%.html` rules fails **loudly** via the unknown-page guard (item 4).
5. Feed self-heal: 12 posts → delete the newest → rebuild → 10 items, next-oldest pulled in
   (item 2's behaviour; the gap is coverage only).
6. `{{permalink}}` in a post body expands to the real permalink (Minor).
7. A body-only `title:` line becomes the `<title>` while `<h4>` renders empty (Minor).
8. `2026-13-40-…` builds with exit 0, `usage: date` noise, and empty date fields (Minor).
9. `make -j8` with a Markdown stub and `url=` set: clean exit, transformed body in both the
   HTML and `rss.xml`, no stray intermediates; a non-executable `Markdown.pl` falls back to
   verbatim (the Markdown test-gap bullet's behaviours).
10. `rm config; make build` recreates `config` and exits 0 (the stale `make build` bullet).
11. `.source/templates/index.txt` is 0 bytes and unreferenced (since deleted — item 7);
    `splitter.txt` ends in a
    blank line (`od -c`).
12. `git ls-files` against `CLAUDE.md:35`; `grep` confirms no test deletes a post or touches
    `templates/base.txt`.

Taken from reading or the first sweep, **not** re-executed in the second: the same-date
sibling-glob over-match, the first-ever-`make`-with-`url=` gotcha, `deploy`'s missing
prerequisite, and `POST_NAMES`' re-expansion cost.
