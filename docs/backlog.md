# Backlog

Findings from a full-repo review on 2026-08-06, run after the RSS feed landed
(`2c0c57d`). Nothing here is a regression from that branch unless noted — most of it
predates both features.

Every item is marked with how it was established:

- **verified** — reproduced by running the build in a sandbox
- **read** — established by reading the code, not executed

Nothing found endangers `posts/`. There were no critical findings.

---

## Important

### 1. The Markdown staging branch swallows every failure

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

### 2. Nothing guards the feed's post-deletion self-heal

`tests/run.sh` — **verified** (the behaviour works; the gap is that no test covers it)

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

### 3. `RENDER_POST` and `WRAP_IN_BASE` hang on an unreadable template

`Makefile` (both `define` blocks) and `CLAUDE.md:26-31` — **verified**

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

### 4. Two documents claim the rule-order breakage is silent. It is not — an earlier fix made it loud

`Makefile:516-524` and `CLAUDE.md:151-158` — **verified**

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

### 5. The Markdown branch has no test coverage at all

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

---

## Minor

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

- **CLAUDE.md's tracked-files claim is false** — `CLAUDE.md:35`, **verified**. It says only
  `Makefile`, `README.md`, and `.source/` are tracked. `git ls-files` also shows
  `CLAUDE.md`, `.gitignore`, `tests/`, `tools/`, and `docs/`. The layout table has no rows
  for them either.

- **`make build` no longer skips anything** — `CLAUDE.md:16`, **verified**. `config` is a
  prerequisite of every page rule, so `make build` recreates a deleted `config` anyway.
  `make build` is equivalent to `make` in every reachable state; the comment describing it
  as "skipping the config check" is stale.

- **README nits** — `README.md`, **verified**. Line 70's Markdown link is inside-out:
  `(this zip file)[https://…]`. Line 5 has "resonably". And the README never says
  `Markdown.pl` must be *executable* — a non-executable copy silently falls back to
  verbatim HTML, because the Makefile tests `[ -x ]`. CLAUDE.md gets this right.

- **`make deploy` does not depend on `build`** — `Makefile:684-686`, **read**. So
  `make clean && make deploy` ships an empty directory. `deploy: all` would make it safe at
  the cost of an incremental no-op build. Arguably the current form is more honest about
  doing exactly what it says.

- **`POST_NAMES` uses `=`** — `Makefile:31`, **read**. The `ls | grep | sort` re-runs on
  every expansion, many times per build via `TMP_FILES` and `tmp_for_page`. `:=` is safe
  here — the lazy-`config` rationale does not apply, and `2>/dev/null` already covers a
  missing `posts/` — and removes a mid-build inconsistency window. Pure polish at blog
  scale.

- **The `split` cleanup glob stops at `az`** — `Makefile:599`, **read**. `$*.a[b-z]*` misses
  chunks past `az`, so a body containing more than 25 delimiter lines would silently
  truncate. Also, a post with no delimiter at all leaves the glob unmatched and `cat` errors
  into the swallowed pipeline. Fixing item 1 would at least make the second case loud.

- **`.source/splitter.txt` ends with a blank line** — **verified harmless**. Markdown-staged
  bodies gain a leading blank line that the verbatim branch does not have. Cosmetic.

---

## If only three get done

1. **Item 1 + item 5 together, as one commit.** The only route to silently deployed wrong
   output, sitting in the only untested code in the repo. The failing-stub test and the
   `&&` fix verify each other.
2. **Item 3.** Two-minute fix, closes a verified reachable hang, and stops a trap that is
   one copy-paste from spreading into the next renderer.
3. **Item 4, with the CLAUDE.md prose fixes from Minor.** Prose only, but documentation
   truth is this repo's stated identity, and "breaks silently" is exactly the kind of claim
   it has been burned by before.
