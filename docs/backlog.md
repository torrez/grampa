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

**Subtractions worth making:** delete `.source/templates/index.txt` (item 7). Nothing in the Makefile itself was
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

### 2. Nothing guards the feed's post-deletion self-heal — STILL OPEN

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

### 4. Two documents claim the rule-order breakage is silent. It is not — an earlier fix made it loud — CLAUDE.md FIXED, Makefile comment STILL OPEN

`Makefile:506-524` — **verified**, still open. `CLAUDE.md` — fixed.

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

### 6. The slash-for-hyphen fragment mapping is documented in two places and is dead in both — CLAUDE.md FIXED, Makefile comment STILL OPEN

`CLAUDE.md` — fixed. The comment block above `$(BUILD_DIR)%.html` in the Makefile
(~line 534) — **read**, still open.

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

### 7. Delete `.source/templates/index.txt` — NEW

`.source/templates/index.txt` and `CLAUDE.md:312` — **verified** (0 bytes; `make setup`
copies it into `templates/` in every install; nothing in the Makefile or the suite
references it)

It is the one tracked file in the repo with no function — a stub for a feature the index
does not need, since `index.html` is fragments wrapped in `base.txt`. The cheapest available
subtraction.

**Fix:** `git rm .source/templates/index.txt`, drop the CLAUDE.md line. Existing installs
keep their already-copied stub harmlessly.
**Cost:** one commit, two lines of doc.

---

## Minor

Every bullet below was re-checked in the second sweep and **all remain open**. Line anchors
are current as of `b0971a2`. New bullets are marked NEW.

- **`all` and `clean` are not `.PHONY`** — `Makefile:482,488`, **verified**. Only `build`,
  `setup`, `deploy`, and `test` are declared. `touch clean && make clean` prints
  `'clean' is up to date` and wipes nothing. One line: `.PHONY: all clean`.

- **Template placeholders in post bodies get expanded** — `Makefile:351-356,418-419`,
  **verified**. `fill()` rescans the composed line, so a body containing a literal
  `{{permalink}}` or `{{page_title}}` renders as the real value. For a blog whose README
  invites people to read the Makefile, a post *about grampa's template syntax* is not
  hypothetical. Cheap mitigation: fill the value-bearing keys last (`body` last in
  `RENDER_POST`, `page_title` before `main` in `WRAP_IN_BASE`), which closes the realistic
  cases. A true single-pass fill is the full fix and probably not worth it yet.

- **`PAGE_TITLE`'s `sed` reads `title:` from anywhere in the file** — `Makefile:562`,
  **verified**. `PARSE_FRONT_MATTER` stops at the delimiter; this `sed` does not. A post
  with no front-matter title but a body line beginning `title:` takes that as its
  `<title>` while its `<h4>` renders empty. Fix: add a delimiter stop —
  `sed -n '/^-----------------------------------/q; s/^title:…'` — the pattern
  `tools/migrate-categories.sh` already uses for `category:`. Cost: nil.

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

- **README nits** — `README.md`, **verified**. Line 70's Markdown link is inside-out:
  `(this zip file)[https://…]`. Line 5 has "resonably". And the README never says
  `Markdown.pl` must be *executable* — a non-executable copy silently falls back to
  verbatim HTML, because the Makefile tests `[ -x ]`. CLAUDE.md gets this right.

- **`make deploy` does not depend on `build`** — `Makefile:708-710`, **read**. So
  `make clean && make deploy` ships an empty directory. `deploy: all` would make it safe at
  the cost of an incremental no-op build. Arguably the current form is more honest about
  doing exactly what it says.

- **`POST_NAMES` uses `=`** — `Makefile:31`, **read**. The `ls | grep | sort` re-runs on
  every expansion, many times per build via `TMP_FILES` and `tmp_for_page`. `:=` is safe
  here — the lazy-`config` rationale does not apply, and `2>/dev/null` already covers a
  missing `posts/` — and removes a mid-build inconsistency window. Pure polish at blog
  scale.

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

- **Markdown-branch test gaps that remain** — `tests/run.sh`, **verified** by manual runs
  rather than by the suite. No test runs the Markdown branch under `-j`
  (`test_parallel_build_is_clean` installs no stub); no test asserts a Markdown-staged body
  reaches `rss.xml` (all three stub sandboxes leave `url=` unset); and the
  "`Markdown.pl` present but not executable → verbatim branch" path is untested. All three
  were checked by hand when the branch was fixed and all pass. Cheap to add.

- **`.source/splitter.txt` ends with a blank line** — **verified harmless**. Markdown-staged
  bodies gain a leading blank line that the verbatim branch does not have. Cosmetic.
  Re-confirmed with `od -c`: 35 hyphens, `\n`, `\n`.

- **NEW — a deleted `templates/post.txt` or `rss-item.txt` silently rebuilds from stale
  fragments** — **verified** (found by the item 3 review, not yet fixed). Both are named
  only in *pattern* rules, so under make 3.81's pattern search they are not "ought to exist"
  files: delete one and the `%.tmp`/`%.rssitem` rule simply becomes inapplicable, the
  existing `work/` fragment is taken as-is with no dependency check, and the build exits 0
  serving the old body — reproduced by editing a post, deleting `templates/post.txt`, and
  rebuilding. `templates/base.txt` and `templates/rss.txt` hard-error in the same state,
  because they are also prerequisites of the explicit `build/index.html` and
  `build/rss.xml` rules. Same silent-stale-output family as the deleted-post and
  deleted-category gotchas. Note this does **not** weaken item 3's fix: awk still never runs
  against a missing template.

- **NEW — `.gitignore` leaves `posts/` and `config` unanchored** — `.gitignore:2-3`,
  **read**. `e4f912f` anchored `/templates/` precisely because an unanchored pattern matches
  at any depth; `posts/` and `config` still match anywhere, so a future `tools/config` or a
  nested `posts/` under `docs/` would silently vanish from git. Fix: `/posts/`, `/config`,
  and while there `/build/`, `/work/`, `/deploy.sh`, `/Markdown.pl`. Cost: a few characters.

- **NEW — CLAUDE.md's tool list omits `sed` — DONE**. `sed` is load-bearing in three places
  (config parsing at `Makefile:116,140`, the `PAGE_TITLE` extraction at `Makefile:562`) and
  is now listed in the opening sentence.

- **NEW — a third stale Makefile comment, same family as items 4 and 6 — DONE**. The
  `RENDER_ITEM` comment claimed the unguarded-`getline` trap was unreachable because "the
  template is a prerequisite, so make stops first" — true for a *missing* template, false
  for the present-but-unreadable one. Fixed with item 3: the full explanation now lives
  above `RENDER_POST` and the other three programs point at it, so there is one place to
  keep true instead of three.

- **NEW — no test covers editing `templates/base.txt`** — `tests/run.sh`, **verified**
  (`grep -c 'touch templates/base.txt' tests/run.sh` → 0).
  `test_editing_post_template_rebuilds_fragments` guards the bare-dependency-line trap for
  `post.txt`; the identical trap exists for `base.txt` in three rules (`%.html`,
  `category/%.html`, `index.html`) and nothing guards it. Fix: ~10 lines mirroring the
  existing test.

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

All three are now done. Next up, on the same reasoning that ranked them: item 2 stays the
most likely regression in the repo, and item 7 stays the cheapest subtraction. What remains
of items 4 and 6 — two stale Makefile comment blocks — is still a single prose-only commit.

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
11. `.source/templates/index.txt` is 0 bytes and unreferenced; `splitter.txt` ends in a
    blank line (`od -c`).
12. `git ls-files` against `CLAUDE.md:35`; `grep` confirms no test deletes a post or touches
    `templates/base.txt`.

Taken from reading or the first sweep, **not** re-executed in the second: the same-date
sibling-glob over-match, the first-ever-`make`-with-`url=` gotcha, `deploy`'s missing
prerequisite, and `POST_NAMES`' re-expansion cost.
