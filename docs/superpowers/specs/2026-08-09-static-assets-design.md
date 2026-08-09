# A `static/` directory, copied into `build/`

## Problem

There is nowhere to put a file that is not generated from a post. A stylesheet, a favicon, a
photograph embedded in a post body, `robots.txt`, a `CNAME` — none of them have a home. The
only directory grampa publishes is `build/`, and `build/` is documented as holding "publishable
output, and nothing else", wiped whole by `make clean`. Anything dropped in there by hand
survives exactly until the next `clean`.

The visible consequence is that every site grampa builds is unstyled. `templates/base.txt`
emits a `<head>` with a title and a feed link and no stylesheet, because there would be no way
to serve one. README's own "Not done yet" section names this: *"A home for static files (CSS,
images) that aren't generated from posts."*

## Goal

A `static/` source directory whose contents are copied into `build/` on every build,
incrementally and per file, with the relative path preserved — and a stock stylesheet so a new
install renders as a styled blog rather than as unstyled HTML.

Settled with the user, not open for the reviewer to relitigate:

- **Mirrored at the site root**, not namespaced under `/static/`. `static/style.css` publishes
  at `/style.css`. This is the only layout that can produce `/favicon.ico`, `/robots.txt`, or a
  `/CNAME`, all of which must live at the root by convention or by hosting-provider rule.
- **A collision between a static file and a generated page is a parse-time `$(error)` naming
  both.** Not "static wins", not "generated wins", and not silent.
- **Filename rules are the minimal set that breaks make or the shell**, not the stricter
  `BAD_CHARS` set `posts/` uses. `logo@2x.png` and `style,min.css` are legal names that break
  nothing, and rejecting them for symmetry's sake would be a rule with no failure behind it.
- **A stock stylesheet ships**, wired into `.source/templates/base.txt`. The alternative
  considered and rejected was mechanism-only, leaving the CSS to the author.

Explicitly out of scope: removing a `build/` file whose `static/` source was deleted. That is
the same untracked-output problem as deleting a post, and its fix is a separate `make prune`
feature. It gets a README Known-issues sentence here, not a fix.

## Design

### 1. Enumeration

Mirrors the `POST_LS` / `POST_NAMES` pair at `Makefile:188`, for the same reasons — one shell
call per build, a simply-expanded result, and a shared listing so no two consumers can drift
about what the directory holds.

```make
STATIC_LS    := find static/ ! -type d 2>/dev/null | sort
STATIC_SRC   := $(shell $(STATIC_LS))
STATIC_PAGES := $(patsubst static/%,$(BUILD_DIR)%,$(STATIC_SRC))
```

`! -type d` rather than `-type f`: a symlinked asset should be copied (`cp` follows the link),
not silently skipped. Everything that is not a directory is an asset.

**The trailing slash on `static/` is load-bearing**, and its absence is a silent-wrong-output
bug rather than a style point. If `static` is itself a symlink to a directory — a plausible
setup, with assets living outside the repo — then `find static` prints the symlink itself and
nothing under it. `patsubst` leaves that unmatched word alone, so `STATIC_PAGES` acquires the
literal word `static`, which exists as a prerequisite, and the build exits 0 having copied
nothing and said nothing. `find static/` traverses it, and behaves identically to the bare form
for a real directory and for a missing one. Verified all three cases.

`sort` because `find` walks in directory order, which is neither stable across filesystems nor
meaningful to a reader. A sorted list makes prerequisite order and error-message order
deterministic.

`2>/dev/null` is what lets a tree with no `static/` build clean at exit 0 — the same handling
`POST_LS` gives a missing `posts/`. Note this differs from `posts`, which has a rule that
creates it; `static/` has none, because nothing downstream requires it to exist.

`:=` throughout, not `=`. `STATIC_SRC` is read by three checks and one prerequisite list, and
the lazy-expansion argument that keeps `CONFIG_NAME` on `=` does not apply: `static/` needs no
recipe to have run first.

`STATIC_LS` holds a shell fragment rather than a command that runs, exactly as `POST_LS` does,
so the character check below can share the identical listing.

### 2. Two filename checks

Both are parse-time `$(error)`s, in this order.

**Characters.** The rejected set is whitespace, control characters, and the ASCII punctuation
that breaks make or an unquoted shell word:

```
space tab : % $ # \ * ? [ ] ` ( ) & ' " | ; < > =
```

Everything else is allowed, including `, + @ ! ~ ^ { } -` and `.`, and non-ASCII is allowed
exactly as it is for posts, so `static/café.jpg` and an emoji filename both build.

The check greps the directory listing rather than the make list:

```make
BAD_STATIC_NAMES := $(shell $(STATIC_LS) | LC_ALL=C grep -e '[[:space:][:cntrl:]]' -e '[]:%$$\#\\*?[`()&'\''"|;<>=]' | cat -vt)
```

That expression is verified, not asserted: against a fixture of 21 deliberately bad names and
11 legal ones it rejects all 21 and accepts all 11, on GNU grep 3.12 and on ugrep 7.5.0. The
escaping is worth reading slowly, since three layers stack on one line — `$$` is make's escape
for a literal `$`, `\#` is make's for a literal `#`, and `'\''` is the shell's way to put a
single quote inside a single-quoted string. `]` leads the bracket expression because that is the
only position where it is literal.

`\\` is the one piece chosen for portability rather than by test. POSIX says a backslash is
literal inside a bracket expression, so `\\` contributes a backslash twice and harmlessly; GNU
reads it as an escaped backslash and contributes it once. Both readings yield the same set, and
a bare `\*` would also work under both — but only by accident under one of them, so the doubled
form is written deliberately. A BSD-host confirmation belongs in the plan's verification list.

Re-reading the directory rather than interpolating `STATIC_SRC` is the lesson
`CONTROL_CHAR_NAMES` records at `Makefile:557`, and here it is load-bearing rather than merely
tidy: a filename containing a space **cannot be an element of the list you would be checking**,
because make splits on whitespace. A check written over `STATIC_SRC` could not see the
principal thing it exists to catch.

`LC_ALL=C` pins `[[:space:]]` and `[[:cntrl:]]` to bytes, matching the existing control-check's
definition — `0x00`–`0x1F` and `0x7F` — so U+0085 NEL arrives as two bytes and builds, the same
line `café` is already on.

`cat -vt` renders control bytes as `^A`, `^?`, `^I` so the message cannot spray raw bytes at a
terminal. It renders non-ASCII the same way, so a rejected `café(1).jpg` is named in the error
as `cafM-CM-)(1).jpg` — ugly, but it only ever applies to a name already being rejected, and it
is the same trade `CONTROL_CHAR_NAMES` already makes.

The command interpolates no filename into a shell line, so this check carries none of the
ordering hazard documented for `BAD_POST_DATES` — there is no `$(>PWN)` shape available to it,
and no textual-position requirement between it and anything else in the file beyond the
existence check below.

**Existence.** One line, and it closes a hole `posts/` still has:

```make
CHECKED_STATIC_SPLIT := $(foreach f,$(STATIC_SRC),$(if $(wildcard $(f)),,$(error ...)))
```

A `0x0A` inside a filename is invisible to a line-based grep: `find` prints such a name as two
lines and neither matches the character class. `CLAUDE.md` records this as a residual for
posts, alongside the space case. Here the two halves word-split into list entries that name no
file on disk, so a positive existence test catches what the denylist structurally cannot.
Confirmed on the same fixture: a file named `nl<0x0A>name.css` passes the character grep and
arrives in `STATIC_SRC` as the two words `static/nl` and `name.css`, neither of which exists.
The
message is worse than the character check's — it names a fragment, because a fragment is all
that exists to name — which is precisely why it runs second, after the check with the good
message has had its chance.

Known limitation, documented rather than cured: if a split fragment coincidentally names a real
path relative to the repo root, that fragment passes. It would then be a source file the copy
rule cannot find, so the build still fails, just later and less clearly.

Neither check is gated on `BUILD_GOAL`, so both fire on `make clean` and `make setup` too. That
matches the existing post checks, and there is no deadlock to avoid of the kind `BUILD_GOAL`
exists for: the cure is renaming a file, not running a recipe this Makefile owns.

**The character check must sit above the first rule that expands `STATIC_PAGES`; the collision
checks of section 4 must sit below the character check.** This is the same class of constraint as
`BAD_CHARS`-above-`BAD_POST_DATES`, and it is a guarantee about position in the file and
nothing else. Verified: with the checks below `build`'s prerequisite line, a file named
`static/a:b.css` dies at that line with make's own `target pattern contains no '%'` — the
unhelpful message CLAUDE.md already documents a `:` producing for posts — instead of the
character check's message naming the file and the character. It gets its own pinning test
rather than a comment alone, exactly as `test_character_error_precedes_the_date_error` does.

Corrected after the Task 3 review, which disproved the first version of this paragraph by
execution: it claimed the *collision* checks also had to sit above the first expanding rule, for
the same `:` reason. Moving the guard block below the copy rule leaves the `:` dying at the
character check exactly as before, because that check did not move. What actually binds the
collision checks is the opposite edge — they must be **below** the character check, since a
space-bearing name word-splits `STATIC_PAGES` into a bogus `build/index.html` word and a `%` in a
name would corrupt the `$(s)/%` filter patterns.

### 3. The copy rule

```make
$(STATIC_PAGES): $(BUILD_DIR)%: static/%
	@echo "Copying $@"
	@mkdir -p '$(dir $@)'
	@cp '$<' '$@'
```

A **static pattern rule**, not a plain `$(BUILD_DIR)%` pattern rule. `$(STATIC_PAGES)` is also
appended to `build`'s prerequisite list at `Makefile:1186`.

The first draft of this spec used a plain pattern rule and argued it was contained by
shortest-stem selection. **That argument was false**, and the spec review disproved it by
execution rather than by reading — the record is worth keeping, because it is the exact shape
of mistake this repo's history is full of.

**What make actually does:** implicit-rule search orders candidate rules by stem length, but the
first pass only accepts a rule whose prerequisites already exist or are themselves targets make
knows how to make. Stem length orders the trial; *existence decides it*. So on any build where a
post's `.tmp` fragment is not yet on disk, `$(BUILD_DIR)%.html` fails that first pass while a
`$(BUILD_DIR)%` rule whose `static/` twin exists on disk passes it — and the longer stem wins.
Verified: with a post `2026-08-06-home_hello.txt` and a twin `static/2026/08/06/hello.html`, and
the section 4 check removed, the impostor shipped **at exit 0** in serial, under `-j8`, and when
the page was requested by name.

Only one of the original four points survives: an **explicit** rule beats every pattern rule
outright, so `build/index.html` and `build/rss.xml` were never reachable this way (verified).
The rest was wrong.

Two changes follow from it.

**The rule becomes a static pattern rule.** `$(STATIC_PAGES): $(BUILD_DIR)%: static/%` is an
explicit rule for exactly the listed targets, so it does not compete on stem length with
anything, and it is inert for every target not in `STATIC_PAGES` — `make build/nonexistent.css`
still fails with make's own `No rule to make target`. An empty `$(STATIC_PAGES)` parses fine
and builds clean, which is the tree with no `static/` at all (verified twice: empty directory,
and no directory).

That also fixes a straightforward behavioural bug the plain form had, which none of the
originally proposed tests would have caught: under the plain form a perfectly legal,
non-colliding `static/about.html` **broke the build**. `$(BUILD_DIR)%.html` beat `$(BUILD_DIR)%`
for it — its prerequisites, an empty `tmp_for_page` plus `templates/base.txt` and `config`, all
exist — and its unknown-page guard fired with `build/about.html: no post in posts/ builds this
page`. So `/about.html`, and `/404.html` which GitHub Pages requires at the root, failed with a
message about posts. Under the static pattern rule both publish correctly (verified, including
`static/category/extra.html` against the category rule).

**The collision check in section 4 is the sole containment, and must be described as such.**
Under either rule form, a static twin of a generated page wins silently absent the check
(verified for both forms). It is not a nicety backed by rule-selection reasoning; it is the
whole defense. Section 6's CLAUDE.md note must say that, since the wrong version of this
argument reaching CLAUDE.md is precisely the failure item 14 of `docs/backlog.md` catalogues.

**The recipe is single-quoted.** `'$(dir $@)'`, `'$<'`, `'$@'`. The rejected character set is
the minimal one by settled decision, so `{` `}` and `,` are all legal in a static filename — and
`static/x{1,2}y.css` brace-expands in an unquoted `cp` on any host whose `/bin/sh` is bash,
failing with `cp: target 'build/x2y.css': No such file or directory`. Loud rather than silent,
but host-dependent: a dash `/bin/sh` builds it fine. Quoting closes it without adding characters
to the rejected set, which keeps the settled decision intact. Verified both ways. `'` is already
rejected, so nothing can escape the quotes.

`$(STATIC_PAGES)` are named directly in `build`'s prerequisite list, so make never treats them
as intermediates and `.SECONDARY` needs no entry — the same standing `RECENT_ITEMS` gives
`.rssitem` files. Verified: no re-copy on a no-op rebuild, and a by-name target still builds.

Plain `cp`, not `cp -p`. The copy gets a current mtime, newer than its source, which is what
make wants; preserving the source mtime would leave the two equal and rely on GNU make's
treatment of a tie.

The recipe echoes `Copying $@` rather than `Building $@`, since it builds nothing.

### 4. The collision check

```make
GENERATED_PAGES := $(BUILD_DIR)index.html $(BUILD_DIR)rss.xml \
                   $(addprefix $(BUILD_DIR),$(addsuffix .html,$(POST_PAGES))) \
                   $(CATEGORY_PAGES)
STATIC_COLLISIONS := $(filter $(GENERATED_PAGES),$(STATIC_PAGES))
```

`POST_PAGES` (`:=`, `Makefile:778`) rather than `html_post_files` (`=`, `Makefile:802`). The two
name the same set, but the recursive one re-walks `TMP_FILES` on every expansion — the shape
that cost 131 shell calls on a 60-post rebuild before `POST_NAMES` became `:=`. Reusing the
snapshot is free.

`$(BUILD_DIR)rss.xml` is listed **unconditionally, not through `FEED_PAGES`**. With `url=`
unset `FEED_PAGES` is empty, so a `FEED_PAGES`-gated check would accept `static/rss.xml` today
and break the build on the day the author sets `url=` — a failure whose cause is a file they
added weeks earlier. The feed page is a reserved path whether or not it is currently built.

The error names both sides and picks no winner, following the duplicate-permalink precedent at
`Makefile:783`:

```
grampa: static/index.html and a generated page both build build/index.html; rename or remove the static file
```

It must run after the character check: a static file with a broken name should be reported as a
broken name, not surface as a collision or, worse, fail to collide because it word-split into
something that matches nothing.

**Exact equality is not the whole collision surface.** A static file whose published path equals
a *directory* that generated pages live under is the same conflict one level up, and it is worse
than the exact case because it is silent. With a 2026-dated post and a static file named `2026`:
the first serial build exits 0 having **never published the file** — post pages build first, so
`build/2026/` exists as a directory newer than the source and make judges the target up to date
— and after the source is touched, the next build runs `cp static/2026 build/2026`, which copies
*into* the directory. `build/2026/2026` appears, `/2026` never gets the content, exit 0 both
times. Under `-j4` from clean it is instead a race-dependent `mkdir: cannot create directory
'build/2026': Not a directory`. A file named `category` does the same. Verified.

The check is two more `filter`s, both directions, and needs no ancestor-walking:

```make
STATIC_SHADOWS_DIR := $(strip $(foreach s,$(STATIC_PAGES),$(if $(filter $(s)/%,$(GENERATED_PAGES)),$(s))))
STATIC_UNDER_PAGE  := $(strip $(foreach g,$(GENERATED_PAGES),$(if $(filter $(g)/%,$(STATIC_PAGES)),$(g))))
```

The first catches `static/2026`, `static/2026/08`, and `static/category`. The second catches the
inverse — `static/index.html/x.css`, a static *directory* named for a generated page — which
fails loudly on its own today but with a `mkdir` message rather than an explanation. Verified
against both, and against the near-misses that must *not* fire: `static/2026/08/06/hello.htmlx`
and `static/categoryextra.css` are clean, since `filter`'s `%` is anchored by the `/`.

All three collision conditions share one message shape, naming both sides and picking no winner.

### 5. Setup, gitignore, template, stylesheet

**`setup`** gains two lines, in the existing style:

```make
	@mkdir -p static;
	-@yes n | cp -i .source/static/* static/ 2>/dev/null
```

Non-clobbering, so re-running setup never overwrites an edited stylesheet — the same guarantee
`templates/` has. The `-@` and the `2>/dev/null` match the templates line exactly.

**`.gitignore`** gains an anchored `/static/`, placed with `/posts/`, `/templates/` and the
other per-install entries and covered by the existing anchoring comment: `static/` is authored
content, per install, not part of the program.

**`.source/templates/base.txt`** gains one line in `<head>`:

```html
<link rel="stylesheet" href="/style.css">
```

**`.source/static/style.css`** is new. Scope: a system font stack, a readable measure with the
content centred, and styling for the three things `post.txt` actually emits — the `<h4>` title,
the body, and the posted-on/category line. Plus the `<h4>` that category and index pages
inherit from the same fragment. No framework, no preprocessor, no build step; it is a file that
gets copied.

New installs get both. An existing install that upgrades and re-runs `make setup` gets the
**file but not the link**: `cp -i` will not clobber its `templates/base.txt`, but
`static/style.css` does not exist yet, and `cp -i` only guards files that are already there. So
such an install ships an unreferenced `/style.css`. Harmless, and the invariant that matters
still holds — nobody acquires a stylesheet *link* pointing at a file they do not have, which is
deliberately *not* the shape of the existing `rel="alternate"` feed link that every install
advertises whether or not `url=` is set.

An earlier version of this paragraph claimed an upgrading install "gets neither the file nor the
link". That is false and was reproduced as such at the Task 4 review: `make setup` is the
documented, encouraged re-run — it is the prescribed step for picking up a newly installed
markdown processor — and it copies the stylesheet in.

An install that predates this feature keeps its old `base.txt` and therefore stays unstyled
until the author adds the link by hand. That is the same "install that predates the change"
shape as the leftover `templates/index.txt`, and gets the same treatment: a documented note, not
a migration.

**The stylesheet is one build late on a virgin tree, and that is the `FEED_PAGES` gotcha again.**
`STATIC_SRC` is snapshotted during the parse, before `setup`'s recipe has copied
`.source/static/style.css` into place — so a first-ever serial `make setup all` (the combination
CLAUDE.md blesses when `posts/` is empty) exits 0 having created `static/style.css` and never
copied it, publishing a `build/` whose pages link a `/style.css` that is not there. The next
`make` heals it. Verified end to end. This is the fifth member of the parse-time-vs-recipe-time
family, reaching a `$(shell)` snapshot this time; it is documented, not fixed, for the same
reason the others are, and the documented `make setup` then `make` flow never sees it.

### 6. Documentation

- **README**: `static/` in Install (what `make setup` creates), a "Static files" section under
  Writing a post covering the root mirroring and the filename rules, `build/style.css` in "What
  it builds", and a Known-issues sentence for the deleted-asset fossil. Remove the "A home for
  static files" line from "Not done yet".
- **CLAUDE.md**: `static/` in the Layout table; the enumeration and all three checks alongside
  the post filename rules; **section 3's corrected rule-selection account** — that stem length
  orders the trial and prerequisite existence decides it, that the static pattern rule sidesteps
  the contest entirely, and that the collision check is the sole containment — which is the piece
  a future reader is least likely to reconstruct and the piece most likely to be re-derived
  wrongly; the unconditional-`rss.xml` reasoning; the virgin-tree stylesheet lag as a new member
  of the parse-time-vs-recipe-time family.

  CLAUDE.md gets the *corrected* argument only. The falsified shortest-stem version stays in this
  spec, where its record is useful, and must not reach the reference document in any form.

- **README**: also a sentence for O1 — `static/` publishes everything in it, editor droppings
  (`style.css~`, `.DS_Store`, swap files) included, since it is a copy and not a filter.

## Testing

Thirteen tests in `tests/run.sh`, house style, each watched failing before its implementation
lands. `sandbox()` already does `cp -R "$REPO/.source" "$SBOX/"`, so `.source/static/` arrives
in every sandbox with no harness change.

| Test | Asserts |
| --- | --- |
| `test_static_file_is_copied` | `static/style.css` → `build/style.css`, bytes identical |
| `test_static_subdirectory_is_preserved` | `static/img/x.png` → `build/img/x.png` |
| `test_static_file_is_not_recopied_when_unchanged` | no `Copying` line on a no-op rebuild |
| `test_changed_static_file_is_recopied` | touched source re-copies, new content lands |
| `test_static_collision_with_index_fails` | `static/index.html` errors naming both |
| `test_static_collision_with_the_feed_fails_without_url` | `static/rss.xml` errors with `url=` unset |
| `test_static_collision_with_a_post_page_fails` | `static/2026/08/06/x.html` errors |
| `test_space_in_a_static_name_fails` | named, with the good message |
| `test_punctuation_in_a_static_name_fails` | one rejected char; and a `logo@2x.png` sibling still builds |
| `test_control_character_in_a_static_name_fails` | rendered `^A`, not raw bytes |
| `test_newline_in_a_static_name_fails` | the existence backstop fires |
| `test_build_works_without_a_static_directory` | exit 0, no `static/` present |
| `test_setup_creates_static_with_the_stylesheet` | `static/style.css` exists after setup, and re-running setup does not clobber an edited one |

Five more, every one of them added because the spec review found a defect no test above would
have caught:

| Test | Asserts |
| --- | --- |
| `test_static_html_page_is_published` | `static/about.html` publishes — the plain-pattern-rule bug of section 3, which failed with a message about posts |
| `test_static_html_page_in_category_dir_is_published` | `static/category/extra.html` likewise, against the category rule |
| `test_static_file_shadowing_a_page_directory_fails` | `static/2026` with a 2026-dated post errors instead of silently vanishing then landing in `build/2026/2026` |
| `test_static_character_error_precedes_the_collision_error` | a name bad in both ways gets the character message — the placement constraint of section 2, pinned the way `test_character_error_precedes_the_date_error` pins its sibling |
| `test_symlinked_static_directory_is_published` | a `static` symlink copies its contents rather than exiting 0 having done nothing |

`test_punctuation_in_a_static_name_fails` grows a `static/x{1,2}y.css` sibling that must
*build*, covering the recipe quoting from section 3 — on a bash-`/bin/sh` host it fails without
the quotes, and on a dash host it passes either way, so the test is honest about being
host-conditional rather than claiming universal coverage.

`test_static_file_is_not_recopied_when_unchanged` doubles as the `.SECONDARY` / intermediate-
reaping guard and should be read as covering both.

## Review

Per `CLAUDE.md`, Fable reviews this spec against the Makefile and the suite before the
implementation plan is written, then the plan, then each task's diff, then the branch end to
end. The reviewer should be told the four settled decisions above are settled, and asked to
prove claims in a sandbox copied the way `tests/run.sh` does — including `tools/`, without which
the suite reports 15 unrelated assertion failures on Linux.

### Spec-checkpoint review, 2026-08-09 (Fable)

Two blocking findings, four recommended, three optional — all folded in, none argued down. The
substantive ones:

- **Section 3's containment argument was false.** Shortest-stem selection does not protect
  generated pages; prerequisite existence decides the first pass. A static twin of a post page
  shipped at exit 0 in serial, under `-j8`, and by name. Section 3 is rewritten, the rule is now
  a static pattern rule, and the collision check is restated as the sole containment.
- **A legal `static/about.html` broke the build** under the plain pattern rule, with a message
  about posts. Fixed by the same rule change; two tests added.
- **A static file shadowing a page *directory* was silent wrong output at exit 0** — the exact
  failure class this project exists to prevent. Two more `filter`s in section 4, one test.
- Symlinked `static/` published nothing at exit 0 (`find static/`); the unquoted `cp` broke on
  brace-containing names on bash-`/bin/sh` hosts (quoted recipe); the check placement constraint
  and the virgin-tree stylesheet lag are now written down and pinned.

I independently re-verified the static pattern rule with an empty and a missing `static/`, the
`about.html` publish, the quoted recipe against `x{1,2}y.css`, the symlink traversal, and all
three collision `filter`s including their near-misses, before folding any of it in.

The reviewer's list of what it actively verified — the mechanism basics, the twin states under
both rule forms, the grep against 23 bad and 11 legal names on two greps, `,` safety end to end,
the `GENERATED_PAGES` reconstruction matching `Makefile:1186` exactly, and the `.SECONDARY`
claim — stands as covered ground for the plan and task checkpoints.

The next reviewer's attention is most wanted on whether `GENERATED_PAGES` stays exhaustive: it
is a hand-maintained restatement of what `build` produces, and a future page type that forgets
to join it silently reopens every collision this design closes.
