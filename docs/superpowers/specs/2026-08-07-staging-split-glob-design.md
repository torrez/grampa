# Replacing the staging split with awk

Date: 2026-08-07

## Problem

The `%.staged` rule (`Makefile:779-795`) splits a post's front matter from its body with
`split -p` and reassembles the body by globbing the resulting chunks. Three defects follow
from that mechanism, all of them in `docs/backlog.md` and all of them producing silently
wrong output or masked errors rather than a failed build.

**1. The chunk glob stops at `az`.** `split` names chunks `.aa`, `.ab`, … `.az`, `.ba`, and
the reassembly glob is `$*.a[b-z]*`. A body containing more than 25 delimiter lines produces
a `.ba` chunk that the glob does not match, so the tail of the post is silently dropped from
the staged file and from every page built out of it. No error, exit 0, truncated post.

**2. The scratch glob over-matches a same-date sibling.** Both `rm -f`s use
`$(WORK_DIR)$*.a[a-z]*`. Given `posts/2026-01-01-home_x.txt` alongside
`posts/2026-01-01-home_x.ab.txt`, the stem `2026-01-01-home_x` expands that glob onto
`work/2026-01-01-home_x.ab.staged` and `…x.ab.tmp` — the sibling's real outputs — and deletes
them mid-build. This one fails loudly (`cat: … No such file or directory`, exit 2, both
serial and under `-j8`) and is pre-existing: `git show HEAD:Makefile` fails identically.
Differing dates do not collide, because the stem carries the date.

**3. A delimiter-less post errors into a masked pipe.** With no delimiter, `split` produces
only `.aa`, the `$*.a[b-z]*` glob matches nothing, and `cat` fails. Because the stage is
`cat … | tail`, the compound reports `tail`'s status, so the `&&` chain — which exists
precisely to catch a failing step — never sees it. The build exits 0. The backlog entry
predicted the `&&` fix would make this loud; it was verified afterwards that it does not.
`&&` catches a failing *step*, never a failing stage of a pipe, and `pipefail` is not POSIX
`sh`.

## Goal

Remove `split` and the globs from the staging step. All three defects are consequences of
splitting into an unknown number of unpredictably-named files; a mechanism that writes two
exactly-named files has none of them.

## Approach: a fifth awk program

`SPLIT_STAGED` joins `RENDER_POST`, `RENDER_ITEM`, `WRAP_IN_BASE`, and `WRAP_IN_CHANNEL` as a
`define` block, `export`ed and invoked as `awk "$$SPLIT_STAGED"`. It takes the two output
paths as `-v` variables and does the split in one pass:

```
define SPLIT_STAGED
!seen && $$0 ~ /^-----------------------------------/ {
    seen = 1;
    next;
}
{
    if (seen){
        print $$0 > body;
    }else{
        print $$0 > head;
    }
}
END {
    printf "" > head;
    printf "" > body;
}
endef
```

The `END` block is load-bearing rather than decorative: awk creates a redirect's file on
first write, so a post with no body would otherwise leave no `body` file at all and the
`Markdown.pl` step would fail on a missing argument. `printf "" >` creates the file when
nothing was written and appends nothing when something was — awk holds the redirect open, so
it does not truncate.

`SPLIT_STAGED` needs its own `export` line beside the other four at `Makefile:561-564`.
Without it the recipe's `"$$SPLIT_STAGED"` expands to an empty program and awk silently
copies nothing — verified.

The recipe becomes, with the `&&` chain intact:

```
$(WORK_DIR)%.staged: posts/%.txt
	@mkdir -p $(WORK_DIR)

	@if [ -x Markdown.pl ]; \
		then \
		rm -f $(WORK_DIR)$*.head $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody && \
		awk -v head=$(WORK_DIR)$*.head -v body=$(WORK_DIR)$*.body \
			"$$SPLIT_STAGED" $< && \
		./Markdown.pl $(WORK_DIR)$*.body > $(WORK_DIR)$*.mdbody && \
		cat $(WORK_DIR)$*.head .source/splitter.txt $(WORK_DIR)$*.mdbody > $@ && \
		rm -f $(WORK_DIR)$*.head $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody; \
	fi;

	@if [ ! -x Markdown.pl ]; \
		then \
		cp $< $@; \
	fi;
```

There is no pipe left in the chain, so `&&` now covers every stage of it. Defect 3 closes as
a side effect of the mechanism change, not as a separate fix.

## What each defect's fix is

| Defect | Why it is gone |
| --- | --- |
| `az` ceiling | No chunks and no glob. One `body` file holds everything after the first delimiter, however many delimiters follow. |
| Sibling over-match | `rm -f` names three exact files. `work/x.head` and `work/x.ab.head` are distinct names, not two matches of one pattern. |
| Masked `cat` failure | No pipe in the chain; and a delimiter-less post now writes an empty `body` file rather than failing at all. |

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Mechanism | One awk pass writing two named files | Kills all three defects structurally rather than patching each. awk is already the house tool, and the program sits with the other four. |
| Delimiter-less post | Empty body, exit 0 | Matches what the verbatim branch does today, and what the Markdown branch already effectively does via the masked error. Making it fatal is a new behaviour, and doing it in one branch only would make the two disagree. Out of scope. |
| Scratch file names | `.head`, `.body`, `.mdbody` | `.body` and `.mdbody` are the existing names. `.head` replaces `.aa` and keeps the per-post namespace that `test_markdown_branch_is_parallel_safe` pins. |
| Delimiter match | Anchored `^`, prefix match | See below. |
| Re-adding the delimiter | Still `cat`s `.source/splitter.txt` | Unchanged from today, including its trailing blank line, which the backlog has already judged harmless. |

## Behaviour changes

Staged output is byte-identical to today's for every ordinary post — verified by `diff -r`
over `work/` and `build/` for a three-post corpus with multiple delimiters, trailing blanks,
and the feed on. Four kinds of post are not ordinary, and all four change. Only the first was
sought; the other three were found by running the proposed program against the current one at
the spec review, and each is listed here rather than left to be discovered during
implementation.

**1. A delimiter matched mid-line no longer splits.** `split -p` takes a basic regular
expression and matches it anywhere in the line, so `see-----------------------------------this`
split a post. `SPLIT_STAGED` anchors at `^`, which is what `PARSE_FRONT_MATTER`
(`Makefile:318-331`) has always done — that line was never a delimiter as far as the renderer
was concerned, so today's build splits at a line the renderer then treats as body text.
Anchoring makes staging and rendering agree. Both match a 35-hyphen *prefix*, not the whole
line, so a line of 40 hyphens stays a delimiter to both.

**2. A post whose delimiter is on line 1 loses a stray delimiter from its body.** Today
`split -p` leaves the delimiter inside `.aa` and the body glob then matches nothing, so the
staged file comes out `[delim, body, delim, blank]` and the page's body carries a visible
35-hyphen line. Under `SPLIT_STAGED` it is `[delim, blank, body]` and the body is clean. The
post builds at exit 0 both ways; only the output differs.

**3. An empty post file stops failing loudly.** This is the one that deserves an argument
rather than a note. Today the Markdown branch produces no `.aa` at all, the final `cat` fails,
and `.DELETE_ON_ERROR` takes the staged file away — `Error 1`. Under the new mechanism the
`END` block creates both files, the chain succeeds, and an empty page ships at exit 0.
Converting a loud failure into silent output is the failure mode this repo's documentation
treats as the cardinal sin, so it is worth being explicit about why it is accepted here: the
verbatim branch **already** does exactly this — `cp` of an empty post, exit 0, empty page,
verified — so today the two branches disagree about what an empty post means, and after the
change they agree. That is the same reasoning that settled the delimiter-less decision above,
applied to the degenerate case of it. Making an empty post fatal is a defensible feature; it
belongs to both branches at once and is out of scope here.

**4. A post with no trailing newline gains one.** awk's `print` appends it, so the staged file
differs by a byte. The rendered page is byte-identical.

## Tests

Four new tests in `tests/run.sh`, each watched failing against the current Makefile before
the fix goes in, per the house rule that a test that has never failed guards nothing.

1. **`test_many_delimiter_lines_stage_completely`** — a post with 30 delimiter lines and a
   marker after the last one, built with the identity Markdown stub. Asserts the marker
   reaches the page. Fails today: the `.ba` chunk is dropped.

2. **`test_same_date_sibling_slug_does_not_collide`** — `2026-01-01-home_x.txt` and
   `2026-01-01-home_x.ab.txt` under the identity stub. Asserts the build succeeds and each
   page carries its own body. Fails today with `cat: … No such file or directory`, exit 2.

   **The assertion must be on the first build**, and the test must not build twice or use a
   helper that retries. Verified at review: the second `make` in the same sandbox exits 0,
   because the surviving post's files are up to date and its `rm` never runs again. A test
   that builds twice cannot fail against the current code and would guard nothing.

3. **`test_post_without_delimiter_stages_cleanly`** — a post with front matter and no
   delimiter, under the identity stub. Asserts exit 0, the title in the page, and no
   `No such file` on the build output. Today the build exits 0 but the `cat` error is on
   stderr, so this fails on the noise assertion — which is the assertion that pins the
   masked-pipe defect.

4. **`test_delimiter_on_first_line_leaves_no_stray_delimiter`** — a post opening with the
   delimiter, under the identity stub. Asserts the body renders without a 35-hyphen line in
   it. Pins behaviour change 2, and fails today, which is what earns it a place: it is the
   only one of the three unsought changes that alters a page a reader would see.

Two existing tests must keep passing unchanged, and they are the reason the head `rm -f`
stays in the chain:

- `test_failed_markdown_leaves_no_stale_chunks` — its premise (a failed run leaves scratch
  behind, and the next run must not sweep it into the output) survives the mechanism change.
  With exact filenames a stale `.body` is overwritten rather than globbed in, so the test
  should pass without edits; if it does not, the fix is wrong.
- `test_markdown_branch_is_parallel_safe` — includes a stray-intermediates assertion
  (`ls work/ | grep -vE '\.(tmp|staged|rssitem)$'` is empty) that covers the new names as-is.

## Documentation updates

- **`Makefile`** — the comment block above `%.staged` (`Makefile:743-778`). Its last
  paragraph documents the masked-pipe hole, which stops being true; the paragraph about the
  head `rm -f` needs rewriting from "the reassembly collects chunks by glob" to the exact-name
  reasoning. A comment block above `SPLIT_STAGED` in the existing `#`-banner style.
- **`CLAUDE.md`** — the opening tool list drops `split` (`tail` stays: `CONFIG_NAME` and
  `CONFIG_URL` both end in `tail -1`). The build-pipeline diagram's "split + (optional)
  Markdown.pl" line. The awk-programs section becomes five programs, not four, and should say
  that `SPLIT_STAGED` shares nothing with the other four — it parses the post format the way
  `PARSE_FRONT_MATTER` does but writes files instead of accumulating strings, and factoring
  those together would couple the staging step to the renderers for no gain.
- **`tests/run.sh`** — three comment blocks describe the mechanism being deleted, and the
  tests they sit above keep passing, so nothing will flag them: `394-397` ("the reassembly
  collects chunks by glob" — that test's whole premise becomes the exact-name overwrite
  argument instead), `408` ("Inner delimiter lines make split produce three chunks"), and
  `441-443`, which names `$(WORK_DIR)$*.aa`.
- **`docs/backlog.md`** — both glob entries marked DONE, in the established
  "**DONE**, then the original finding" shape. Remaining-work item 1 struck through. The DONE
  entry should mention one upgrade wrinkle: an install whose `work/` holds `.aa`/`.ab` chunks
  from a pre-change *failed* run keeps them indefinitely, since the new `rm -f` does not name
  them and nothing globs them any more. They are inert; `make clean` clears them.

## Not changed, and deliberately so

`-v head=$(WORK_DIR)$*.head` is unquoted, so a slug containing an apostrophe breaks the
recipe. The current recipe breaks on the same post — verified, loudly, with a bash syntax
error rather than an awk one. It is a pre-existing repo-wide property of every recipe that
interpolates a stem, and quoting this one rule alone buys nothing.

## Out of scope

- Making a delimiter-less post fatal in either branch.
- The residual placeholder-expansion item, the feed self-heal, and everything else on the
  remaining-work list.
- Any change to `.source/splitter.txt`, including its trailing blank line.
