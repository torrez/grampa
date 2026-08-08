# The four small remaining backlog items

Date: 2026-08-07

## Problem

`docs/backlog.md` is down to six open items. Two of them — the feed's post-deletion self-heal
(item 8's behaviour half) and the single-pass `fill()` (the residual placeholder leak) — are
real design and are deliberately out of scope here. The other four are small, independent of
each other, and share nothing but their size:

| backlog rank | item |
| --- | --- |
| 4 | An ASCII control character in a slug still builds and lands in the URL |
| 5 | `make deploy` does not depend on `build` |
| 7 | The trailing blank line in `.source/splitter.txt` |
| 8 | `make -j setup all` in a fresh directory fails |

They are specified together because each is too small to carry its own spec, not because
they interact. Nothing below couples them; the plan can order them freely.

## Survey: what actually happens today

Every row verified by building it in a sandbox before designing anything, the way
`tests/run.sh` builds one — `Makefile`, `.source/`, and `tools/` copied into a scratch
directory, `make setup`, posts written by hand.

| input | today |
| --- | --- |
| `posts/2026-01-02-home_a<0x01>c.txt` | exit 0, publishes `build/2026/01/02/a^Ac.html` |
| `posts/2026-01-02-home_a<TAB>c.txt` | exit 2, `posts/c.txt: no category in filename` |
| `posts/2026-01-02-home_a<LF>b.txt` | exit 2, `posts/b.txt: no category in filename` |
| `make && make clean && make deploy` | `deploy.sh` is handed a `build/` with **0 entries** |
| `.source/splitter.txt` | 35 hyphens, `\n`, `\n` — the second `\n` reaches every Markdown-staged `.staged` |
| `make -j4 setup all` in a fresh dir | `No rule to make target 'templates/base.txt'` |

Two rows moved the design and are worth pulling out.

**The tab and newline rows.** Both die today, so neither is silently wrong output — but both
die naming `posts/c.txt` or `posts/b.txt`, a *fragment* of the filename, because
`POST_NAMES` word-splits on the whitespace and `check_post_name` then judges the fragments.
The message names a file that does not exist and gives a reason that is not the reason.
This is the same defect the control character has, one layer along: the build's account of
what is wrong with the filename is wrong.

**The splitter row.** The blank line does **not** reach `build/`. `PARSE_FRONT_MATTER`
accumulates the body with `body = (body == "" ? $0 : body "\n" $0)`, so a leading empty line
leaves `body` empty and is swallowed by the next line. Verified over a five-post corpus with
`url=` set and a Markdown stub — including a post whose body legitimately begins with a blank
line and a post with no body at all — that `diff -r` over `build/` is **empty** in both
directions, and the only difference anywhere is one blank line per `.staged` file. So this
item is not "a cosmetic difference in the output"; it is a one-byte disagreement between the
two staging branches in an intermediate, with no output consequence at all. That is a smaller
claim than the backlog's, and it is the true one.

## Item 3: reject control characters at parse time

### Approach

A batched `$(shell)` that reads the posts directory itself and greps for control characters:

```make
POST_LS    := ls posts 2>/dev/null | grep '\.txt$$'
POST_NAMES := $(shell $(POST_LS) | sort -t- -k1,1n -k2,2n -k3,3n)
…
CONTROL_CHAR_NAMES    := $(shell $(POST_LS) | LC_ALL=C grep '[[:cntrl:]]' | cat -vt)
CHECKED_CONTROL_CHARS := $(if $(CONTROL_CHAR_NAMES),$(error …))
```

`POST_LS` exists so the two `$(shell)` calls cannot drift about which files are posts. This
is the same argument that produced `date_args` in the filename-checks change: a check that
answers a slightly different question than the build asks is the same class of defect as no
check. It is a `:=` holding a shell fragment, not a command that runs — the `\.txt$$` escapes
to `\.txt$` in both expansions.

**Verified against make 3.81, not reasoned about.** The spec review built these exact four
lines into a sandbox Makefile: the stored value is `grep '\.txt$'` and is substituted verbatim
rather than rescanned at both call sites, and `POST_NAMES` comes out byte-identical to the
current Makefile's over a corpus mixing padded and unpadded dates (`2026-7-4` still sorting
before `2026-10-1`), `café`, CJK, emoji, uppercase, and dotted names. This was the one
load-bearing mechanical claim in the spec that had not been built when it was written.

`LC_ALL=C` pins `[[:cntrl:]]` to `0x00`–`0x1F` and `0x7F`. Verified that BSD `ls` writes raw
bytes when its output is a pipe (the `?`-substitution is terminal-only behaviour), so the
bytes are there to be matched; verified that the grep catches both `0x01` and DEL `0x7F`, and
matches nothing on a clean corpus.

### Why it reads the directory instead of `$(POST_NAMES)`

The obvious alternative, `printf '%s\n' $(POST_NAMES) | grep …`, interpolates post filenames
into a shell command line unquoted — which is exactly the property that forces the date check
to sit below `CHECKED_POST_NAMES` and that needed
`test_character_error_precedes_the_date_error` to guard it. Re-reading the directory
interpolates nothing, so this check has **no ordering dependency in either direction**. That
is worth one extra process: it is one fewer load-bearing textual-order constraint in a file
that already has three.

### Why it goes *above* `CHECKED_POST_NAMES`

Having no ordering hazard means the position is free, so it is chosen for the message quality
instead. Placed first, a **tab** in a filename gets

```
posts/2026-01-02-home_a^Ic.txt: control character in filename
```

instead of today's `posts/c.txt: no category in filename`. Placed second, the word-split
fragments reach `check_post_name` first and the confusing message wins.

The `check_post_name` comment block currently opens "Characters are checked first, before any
clause tries to make sense of the filename's shape." That stays true of the *shape* clauses
and stays true of everything the date check depends on — `BAD_CHARS` still runs above
`BAD_POST_DATES`, which is the constraint that matters — but the block must say that the
control-character check precedes it and why its position is a free choice rather than a
requirement.

### The error message

`cat -vt` renders the offending bytes: `0x01` as `^A`, DEL as `^?`, tab as `^I`. Three
reasons, all of which matter:

1. Raw control bytes never reach the terminal.
2. The rendered name has no whitespace, so a tab-bearing filename stays **one** make word and
   the error names whole filenames rather than fragments — the very failure being fixed. `-t`
   and not plain `-v` for exactly this: BSD `cat -v` passes tab through untouched. Verified.

   The one-make-word guarantee is for **control characters alone**. A filename carrying both
   a control byte *and* a space still renders with the space intact, so `$(addprefix posts/,…)`
   prefixes both halves and the message fragments again — though it is still the
   control-character error and still loud. Worth a clause in the Makefile comment so the claim
   there is airtight rather than nearly true.
3. The message is readable, which is the whole point of the item.

The message must therefore say the name is *rendered*, not literal, since `^A` is two
characters standing in for one byte. Wording:

```
posts/2026-01-02-home_a^Ac.txt: control character in filename (shown as ^X);
a post filename may contain letters, digits, and only these punctuation marks: - _ .
```

One error naming all offending files, matching `check_page_collisions` and the date check.

### Residual: a newline in a filename is still not caught

A line-based grep cannot see a newline inside a filename — `ls` prints such a name as two
lines and neither line matches. Verified twice, independently: it still fails with the
fragment message, exit 2.

The residual is **exactly `0x0A`, one byte of the 33**. CR (`0x0D`) *is* caught and renders
as `^M` — verified — so this is not "the whitespace controls get through", it is the line
terminator and nothing else. Say the byte, not the category; a reader can check the byte.

This is documented, not closed. Closing it means `find posts -print0` or similar and a
different shape of check for one byte, and the result would still be a filename nobody can
type by accident. It belongs beside the `:` residual already documented in CLAUDE.md — the
honest statement is "control characters are rejected except the line terminator", not "the
class is closed".

**If a test for this residual is ever written, it must use `$'\n'` and not
`$(printf '\n')`.** Command substitution strips trailing newlines, so
`touch "…home_a$(printf '\n')b.txt"` creates a file with *no* newline in its name — a clean
filename that builds. The spec review fell into this and its first residual probe silently
tested the wrong thing. That is precisely the can-only-pass shape that has bitten this suite
twice before, and it is cheaper to write the warning down than to have someone rediscover it.

### Cost

One extra process group per build (`ls`, two `grep`s, `cat`), unconditionally. It does not
touch the date check's "a blog dated the 1st to the 28th spawns nothing" property, which is
about a fork *per suspect post*.

Pre-measured by the spec review against a working implementation: a 42-post no-op rebuild
went **0.10s → 0.11s**, five runs each. Constant in the post count, as expected — it is one
process group however many posts there are. Still to be re-measured at 60 posts during
implementation and reported in the commit message, per the precedent set when a no-op rebuild
went from 0.79s to 0.12s: if it lands materially above the current 0.12s, say so rather than
shipping it quietly.

## Item 4: `make deploy` builds first

```make
.PHONY: deploy
deploy: all
	@./deploy.sh $(BUILD_DIR)
```

One line. `all` is `config build` and is already `.PHONY`, so this is an incremental no-op
build in the common case.

The backlog's counter-argument — that the current form "is more honest about doing exactly
what it says" — is real but loses to the failure mode. `deploy.sh` is user-supplied and the
example is an `rsync`; a `--delete` flag in it turns `make clean && make deploy` into
"unpublish the site". Verified today: `deploy.sh` is handed a `build/` containing 0 entries
and no warning is printed. The cost is one quiet no-op build, which the repo has already paid
for and measured at 0.12s across 60 posts.

**Behaviour change worth writing down:** `make deploy` in a fresh clone now creates `config`
and builds rather than failing on a missing `build/`. That is a strict improvement, but it
means `deploy` is no longer a leaf target, and someone who deliberately hand-edits `build/`
before deploying will have their edits overwritten. That is what `deploy.sh build/` invoked
directly is for, and the Commands section should say so.

## Item 5: strip the trailing blank line from `.source/splitter.txt`

The file becomes 35 hyphens and one `\n`. Per the survey above, `build/` is byte-identical —
verified with `diff -r` over a corpus including the two degenerate bodies — and the only
effect is that the Markdown branch's `.staged` files stop differing from the verbatim
branch's by one blank line.

The value is that the two staging branches produce the same intermediate for the same input,
so `.staged` is diffable across branches and the file named "the delimiter" holds only the
delimiter. Framed correctly this is worth the one byte; framed as the backlog frames it —
"Markdown-staged bodies gain a leading blank line" — it sounds like an output bug and is not
one.

**Existing installs are unaffected.** `.source/splitter.txt` is read directly by the
`%.staged` recipe, not copied into `templates/` by `make setup`, so there is no stale-copy
problem of the kind item 7's deleted `index.txt` had.

## Item 6: document that `setup` wants its own invocation

Prose only, in two places:

- `CLAUDE.md` Commands section, under the command list: `setup` is a one-time step; do not
  combine it with a build goal under `-j`, because the template copying races the build rules
  and stops with `No rule to make target 'templates/…'`. Serial `make setup all` is fine, and
  so is the documented `make setup` then `make`.

  **Do not name a specific template in that message.** Which one loses the race is
  race-dependent: the backlog's reproduction got `base.txt` and the spec review's got
  `post.txt`, same command in the same shape of directory. A document whose stated identity is
  checkable against the code must not print a specific string here, because a reader who
  checks it will half the time find it false.
- `README.md`, in the sentence that already tells people to run `make setup` first.

Not fixed in the Makefile. An order-only prerequisite is the obvious mechanical fix and does
not work here: `setup` is `.PHONY`, so `build: | setup` would run the copying on **every**
build. Making it non-phony means inventing a stamp file for a one-time step, which is more
machinery than the problem deserves — the documented workflow already has `setup` on its own
line in both documents.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Control-char mechanism | A second `$(shell)` re-reading `posts/` | Interpolates no filenames, so it has no ordering hazard and needs no guard test. Costs one process per build. |
| Sharing the listing | `POST_LS` variable | Two independently-written listings could drift about what counts as a post. Same argument as `date_args`. |
| Control-char position | Above `CHECKED_POST_NAMES` | Free choice, spent on giving a tab-bearing filename a true message instead of a fragment. |
| Error rendering | `cat -vt` | Keeps raw bytes off the terminal and keeps a tab-bearing name a single make word. |
| Newline in a filename | Documented residual | A line-based grep cannot see it; closing it is a different mechanism for one unreachable-by-accident byte. |
| `deploy` | `deploy: all` | A `--delete` rsync against an empty `build/` unpublishes the site. One quiet no-op build is cheap insurance. |
| `splitter.txt` | Strip the blank line | Makes the two staging branches agree on `.staged`. Verified to change no output. |
| `make -j setup all` | Document | The mechanical fix needs a stamp file for a one-time step; both documents already show `setup` alone. |

## Behaviour changes

1. **A control character in a post filename is now a parse-time `$(error)`.** Previously exit
   0 and a published page with the byte in its URL.
2. **A tab in a post filename gets a different, true message.** Previously exit 2 naming a
   fragment; now exit 2 naming the file. Still a failure either way.
3. **`make deploy` builds first.** See item 4 above.
4. **Nothing changes in `build/` for any well-formed post**, from any of the four. The
   splitter change alters `work/*.staged` only; the others are parse-time errors, a
   prerequisite, and prose.

`posts/` is untouched by all four.

## Tests

Each watched failing against the current `Makefile` before the fix goes in, per the house
rule that a test that has never failed guards nothing. Where a test **cannot** fail
beforehand it is marked as such, and it guards the new check's false-positive surface rather
than the bug.

1. **`test_control_character_slug_is_rejected`** — `posts/2026-01-02-home_a<0x01>c.txt`
   beside a well-formed post. Asserts the build fails, the message names the file with `^A`
   in it, and — the load-bearing assertion — that **no page was published under the control
   byte's name**, mirroring how `test_glob_character_slug_is_rejected` asserts the sibling's
   page is absent rather than merely that the build failed. Fails today at exit 0 with the
   page published.

2. **`test_tab_in_filename_names_the_whole_file`** — `posts/2026-01-02-home_a<TAB>c.txt`.
   Asserts the message contains `home_a^Ic.txt` and does **not** contain
   `no category in filename`. Fails today: the build already fails, but with the fragment
   message, so an exit-status assertion would pass against the behaviour being fixed. This is
   the same trap recorded in the shell-metacharacter tests, and the reason this test asserts
   text.

3. **`test_del_character_slug_is_rejected`** — `0x7F`. Fails today at exit 0. Separate from
   test 1 because DEL is the one control character outside the `0x00`–`0x1F` run, so a
   hand-written character class that stopped at `0x1F` would pass test 1 and fail this one.

4. **`test_ordinary_filenames_survive_the_control_check`** — the `café`, uppercase, and
   dotted slugs from `test_unusual_but_safe_slug_still_builds`, asserting exit 0 and each
   body on its own page. **Cannot fail before the change**, and — settled by the spec review
   rather than left for implementation — **it does not guard the `LC_ALL=C` pin either.** The
   reviewer swept all 288 locales installed on this machine, comparing the pipeline's output
   against the `LC_ALL=C` reference over a corpus of `café`, CJK, emoji, uppercase, `0x01`,
   `0x7F`, and tab: **zero locales differ**, `en_US.ISO8859-1` included, where UTF-8
   continuation bytes `0x80`–`0x9F` are nominally C1 controls but macOS's locale tables do not
   class them `cntrl`. The hazard is also unreachable at the filesystem — APFS rejects invalid
   UTF-8 outright with `Illegal byte sequence`.

   So the `LC_ALL=C` stays as a **pin by principle, not by demonstration**, exactly as
   `rfc822_from_filename`'s does: both are about environments the development machine cannot
   reproduce. The Makefile comment must say that, and **test 4's banner must not claim to
   guard the locale pin** — what it guards is any edit that widens the grep pattern or breaks
   the pipeline into matching everything. Do not spend implementation time re-running the
   mutation; it has been run.

5. **`test_deploy_builds_first`** — a sandbox with a stub `deploy.sh` that records how many
   entries it was handed. `make`, `make clean`, `make deploy`; assert the stub saw a
   populated `build/` with `index.html` in it. Fails today: the stub records 0 entries.

6. **`test_markdown_staged_file_has_no_blank_line_after_the_delimiter`** — with the Markdown
   stub, assert the `.staged` file's line 3 is the body's first line rather than empty. Fails
   today. Pins the two branches' agreement so a future edit to `splitter.txt` cannot quietly
   restore the blank line.

The full suite must be run behind this: the control check runs against every post filename in
every sandbox, so a mistake in it breaks tests unrelated to this work. Current baseline is
**259 passed, 0 failed** at `f3478d0`, which is the suite's own `passed:` line and the number
every other entry in `docs/backlog.md` quotes. It is not 160: `grep -c '^test_' tests/run.sh`
returns 160 because it counts each of the 80 test functions twice, once at its definition and
once in the invocation list at the bottom of the file. An earlier draft of this spec quoted
that number; the review caught it. Confirmed by running the suite from a scratch copy of
`master`.

## Documentation updates

- **`Makefile`** — a comment block above `POST_LS`/`CONTROL_CHAR_NAMES` in the existing
  `#`-banner style covering: what `[[:cntrl:]]` under `LC_ALL=C` covers, why the check
  re-reads the directory rather than interpolating `POST_NAMES` (no ordering hazard, unlike
  the date check), why it is placed above `CHECKED_POST_NAMES` (a free choice spent on the
  tab message), why `cat -vt` and not `cat -v`, and the newline residual. The
  `check_post_name` block's "characters are checked first" opening amended to say what now
  precedes it and that `BAD_CHARS` above `BAD_POST_DATES` is the constraint that still
  matters. A short note on `deploy: all` saying what it costs and what it prevents.
- **`CLAUDE.md`** — the Post format section's closing sentence, currently "Two things still
  get through: an ASCII **control character** builds and lands in the URL … and a **`:`**
  dies earlier and less helpfully", becomes the newline and the `:`. The four filename rules
  become five. The Commands section gains the `make deploy` behaviour and the `-j setup`
  line. The `.source/splitter.txt` row in the Layout table is unchanged; the file still holds
  the delimiter.
- **`README.md`** — the `make setup` sentence gains the `-j` caveat.
- **`docs/backlog.md`** — all four marked DONE in the established "**DONE**, then the
  original finding" shape, and struck through in the ranked remaining-work list. The ranked
  list's preamble needs updating: with these four gone, what is left is exactly the two
  design items, which is worth saying plainly since it changes the list from "a pile of
  small things" to "two decisions nobody has made yet".

## Already verified by execution — do not re-check

The spec review (checkpoint 1) proved the following in throwaway sandboxes against GNU make
3.81. The plan and task checkpoints should treat these as settled and spend their effort
elsewhere.

1. `POST_LS` works as a shared shell fragment across both `$(shell)` sites; `POST_NAMES` is
   byte-identical to today's over a mixed corpus.
2. The control check placed above `CHECKED_POST_NAMES` produces the promised messages —
   `^A`, `^?`, `^I`, `^M`, one error naming two offenders — and placed *below* it, tab
   regresses to the fragment message. The placement argument is empirically right.
3. The check disturbs no existing test: **259 passed, 0 failed** both with and without it.
4. `[[:cntrl:]]` is locale-insensitive across all 288 locales on this machine; APFS rejects
   invalid UTF-8 filenames outright.
5. BSD `ls` pipes raw bytes; `cat -v` alone passes tab through, so `-t` is load-bearing.
6. `deploy: all` is clean serially, under `-j8`, and in a fresh clone with no `config` and no
   `build/`. No pattern-rule or `.PHONY` interaction.
7. Stripping the splitter blank line leaves `build/` byte-identical — including `rss.xml` —
   over an 11-post corpus built to break it: leading-blank body, double-blank, no body,
   delimiter on line 1, no delimiter, delimiter as first body line, no trailing newline,
   blank-only body, whitespace-only first line, and an empty file. `splitter.txt` has exactly
   one consumer (`Makefile:1049`) and `make setup` never copies it.
8. `build: | setup` does make `setup` remake on every build (`make --debug=b`), so
   documenting rather than fixing item 6 is correct.
9. All six proposed tests fail before the change for the stated reasons, except test 4, which
   is flagged as unable to fail and now correctly scoped.

## Out of scope

- The behaviour half of backlog item 8 (the feed's post-deletion self-heal).
- The residual placeholder-expansion hole (the single-pass `fill()`).
- A newline inside a post filename, per the residual above.
- Quoting stems in recipes — unchanged, and unreachable for the same reason the filename
  checks made it unreachable.
- Any change to what a well-formed filename means.
