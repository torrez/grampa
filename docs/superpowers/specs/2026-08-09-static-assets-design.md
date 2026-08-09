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
STATIC_LS    := find static ! -type d 2>/dev/null | sort
STATIC_SRC   := $(shell $(STATIC_LS))
STATIC_PAGES := $(patsubst static/%,$(BUILD_DIR)%,$(STATIC_SRC))
```

`! -type d` rather than `-type f`: a symlinked asset should be copied (`cp` follows the link),
not silently skipped. Everything that is not a directory is an asset.

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

### 3. The copy rule

```make
$(BUILD_DIR)%: static/%
	@echo "Copying $@"
	@mkdir -p $(dir $@)
	@cp $< $@
```

`$(STATIC_PAGES)` is appended to `build`'s prerequisite list at `Makefile:1186`.

A pattern rule whose target is `$(BUILD_DIR)%` matches every path under `build/`, which in a
Makefile with this one's history deserves the argument written out. Four things contain it, and
the comment block above the rule will carry all four:

1. **It is only applicable when `static/<stem>` exists.** Make drops a pattern rule whose
   prerequisite neither exists nor can be built. On a tree with no `static/index.html` the rule
   is simply not a candidate for `build/index.html`.
2. **`build/index.html` and `build/rss.xml` have explicit rules**, and an explicit rule beats
   every pattern rule outright regardless of stem length.
3. **Shortest-stem selection covers the two pattern-matched families.** For
   `build/2026/08/06/x.html` the competing stems are `2026/08/06/x.html` against `%.html`'s
   `2026/08/06/x`; for `build/category/home.html` they are `category/home.html` against
   `category/%.html`'s `home`. The existing rules win both, at every make version above the 4.2
   floor. (Below it this would be makefile-order-dependent, which is why the floor guard
   matters here too.)
4. **`%` is in the rejected character set**, so no static filename can perturb stem matching.

Point 1 means the collision check in section 4 is not merely a nicety: it is what guarantees
the states where points 2 and 3 would be doing the work never arise in a build that runs at
all.

`$(STATIC_PAGES)` are named directly in `build`'s prerequisite list, so make never treats them
as intermediates and `.SECONDARY` needs no entry — the same standing `RECENT_ITEMS` gives
`.rssitem` files.

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

Both files reach existing installs together or not at all: `cp -i` will not clobber an existing
`templates/base.txt`, and an existing install has no `static/`, so nobody acquires a stylesheet
link pointing at a file they do not have. New installs get both. This is deliberately *not* the
shape of the existing `rel="alternate"` feed link, which every install advertises whether or
not `url=` is set — the README already admits that one 404s.

An install that predates this feature keeps its old `base.txt` and therefore stays unstyled
until the author adds the link by hand. That is the same "install that predates the change"
shape as the leftover `templates/index.txt`, and gets the same treatment: a documented note, not
a migration.

### 6. Documentation

- **README**: `static/` in Install (what `make setup` creates), a "Static files" section under
  Writing a post covering the root mirroring and the filename rules, `build/style.css` in "What
  it builds", and a Known-issues sentence for the deleted-asset fossil. Remove the "A home for
  static files" line from "Not done yet".
- **CLAUDE.md**: `static/` in the Layout table; the enumeration and both checks alongside the
  post filename rules; the pattern-rule containment argument from section 3, which is the piece
  a future reader is most likely to need and least likely to reconstruct; the `FEED_PAGES`-vs-
  unconditional-`rss.xml` reasoning as a Gotcha, since it is a fifth member of the
  parse-time-vs-recipe-time family in spirit if not in mechanism.

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

The pattern-rule containment argument needs a test that would fail if the rule started winning
where it should not: `test_static_collision_with_a_post_page_fails` covers the collision, and
`test_static_file_is_copied` run in a tree that also has posts covers the converse — both rules
active, each claiming its own targets.

## Review

Per `CLAUDE.md`, Fable reviews this spec against the Makefile and the suite before the
implementation plan is written, then the plan, then each task's diff, then the branch end to
end. The reviewer should be told the four settled decisions above are settled, and asked to
prove claims in a sandbox copied the way `tests/run.sh` does — including `tools/`, without which
the suite reports 15 unrelated assertion failures on Linux.

The reviewer's attention is most wanted on section 3: whether a `$(BUILD_DIR)%` pattern rule can
be made to claim a generated page under any reachable state, `-j` included.
