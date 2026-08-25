# Backlog

Findings from full-repo reviews. Two full sweeps, two branch reviews and two whole-branch
pre-merge reviews so far:

- **First sweep**, 2026-08-06, after the RSS feed landed (`2c0c57d`).
- **Second sweep**, 2026-08-06, after the Markdown failure fix (`b0971a2`). Every item from
  the first sweep was re-checked. New items are numbered from 6.
- **Branch review**, 2026-08-08, of markdown processor detection (`4072a31`) — the four
  CLAUDE.md checkpoints rather than a full-repo sweep, so it carries no verdict on anything
  the branch did not touch. Its residuals were items 9 and 10 and the four NEW Minor bullets
  at the end of that list; item 9's probe half and item 10 are now DONE, closed by the next
  branch below. Everything it found blocking was fixed on the branch; what is recorded here
  is what shipped knowingly unresolved.
- **Branch review**, 2026-08-08, of deletion staleness and the setup probe (`b2dc08c`) — same
  four-checkpoint method, closing items 8, 9 (probe half), 10, and the rejected-candidate
  Minor bullet, and adding items 11–14: a broken `make test` nobody had noticed (closed in
  the same branch), a coverage gap in the rejected-candidate diagnostic, a category-rename
  lag, and a count of this branch's own recurring confident-but-false-claim defect.
- **Whole-branch review**, 2026-08-08, of the same branch before merge (`666ec7a`) — found that
  items 12 and 13, written by the branch review directly above, were themselves each half
  wrong in the way item 14 exists to catch, and that a third, unrewritten copy of an earlier
  falsified claim survived in `tests/run.sh`. Item 12 is now closed rather than open: the real
  gap was one branch, not two, and the last branch is now guarded too. Item 13's provenance is
  corrected: the mtime mechanism is pre-existing, but the one-build lag it now produces exists
  only because this branch's own fix (item 8) made the rest of a rename heal, where nothing did
  before. Item 14's count moved from four to seven.
- **Whole-branch review**, 2026-08-09, of static assets (`b769921`) — the four CLAUDE.md
  checkpoints across five tasks, then the whole branch before merge. It found one behaviour
  bug that had to be fixed before shipping (a FIFO in `static/` hung the build forever) and a
  further run of item 14's defect, taking that count from eight to eighteen. Nothing it found
  endangers `posts/`. Its residuals are recorded in the section at the end of this file rather
  than as new numbered items: none of them is a fix waiting to be scheduled, they are decisions
  taken with their costs known.

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
still open. **No longer true as of the awk staging split**: there is no pipe left in the
chain, and the two glob items below are closed.

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

### 8. The feed's post-deletion self-heal barely ever fires — DONE

From the branch review, 2026-08-08 (deletion staleness and setup probe). Found by the item 2
review, marked STILL OPEN there for one release, now closed by making `posts` (the directory)
a prerequisite of `work/index.tmp`, `work/rss.tmp`, and every `build/category/%.html`. A
directory's mtime moves when an entry is created or removed, which is exactly "the set of
posts changed" — the same signal the entry's own proposed stamp file would have carried, for
free and without inventing a file. The stamp file this entry proposed was not needed.

**The entry was two consumers short, and the second one it was missing is worse than the one
it named.** It was filed as a feed bug: `rss.tmp`'s prerequisites are the ten newest
`.rssitem` files, so deletion heals only when the newly-in-window post lacks one. But
`index.tmp` and every category page have the identical shape and neither was covered by the
entry at all — and neither ever healed, for a structural reason the entry did not have.
`rss.tmp`'s heal was *conditional* on the incoming fragment being absent; the index and
category pages had no such condition to fail, because **every post has a `.tmp` fragment the
moment it has a page**, unlike a `.rssitem`, which only exists for a post that was once in the
feed's ten-item window. The incoming fragment is therefore always already on disk and always
older than `index.tmp`, so `index.tmp` never re-cats and the front page went on linking to a
deleted post indefinitely — worse than the feed case this entry described, since the feed at
least healed on a fresh clone or a `make clean`, and it was undocumented until this branch's
review found it.

The fix closes all three uniformly and needs no per-target reasoning about fragment history:
`posts` doesn't distinguish "this post never had a fragment" from "this post's fragment is
still on disk", it just says the post set changed, which is the question that actually
matters. One exception survives on purpose: a category deleted down to zero posts is not
covered, because `CATEGORY_SLUGS` is parse-time-derived from the filenames that exist, so a
category with no posts left is not in the target list at all and nothing rebuilds or removes
its page — that is the pre-existing deleted-category gotcha, unrelated to this fix, and
`make clean` remains its answer.

The fix is deliberately coarse: `posts` is a directory-level prerequisite, so **any** entry
created or removed under `posts/` — an editor's swap file, an unrelated dotfile — triggers the
same rebuild of the index, every category page, and the feed, not only a `.txt` post. One
cheap, self-healing rebuild; the next build is quiet again. Recorded as a known over-trigger,
not a defect: narrowing it to `.txt` entries only would need `$(wildcard posts/*.txt)` as the
prerequisite instead of the bare directory — and that is not a cheaper, more-precise version of
the same fix, it is a **broken** one. A wildcard-expanded list is just a set of filenames at
parse time; deleting a post removes its name from that list along with it, so nothing is left
behind to compare against and be newer than the target. It cannot detect a deletion **at all**,
which is the exact case this fix exists for. The bare directory is not a coarser tool bought at
some bookkeeping cost — it is the only one of the two that works.

**Credit belongs here too for a bug the entry never set out to fix.** The same `posts`
prerequisite also closes the *rename* case, not only deletion: renaming a post into a different
category with `mv`/`git mv` used to leave both the old and new category pages permanently
wrong — verified on `main` at `82065e8`, three rebuilds deep, still wrong every time. On this
branch both category pages now correct themselves on the very next `make`, the same rebuild that
already fixes the index and the feed. See item 13, which the whole-branch review corrected after
an earlier draft called the remaining one-build lag on the post's own page "pre-existing,
unrelated to this branch" — backwards: that lag is residue *of* this same improvement, not
something the improvement left untouched.

Guarded by `test_deleting_a_post_heals_the_index`, `test_deleting_a_post_heals_the_category_page`,
and `test_deleting_a_post_heals_the_feed_after_incremental_growth` — the last built specifically
to cover the case `test_deleting_a_post_heals_the_feed` cannot: that older test builds all
twelve posts at once, which is the one corpus shape where the pre-existing heal already
worked, so it passed against the unfixed Makefile and covered none of this bug.
`test_build_works_without_a_posts_directory` guards the companion problem the fix would
otherwise have introduced: a bare `posts` prerequisite with no rule to satisfy it turns a
missing `posts/` from "build an empty site at exit 0" into make's own
`No rule to make target 'posts'`, so a `posts:` rule (`@mkdir -p posts`) recreates it.

This was the last of the file's two "open questions" — see "If only three get done" below,
which is updated to say so.

Full suite: **352 passed, 0 failed.**

Original finding follows.

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

### 9. Three of the twelve markdown candidates ship with flags nobody has run — DONE (probe half); table-correction half STILL OPEN

From the branch review, 2026-08-08 (markdown processor detection), closed by the branch
review, 2026-08-08 (deletion staleness and setup probe) — the probe extension this entry
itself ranked as the better buy. The probe input gained ` -- z`, and setup rejects any
candidate whose output loses the `--`, on the theory that a wrong smartypants flag mangles a
double dash into an en or em dash. Guarded by `test_probe_rejects_a_smartening_candidate` and
`test_setup_names_a_rejected_candidate`.

**The entry predicted the risk of an over-strict probe without knowing it was already
realised.** The obvious form of a punctuation check — assert a literal `"` survives the round
trip — rejects `cmark`, `cmark-gfm`, and `md2html` on this host: all three HTML-escape `"` to
`&quot;` in text content, which is escaping, not smartening, and renders identically. A quote
assertion cannot tell the two apart and would have skipped three correctly-behaving
candidates. The dash alone discriminates cleanly: intact (`--`, unescaped) in all seven
candidates on this host that the probe correctly accepts, mangled in all three of the
deliberately wrong-flagged stubs used to test the rejection path. `test_probe_accepts_escaped_quotes`
is kept in the suite as a tripwire against the quote assertion being added later — the stub's
escaping is conditional, so the test cannot pass trivially if a literal-`"` check is added
alongside it, and today it has nothing to catch, which its own docstring says plainly.

**The other half of this item stays open and unranked, exactly as before.** Installing
`multimarkdown`, `comrak`, and `markdown-it` to correct their table rows by hand still fixes
only today's table, not the class — the probe extension is what fixes the class, and it is
now done. Nobody has run these three either way. See "Not verified" in the branch-review
subsection below.

Full suite: **352 passed, 0 failed.**

Original finding follows.

**read** — established from each tool's documentation
and from the behaviour of its family, not by executing it.

`multimarkdown`, `comrak` and `markdown-it` are the three rows of `MARKDOWN_CANDIDATES` that
were never executed during development, because installing them was disproportionate
(`multimarkdown` wants `cmake`, the other two want their language toolchains). Their argv
came from documentation. This is a deliberate, recorded decision — the spec's Flag
Verification section is the authority on which three — and it is not the same as shipping
them untested in the dangerous sense, because **the probe is what keeps it honest**: setup
runs each candidate against `x <i>y</i>` and rejects any that exits non-zero, eats the raw
HTML, or emits a whole document. A wrong flag on the user's machine means the candidate is
skipped, not that posts are silently mangled.

**The gap the probe does not close is punctuation.** It checks raw-HTML survival and
document-vs-fragment; it does not check that quotes and dashes came through unsmartened. So
a candidate whose smartypants flag is wrong passes detection and quietly rewrites the
author's punctuation. `multimarkdown --snippet` is the specific suspect: `--snippet` controls
document-vs-fragment output and says nothing about typography, and MultiMarkdown 6 enables
smart typography by default, so the row may well need a `--nosmart` it does not have. Nobody
has run it either way.

**Two ways to close it, and they are independent.** Extend the probe to assert that a `"`
and a `--` survive the round trip, which fixes the whole class for every present and future
row and costs a longer probe string; or install the three tools once and correct their rows,
which fixes today's table and leaves the class open. The probe extension is the better buy.
**Cost:** a few lines in setup's walk plus a test; the risk is a probe so strict that a
perfectly good processor gets skipped, which argues for asserting punctuation and *not*
asserting anything about the rendered markdown itself.

---

### 10. Nothing serialises two concurrent `make setup` runs against `config.mk.new` — DONE

From the branch review, 2026-08-08 (markdown processor detection), closed by the branch
review, 2026-08-08 (deletion staleness and setup probe), exactly the way this entry
predicted: the scratch name is now `config.mk.$$$$` — the PID — in place of the fixed
`config.mk.new`, one line of recipe. Guarded by `test_noop_setup_leaves_config_mk_untouched`,
which asserts `ls config.mk.* | wc -l` is zero after a clean setup, rather than the vacuous
`assert_no_file config.mk.new` a fixed-name check would now be, since nothing can create that
name any more.

**The cost this entry didn't have: a setup that aborts between the write and the `mv` now
leaks `config.mk.<pid>` indefinitely.** The old fixed name was silently overwritten by the
next setup's write to the same path; the new per-process name is never reused, so an abort
leaves an orphaned file behind for good. It is gitignored (`/config.mk.*`) and inert — nothing
reads it, and `make clean` does not remove it, since it is not a `build/`/`work/` artifact.
Accepted rather than closed with a `trap … EXIT`, which would grow an already-long single
logical recipe line for a file nothing reads. Not tested, on the same reasoning the entry gave
originally: `setup` aborting mid-write needs an injected failure, and nothing on the branch
needed one.

**The concurrent-interleaving claim itself is unchanged: still read, not reproduced.** The
fix removes the shared name that made the interleaving possible, but two actual concurrent
`make setup` processes were not run against either the old or the new code. See "Not
verified" in the branch-review subsection below.

Full suite: **352 passed, 0 failed.**

Original finding follows.

**read** — the interleaving was reasoned from the recipe, not reproduced.

Setup writes its probe results to a fixed filename, `config.mk.new`, and then `mv`s it over
`config.mk` if `cmp` says the content differs. Two setups running at once in the same
directory share that one scratch name, so one can truncate the file the other is midway
through writing, and the `mv` can promote a half-written `config.mk` — which is `-include`d
by every subsequent parse. `mv` is atomic, so the failure needs the interleaving to land
inside the write rather than inside the rename.

It is a narrow window and an odd thing to do: `setup` is documented as a one-time step, and
the two-invocation case that *is* documented (`make -j setup all`) fails for an unrelated
reason before it gets here. `make -j4 setup` was exercised on the branch and was clean — but
that is one make process, not two, so it does not test this. The fix is a PID-suffixed temp
name, `config.mk.$$$$`, which is two characters of recipe and no new failure mode; it was
left alone only because nothing on the branch needed it. **Cost:** one line, no test worth
writing for it.

---

### 11. `make test` was broken, and nobody had noticed — NEW, DONE

From the branch review, 2026-08-08 (deletion staleness and setup probe). **verified**.

`make test` reported **334 passed / 1 failed** where `bash tests/run.sh` reported
**335 passed / 0 failed**, on identical code. Reproduced on a clean clone of `main` at
`82065e8` — the commit this branch started from — so it predated this branch entirely and was
not introduced by anything here.

The cause: `make test` runs `tests/run.sh` as a recipe, and make exports `MAKELEVEL`,
`MAKEFLAGS`, and `MFLAGS` into every recipe's environment. Each sandbox `make` the suite
shells out to inherits them, sees `MAKELEVEL=1`, concludes it is a sub-make, and
auto-enables `--print-directory` — so `make[1]: Entering directory …` becomes the first line
of a captured build, which broke `test_build_announces_the_processor`'s assertion that the
markdown notice is the first line of build output.

That assertion is load-bearing, not incidental: the notice's position is the whole reason it
is written as a parse-time `$(info)` rather than a line inside `build`'s recipe (see
CLAUDE.md's "build notice" gotcha) — a real regression there would be silent under the old
`tests/run.sh`-only invocation and loud under `make test`, or vice versa, depending on which
command a reviewer happened to type.

Fixed by `unset MAKELEVEL MAKEFLAGS MFLAGS` at the top of `tests/run.sh`, not by
`--no-print-directory` on the recipe: that would silence the symptom while leaving
`MAKEFLAGS` inherited, so `make -j4 test` or `make -s test` would still hand every sandbox
flags nobody chose, and `-s` would additionally silence the very output the assertions read.
Unsetting all three up front makes every sandbox `make` behave as a top-level invocation no
matter how `tests/run.sh` itself was started — the same principle `hide_markdown_tools`
already applies to `PATH`: the suite's result must not depend on the environment it inherits.
Verified fixed under plain `make test`, `make -s test`, and `make -j4 test` alike.

**This is worth its own entry rather than a line inside another one**: the repository's own
documented test command (`make test`, named first in CLAUDE.md's Commands section) was
producing a wrong result, and which of two invocations of "the same" suite a reviewer ran
determined whether they saw green or red. Nobody had noticed, because every review of this
repo up to this branch ran `tests/run.sh` directly rather than `make test`.

Full suite after the fix, under `make test`: **352 passed, 0 failed.**

---

### 12. DONE — the rejected-candidate diagnostic's `>&2` coverage gap, and a self-review that understated its own closure by half

From the branch review, 2026-08-08 (deletion staleness and setup probe); the finding below
corrected and closed by the whole-branch review that also produced item 14's count.
**verified**, by mutation, at every stage.

Dropping a single `>&2` from setup's probe loop — so a rejection reason lands on stdout
instead of stderr — corrupts `config.mk` to `DETECTED_MARKDOWN := grampa: setup: <probe>:
<reason>` instead of naming a real processor or being empty. That is exactly the silent,
build-wrong-processor failure the diagnostic (the Minor bullet above) exists to avoid falling
into by accident.

**The original writeup of this item said the gap was two branches wide, and that neither test
aimed at this area asserted anything about `config.mk`'s content. Both halves are false, and
this entry is itself one of the seven counted in item 14.** `test_probe_skips_a_candidate_that_eats_raw_html`
does assert content — `assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"` — and that
assertion, incidentally, already catches the `drops raw HTML` mutation: dropping its `>&2`
mangles `DETECTED_MARKDOWN` into a value carrying the leaked diagnostic ahead of the real
winner, which no longer matches `cmark --unsafe`. Verified by mutation: the full suite fails
352/1 with `FAIL: probe_raw_html: expected 'DETECTED_MARKDOWN := cmark --unsafe' in config.mk`.
The protection is **incidental** — the test asserts a specific winner because the scenario
needs one, not because anyone set out to guard the diagnostic stream — but incidental coverage
is still coverage, and the original writeup's claim that this test "asserts nothing about
`config.mk`'s content" was checkable and wrong.

So the real residual gap was **one branch, not two**: `emits a whole document`, exercised by
`test_probe_skips_a_whole_document_candidate`, which asserted only that `lowdown` was not
chosen and nothing about what, if anything, won instead. **That branch is now closed too.**
The test gained the same exactly-empty `DETECTED_MARKDOWN` assertion
`test_setup_names_a_rejected_candidate` already used, watched RED first — dropping the
branch's `>&2` in a scratch copy fails it with `FAIL: probe_document: no diagnostic leaked into
the winner: expected [DETECTED_MARKDOWN :=] got [DETECTED_MARKDOWN := grampa: setup: lowdown:
emits a whole document]` — then restored to GREEN.

The fourth branch, `not runnable`, still needs no such guard, for the reason the original
writeup gave: it is the fall-through every non-candidate on `PATH` hits, so a normal sandbox
reaches it roughly eleven times per `make setup` (once per unsatisfied row in the twelve-row
table). A leaked `>&2` there would corrupt `config.mk` loudly and on essentially every test in
the suite that calls `make setup`, not quietly on one.

Full suite: **353 passed, 0 failed.**

---

### 13. STILL OPEN, but its own provenance claim was backwards — a post page lags one build behind an mtime-preserving category rename

From the branch review, 2026-08-08 (deletion staleness and setup probe); its own "pre-existing,
unrelated to this branch" framing corrected by the whole-branch review — the same review that
wrote item 14's count, and this entry is one of the seven it counts. **verified** by direct
comparison, both `main` at `82065e8` (this branch's own start point) and this branch, three
rebuilds deep on each.

Rename a post's category with `mv` or `git mv` — the direct, unaided way, as opposed to
`tools/migrate-categories.sh` — and the renamed `.txt` keeps its **old** mtime, since neither
`mv` nor `git mv` touch content or timestamps. The post's own page rule,
`$(BUILD_DIR)%.html`, depends on the `.tmp` fragment matched by `tmp_for_page`, and that
fragment's *name* changes with the rename (the category is embedded in the filename) but nothing
forces the *page* to notice on the build immediately following the rename: make compares the
renamed `.txt`'s mtime against the page's, finds the source no newer, and considers the page up
to date on that first build. **That mtime-comparison mechanism is pre-existing** — `mv`
preserving timestamps is not something this branch touched.

**What is not pre-existing is any of it *healing*, and that is exactly what the original
writeup got backwards.** Reproduced on `main` at `82065e8`: rename `2026-01-03-home_p03.txt` to
`2026-01-03-work_p03.txt`, then rebuild three times running — `build/category/home.html` still
lists Post 03, `build/category/work.html` never gets it, and the post's own page keeps linking
`category/home.html`, unchanged across all three rebuilds. Permanently stale; only
`make clean` fixes it, same as the deleted-category gotcha. On this branch, the identical rename
heals in two builds, not one: `posts` (the directory, item 8) is a prerequisite of every
category page, so `build/category/home.html` and `build/category/work.html` already correct
themselves on the very first rebuild after the rename. Only the post's *own* page lags — it
still says `category/home.html` after that first rebuild — and updates on the second. **The
one-build lag is real, but it is residue of an improvement this branch made, not a defect this
branch introduced: before, nothing about a rename ever healed, on any target, at any number of
rebuilds.** The mechanism that closes the lag on the second build is the same `posts`
prerequisite: it is what forces the renamed post's *new* `.tmp` fragment into existence on the
first rebuild (verified with `make --debug=v`: `work/2026-01-03-work_p03.tmp` is built during
that first `make`), and having that fragment genuinely on disk, newer than the still-stale page,
is what lets the second `make` rebuild the page correctly.

**`tools/migrate-categories.sh` does not have this problem, and that part of the original
finding stands.** The script does not rename in place: at `tools/migrate-categories.sh` lines
99–117 it writes the renamed post fresh with `awk … > "$new"`, then `rm "$f"` removes the old
file. The freshly written file is newer than everything downstream of it, so its page rebuilds
on the very next `make` with no lag. The distinction is exact and mechanical: the lag turns on
whether the renamed `.txt` is *older* than the page it feeds, not on whether a `.tmp` fragment is
*missing* — a plausible-sounding alternative explanation that was tried and disproved during
this branch's own review (see item 14 below). Verified both ways, including under `-j8`.

Not fixed and not ranked here: closing the post page's own one-build lag needs the same category
of dependency-shape work as the feed/index/category self-heal problem this branch did fix (item
8), but for a different target (a post's own page, keyed on a rename rather than a deletion),
and nothing on this branch's scope required it.

---

### 14. The branch's own recurring defect — twenty confident-but-false claims across three branches, and the finding is that counting them was the wrong instrument

This file's own recurring lesson, stated in "If only three get done" below, is "a confident,
formerly-true, empirically-false claim". It happened four times on this branch before this
entry was first written — twice inside the very commits written to correct an earlier instance
of itself:

1. **The implementation plan asserted `test_build_works_without_a_posts_directory` passes
   before the change.** It does not: `mkdir -p posts` lives only in `setup`'s recipe, so
   nothing recreates a deleted `posts/` directory on a plain build, and the test's directory
   assertion fails against unmodified `HEAD`. Caught at the plan review, before any code was
   written against the false premise.
2. **The documentation commit that followed item 8's implementation (`8bec56e`, "Correct
   every claim the posts prerequisite falsified") asserted "nothing links to the orphan"
   after a post deletion.** False whenever the deleted post was its category's *last*
   post: `CATEGORY_SLUGS` is derived from the filenames that exist at parse time, so a
   category with zero posts left is never rebuilt or removed, and it fossilises holding both
   the deleted post's body *and* a still-live link to the post's now-orphaned page.
3. **The fix for that claimed the fossil's link is "equally orphaned" after a *rename*
   instead of a deletion.** Also false: the category is not part of a post's URL, so renaming
   a post to a different category leaves its page at the exact same address — live, current,
   and reachable — while only the deletion case actually orphans anything.
4. **The fix for *that* asserted the renamed post's page "lags one build behind", in a bullet
   that named `tools/migrate-categories.sh` as the rename mechanism this applies to.** That is
   the one rename mechanism that does **not** lag — see item 13 above, found in the same
   review pass: the script writes the renamed file fresh rather than renaming in place, so it
   is always newer, never older, than the page it feeds.

**The whole-branch review that checked this branch before merge found three more, and the count
above was itself already wrong by the time it said "four" — two of the three new ones are inside
this entry's own commit (`666ec7a`, which wrote items 12, 13, and this item together):**

5. **A third, unrewritten copy of a claim item 8's own fix falsified — a different claim from
   1–4, and missed by every stage that caught the item-8 saga.** `tests/run.sh`'s comment above
   `test_deleting_a_post_heals_the_feed` still said listing `RSSITEM_FILES` in `.SECONDARY`
   "suppresses the rebuild" and the feed "goes stale instead of healing" — true before `posts`
   became a prerequisite of `rss.tmp`, false after. The claim was rewritten in the two places
   the spec named, the Makefile's own `.SECONDARY` comment and CLAUDE.md, but this third copy
   survived spec, plan, implementation, and four review rounds untouched. Verified false by
   mutation: appending `$(RSSITEM_FILES)` to `.SECONDARY` passes the full suite, this test
   included, identically (353/0). Fixed in this pass.
6. **Item 12's own first writeup**, inside `666ec7a`: it said the diagnostic-leak gap was two
   branches wide and that neither of two named tests asserted anything about `config.mk`'s
   content. Both false — one of the two tests already asserted content and, incidentally,
   already caught one of the two branches; the real gap was one branch, not two. See item 12
   above, corrected and closed in this pass.
7. **Item 13's own first writeup**, also inside `666ec7a`: it called the post-rename lag
   "Pre-existing — unrelated to anything this branch changed." Backwards — reproduced against
   `main` at `82065e8`, a rename never heals at all, on any target, at any number of rebuilds;
   this branch's own `posts`-prerequisite fix (item 8) is what makes the category pages heal on
   the very next build and is what produces the one-build lag on the post's own page as a
   residue of that improvement. See item 13 above, corrected in this pass.

Two of those three (6 and 7) were in one commit, in a file whose subject is not making this
mistake — and they are themselves instances of the shape: item 12 and item 13 each tried to
state, confidently and in one pass, a fact about code that had just changed underneath them,
without rerunning it against both the old and new state to check. Instance 5 is older; it
dates to `7f03f00` on main and had simply never been found.

**8. And then this entry's own commit made the eighth.** Correcting item 13 above, it added a
sentence to CLAUDE.md explaining the lag as a `.tmp` fragment carrying "the *renamed source's*
old, preserved mtime". `mv` preserves the mtime of the `.txt`, not the fragment: the fragment
does not exist at rename time and is built fresh, *newer* than the source — verified by `stat`,
and the sentence contradicted itself two clauses later. Found by the re-review of the fix wave,
which was looking for exactly this because the entry above predicts it.

That is where the counting stopped, and how: **not by writing a ninth, more careful sentence,
but by deleting the eighth.** The mechanism is stated correctly once, in item 13, and the
CLAUDE.md bullet now points at it and says plainly that three attempts to compress it in place
each produced something false. The same subtraction ended the earlier run at instance 4. A
count is a poor instrument for a defect that regenerates under correction; what the eight
instances actually establish is that **this class is produced by compression** — by a summary
sentence restating, from memory, a mechanism verified somewhere else — and the reliable cure is
one statement in one place with a pointer to it, not a better sentence in both.

**Record the shape, not just the count, because it is the same every time: one clause trying
to cover deletion and renaming as though they behave the same way, when every attempt to say
so in one sentence produced a false half.** Deletion orphans a fossil's link; renaming does
not, because the URL doesn't carry the category. A rename can still *lag* a build behind, but
only via the mtime-preservation mechanism that `mv`/`git mv` has and
`tools/migrate-categories.sh` deliberately does not.

**The static-assets branch produced ten more, 2026-08-09, taking the count from eight to
eighteen — and the only finding that matters about them is how they were caught.** Every one
was found by **running something**; not one was found by reading. The ten:

9. **The spec's central design argument.** A plain `$(BUILD_DIR)%` pattern rule was argued safe
   because make's shortest-stem selection would keep it away from generated pages. False: stem
   length only *orders* the trial, and which candidate the first pass accepts is decided by its
   prerequisites. Caught at the Task 3 checkpoint by building the two-rule reproduction, not by
   re-reading the spec — which had been read at two prior checkpoints.
10. **The check-placement constraint**, in the first form it was written: that the collision
    guards had to sit above the first rule expanding `STATIC_PAGES`. Disproven by moving the
    block; only the character check has that constraint.
11. **The upgrade-path claim** at Task 4, reproduced as false by the Task 4 review.
12. **A make-4.4-only behaviour stated as universal.** The rule-selection boundary — what
    counts as a prerequisite that "ought to exist" — moved in 4.4, and the comment stating it
    said "makeable" without a version column. Caught by probing three binaries.
13. **`find static` without the trailing slash "exits 0 having copied nothing and said
    nothing"** (R-1). True when written against the plain pattern rule of Tasks 1–2; Task 3
    changed the rule form and nobody re-ran it. Under the shipped static pattern rule make
    prints `target 'static' doesn't match the target pattern` — still exit 0, still nothing
    copied, but not silent. Both forms reproduced.
14. **The brace-expansion hazard applies "on any host whose `/bin/sh` is bash"** (R-2), said in
    three places, with the test calling itself host-conditional coverage on the strength of it.
    `Makefile:40` sets `SHELL := /bin/bash`, and make runs recipes with `$(SHELL)`, so the
    hazard and the guard are universal. This one **understated** a guard rather than
    overstating it — the same defect pointing the other way, and worse for it, since an
    understated guard invites someone to discount it.
15. **"`STATIC_SRC` is read by three checks and one prerequisite list"** (R-4). It is read by
    one check and one `patsubst`; the character check reads the listing and the three guards
    read `STATIC_PAGES`. Written at Task 1 as a forward claim — "true once Tasks 2–3 land" —
    and never revisited when Tasks 2–3 built those readers over something else. A deferred
    claim is a claim.
16. **"The placement constraint, pinned rather than commented"** — the comment on
    `test_static_character_error_precedes_the_collision_error`, which pinned nothing: its
    `static/index:x.html` fixture is bad in one way only, so the test passed under both
    orderings. A claim about *coverage* rather than about behaviour, and invisible to reading
    for exactly that reason — the test existed, was named correctly, and asserted the right
    message. Only mutation showed it was inert.
17. **"Everything that is not a directory is an asset."** The spec's justification for
    `! -type d`. False, and the only one of the nine that was a live hang rather than a wrong
    sentence: the predicate also admits FIFOs, and `cp` blocks on one forever. Caught by
    creating one.
18. **"The four-line reproduction makefile … is written up in the comment above the copy rule."**
    Written *by the fix wave for instances 9, 12 and 13* — the commit whose entire purpose was
    collapsing the triplicated argument down to one copy plus a pointer. The pointer was wrong
    in one element: the Makefile comment carries a prose *description* of the reproduction, and
    the literal four-line makefile existed only in `CLAUDE.md`, so the collapse deleted the
    repo's only copy while asserting it had been preserved elsewhere. Caught by the fix wave's
    own re-review running `grep -rn "echo REAL"` across all three documents and getting nothing.
    Fixed by describing the pointer's target accurately rather than restoring the four lines.
    **The instructive part is where it landed**: a de-duplication written to cure this defect
    introduced a fresh instance of it, which is the strongest available argument that the cure
    for the class is not care but execution.

**The pattern, and it is the whole finding — the ten here being instances 9 through 18, the
static-assets branch, with instances 19 and 20 below extending the run to twelve: ten for ten
were caught by execution, zero by inspection** — and several had survived multiple careful
readings by reviewers who were specifically looking for this class, because a false claim about
code reads exactly like a true one. Instance 16 is the sharpest case, since the thing that was
false was a test's own claim to be testing something, and instance 18 the most instructive.
What separates the ten from the earlier eight is not the rate but the cure that now exists for
their commonest cause: instances 9, 12 and 13 are all the same
argument stated in three places — Makefile comment, `CLAUDE.md`, spec — where re-running it in
one place left two copies asserting something that had stopped being true. That fix wave
collapsed `CLAUDE.md`'s copy to the conclusion plus a pointer at the Makefile's, which is the
same subtraction that ended the run at instance 4 and the run at instance 8, applied a third
time. It is the only move that has ever worked on this defect.

**19. The `refuse-decorated-date` branch's spec measured its own closure with an instrument
that could not fail.** Its section titled "What closes the item" backed the claim *no post page
path can contain a repeated slash* with `find build -name '*.html' | grep -c '//'` — a
measurement that returns 0 on **every** Makefile ever written, since the kernel collapses a
repeated `/` at file creation and `find` therefore structurally cannot print one. It scored 0
on an unmodified tree with the clobber live and `EVIL BODY` sitting in the twin's page. The
error is ordinary; the disguise is what earns it a number. It read as a *measurement* rather
than as an argument, which is the form this file trusts most, and a reader checking the section
for hand-waving would have found none. **Caught by the Fable spec review — the first of the
four checkpoints — by running the instrument against the *unfixed* tree, which is the single
operation that separates an instrument from a sentence.** Reading it again would not have done
it. Replaced by `make clean && make -n | grep -o 'build/[^ "]*' | grep -c '//'`, which reads
make's target strings before the filesystem gets a chance to normalize them: **4** on the bug,
**0** on the fix. That takes the execution-caught run from ten of ten to **eleven of eleven**,
counting from instance 9; still none found by reading.

**20. And the commit that collapsed instance 19's duplicate argument made the twentieth, which
is instance 18's shape exactly.** `09addec` de-duplicated the date-shape mechanism down to one
copy plus two pointers — the cure this entry prescribes — and in the same commit corrected the
`make -n | grep -c '//'` false-hit count from a flat 10 to one per post, attributing the hit to
"the `.staged` recipe's own `sed` text". The rate is right and was measured; the attribution is
wrong and was not. The `.staged` recipe contains no `sed` at all (`Makefile:2118`); the `//` is
the empty replacement in `s/^title:[[:space:]]*//p` in the `$(BUILD_DIR)%.html` page rule
(`Makefile:1917`), which `make -n` prints directly under that page's `Building`/`mkdir` lines.
Caught by a re-reviewer locating the line in `make -n` output instead of reading the recipe it
had been assigned to. **The mechanism worth naming is that half the sentence was measured and
half was assumed** — running the count proved the number and said nothing about where it came
from, and the measured half lent its credibility to the other. Twelve of twelve by
execution, counting from instance 9. That is twice now that a de-duplication written to cure this defect
has produced a fresh instance of it, which is the argument instance 18 makes, made again
without help.

**How it was finally stopped is itself worth recording: by *deleting* the fourth claim rather
than splitting the sentence a third way.** After three consecutive corrections each replaced
one false generalization with a narrower one that turned out to still be false in a new spot,
the fourth fix round removed the lag claim from CLAUDE.md outright, on the grounds that the
fact is pre-existing (not caused by this branch) and belongs in this backlog — as item 13
above — rather than in a document that had already shown it could not phrase the distinction
correctly in three tries.

---

### 15. DONE — a hand-typed doubled-hyphen date in a post filename silently clobbered a same-permalink post's page at exit 0

Fixed by a sixth and last clause in `check_post_name`: the date-and-category segment must
**begin with its own three date fields rejoined by single hyphens** — the prefix built with
`$(word)`, which normalizes, and matched against the raw segment with `$(filter)`, which sees
what `$(wordlist)` preserved. **Scoped to the date span on purpose.** A hyphen run *after* the
day is category territory, where runs are legal and `make new CATEGORY='a--b'` writes them, so
`2026-01-02-a--b_x.txt` still builds `build/category/a--b.html`. The collateral is one shape
and is accepted on the `BAD_CHARS` precedent: a lone `posts/-2026-01-02-home_q.txt` built
correctly before and no longer builds. Design:
`docs/superpowers/specs/2026-08-24-repeated-hyphen-permalink-clobber-design.md`.

**The spec's first closure measurement was vacuous, which is item 14's instance 19 above.**
`find build -name '*.html' | grep -c '//'` returns 0 on every Makefile ever written — the
kernel collapses the repeated slash at file creation, so `find` cannot print one — and it duly
scored 0 on an unmodified tree with the clobber live. The instrument that works reads make's
target strings off an **unbuilt** tree:

```sh
make clean && make -n 2>/dev/null | grep -o 'build/[^ "]*' | grep -c '//'
```

**4** on the unfixed tree carrying `2026-01--02-evil_x.txt` — `build/2026/01//02/x.html` and
its directory — and **0** on the fixed tree carrying every accepted shape. The `make clean` is
load-bearing: on an already-built tree `make -n` has nothing left to print and scores 0 either
way. A bare `make -n | grep -c '//'` is not a substitute either: the `$(BUILD_DIR)%.html` page
rule's `sed` line (`Makefile:1917`) carries a `//` in `s/^title:[[:space:]]*//p`, so the bare
form scores **one false hit per post** on a corpus with no bug in it at all — measured as 3 on
three posts and 10 on ten. The `grep -o 'build/[^ "]*'` is what keeps the count to target
strings.

**Three of the five tests cannot be watched failing against `main`, and are mutation-proved
instead.** `test_repeated_hyphen_in_date_is_rejected` and
`test_leading_hyphen_in_date_is_rejected` were watched RED. The other three —
`test_date_shape_error_follows_the_character_error`,
`test_date_shape_error_follows_the_empty_category_error` and
`test_doubled_hyphen_category_still_builds` — assert behaviour already correct on `main`, so
their whole job is to stop a future edit from breaking it, and each was proved by mutation:

- **A**, the clause moved to *first* in `check_post_name`: **540 passed, 4 failed**, the
  failures falling in the two ordering tests and nowhere else.
- **B**, the clause overtightened to `$(findstring --,$(call date_and_category,$(1)))` — a
  whole-segment test where the shipped one is a date-span test: **536 passed, 3 failed**, in
  `test_doubled_hyphen_category_still_builds`, the pre-existing
  `test_new_trims_edge_hyphens_from_category`, and `test_leading_hyphen_in_date_is_rejected`.
  The third is worth its own sentence: `$(findstring --,-2026-01-02-home)` is empty, so under
  that mutant a *lone* leading hyphen builds again. The overtightening is simultaneously an
  under-tightening, which is not what "tighten the rule" sounds like.

**The scope test is not the only net for mutation B, and it exists to name the reason rather
than to be the only thing that fires.** Applied to `main` before any of this branch's tests
existed, the same overtightening scores **524 passed, 1 failed** — caught by
`test_new_trims_edge_hyphens_from_category` alone, a `make new` test, which reports that
`CATEGORY='a--b'` stopped working without saying that the rule's *scope* is what changed.
`test_doubled_hyphen_category_still_builds` says it in its name.

**Two residuals this does not close, both deliberate.** The claim covers `//` in a page path
but not `/./`, and `.` is a legal filename character: `2026-.-01-home_x.txt` would build
`2026/./01/x.html` and collide with `2026-01-.-…`'s `2026/01/./x.html` by exactly this item's
mechanism, without a doubled hyphen anywhere. The new clause accepts both names; they do not
build only because `CHECKED_POST_DATES` refuses every dotted field first, so the closure leans
on the calendar check — which is `DATE_DIALECT`-gated. The full statement of that dependency,
including what relaxing the calendar check would reopen, lives in the comment above
`date_prefix` in the `Makefile`; this entry records the conclusion, because a closed item has to
say what its closure rests on, and `CLAUDE.md` carries neither — one copy of the argument plus
two pointers, on item 14's rule. Second, a **leading dot** is neither refused nor built but
*invisible*: `POST_LS` is `ls posts` without `-A`, so `posts/.-2026-01-02-home_x.txt` never enters
`POST_NAMES` and no rule in the file can see it. Pre-existing on `main` and out of scope here,
recorded because the two refused leading-hyphen shapes invite exactly the wrong generalisation.

Full suite: **544 passed, 0 failed** — 526 before the branch, 537 after the clause and its two
RED-able tests, 544 with the three mutation-proved ones. The counter counts `assert_*` calls,
not test functions, which is why three tests add seven.

Original finding follows.

Found during the `make new` branch's pre-merge fix wave, while reproducing the DATE=
validation finding below it (a `date_shape_bad` hole that let `make new` *write* a filename
of this shape). This entry is the other half: `page_for`/`CHECKED_POST_PAGES`, the machinery
that turns a filename into a build target and catches colliding permalinks, are untouched by
that branch, so the same clobber is reachable today on `main` by typing the filename by hand —
no generator, no `DATE=`, nothing branch-specific. **Verified** against a plain checkout with
`make setup` run and nothing else changed.

```sh
printf 'title: Real\n-----------------------------------\n<p>REAL BODY</p>\n' \
  > posts/2026-01-02-home_x.txt
make                                            # publishes build/2026/01/02/x.html, "REAL BODY"
printf 'title: Evil\n-----------------------------------\n<p>EVIL BODY</p>\n' \
  > posts/2026-01--02-evil_x.txt                # note the doubled hyphen before "02"
make
```

The second `make` exits **0** and prints `Building build/2026/01//02/x.html` — the doubled
hyphen survives `date_and_category`/`category_slug`'s hyphen-splitting into a **double slash**
in the target path, since paths are built straight from the filename's date fields with no
normalization. `build/2026/01//02/x.html` and `build/2026/01/02/x.html` are the same file on
every POSIX filesystem — the kernel collapses a repeated `/` — but `CHECKED_POST_PAGES`
compares the two path *strings* byte-exactly with `$(filter)`, which does not, so no collision
is ever reported. Whichever post's rule runs last wins the write; in this reproduction that is
the "evil" post, and `cat build/2026/01/02/x.html` afterward shows `EVIL BODY`, not `REAL
BODY` — the real post's page silently replaced, at exit 0, with `make deploy` shipping exactly
that.

Same family as "The guards compare byte-exactly, and on a case-insensitive filesystem that is
a hole" (`CLAUDE.md`, static-file guards) and its sibling two-post-slugs-differing-only-in-case
gotcha for posts (`2026-08-07-home_dup.txt` / `2026-08-07-work_Dup.txt`, both documented as
publishing side by side rather than colliding) — a third instance of the same root cause,
byte-exact comparison where the filesystem (or, here, the URL-path normalization every server
and browser does) does not agree that the two strings name different things. Not fixed here
and not ranked: it predates this branch, `page_for`/`CHECKED_POST_PAGES` were not touched by
it, and closing it needs the collision check to normalize (or reject) repeated hyphens the same
deliberate way the character check already rejects other shapes a filename could take —
scoped work for its own task, not a side effect of validating `make new`'s input.

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
  `{{title}}` puts the post title inside every *item's* `<link>` and `<guid>` — though not
  the channel `<link>`, which is filled first and takes the blog name instead. The single-pass fill
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

- **Out-of-range dates build successfully — DONE**, and closed wider than the item asked.
  The key realisation is that **`date` already rejected these dates and exited 1** — nothing
  heard it, because `date_from_filename` is a `$(shell)` call, which keeps the output and
  discards the status, and make 3.81 has no `.SHELLSTATUS`. So the fix is not a second
  implementation of `date`'s judgement; it is the only way to hear a verdict `date` already
  reaches, asked at parse time where a non-zero exit can still become an `$(error)`.

  Two stages, which is this entry's own "~6 lines of range-checking" with its known hole
  plugged. Make clears any year of one to five digits with month 1–12 and day 1–28 — the
  largest day valid in every month of every year, so clearing it needs no calendar knowledge —
  and only days 29–31 and malformed fields go to `date`, in one batched `$(shell)` per build.
  Range-checking alone would have passed `2026-02-30`, leaving the item half closed while
  reading as done. The result is leap-year exact: `2026-02-29` rejected, `2028-02-29` built.

  Stage one **proves rather than judges** — it must never clear anything `date` would reject —
  and the plan review caught it breaking exactly that invariant: an unbounded all-digit year
  cleared `999999999999-01-02`, never sent it to `date`, and published it with empty date
  fields, the optimisation reintroducing the bug it was meant to make cheap. Hence the
  five-digit bound. Note the real cliff is on the year's *value*, not its digit count —
  `100000000000` is accepted and `999999999999` is not, both twelve digits — which is the
  reason stage one does not try to be clever and simply defers.

  Cost: a 60-post corpus dated the 1st–28th forks zero times and measures 0.120s → 0.120s; one
  loaded with month-ends (18 suspects of 66, about triple a real calendar's share) goes 0.130s
  → 0.181s. Forking for every post instead measured 0.285s against a 0.150s baseline.

  `date_words` and `date_args` were factored out of `date_from_filename` and
  `rfc822_from_filename` so the check runs the same arguments the build will — a second,
  independently written copy could drift, and a check that answers a slightly different
  question is the same class of defect as no check. Verified byte-identical over `build/` and
  `work/`.

  Guarded by `test_out_of_range_date_is_rejected`, `test_non_numeric_date_is_rejected`,
  `test_impossible_calendar_date_is_rejected`, `test_non_leap_february_29_is_rejected`,
  `test_absurdly_long_year_is_rejected`, `test_unpadded_date_still_builds`, and
  `test_month_end_dates_still_build`. Fable's sweep cross-checked 6,188 candidate filenames
  against a direct `date` probe with zero mismatches in either direction.

  The two checks are **order-dependent and that is now tested, not merely commented**. The date
  check's `$(shell)` interpolates filenames unquoted, so `20xx-01-02-home_x$(>PWN).txt`
  executes during the parse — demonstrated, with the payload consumed so the error message
  looks clean. The character check rejects `$`, `(`, `)`, and the backtick first. The Task 2
  review found the whole property unguarded: with the two swapped, all eleven other tests still
  passed, because each used a name bad in exactly one way.
  `test_character_error_precedes_the_date_error` uses one bad in both.

  Original finding follows.

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

- **`make deploy` does not depend on `build` — DONE**, exactly as predicted and for the price
  predicted: one line, one incremental no-op build. Upgraded from **read** to **verified** on
  the way in — a recording stub `deploy.sh` confirmed it was handed a `build/` with **0
  entries** and no warning.

  The item's own counter-argument, that the current form "is more honest about doing exactly
  what it says", deserves an answer rather than a silent overrule. It loses to what the
  dishonesty costs: `deploy.sh` is user-supplied and the shipped example is an `rsync`, so one
  `--delete` turns `make clean && make deploy` into unpublishing the site. Honesty about doing
  one thing is worth less than not doing that.

  Consequences recorded rather than discovered later. `deploy` builds first but does not *set
  up* first — a directory where `make setup` has never run still fails on the missing
  templates, unchanged and correct.

  **The first write-up of this entry got the leaf-target consequence backwards, and the task
  review caught it in all three places it had been asserted.** It said hand-edits to `build/`
  are rebuilt over, with `./deploy.sh build/` offered as the escape hatch. The opposite is
  true: a hand-edited page is *newer* than its prerequisites, so make considers it up to date
  and `deploy` ships the edit — reproduced with a sentinel string, which arrived intact in the
  shipped copy at exit 0. What is regenerated is a page you *deleted*, or one whose source is
  newer. So `build/` is no safer a scratchpad than before, and the escape hatch had no premise:
  both routes ship the same bytes. Worth recording as a finding rather than quietly correcting,
  because it is this list's own recurring defect — a confident, checkable, false claim — landing
  in a commit whose whole subject was making the build safer.

  What the change really does have teeth for is that a **failing build now stops the ship**.
  That reads as losing the old form's ability to re-ship the last good `build/`, but that last
  good `build/` is mostly a myth: `.DELETE_ON_ERROR` removes a half-written page, so a build
  failing partway leaves the site with a page *missing*, and the old `deploy` shipped exactly
  that at exit 0 — verified both ways. Refusing is strictly better.

  One interaction, found by the same review: `deploy: all` gives the first-ever-`make`
  `FEED_PAGES` gotcha a one-command shape, so `make deploy` as a first invocation can *ship* a
  feedless site with no skip note. It is the documented gotcha through a new front door — the
  old `make && make deploy` shipped the same feedless output — and it needs a
  `.source/config.example` customized with `url=`. Noted in that gotcha's bullet.

  Guarded by `test_deploy_builds_first`, watched failing first — `deployed.txt` present at
  **0 bytes**, which is the empty listing rather than a missing stub, and worth checking
  because those two failures look identical in the assertion. Verified also under `-j8` and on
  a fresh install with `config` and `build/` removed.

  Original finding follows.

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

- **The `split` cleanup glob stops at `az` — DONE**, together with the same-date sibling item
  below and the masked-`cat` half of this one. `split` and both globs are gone: `SPLIT_STAGED`
  makes one awk pass over the post and writes `work/<stem>.head` and `work/<stem>.body` by
  exact name. No chunks means no ceiling, exact names mean no overreach, and no pipe means the
  `&&` chain finally covers every stage of itself — the three defects were one mechanism's
  three consequences, which is why they closed together rather than one at a time.

  Guarded by `test_many_delimiter_lines_stage_completely` (30 delimiters, five past the old
  ceiling), `test_same_date_sibling_slug_does_not_collide`,
  `test_post_without_delimiter_stages_cleanly`, and
  `test_delimiter_on_first_line_leaves_no_stray_delimiter`. All four were watched failing
  first, each with its own message rather than merely as a count.

  The fourth could not fail at all until the suite was fixed: `assert_not_grep` ran
  `grep -qF "$2"`, and a 35-hyphen pattern is read by grep as an unrecognized long option —
  exit 2, which the helper's else-branch counted as a pass. It passed against the broken
  build. All four grep helpers now pass `--`. An assertion that can only pass is worse than
  no assertion, and this one was written *on purpose* to catch a hyphen.

  Four behaviour changes, only the first of which was sought. (1) A delimiter matched
  mid-line no longer splits a post: `split -p` matched anywhere in the line, `SPLIT_STAGED`
  anchors at `^` the way `PARSE_FRONT_MATTER` always has, so staging and rendering now agree.
  (2) A post whose delimiter is on line 1 loses a stray 35-hyphen line from its rendered body.
  (3) An empty post file stops failing loudly and ships an empty page at exit 0 — a
  loud-to-silent conversion, accepted only because the verbatim `cp` branch already did
  exactly that, so the two branches now agree instead of disagreeing; making an empty post
  fatal belongs to both branches at once and is not this change. (4) A post with no trailing
  newline gains one byte in `.staged`; the page is byte-identical. Everything else is
  byte-identical, `diff -r` over `work/` and `build/` — with one exception outside the set of
  well-formed posts, the glob-character slug recorded below, which the change makes worse.

  One upgrade wrinkle: an install whose `work/` holds `.aa`/`.ab` chunks from a pre-change
  *failed* run keeps them indefinitely. The new `rm -f` does not name them and nothing globs
  them any more. They are inert; `make clean` clears them.

  The head `rm -f` survives as hygiene rather than correctness, and the Makefile comment now
  says so. Every scratch file is truncated before it is read — awk's `print >` on first write,
  the `END` block's `printf` even when nothing else is written, and the shell's `>` before
  `Markdown.pl` execs — so no stale byte can reach `$@`. Verified by neutering the `rm`:
  the whole suite still passes. An earlier draft of that comment claimed the `rm` prevented a
  stale `.mdbody` reaching the output, which review disproved before it shipped.

  Original finding follows.

- **The `split` cleanup glob stops at `az`** — `Makefile:621-626`, **read**. The masking is
  at least documented now, in the rule's own comment at `Makefile:612-614`. `$*.a[b-z]*` misses
  chunks past `az`, so a body containing more than 25 delimiter lines would silently
  truncate. Also, a post with no delimiter at all leaves the glob unmatched and `cat` errors
  into the pipeline. This item originally predicted that fixing item 1 would make the second
  case loud. It does not — **verified** after the fix: `cat … | tail` reports `tail`'s
  status, so a `cat` that finds nothing to read is still masked and the build exits 0. Item
  1's `&&` catches a failing *step*, never a failing stage of a pipe. Closing this one needs
  the pipeline broken up (or `pipefail`, which is not POSIX `sh`).

- **The staging branch's scratch glob can eat a same-date sibling's fragments — DONE**, with
  the item above and by the same mechanism: `rm -f` now names three exact files, and
  `work/x.head` and `work/x.ab.head` are distinct names rather than two matches of one
  pattern. Guarded by `test_same_date_sibling_slug_does_not_collide`, which must assert on the
  **first** build — a second `make` exits 0, because the surviving post's files are up to date
  and its `rm` never runs again, so a test that built twice could not fail. Original finding
  follows.

- **NEW — a slug containing shell glob characters silently stages a same-date sibling's
  content — DONE**, by rejecting the filename rather than by quoting the recipes. `BAD_CHARS`
  is every ASCII punctuation character except `-`, `_`, and `.`, checked as the first clause of
  `check_post_name`, so `posts/2026-01-02-home_a[b]c.txt` is now a parse-time `$(error)` naming
  the file and the offending characters.

  Quoting `$<` was the other option and is the one this entry originally leaned toward. It was
  rejected on this entry's own argument: `%.tmp` and `%.rssitem` interpolate stems the same
  way, so quoting one rule half-fixes it and reads as closed. With the filename rejected there
  is no reachable input left that reaches any of the three.

  The set is closed by enumeration rather than by judging which characters look dangerous —
  which is precisely how `[` and `]` got through in the first place. Cost: `%` and `+` stop
  building, both of which built correctly before; `%` is make's pattern-rule wildcard, so it
  was a landmine that happened not to have gone off. Non-ASCII is untouched, verified end to
  end for CJK, emoji, RTL, combining marks, and fullwidth forms.

  Guarded by `test_glob_character_slug_is_rejected` (whose load-bearing assertion is that the
  *sibling's* page is absent, not merely that the build failed),
  `test_shell_metacharacter_slug_is_rejected`, and `test_unusual_but_safe_slug_still_builds`.
  All three watched failing at 226/8 — and the RED run is worth recording, because only the
  `a*c` case failed on exit status. The apostrophe, `$` and `;` cases already failed for
  unrelated reasons (`usage: cp`, `no post in posts/ builds this page`, `No rule to make
  target`), so an exit-status assertion would have passed against the bug it exists to catch.
  All four assert the message instead.

  Two things found by review and left open, both recorded rather than snuck in: an ASCII
  **control character** in a slug still builds and lands in the URL (not shell-hazardous, so
  this item's own failure mode stays closed; rejecting it means raw control bytes in the
  Makefile source), and a **`:`** never reaches the check at all — it hits `.SECONDARY`'s
  prerequisite list first and make's own parser stops with `target pattern contains no '%'`,
  naming neither the post nor the reason. Loud, but the one character of the 29 whose error is
  make's rather than ours.

  An **empty title slug** was found in the same pass and closed with it:
  `posts/2026-01-02-home_.txt` passed every clause and published `build/2026/01/02/.html`, a
  dotfile nothing will serve. One clause, the sibling of the empty-category one, and
  `test_empty_title_slug_is_rejected`.

  Original finding follows.

- **NEW — a slug containing shell glob characters silently stages a same-date sibling's
  content** — **verified**, and **pre-existing**: found while reviewing the awk staging split.
  `posts/2026-01-02-home_a[b]c.txt` beside `posts/2026-01-02-home_abc.txt` builds at exit 0,
  and `/2026/01/02/a[b]c.html` ships the *sibling's* content. The cause is not the staging
  step's own names — those are exact now — but the unquoted `$<` in the recipe, which the
  shell glob-expands onto the neighbour before awk ever sees it. `%.tmp` and `%.rssitem`
  interpolate stems unquoted the same way, so quoting this one rule would half-fix it and read
  as if it were closed.

  Pre-existing is exact for the verbatim branch and **not** exact for the Markdown branch,
  which is worth stating plainly because the staging change made this case worse. Before it,
  the Markdown branch published the sibling's title with an *empty* body: `split` read the
  glob-expanded `$<`, but the reassembly glob `…a[b]c.a[b-z]*` read the `[b]` in the stem as a
  character class, matched none of the bracket-named chunks actually on disk, and the failing
  `cat` was masked by the pipe. Now that the leak reaches awk whole and the file names are
  exact, the whole sibling post is published. The four behaviour changes recorded above say
  everything else is byte-identical; this degenerate slug is the exception, and it moved in
  the wrong direction.

  Same family as the apostrophe-in-slug hazard the staging spec settled as out of scope, with
  one difference that earns it a bullet: the apostrophe fails **loudly**, with a shell syntax
  error, and this one is silently wrong output. Degenerate input either way — a slug with
  brackets in it produces `/2026/01/02/a[b]c.html` — but "degenerate" is an argument for
  rejecting the filename in `check_post_name`, not for publishing the wrong post.

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

- **`.source/splitter.txt` ends with a blank line — DONE**, and the finding's own description
  of it was wrong in a way worth recording. "Markdown-staged bodies gain a leading blank line"
  reads as an output difference. There is none: `PARSE_FRONT_MATTER` accumulates with
  `body = (body == "" ? $0 : body "\n" $0)`, so a leading empty line leaves `body` empty and is
  swallowed by the next line. Verified `diff -r` **byte-identical over `build/`, `rss.xml`
  included**, against an 11-post corpus built to break it — leading-blank body, double-blank,
  no body, delimiter on line 1, no delimiter, delimiter as the first body line, no trailing
  newline, blank-only body, whitespace-only first line, and an empty file. The only difference
  anywhere was one deleted blank line in each of the 11 `.staged` files.

  So the item is not cosmetic-output, it is a one-byte disagreement between the two staging
  branches in an intermediate — the Markdown branch's `.staged` differed from the verbatim
  branch's for the same input. What closing it buys is that `.staged` files are now diffable
  across branches, and that the file named "the delimiter" holds only the delimiter.

  Existing installs need nothing: `.source/splitter.txt` is read directly by the `%.staged`
  recipe and `make setup` never copies it, so there is no stale-copy problem of the kind the
  deleted `.source/templates/index.txt` stub had (§7 above, not residual item 7, which is this
  entry). The contrast is exact: `index.txt` lived inside `.source/templates/` and *was* copied
  by `make setup`'s glob; `splitter.txt` sits at `.source/` root and never was.

  One qualification on "need nothing", since the entry's stated benefit is about `.staged`
  files: `%.staged`'s only prerequisite is `posts/%.txt`, so an install's **existing** `.staged`
  files keep the old blank line indefinitely. The diffable-across-branches property arrives
  per-post as posts are next edited, or all at once on `make clean`. Verified harmless in the
  mixed state — one post restaged, its sibling stale — with `build/` byte-identical including
  `rss.xml`.

  Guarded by `test_markdown_staged_file_has_no_blank_line_after_the_delimiter`, watched failing
  first — `expected [MD:<p>STAGED BODY</p>] got []` — and it is the **only** one of the 274 that
  notices the regression, which is consistent with "reached no output" and means the single
  assertion carries all the weight. That is why the review's finding on its shape mattered: the
  first form checked line 3 by number while its label claimed "line after the delimiter", and a
  title-less fixture — a shape that already exists elsewhere in the suite — moves the delimiter
  to line 1. Verified across all four combinations, `sed -n '3p'` is wrong in **both**
  directions there: it passes against the old splitter and fails against the new one. The
  delimiter-relative `awk` form is correct in all four.

  Original finding follows.

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

- **NEW — `make -j setup all` in a fresh directory fails — DONE**, by documentation, which is
  what this entry itself proposed as the cheapest honest option. CLAUDE.md's Commands section
  and README.md both now say `setup` is a one-time step that wants its own invocation.

  Three things the entry did not have, and **two of them are corrections to the first version
  of this very entry**, caught at the Task 4 review.

  First, **`make -j setup deploy` inherits it**, now that `deploy: all` makes `deploy` a build
  goal — verified, 5/5 runs, same error. Closing ranked item 5 quietly widened this one.

  Second, **it is not a race**, and the first draft of both this entry and the CLAUDE.md
  paragraph called it one. Make resolves the whole prerequisite graph before running any
  recipe, so `build`'s prerequisites are looked up while `setup`'s recipe has copied nothing.
  On a first run `templates/` is still empty when make dies — verified — so no template lost
  anything. The word mattered because it suggests a sequencing fix.

  Third, **which template is named is deterministic**, and the first draft claimed it "varies
  between runs and machines". It does not vary at all: make names the first missing template in
  its dependency walk, which is fixed by the directory's contents. With posts present it is
  `templates/post.txt` needed by the first fragment; with `posts/` empty it is
  `templates/base.txt` needed by `build/index.html`. Verified across `-j2`, `-j4`, `-j8`, both
  goals, no within-state variation.

  The evidence that produced the wrong claim is worth recording, because it looked conclusive:
  ten runs here named `base.txt` and the checkpoint-2 review's run of the *same command* named
  `post.txt`. Same command, different `posts/` — the runs here never created one. Two
  observations that differ are evidence of a hidden variable, not of randomness, and the entry
  reached for the weaker conclusion. The documentation still quotes no filename, but now for a
  provable reason: the name is predictable from something the reader has and the document does
  not. The first draft's "a reader who checks would half the time find it false" also had the
  wrong quantifier — a reader with posts will *always* find `base.txt` false.

  The mechanical fix stays rejected, and on a stronger ground than first written. The entry
  said only that `setup` is `.PHONY`, so an order-only `build: | setup` makes `setup` remake on
  **every** build — true, confirmed with `make --debug=b`, one "Must remake target `setup'" per
  no-op rebuild against zero without it. But that is the lesser objection, and stating it alone
  implies the fix would work at that price. **It does not close the failure at any price**: an
  order-only prerequisite sequences the target's *recipe* against `setup`, not make's walk of
  `build`'s other prerequisites, and the error fires during that walk. Verified — with it
  added, `make -j4 setup all` fails identically, 3 of 3, as does `make -j4 all` alone. Making
  `setup` non-phony means inventing a stamp file for a step run once.

  Original finding follows.

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

  **Mechanism corrected, 2026-08-09.** The observation stands, but it is not a fact about make
  3.81: a Linux source build of that same 3.81 *does* compare sub-second mtimes (verified with
  `touch -d` at a fixed 0.5s delta, on every version 3.81 through 4.4.1). Make compares whole
  seconds only when its own build did not detect nanosecond `stat(2)`, so this is a property of
  the binary and the filesystem together — Apple's build on APFS truncates, this host's does
  not. The `sleep 1` guards stay: raising the make floor does not remove them, and they are
  cheap insurance against a same-tick collision even where resolution is fine.

  Original finding: **verified** (`grep -c 'touch templates/base.txt' tests/run.sh` → 0).
  `test_editing_post_template_rebuilds_fragments` guards the bare-dependency-line trap for
  `post.txt`; the identical trap existed for `base.txt` in three rules and nothing guarded
  it.

- **The markdown branch's new make constructs have never run under make 3.81 — DONE,
  2026-08-09.** **verified.** The suite was run against source builds of GNU make 3.81, 3.82,
  4.0, 4.1, 4.2, 4.2.1 and 4.3, plus the host's 4.4.1. The new constructs were not the
  problem — `$(or)`, `$(and)`, `$(origin)`, the parse-time `$(info)` and `$(wildcard)` in a
  prerequisite list all behave on 3.81. Two other things were:

  - **3.81: 352/353.** `test_unreadable_post_template_fails_the_build` fails because 3.81
    silently voids `.DELETE_ON_ERROR` for any target named in `.SECONDARY` — isolated to
    `.SECONDARY` in a six-line makefile, fixed in 3.82. Consequence verified end to end: after
    one unreadable `templates/post.txt`, a second `make` publishes a post page with an **empty
    body** at exit 0, where 4.4.1 rebuilds it correctly. The floor was not conservative, it
    was false.
  - **4.0: 350/353 + a crash.** `make` hangs or segfaults during the parse on a post filename
    containing a 4-byte UTF-8 character (`🎉party`). Fixed in 4.1. Held loosely — 4.0 was
    built from source here with glibc-compat flags, though 4.1 and 4.2 built identically are
    clean.

  3.82, 4.1, 4.2, 4.2.1, 4.3 and 4.4.1 are all 353/353. **The floor is now GNU make 4.2**,
  enforced by a `$(MAKE_VERSION)` guard at the top of the Makefile: the lowest version that is
  monotonically green *and* the one where `.SHELLSTATUS` arrives. The decision behind it —
  that macOS ships 3.81 and Mac users will be asked to `brew install make` — was made by the
  user on 2026-08-09.

  The branch review caught one consequence the change had missed: `tests/run.sh` invoked a
  bare `make` at every call site, and make does not export `MAKE`, so `gmake test` on a Mac
  would have run the suite against Apple's 3.81 and failed *every* test at the new guard
  rather than running at all. Fixed on the same branch — the suite drives `$MAKE`, the `test`
  recipe passes `$(MAKE)` in, and run.sh checks the floor once up front by running the real
  Makefile's guard rather than a second copy of the version test.

- **`.SHELLSTATUS` is now available and `BAD_POST_DATES` does not use it — NEW, opportunity
  rather than defect.** **verified** (`$(shell exit 3)$(.SHELLSTATUS)` → empty on 3.81/3.82/
  4.0/4.1, `3` on 4.2 and up). The two-stage date check exists because `$(shell)` keeps
  `date`'s output and throws its status away, and under the old 3.81 floor there was no way to
  read that status. There is now. This is **not** a straight simplification: stage one also
  exists to avoid forking at all for the common case (a corpus dated the 1st–28th forks zero
  times), and that reason survives `.SHELLSTATUS` untouched. What could go is the awkward part
  — inferring rejection from empty output rather than reading the exit code. Any rewrite has
  to keep the ordering guarantee that `CHECKED_POST_NAMES` runs first, since the `$(shell)`
  still interpolates filenames unquoted. Not started; the current form is the one the suite
  covers.

- **The no-op-setup test asserts `config.mk`'s mtime, not the `.staged` mtimes the spec named
  — NEW.** **verified** (the test passes and was watched failing). A recorded deviation
  rather than a gap: the spec asked to prove that a second `make setup` re-stages nothing,
  and the test proves the one link in that chain that can break — `config.mk`'s mtime not
  moving — while `.staged` mtimes are downstream of it through an ordinary prerequisite the
  suite already covers elsewhere. Asserting the `.staged` mtimes directly would need the
  `sleep 1` the APFS bullet above explains, in a test that currently needs one anyway. Worth
  knowing the wording drifted from the spec, not worth rewriting.

- **`make setup` is quiet about a candidate it rejected — DONE.** From the branch review,
  2026-08-08 (deletion staleness and setup probe). Setup's probe loop now prints one line per
  rejection to stderr, prefixed `grampa: setup: <probe>: <reason>`, with four reasons —
  `not runnable`, `emits a whole document`, `drops raw HTML`, `smartens punctuation`. The
  build notice's confusing-outcome case this entry described — a processor you did not expect,
  no hint why — is closed: rerun `make setup` and the rejected candidates name themselves.

  **The prefix had to be `grampa: setup:` and specifically not `grampa: markdown:`**, which
  would have read as the more natural match to the build notice's own `grampa: markdown: …`
  line. `test_clean_and_setup_print_no_notice` asserts that `grampa: markdown:` is absent from
  setup's output — the build notice belongs to a build, not to setup, and setup must stay
  quiet about it — so a rejection line sharing that prefix would have failed an existing test
  written for an unrelated reason. Guarded by `test_setup_names_a_rejected_candidate`, which
  also pins `config.mk`'s `DETECTED_MARKDOWN` line to exactly empty in the rejected-everything
  case, closing the coverage gap the diagnostic itself could have opened — see "STILL OPEN,
  the `>&2` coverage gap is only half closed" among the new findings below.

  Full suite: **352 passed, 0 failed.**

  Original finding follows.

- **`make setup` is quiet about a candidate it rejected** — **verified** as behaviour;
  the judgement is a judgement. If you have `lowdown` installed but a version whose flags the
  probe does not accept, setup skips it, silently falls through to the next candidate, and
  reports only the winner. The build notice then names a processor you did not expect and
  gives no hint why. A `--debug`-ish escape hatch, or one line per rejection on stderr, would
  turn a confusing outcome into an obvious one. Left out deliberately: the recipe is already
  the longest in the file, and nobody has hit this yet.

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

**What was left was two items, and both were decisions rather than oversights.** A later pass
took the last four small ones — the control character in a filename, `make deploy`'s missing
prerequisite, the splitter's trailing blank line, and the `-j setup` failure — leaving ranked
items 2 and 6 below: the feed's post-deletion self-heal, and the single-pass `fill()`. Neither
was waiting on anyone to notice it. Both had their reasoning written down, both were real
design rather than a fix, and both had a documented answer at the time (`make clean && make`
for the first, a closed body case for the second). **This ranked list — the numbered 1–8 below,
not the file as a whole — briefly stopped being a pile of small things and became two open
questions, and now it is back to one.** The
deletion-staleness-and-setup-probe branch closed ranked item 2: `posts` (the directory) is now
a prerequisite of `work/index.tmp`, `work/rss.tmp`, and every `build/category/%.html`, so a
directory mtime — not a stamp file, which this list's own item 8 entry once proposed and turned
out not to need — does the job. See item 8 above for the full account, including that the
entry closing it was two consumers short: it was filed as a feed bug, and the index and
category page turned out never to have healed at all. Item 6, the single-pass `fill()`, is
unaffected and remains this ranked list's one open question — a scope worth being explicit
about, because that same branch review separately opened items 12 and 13 above, in the `##
Important` numbering, not this one. Item 12 is closed as of this pass; item 13 is not, so the
file's honest total across both numberings is one open ranked item plus **two** open
`Important` items, not one flat — item 13, and the table-correction half of item 9, which has
been open all along and stays unranked. An earlier draft of this very sentence said "one open
`Important` item"; it was added to fix a scoping error and introduced a counting one.

The four that closed did what everything on this list does: **three of the four were described
wrongly by their own entries**, and the fourth was described rightly and then closed by a commit
that got something backwards. Enumerated, because a count nobody can check is exactly the kind
of claim this file exists to stop:

1. **The control-character item was one item short.** A **tab** already failed, but named a
   fragment of the filename for a reason that was not the reason. Fixing it came free with
   choosing where to put the new check.
2. **The splitter item called itself cosmetic output.** The blank line reached no output at
   all; the real defect was a one-byte disagreement between the two staging branches in an
   intermediate.
3. **The `-j setup` item proposed an order-only prerequisite as a viable fix.** It is not one —
   it does not close the problem at all, for the reason recorded in that entry. The same entry
   then described the failure as a race with a varying error message, and it is neither.
4. **`make deploy`'s entry was right** — and the commit closing it asserted the opposite of the
   truth in three places, that hand-edits to `build/` get rebuilt over. Caught by review, in the
   commit whose whole subject was making deploys safer.

Three of the four went the same way the rest of this list has: the entry was a sketch made from
reading, and contact with the code moved it. The fourth is the more uncomfortable one, since the
error was introduced by the fix rather than inherited from the finding.

**The ranked list, in rough order of how much a reader would care:**

1. ~~**The two staging-branch glob items** — the `az` ceiling and the same-date sibling
   over-match.~~ Done, in one commit, and they did want doing together. The prediction that
   they needed the pipeline broken up was right about the diagnosis and wrong about the size:
   replacing `split` with an awk pass removed the pipeline rather than restructuring it, and
   took the delimiter-less post's masked `cat` failure with it. What it grew instead was a
   test-suite defect — the assertion written to catch a 35-hyphen line could not fail, because
   grep read the pattern as an option — which is this list's recurring lesson showing up in
   the tests for once rather than in the code.

   That left item 5 and the newly found glob-character slug as the only remaining bullets
   producing silently wrong output on a strange post. **The glob-character slug has since been
   closed**, along with the out-of-range dates and an empty title slug found beside them, by
   rejecting degenerate filenames at parse time — so item 6, the residual half of the
   placeholder fix, is now the only one left, and it is a deliberate deferral rather than an
   oversight.
2. ~~**The behaviour half of item 8** — the feed's post-deletion self-heal.~~ **DONE**, by the
   deletion-staleness-and-setup-probe branch, and wider than ranked: the entry was filed as a
   feed-only bug, but the index and every category page had the identical gap and neither had
   ever healed at all — see item 8 above. `posts` (the directory) is now a prerequisite of all
   three targets, so a directory mtime carries the "the post set changed" signal the entry's
   proposed stamp file would have, without inventing one. `make clean && make` remains the
   answer for the one case this does not cover: a category deleted down to zero posts, which
   is the pre-existing deleted-category gotcha, not this one.
3. ~~**Out-of-range dates build successfully** — ~6 lines of range-checking in
   `check_post_name`, or leave as garbage-in-garbage-out.~~ Done, together with the
   glob-character slug, since both wanted the same function. Range-checking turned out to be
   the right shape but not the whole answer: it passes `2026-02-30`, so the check clears the
   ordinary case in make and asks `date` about the rest, which makes it leap-year exact. The
   recurring lesson of this list showed up twice more — the prefilter added to make it cheap
   reintroduced the very bug it was guarding, on absurdly long years, and the ordering the two
   checks depend on turned out to be guarded by a comment and no test at all.
4. ~~**An ASCII control character in a slug still builds**~~ — **DONE**, and by neither of the
   two routes this item predicted. Not raw control bytes in the Makefile source, and not the
   date check's shell stage — which would have been wrong anyway, since that stage only runs
   for posts whose date make cannot clear, and a control byte is orthogonal to the date.
   `CONTROL_CHAR_NAMES` is a second `$(shell)` that re-reads the posts directory and greps it
   under `LC_ALL=C` for `[[:cntrl:]]`, sharing the listing with `POST_NAMES` through a new
   `POST_LS` so the two cannot drift about what counts as a post.

   Re-reading the directory rather than interpolating `POST_NAMES` is what earns the design:
   it interpolates no filenames, so it has **no ordering hazard in either direction** and needs
   no equivalent of `test_character_error_precedes_the_date_error`. Verified against the real
   diff in three payload spellings — `…home_a<0x01>$(>PWN).txt` renders the payload literally
   and executes nothing, backticks likewise, and the decisive case is `$(SHELL)`, which prints
   as `$(SHELL)` and not `/bin/bash`, because `:=` never rescans a function's result.

   **The item was one item short.** A **tab** already failed, so it read as out of scope — but
   it failed with `posts/c.txt: no category in filename`, naming a file that does not exist for
   a reason that is not the reason, because `POST_NAMES` word-splits on the tab and
   `check_post_name` then judges the fragments. Having no ordering hazard made the check's
   position a free choice, and spending it on going *first* makes that message true.
   `test_tab_in_filename_names_the_whole_file` asserts both the new text and the absence of the
   old, because the build already failed and an exit-status assertion would have passed against
   the behaviour being fixed — the same trap the shell-metacharacter tests record.

   `cat -vt` and not `cat -v`: BSD `cat -v` passes a tab through untouched, and a raw tab in
   the message would split the filename back into two make words, reintroducing the exact
   fragment problem the ordering exists to fix.

   **The class is not closed, and this entry names the byte that is left.** `0x0A` is invisible
   to a line-based grep — `ls` prints such a name as two lines and neither matches — so a
   newline in a filename still dies with the fragment message. CR is caught and renders `^M`,
   so the residual is one byte and not a category. Closing it needs `-print0` and a different
   shape of check, for a filename nobody can type by accident.

   `LC_ALL=C` stays as a pin by principle rather than by demonstration, the same standing
   `rfc822_from_filename`'s has. Fable swept all 288 locales installed on the development
   machine against a mixed corpus: zero differ from the C reference, `en_US.ISO8859-1`
   included, and APFS rejects invalid UTF-8 filenames outright, so the continuation-byte hazard
   cannot reach the grep at all. `test_ordinary_filenames_survive_the_control_check` therefore
   guards the grep's false-positive surface — café, CJK, emoji — and its banner says plainly
   that it does **not** guard the locale pin. A test whose docstring claims a guarantee it has
   not got is the same defect as a test that can only pass.

   Cost: one process group per build, unconditionally. A 60-post no-op rebuild measured 0.128s
   without and 0.134s with. It does not touch the date check's "a blog dated the 1st to the
   28th spawns nothing" property, which is about a fork per *suspect post*.

   Guarded by `test_control_character_slug_is_rejected` — whose load-bearing assertion is that
   no page was published under the byte's name, not merely that the build failed —
   `test_tab_in_filename_names_the_whole_file`, `test_del_character_slug_is_rejected` (DEL is
   the one control character outside the `0x00`–`0x1F` run, so a class that stopped at `0x1F`
   would pass the first test and fail this one), and
   `test_ordinary_filenames_survive_the_control_check`. All watched failing first except the
   last, which cannot fail and says so.

   A fifth, `test_control_check_ignores_non_post_files`, was added at the whole-branch review,
   which found **the sharing argument itself unguarded**. `POST_LS` exists so the check and
   `POST_NAMES` cannot drift about what counts as a post — and severing it, by giving the check
   its own `ls posts` without the `.txt` filter, passed the entire suite at 274. `posts/` is the
   author's directory, so an editor backup with an odd byte in its name is a thing that happens;
   the mutant rejects it, the real Makefile builds. Only the harmless direction of the drift was
   open — a listing that *misses* posts is already killed by the three rejection tests — which
   is why it was a loud false positive rather than a reopened hole, and why it was still worth
   closing: it is the same class as the `addprefix` mutant closed at 271, and this list's own
   bar says surviving mutants get closed. Full suite: **275 passed, 0 failed.**

   Original finding follows.

   **An ASCII control character in a slug still builds** — **verified**, found by the Task 1
   review of the filename checks. `posts/2026-01-02-home_a<0x01>c.txt` exits 0 and publishes
   `build/2026/01/02/a\001c.html`, control byte and all, in the URL. It is not shell-hazardous
   — no globbing, no word-splitting — so the sibling-body bug that motivated `BAD_CHARS` stays
   closed, and this is a policy gap rather than a reopened hole. It also falls outside
   `BAD_CHARS`' own taxonomy: a control byte is neither a letter, a digit, ASCII punctuation,
   nor "any non-ASCII byte". Closing it means either raw control bytes in the Makefile source
   or moving the test into the date check's shell stage. Deliberately left: a control byte in a
   filename takes effort to produce, and it is not the class of mistake — a mistyped date —
   that motivated these checks.
5. ~~**`make deploy` does not depend on `build`** — arguably more honest as it is.~~ **DONE**,
   one line. The "more honest" reading lost to the cost: the example `deploy.sh` is an `rsync`,
   so an empty `build/` plus one `--delete` unpublishes the site.
6. **The residual half of the placeholder fix** — a *title* containing a literal `{{body}}`
   or `{{main}}`, or a `url=` containing `{{title}}`; see the full entry above for all four
   reproduced cases. Silently wrong output on a strange post, same as item 1, but this one is
   a decision rather than an oversight: it needs the single-pass fill, deliberately deferred.
7. ~~**The trailing blank line in `.source/splitter.txt`** — verified harmless, cosmetic.~~
   **DONE**, and "cosmetic" was the wrong word: the blank line never reached `build/` at all,
   so it was a one-byte disagreement between the two staging branches in an intermediate.
8. ~~**`make -j setup all` in a fresh directory** — close to a non-problem; the cheapest honest
   option is a line in the Commands section.~~ **DONE**, by exactly that line, in CLAUDE.md and
   README.md. `make -j setup deploy` inherits it now that `deploy: all`, and the docs
   deliberately quote no filename, because which template is named depends on the reader's
   `posts/` directory. It is also not a race, and the order-only fix does not close it.

**Of what the 2026-08-08 markdown-processor-detection branch review added, both worth-doing
items are now done, by the 2026-08-08 deletion-staleness-and-setup-probe branch review.** Item
9's *probe extension* — assert a dash survives, not just the raw HTML — was the buy, and it
shipped, closed by the deletion-staleness-and-setup-probe branch: it closes the punctuation
class for every present and future candidate row, including the three nobody has run, without
installing anything. Correcting those three rows by hand still fixes only today's table and
leaves the class open, so it is the item's worse, unranked half and stays open. Item 10
shipped too, at the predicted two characters
(`config.mk.$$$$`), with one cost the original entry didn't have: an aborted setup now leaks a
PID-named scratch file indefinitely, where the old fixed name was self-cleaning by
overwrite — see item 10 above. The 3.81 bullet is still not work, it is still a decision —
whether that floor is still real — and it is still unanswered; see "Not verified" below.

**What that same branch's own review added:** item 8's behaviour half (closed, see above and
the ranked list), a broken `make test` nobody had noticed (item 11, closed), an unguarded
coverage gap in the rejected-candidate diagnostic's own safety net (item 12, now also closed —
the whole-branch review found the gap it fixed was itself only half-described, closed the
remaining half, and corrected the writeup), a category-rename lag distinct from anything this
list had recorded, whose *mechanism* is pre-existing but whose one-build residue exists only
because this branch's own `posts`-prerequisite fix made everything else about renaming heal
(item 13, still open), and a count of the branch's own recurring defect — a confident, checkable,
false claim, seven times now, three of them inside the commits and entries meant to fix or
record an earlier instance of it (item 14). Items 12 and 13 are numbered separately from the
ranked list below and are not what "back to one" refers to — see that sentence's own scoping.

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

### Branch review, 2026-08-08 (markdown processor detection)

Same method — scratch copies of `Makefile`, `.source/`, `tests/` and `tools/`, never the real
tree. All **verified** by execution unless marked otherwise:

1. Full suite: **335 passed, 0 failed** (one environmental SKIP: no `chflags` on Linux).
2. A `#` in `markdown=` drops an author's edit at exit 0 on a *rebuild* — reproduced against
   the unfixed recipe, with `Build completed.` on stdout — and fails loudly with the parens.
   Both directions confirmed by mutation.
3. Installing a processor and running a plain `make` still stages verbatim; `make setup` then
   a plain `make` re-stages, with no `make clean`. The old `Markdown.pl` gotcha is genuinely
   closed rather than reworded.
4. A detected processor that is later uninstalled fails at `Error 127` on the next re-stage —
   never a silent fall back to verbatim — and `make setup` heals it.
5. Notice is line 1, exactly once, serial and under `-j4`; silent for `clean`/`setup`/`config`;
   prints under `-n`, `-q`, `-s`.
6. Notice costs one `$(shell)` per parse, not three — counted with a `sed` wrapper against both
   forms.
7. The upgrade guard fires on a `config.mk` holding only `DATE_DIALECT`, for the default goal,
   an explicit page goal, and `-j4`; `clean` still works; `setup` recovers without deadlock;
   `make setup all` on such a tree dies at the guard.
8. The probe rejects a candidate that eats raw HTML, one that emits a whole document, and one
   that truncates its input without poisoning the candidates behind it; the first working row
   in table order wins.
9. An installed-but-rejected candidate is never named in setup's output — the Minor bullet's
   claim, checked with a deliberately wrong-flagged `lowdown` stub.
10. Interaction check across the seven tasks: reverting `markdown_stub`'s setup re-run fails 11
    assertions across 6 pre-existing tests, and removing `hide_markdown_tools` from `sandbox()`
    fails 44 on a machine with real processors — so neither change left an older test passing
    for a changed reason.

**The BSD `date` dialect was exercised by hand on a Mac by the repo owner and worked** —
reported 2026-08-08, not reproduced here and not covered by any automated run, since every
review host has been GNU. That is the only evidence the `bsd` half of `DATE_DIALECT` has, and
it is worth more than the nothing it had before; it is recorded here so the next reviewer
does not re-open it as unverified, and so nobody mistakes it for something the suite checks.

Not executed in this review: the three unrun candidates' flags (item 9), the concurrent-setup
interleaving (item 10), make 3.81 (Minor), and the `stat -f %m` fallback in the mtime test,
which only runs on BSD.

### Branch review, 2026-08-08 (deletion staleness and setup probe)

Same method — scratch copies of `Makefile`, `.source/`, `tests/` and `tools/`, never the real
tree. All **verified** by execution unless marked otherwise:

1. Full suite from a clean tree: **352 passed, 0 failed**, under plain `make test`,
   `make -s test`, and `make -j4 test` alike (item 11).
2. `make test` and `bash tests/run.sh` disagreed on `main` at `82065e8`, before this branch —
   `MAKELEVEL`/`MAKEFLAGS` leaking into sandbox `make` calls printed
   `make[1]: Entering directory …` as the captured first line, breaking
   `test_build_announces_the_processor`'s first-line assertion; `unset` at the top of
   `tests/run.sh` fixes it (item 11).
3. Deleting a post heals the index, the category page, and the feed on the very next `make`,
   including the incremental-growth shape (11 posts, add a 12th, delete the 12th) where the
   feed previously did not heal — `posts` as a directory-level prerequisite of all three
   targets (item 8).
4. A tree with no `posts/` at all still builds an empty site at exit 0, and `posts/` is
   recreated by the new `posts:` rule rather than by make's own missing-target error (item 8's
   companion test).
5. Any entry created or removed under `posts/` — not only a `.txt` post — triggers the same
   rebuild of the index, every category page, and the feed; confirmed as a known over-trigger
   rather than a defect.
6. The punctuation probe: a stub that turns `--` into `&ndash;` is rejected and named on
   stderr as `grampa: setup: <probe>: smartens punctuation`; the winner's `config.mk` line is
   pinned to exactly empty in that case, not merely absent the rejected name (item 9, the
   Minor rejected-candidate bullet).
7. A stub that HTML-escapes `"` to `&quot;` — the false-positive shape a literal-quote probe
   would have hit — is still accepted, confirming the dash-only check does not reject
   `cmark`/`cmark-gfm`/`md2html`-style escaping (item 9).
8. `config.mk.$$$$` leaves no scratch file behind after a normal, uninterrupted `make setup`
   (`ls config.mk.* | wc -l` is 0) (item 10).
9. Dropping the `>&2` from the `smartens punctuation` branch of setup's probe loop corrupts
   `config.mk`'s `DETECTED_MARKDOWN` line and is caught by the exactly-empty assertion. Doing
   the same to the `drops raw HTML` branch corrupts it identically and is **also** caught,
   incidentally, by `test_probe_skips_a_candidate_that_eats_raw_html`'s existing
   `assert_grep config.mk "DETECTED_MARKDOWN := cmark --unsafe"` — verified by mutation, 352/1,
   `FAIL: probe_raw_html: expected 'DETECTED_MARKDOWN := cmark --unsafe' in config.mk`. Only the
   `emits a whole document` branch was genuinely uncaught; item 12 records that correction and
   its closure.
10. A post's category renamed with `mv`/`git mv` keeps its old mtime and its page rebuilds one
    `make` late, both serially and under `-j8`; the identical rename done through
    `tools/migrate-categories.sh` rebuilds on the very next `make`, with no lag, because the
    script writes the renamed file fresh rather than renaming in place (item 13).
11. Interaction check: reverting the `posts` prerequisite on any one of `work/index.tmp`,
    `work/rss.tmp`, or `build/category/%.html` fails exactly that target's own heal test and
    no others, confirming the three fixes are independent rather than accidentally
    overlapping.

**Not verified — recorded here so the next reviewer does not have to rediscover the gap:**

- **make 3.81 — no longer a gap, 2026-08-09.** Closed by the item above: every version from
  3.81 to 4.4.1 has now been built and run against the suite, and the floor moved to 4.2 as a
  result. The `.SECONDARY` comment this bullet flagged as a 4.4.1-only finding was re-verified
  by mutation on 4.2, the new floor, so the claim is now checked at both ends of the supported
  range rather than at one.
- **macOS/APFS directory-mtime semantics.** The `posts` fix (item 8) depends on a directory's
  mtime moving when an entry is created or removed inside it — true under POSIX and observed
  under Linux/ext4 on every review host here, but not observed on macOS/APFS. The existing
  `test_editing_base_template_rebuilds_every_page` bullet already records whole-second mtime
  truncation observed with Apple's make 3.81 on APFS — see the mechanism correction there,
  since it is a property of that binary rather than of the version — which is a related but
  distinct hazard from whether the directory mtime moves at all. This one is not closed by the
  new 4.2 floor: a Mac running `gmake` is still a Mac running APFS.
- **The concurrent-`make-setup`-interleaving itself.** Item 10's fix removes the fixed
  filename that made two setups collide, but no test or manual run started two `make setup`
  processes against the same directory at once, either before or after the fix.
- **The dash behaviour of `smu`, `comrak`, `multimarkdown`, and `markdown-it`** — none
  installed on any review host across either branch review. The probe extension (item 9) is
  believed to generalize to them on the same reasoning that motivated it, but "believed" is
  the honest word: nobody has run any of the four.

### Whole-branch review, 2026-08-09 (static assets)

Same method — scratch copies of `Makefile`, `.source/`, `tests/` and `tools/`, never the real
tree. All **verified** by execution unless marked otherwise. The branch adds `static/`: a
directory copied verbatim into `build/`, about twenty non-comment lines of make.

**One blocking finding, fixed before merge.** `STATIC_LS` was `find static/ ! -type d`, which
admits FIFOs, sockets and device nodes as well as the symlinks it was written for. `mkfifo
static/pipe && make` then **hung forever** at `Copying build/pipe` — killed at 20s, in serial
and under `-j8` alike; `make -n` was clean, so it was recipe-time. This is the class the
`getline` guards and the two `cat`s' `/dev/null` already close everywhere else in this program.
Shipped as `\( -type f -o -type l \)` plus `CHECKED_STATIC_TYPES`, a parse-time error naming
anything the predicate drops — loud rather than skipped, because a silent skip trades the hang
for a `static/` that does not publish in full and says so nowhere. The check runs `find -L`, so
a *symlink to* a FIFO — which hangs `cp` identically — is caught too; both halves reproduced
against the unfixed listing and pinned by `test_fifo_in_static_does_not_hang`.

**What shipped knowingly unresolved.** None of these is scheduled work; each is a decision with
its cost written down.

1. **The `category/` namespace is not reserved unconditionally, the way `rss.xml` is.** The
   guards compare against `CATEGORY_PAGES`, which is derived from the posts that exist at parse
   time, so `static/category/home.html` **builds at exit 0 and publishes** on a tree with no
   posts — and parse-errors with `static file and a generated page both build
   build/category/home.html` the day a `home` post lands. Verified both halves. That is exactly
   the "cause added weeks earlier" shape the unconditional `rss.xml` listing exists to avoid,
   and it is left open deliberately: reserving `build/category/` wholesale would forbid a
   hand-written `/category/index.html`, which is a reasonable page for a blog to want and which
   grampa itself will never generate. `rss.xml` is one fixed path with no such tension;
   `category/` is a namespace.
2. **The three collision guards compare byte-exactly, and on a case-insensitive filesystem that
   is a hole.** `$(filter)` is neither case-folding nor Unicode-normalizing, so
   `static/Index.html` does not match `build/index.html`, no guard fires, and on APFS's default
   the two paths name one inode: two rules write one file and the survivor is order-dependent,
   at exit 0. NFD/NFC twins of a non-ASCII name are the same hole. Not new and not this
   branch's: two post slugs differing only in case already evade `CHECKED_POST_PAGES`
   identically. Left as-is because a case-folding comparison would reject `static/Index.html`
   on Linux, where it is legal and collides with nothing.
3. **The shadow and under-page messages name the offender by its `build/` path, not the path
   the user has to rename.** Verified: `static/2026` beside a 2026-dated post errors with
   `static file build/2026 has the same path as a directory generated pages live in`, and a
   `static/index.html` *directory* with `static directory build/index.html …`. The file to move
   is `static/2026` and `static/index.html`. Both messages are correct about the collision and
   wrong about the address; the exact-collision message is fine, because it says "both build".
   Left as-is: the variables genuinely hold `build/` paths, and mapping back would mean a
   `patsubst` per message for a diagnostic that already names the right file to within one
   directory component.
4. **`sort -u` makes the two amended html-only tests unbounded in `.css`.**
   `test_build_output_is_html_only` and `test_category_pages_are_html_only_in_build` assert the
   set of extensions under `build/` is exactly `css html`, and `setup` now seeds
   `static/style.css`, so `css` is expected output rather than a leak. But `sort -u` collapses
   duplicates: verified with `static/extra.css` and `static/deep/more.css` added, three
   stylesheets still read as `css html` and both tests still pass. What the tests were written
   to catch — a `.tmp` or `.staged` escaping `work/` into `build/` — is still caught, since that
   would add a term. The `css` term specifically no longer counts anything.
5. **`make setup deploy` on a virgin tree ships a dangling stylesheet link.** Verified: on a
   directory where `setup` has never run, that one invocation deploys `build/index.html`
   carrying `<link rel="stylesheet" href="/style.css">` and **no `build/style.css`**, at exit 0.
   `STATIC_SRC` is a `:=` `$(shell find static/ …)` snapshotted during the parse, before
   `setup`'s recipe copies `.source/static/style.css` into place, so `STATIC_PAGES` is empty for
   that whole process. This is the sixth member of the parse-time-vs-recipe-time family already
   documented at the top of `CLAUDE.md` — the same shape as `url=`/`FEED_PAGES` — and it
   self-corrects on the next `make`. Not fixed for the same reason none of the others are: the
   documented flow is `make setup` and then `make`.
6. **The make 4.2.1 segfault is a host artifact, not branch breakage.** The prebuilt vanilla
   4.2.1 used for the cross-version probes segfaults during the parse (exit 139) on this
   branch — and on pre-branch `main` at `974c186`, at `make setup`, before any of this
   branch's code is reached. Isolated to a two-line makefile containing nothing but
   `X := $(wildcard config.mk)`, which segfaults with or without the file present, while 4.3
   and 4.4 print `ok`: vanilla 4.2.1's bundled `glob` against glibc 2.44. 4.3 and 4.4.1 both
   build this branch clean at exit 0. So the floor at 4.2 is not in question and no test needs
   changing; what cannot be done on **this host** is running the suite against a stock 4.2.1
   binary. Recorded so the next reviewer does not read the crash as a regression.

**Also verified, so the next checkpoint need not re-run it:**

7. Full suite, real tree: **427 passed, 0 failed** (one environmental SKIP: no `chflags` on
   Linux). 419 before this fix wave; the new FIFO test and the amended check-order test account
   for the other eight assertions.
8. The check-placement constraint is now genuinely pinned. It was not:
   `test_static_character_error_precedes_the_collision_error` shipped with a
   `static/index:x.html` fixture, which is bad in one way only — nothing generates
   `build/index:x.html`, so there was no collision to lose the race to — and moving the
   `GENERATED_PAGES`-and-guards block above the character check left the suite at **419/0**.
   With the fixture changed to `static/index.html x`, the same mutation gives **425/2**, failing
   on exactly that test with `static file and a generated page both build build/index.html`
   where the real Makefile says `bad character in static filename`. Both numbers measured, both
   directions. The other placement constraint — character check above the copy rule — was
   already genuinely pinned: moving the whole check-and-guard block below the copy rule gives
   **424/3**, failing `test_bad_character_in_a_static_name_fails` and the colon half of the
   check-order test, all three with make's own `multiple target patterns` where the real
   Makefile gives the character error. (416/3 was the same mutation measured against the
   419-test suite before this fix wave; the failure count is what carries over, not the pass
   count. Re-measured rather than carried forward, which is the discipline item 14 is about.)
9. Every symlink shape behaves as its test expects under the narrowed listing: a symlinked
   `static/` root publishes its contents, a symlinked asset file publishes, a symlink to a
   directory still fails loud at `cp: -r not specified`, a dangling symlink fails loud one step
   earlier than expected — at make's own `No rule to make target 'static/dangle.css'`, since
   make cannot stat the prerequisite and `$(wildcard)` in `CHECKED_STATIC_SPLIT` matches a
   dangling link so does not catch it first — and a `static/self -> .` loop is walked by
   `find`'s own loop detection without hanging. The first draft of the fix's comment said the
   dangling case was "left to `cp`"; it never reaches `cp`. Caught by running it, which is the
   point of the entry above.
10. A `,` in a static filename would silently empty the `$(filter $(s)/%,…)` argument —
    `$(filter a,b c,a b c)` is empty, and so is `$(filter build/x,y/%,build/x,y/z)`, both
    measured in a two-line makefile. It is **unreachable**, because the guards only matter when
    `$(s)` or `$(g)` is a generated-page path — `build/<y>[/<m>[/<d>]]`, `build/category`, or a
    page — none of which can hold a comma. Recorded in the guard comment because it is closed by
    an argument about the *other* operand, not by the rejected character set, so a future page
    type with an author-supplied path component reopens it.
11. The brace-expansion guard is universal, not host-conditional. `SHELL := /bin/bash` at
    `Makefile:40` is what make runs every recipe with; `/bin/sh` never enters it. Verified with a
    probe recipe printing `$0`/`$BASH_VERSION`, and by repointing `SHELL` and watching `$0`
    follow it rather than staying `/bin/sh`.
12. Only the newest ten `.tmp` fragments are prerequisites of `work/index.tmp` — `RECENT_FILES`
    is a `$(wordlist 1, 10, …)`. Confirmed with `make -pn` on a 12-post tree: `index.tmp` names
    10 of the 12. Two comments said "the fragments are prerequisites of `work/index.tmp`" without
    that qualifier; the argument they were making rests on `.SECONDARY`, which does cover all of
    them, so tightening the sentence did not change any conclusion.

**Not verified — recorded so the next reviewer does not have to rediscover the gap:**

- **Anything on macOS or APFS.** Every host in this review was Linux/ext4 with GNU coreutils.
  That covers the BSD `date` dialect (unchanged by this branch but re-exercised by nothing
  here), the case-insensitive-filesystem hole in residual 2, and BSD `find`'s handling of
  `-L` and of the `\( -type f -o -type l \)` grouping, all of which are POSIX but none of which
  were run there.
- **A stock GNU make 4.2.1 binary against the suite**, for the reason in residual 6. 4.3 and
  4.4.1 were both run.
- **Sockets and device nodes specifically.** `CHECKED_STATIC_TYPES` is written as a negation, so
  they are covered by construction rather than by enumeration, but the only special file
  actually created in a sandbox was a FIFO — the one that hangs.
