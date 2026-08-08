#
# Default to the right shell
#
SHELL := /bin/bash

#
# Per-install platform config, written by `make setup`:
# DATE_DIALECT := bsd|gnu, chosen by probing date(1). The
# leading - suppresses the "no such file" error on a tree
# that has not been set up yet. include is processed at
# parse time, so $(DATE_DIALECT) is in scope for both the
# parse-time date check and the recipes. An unconfigured
# build fails loud in date_select below.
#
-include config.mk

#
# build/ holds only publishable output. Everything
# the build needs along the way lives in work/ so
# deploy.sh never has to filter anything out.
#
BUILD_DIR := build/
WORK_DIR := work/

#
# Prerequisites for the second expansion of the
# %.html pattern rule below.
#
.SECONDEXPANSION:

#
# Starting with posts, we have to generate
# a list of all the .tmp files we need to
# create.
#
# The list is sorted numerically on the y-m-d
# fields of the filename, so unpadded dates
# (2026-7-4) still sort correctly against padded
# ones (2026-10-01). A plain $(wildcard) sorts as
# strings and gets that wrong.
#
# := and not =, so the ls|grep|sort runs once per build
# instead of once per expansion. TMP_FILES below is built
# from it, and the %.html rule's second-expanded
# prerequisites reach tmp_for_page twice per page -- once
# directly, once through post_for_page -- so with = the
# pipeline ran O(posts) times: counted at 131 runs for a
# 60-post no-op rebuild, against 1 now. The
# lazy-expansion argument that keeps CONFIG_NAME and
# CONFIG_URL on = does not apply here: those exist because
# config may not be on disk when this file is parsed,
# whereas a missing posts/ is already handled by the
# 2>/dev/null, which yields the same empty list either
# way. Being simply expanded also removes a window where
# two expansions in one build could disagree.
#
# POST_LS is the listing itself, split out so the
# control-character check below can share it and the two
# cannot drift about which files are posts. It holds a
# shell fragment, not a command that runs: the $$ escapes
# to a single $ once, here, and the stored value is
# substituted verbatim into both $(shell) calls rather than
# rescanned. Same argument as date_args -- a check that
# answers a slightly different question than the build asks
# is the same class of defect as no check.
#
POST_LS := ls posts 2>/dev/null | grep '\.txt$$'
POST_NAMES := $(shell $(POST_LS) | sort -t- -k1,1n -k2,2n -k3,3n)
POST_FILES = $(addprefix posts/, $(POST_NAMES))
TMP_FILES = $(addprefix $(WORK_DIR), $(POST_NAMES:.txt=.tmp))
STAGED_FILES = $(addprefix $(WORK_DIR), $(POST_NAMES:.txt=.staged))
RSSITEM_FILES = $(addprefix $(WORK_DIR), $(POST_NAMES:.txt=.rssitem))

#
# The .tmp and .staged files are made by pattern rules,
# which make would treat as intermediate and delete on
# the way out. Keeping .tmp is the whole point of
# incremental builds; .staged is kept for the same
# reason, and because more than one consumer reads it.
#
# .rssitem files are deliberately NOT listed here. They
# don't need .SECONDARY -- RECENT_ITEMS names them as
# explicit prerequisites of the explicit target work/rss.tmp,
# and make only reaps files it never sees mentioned -- and
# listing them would be actively harmful: with 12 posts,
# deleting the newest should drop it from the window and
# pull the next-oldest post in as the new tenth item, which
# requires building that newly-in-window .rssitem and
# re-cat'ing rss.tmp. Marking .rssitem as .SECONDARY makes
# make tolerate that file being *missing* as long as the
# target is up to date against its prerequisites'
# prerequisites, which suppresses exactly that rebuild -- the
# feed goes stale instead of self-healing. Verified
# empirically both ways; see the design doc, and
# test_deleting_a_post_heals_the_feed in tests/run.sh,
# which was watched failing against exactly that edit.
#
.SECONDARY: $(TMP_FILES) $(STAGED_FILES)

#
# Reverses a list
#
reverse = $(if $(1),$(call reverse,$(wordlist 2,$(words $(1)),$(1)))) $(firstword $(1))

#
# It's stupid hard to get a space character
# in subst searching.
#
space = $(empty) $(empty)

#
# The posts the index links to: newest first.
# Reverse before taking the window, or you get the
# ten *oldest* posts listed newest-first.
#
RECENT_FILES = $(wordlist 1, 10, $(call reverse, $(TMP_FILES)))

#
# The items the feed carries: the same newest-ten window
# the index uses.
#
RECENT_ITEMS = $(wordlist 1, 10, $(call reverse, $(RSSITEM_FILES)))

#
# Every category that has at least one post. sort
# dedupes and orders in one call, so this needs no
# shell at all -- categories are in the filenames.
#
CATEGORY_SLUGS = $(sort $(foreach f,$(POST_NAMES),$(call category_slug,$(f))))
CATEGORY_PAGES = $(addprefix $(BUILD_DIR)category/,$(addsuffix .html,$(CATEGORY_SLUGS)))

#
# The feed, but only when config supplies a url=. With no
# absolute base there is nothing valid to emit, so the
# whole feed -- fragments included -- is simply not built.
#
FEED_PAGES = $(if $(SITE_URL),$(BUILD_DIR)rss.xml)

#
# The fragments belonging to one category, newest
# first. Reversing before filtering keeps the ordering
# the index already established.
#
tmp_files_in_category = $(foreach f,$(call reverse,$(TMP_FILES)),$(if $(filter $(1),$(call category_slug,$(f))),$(f)))

#
# The weblog name, read from the config file. Blank
# lines and # comments are ignored and the last name=
# line wins, which is what config.example promises.
#
# Lazily expanded on purpose: the config target may
# not have copied the file into place yet when this
# Makefile is parsed.
#
CONFIG_NAME = $(shell sed -n 's/^name=[[:space:]]*//p' config 2>/dev/null | sed 's/[[:space:]]*$$//' | tail -1)
BLOG_NAME = $(if $(strip $(CONFIG_NAME)),$(CONFIG_NAME),Grampa)

#
# Exported rather than interpolated into the recipes,
# so a name containing a quote, a $$ or an & can't
# break the build or the substitution.
#
export BLOG_NAME

#
# The site's absolute URL, read from the same config file.
# Read lazily for the same reason as CONFIG_NAME: the
# config target may not have copied the file into place
# yet when this Makefile is parsed.
#
# A feed needs absolute links -- a reader has no base to
# resolve against -- so this is the one thing that decides
# whether build/rss.xml exists at all. Unset means no feed
# and no error.
#
# The trailing slash is stripped so that url= with or
# without one produces the same links.
#
CONFIG_URL = $(shell sed -n 's/^url=[[:space:]]*//p' config 2>/dev/null | sed 's/[[:space:]]*$$//' | tail -1)
SITE_URL = $(patsubst %/,%,$(strip $(CONFIG_URL)))

#
# Exported rather than interpolated into recipes, for the
# same reason BLOG_NAME is: a URL containing a quote or a
# $$ can't then break the build.
#
export SITE_URL

#
# The three date fields of a post filename, as words, and
# the date(1) arguments they make. Three call sites share
# date_select: the two date formatters below and the parse-
# time date check further down. The check's whole correctness
# rests on it running the same arguments the build will, so
# this is factored rather than repeated -- a second,
# independently written copy could drift, and a check that
# answers a slightly different question than the build asks
# is the same class of defect as no check.
#
date_words = $(wordlist 1, 3, $(subst -, , $(notdir $(1))))

#
# date_select: the arguments that name that day at midnight,
# one twin per dialect, chosen by DATE_DIALECT from config.mk.
#   bsd: -v2026y -v07m -v04d -v0H -v0M -v0S
#   gnu: -d "2026-07-04 00:00:00"
# The midnight pin is folded in for both: %B %d, %Y prints no
# time, so it is output-preserving for the long form, and it
# is what rfc822 and the check need (date with only y/m/d
# keeps the current clock time). The else branch fails loud --
# date_select is expanded only while building something dated,
# never by setup's own recipe, so `make setup` still boots a
# tree that has no config.mk yet.
#
ifeq ($(DATE_DIALECT),bsd)
date_select = $(join $(addprefix -v,$(call date_words,$(1))),y m d) -v0H -v0M -v0S
else ifeq ($(DATE_DIALECT),gnu)
date_select = -d "$(subst $(space),-,$(call date_words,$(1))) 00:00:00"
else
date_select = $(error grampa: no DATE_DIALECT -- run `make setup` first)
endif

#
# Creates a formatted date from a file name.
#
date_from_filename = $(shell date $(call date_select,$(1)) "+%B %d, %Y")

#
# The same date in RFC-822, which is what RSS pubDate
# wants. Two things here are load-bearing:
#
# LC_ALL=C -- RFC 822 day and month names are literal
# English tokens, and $(shell) inherits the user's locale.
# Without it a French machine emits "jeu., 06 aout 2026",
# which is silently invalid.
#
# The midnight pin lives in date_select now (bsd's -v0H -v0M
# -v0S, gnu's literal 00:00:00): date with only y/m/d keeps
# the current clock time, so without it every build would
# stamp a different pubDate and rss.xml would look changed on
# every deploy.
#
rfc822_from_filename = $(shell LC_ALL=C date $(call date_select,$(1)) "+%a, %d %b %Y %H:%M:%S %z")

#
# Post filenames are y-m-d-<category>_<title>.txt.
# Splitting on the underscore first gives two halves:
# the date and category on the left, the title slug on
# the right. Everything else falls out of those.
#
underscore_split = $(subst _,$(space),$(notdir $(1)))
date_and_category = $(firstword $(call underscore_split,$(1)))
title_slug = $(word 2,$(call underscore_split,$(1)))
post_slug = $(basename $(call title_slug,$(1)))

#
# The category is whatever follows the three date
# fields in the left half, rejoined with hyphens so
# that multi-word categories survive.
#
dc_words = $(subst -,$(space),$(call date_and_category,$(1)))
category_slug = $(subst $(space),-,$(wordlist 4, $(words $(call dc_words,$(1))), $(call dc_words,$(1))))

#
# Display form of a category *slug*, and the page it
# links to. category_display takes a slug; the others
# take a filename.
#
category_display = $(subst -,$(space),$(1))
category_url = /category/$(call category_slug,$(1)).html

#
# Every ASCII punctuation character except the three a post
# filename actually needs: - separates the date fields and
# the category words, _ separates the date/category half
# from the title slug, and . carries the .txt extension.
#
# The set is closed by enumeration rather than by judging
# which characters look dangerous. That is the whole point:
# the glob-character bug this closes existed because [ and ]
# were not on anybody's list of scary characters. Letters,
# digits, and every non-ASCII byte are allowed, which is what
# keeps posts/2026-01-02-home_café.txt building.
#
# \# and $$ are make escapes, not part of the set. Space and
# tab cannot be elements of a make list at all -- a filename
# containing a space splits POST_NAMES into two words and
# dies on the "no category in filename" clause below, naming
# a fragment of the filename rather than the whole thing.
# Loud, if not pretty; verified.
#
BAD_CHARS := ! " \# $$ % & ' ( ) * + , / : ; < = > ? @ [ \ ] ^ ` { | } ~

#
# The forbidden characters present in a filename, or empty.
# findstring returns its needle when found, so the foreach
# collects one word per offending character.
#
bad_chars_in = $(strip $(foreach c,$(BAD_CHARS),$(findstring $(c),$(1))))

#
# Control characters, rejected before anything tries to
# make sense of the filename's shape.
#
# They are checked here and not as a clause of
# check_post_name below because they cannot be elements of
# a make list at all -- the same reason space and tab are
# absent from BAD_CHARS. A grep over the directory is the
# only way to see them.
#
# LC_ALL=C pins [[:cntrl:]] to 0x00-0x1F and 0x7F. That pin
# is by principle rather than by demonstration: all 288
# locales installed on the development machine agree with C
# here, and APFS refuses invalid UTF-8 filenames outright,
# so no undecodable byte can reach the grep on this
# platform. It has the same standing as
# rfc822_from_filename's LC_ALL=C -- both are about
# environments this machine cannot reproduce, and neither
# is guarded by a test that could fail.
#
# This re-reads the directory rather than interpolating
# $(POST_NAMES) into the shell, which is why -- unlike the
# date check below -- it has no ordering dependency in
# either direction. Verified: a post named
# ...home_a<0x01>$(>PWN).txt renders the payload literally
# and executes nothing, because := never rescans a
# function's result. $(SHELL) in a filename prints as
# $(SHELL) and not /bin/bash, which is the decisive case.
#
# That freedom is spent on putting the check FIRST. A tab
# in a filename word-splits POST_NAMES, so checked second
# it dies on check_post_name's category clause naming
# "posts/c.txt" -- a file that does not exist, for a reason
# that is not the reason. Checked first it names the whole
# file. Guarded by test_tab_in_filename_names_the_whole_file,
# which asserts both the new text and the absence of the
# old.
#
# cat -vt and not cat -v: BSD cat -v passes a tab through
# untouched, and a raw tab in the message would split the
# filename back into two make words, reintroducing the very
# fragment problem this ordering exists to fix. -t renders
# it ^I. The rendering also keeps raw control bytes off the
# terminal, at the cost of the message showing ^A for one
# byte -- which is why it says so.
#
# The one-make-word guarantee covers control characters
# alone. A filename holding both a control byte and a SPACE
# still renders with the space intact and still fragments --
# loudly, and with the control-character message, so the
# diagnosis stays right even when the naming does not.
#
# 0x0A is the one control character this cannot catch: a
# line-based grep cannot see a newline inside a filename, so
# ls prints such a name as two lines and neither matches. It
# falls through to the fragment message, exactly as a tab
# used to. Deliberately left -- closing it needs -print0 and
# a different shape of check, for one byte nobody can type
# by accident. CR is caught and renders ^M, so the residual
# is that one byte and not a category.
#
CONTROL_CHAR_NAMES := $(shell $(POST_LS) | LC_ALL=C grep '[[:cntrl:]]' | cat -vt)
CHECKED_CONTROL_CHARS := $(if $(CONTROL_CHAR_NAMES),$(error control character in filename: $(addprefix posts/,$(CONTROL_CHAR_NAMES)); shown rendered, so ^A is one byte. A post filename may contain letters, digits, and only these punctuation marks: - _ .))

#
# A malformed filename is a parse-time error, so the
# build stops before any recipe runs. Assigning with
# := forces the check to happen now; the result is
# discarded.
#
# Characters are checked before any clause tries to make
# sense of the filename's shape. Two things downstream
# depend on that having happened: the date check below
# interpolates filenames into a shell, and its year test
# maps digits onto + and would be fooled by a literal one.
#
# The control-character check above runs before this one,
# but nothing depends on that: it interpolates nothing, so
# its position is a free choice made for the sake of the tab
# message, not a requirement. The constraint that still
# matters is unchanged and is about the two checks below --
# BAD_CHARS must stay above BAD_POST_DATES.
#
# "First" means first among these clauses, not first of
# anything in the file. A filename containing a : never gets
# here at all: it reaches .SECONDARY's prerequisite list up
# at the top and make's own parser stops with "target
# pattern contains no `%'", naming neither the post nor the
# reason. Loud either way, and the one character out of the
# 29 whose error is make's rather than ours.
#
check_post_name = \
	$(if $(call bad_chars_in,$(1)),$(error posts/$(1): illegal character in filename: $(call bad_chars_in,$(1)); a post filename may contain letters, digits, and only these punctuation marks: - _ .))\
	$(if $(word 3,$(call underscore_split,$(1))),$(error posts/$(1): more than one _ in filename; expected y-m-d-category_title.txt))\
	$(if $(word 2,$(call underscore_split,$(1))),,$(error posts/$(1): no category in filename; expected y-m-d-category_title.txt))\
	$(if $(call category_slug,$(1)),,$(error posts/$(1): empty category in filename; expected y-m-d-category_title.txt))\
	$(if $(call post_slug,$(1)),,$(error posts/$(1): empty title slug in filename; expected y-m-d-category_title.txt))
CHECKED_POST_NAMES := $(foreach f,$(POST_NAMES),$(call check_post_name,$(f)))

#
# Maps every digit to a +, leaving everything else alone.
# A run of + is then both a proof that the field was all
# digits and a tally of how many there were, which is what
# YEAR_SHAPES below matches against.
#
# + and not a letter: a letter would make 20xx map to xxxx
# and match a four-character shape, clearing a year that is
# not a year at all. + cannot survive here because BAD_CHARS
# rejects it, which is a second thing the character check
# above is load-bearing for.
#
digits_to_plus = $(subst 0,+,$(subst 1,+,$(subst 2,+,$(subst 3,+,$(subst 4,+,$(subst 5,+,$(subst 6,+,$(subst 7,+,$(subst 8,+,$(subst 9,+,$(1)))))))))))

#
# Strips every digit out. Empty means the field was all
# digits -- and an empty field also strips to empty, so
# callers must establish non-emptiness separately, which
# YEAR_SHAPES does.
#
# This overlaps digits_to_plus on purpose, and the overlap
# is the point. Alone, the shape match trusts that the
# marker character cannot occur in a filename, which is true
# only because BAD_CHARS rejects +. Swap the marker for a
# letter -- an edit the comment above warns against and a
# reviewer's mutation actually made -- and a year like 2q26
# maps to qqqq, matches a four-character shape, and is
# cleared without date ever seeing it. That mutation
# survived all 34 tests, because it can only be reached by a
# filename containing the new marker, and any letter is
# legal, so no fixed test name pins it.
#
# Checking the digits directly makes the marker's identity
# irrelevant to correctness rather than load-bearing, which
# is worth ten substitutions.
#
strip_digits = $(subst 0,,$(subst 1,,$(subst 2,,$(subst 3,,$(subst 4,,$(subst 5,,$(subst 6,,$(subst 7,,$(subst 8,,$(subst 9,,$(1)))))))))))

#
# A year of one to five digits. The upper bound is not
# decoration: date -v accepts enormous years and then stops,
# so "all digits" alone would clear 999999999999-01-02,
# never send it to date, and publish
# /999999999999/01/02/x.html with an empty posted-on line --
# exactly the silently wrong output this check exists to
# stop, reintroduced by the optimisation meant to make it
# cheap.
#
# Where date stops is a ceiling on the year's VALUE, not on
# its digit count: 100000000000 is accepted and
# 999999999999 is not, both twelve digits, the boundary
# being the 64-bit time_t year limit around 2.92e11. Which
# is the reason not to try to be clever here. Five digits
# keeps 99999 building without a fork; everything longer
# becomes a suspect and gets date's opinion, which is right
# either way and needs no knowledge of where the cliff is.
#
YEAR_SHAPES := + ++ +++ ++++ +++++

#
# Months 1-12 and days 1-28, padded and unpadded. 28 and not
# 31 on purpose: 28 is the largest day valid in every month
# of every year, so clearing it needs no calendar knowledge
# at all. Days 29-31 are where month lengths and leap years
# start to matter, and those go to date itself below.
#
DATE_OK_MONTHS := 1 2 3 4 5 6 7 8 9 10 11 12 01 02 03 04 05 06 07 08 09
DATE_OK_DAYS := 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 01 02 03 04 05 06 07 08 09

#
# Non-empty when make can PROVE date will accept this
# filename's date: a year of one to five digits, a month in
# 1-12, a day in 1-28. It proves rather than judges -- it
# must never clear anything date would reject, and anything
# it cannot clear is a suspect rather than a reject. Every
# bound here exists because of that invariant, not to
# describe what a sensible date looks like.
#
# The year takes two clauses rather than one: the shape
# match gives non-empty and short enough, the strip gives
# all-digits without depending on which character the shape
# match uses as its marker. See strip_digits above for why
# that separation earns its keep.
#
# The $(strip) is load-bearing: $(if) treats a whitespace-
# only expansion as true, and the \-continuations below
# would otherwise produce one.
#
date_is_sound = $(strip \
	$(if $(filter $(call digits_to_plus,$(word 1,$(call date_words,$(1)))),$(YEAR_SHAPES)),\
	$(if $(call strip_digits,$(word 1,$(call date_words,$(1)))),,\
	$(if $(filter $(word 2,$(call date_words,$(1))),$(DATE_OK_MONTHS)),\
	$(if $(filter $(word 3,$(call date_words,$(1))),$(DATE_OK_DAYS)),x)))))

#
# The names stage one could not clear, asked of date itself.
# One shell invocation however many posts there are, running
# one date call per suspect -- which in practice is only
# posts dated the 29th to the 31st. The outer $(if) skips
# even that one shell when nothing is suspect, which is the
# common case and makes "a blog dated the 1st to the 28th
# spawns nothing" true rather than nearly true.
#
# date already rejects a bad date and exits 1. Nothing in
# the build hears it: date_from_filename is a $(shell) call,
# which keeps the output and throws the status away, and
# make 3.81 has no .SHELLSTATUS. So this is not a second
# implementation of date's judgement, it is the only way to
# hear a verdict date already reaches -- at parse time,
# where a non-zero exit can still become an $(error).
#
# THIS MUST STAY BELOW CHECKED_POST_NAMES. The $(shell)
# interpolates filenames into a shell command line
# unquoted, so a post named 20xx-01-02-home_x$(>PWN).txt
# executes during the parse -- $(>PWN) is a command
# substitution whose body is a redirection, so it creates
# the file. Verified: with the character check above, the
# $(error) fires first and nothing runs; with the two
# swapped, the payload runs and is consumed by the shell,
# so even the resulting error message looks clean. Both are
# := , so this is a guarantee about textual order in this
# file and nothing else.
#
# It takes a FAILING date to get there -- the payload rides
# in on the `|| echo $(n)` branch -- which narrows the
# hazard without closing it, since a bad date is exactly
# what this check is looking for.
#
# The trailing `true` is for intent, not correctness --
# nothing reads this $(shell)'s exit status.
#
SUSPECT_POST_DATES := $(foreach n,$(POST_NAMES),$(if $(call date_is_sound,$(n)),,$(n)))
#
# Gated on DATE_DIALECT so it does not run -- and so does not
# expand date_select -- on an unconfigured tree. Without the
# gate, this := line expands date_select's $(error) at parse
# time on a month-end post during `make setup` itself, before
# the recipe can write config.mk: a deadlock. Gated, an
# unconfigured build fails loud one step later, at recipe time
# via date_from_filename, with the same message. When a
# dialect IS set the check runs exactly as before -- the gate
# skips validation, it does not weaken it.
#
BAD_POST_DATES := $(if $(DATE_DIALECT),$(if $(SUSPECT_POST_DATES),$(shell $(foreach n,$(SUSPECT_POST_DATES),LC_ALL=C date $(call date_select,$(n)) >/dev/null 2>&1 || echo $(n);) true)))
CHECKED_POST_DATES := $(if $(BAD_POST_DATES),$(error no such calendar date in: $(addprefix posts/,$(BAD_POST_DATES)); a post filename must begin with a real y-m-d date))

#
# Never leave a half-written target behind for the next
# build to trust.
#
.DELETE_ON_ERROR:

#
# Makes a y/m/d/ for a .tmp file.
#
path_from_filename = $(subst $(space),/,$(wordlist 1, 3, $(subst -,$(space), $(notdir $(1)))))

#
# The page a post builds to, without build/ or the
# .html extension. The category is deliberately absent
# -- it lives in the source filename but never in a
# URL, so permalinks did not change when categories
# moved into filenames.
#
page_for = $(call path_from_filename,$(1))/$(call post_slug,$(1))

#
# Two posts in different categories can still want the same
# page: the category is not in the URL, so
# 2026-08-06-home_dup.txt and 2026-08-06-work_dup.txt both
# claim build/2026/08/06/dup.html. One of them would win by
# nothing better than filename sort order, and the loser's
# fragment would still be linked from the index and from its
# category page. That was impossible while the filename *was*
# the URL, so it is caught here instead: a parse-time error
# naming both files, before any recipe runs.
#
# sort dedupes, so a shorter deduped list is proof that some
# page is claimed twice -- cheap enough to check on every
# build. Only when it is do we walk the list to find which
# page, and which files.
#
# This lives below page_for rather than beside
# check_post_name because CHECKED_POST_NAMES is an immediate
# assignment and page_for is not defined yet up there.
#
POST_PAGES := $(foreach f,$(POST_NAMES),$(call page_for,$(f)))
files_for_page = $(strip $(foreach f,$(POST_NAMES),$(if $(filter $(1),$(call page_for,$(f))),posts/$(f))))
check_page_collisions = \
	$(foreach p,$(sort $(POST_PAGES)),\
		$(if $(word 2,$(filter $(p),$(POST_PAGES))),\
			$(error two posts build the same page /$(p).html: $(call files_for_page,$(p)); the category is not part of a URL, so rename one of them)))
CHECKED_POST_PAGES := $(if $(filter-out $(words $(POST_PAGES)),$(words $(sort $(POST_PAGES)))),$(call check_page_collisions))

#
# Because the category is in the filename but not the
# URL, a page cannot be mapped back to its fragment by
# turning slashes into hyphens. Search instead.
#
# O(posts) per target, so O(posts squared) per build.
# Fine at blog scale; if it ever drags, generate
# explicit per-post rules with foreach and eval.
#
tmp_for_page = $(strip $(foreach f,$(TMP_FILES),$(if $(filter $(1),$(call page_for,$(f))),$(f))))
post_for_page = $(patsubst $(WORK_DIR)%.tmp,posts/%.txt,$(call tmp_for_page,$(1)))

#
# Generates all the post.html files that
# need to be built.
#
html_post_files = $(foreach f,$(TMP_FILES),$(call page_for,$(f)).html)

#
# Replaces the first {{key}} on a line. Every template
# substitution goes through this rather than awk's
# sub(), because sub() treats & in the replacement as
# "the matched text" -- a post titled "Tom & Jerry"
# came out as "Tom {{title}} Jerry".
#
define FILL_FN
function fill(line, key, value,    marker, at) {
    marker = "{{" key "}}";
    at = index(line, marker);
    if (at == 0) return line;
    return substr(line, 1, at - 1) value substr(line, at + length(marker));
}
endef

#
# The front-matter parse shared by RENDER_POST and
# RENDER_ITEM. Both read the same post format -- a title
# line, the delimiter, then a body -- and this is the one
# place that format is defined. Only the rendering and
# escaping differ between the two, which is why those stay
# separate programs while this is interpolated into both,
# the same way $(FILL_FN) is.
#
define PARSE_FRONT_MATTER
{
    if (!seen){
        if ($$0 ~ /^-----------------------------------/){
            seen = 1;
        }else if ($$0 ~ /^title:/){
            title = $$0;
            sub(/^title:[ \t]*/, "", title);
        }
    }else{
        body = (body == "" ? $$0 : body "\n" $$0);
    }
}
endef

#
# XML-escapes a value on its way into the feed. HTML pages
# must not escape bodies and the feed must, so this is
# deliberately not wired into fill().
#
# & has to go first, or < becomes &lt; and the next pass
# turns it into &amp;lt;.
#
# The replacements are written "\\&amp;" and not "&amp;"
# because gsub, like sub, expands a bare & in the
# replacement to the matched text -- the same trap that
# made fill() necessary. On the first line that would come
# out right by accident; on the other two the matched text
# is < or >, so a bare & yields "<lt;" and "<gt;".
#
define XML_ESCAPE_FN
function xml_escape(s) {
    gsub(/&/, "\\&amp;", s);
    gsub(/</, "\\&lt;", s);
    gsub(/>/, "\\&gt;", s);
    return s;
}
endef

#
# Renders one post into a fragment via
# templates/post.txt.
#
# The template read is guarded with > 0, and the -1 case
# is reported and exits 1. getline returns -1 on a file it
# cannot open, and -1 is truthy, so an unguarded loop spins
# forever instead of erroring -- this one also appends the
# stale $$0 every pass, so it eats memory while it spins.
#
# A missing template never reaches this: it is a
# prerequisite of every rule that runs this program, so awk
# is not invoked at all. (Not the same as "make errors" --
# for the two templates named only in pattern rules, make
# 3.81 can quietly reuse a stale fragment instead. See the
# deleted-template bullet in docs/backlog.md.) A template
# that is present but *unreadable* -- chmod 000, or a
# cp/rsync that dropped the mode -- does reach it, because
# the prerequisite is satisfied.
#
# Exiting 1 rather than printing an empty fragment matters:
# it lets .DELETE_ON_ERROR take the half-written file away.
# A guard that merely stopped the loop would turn the hang
# into a clean exit 0 and a fully rendered, empty page --
# the same silently-deployable wrong output the .staged
# recipe's && chain exists to prevent.
#
# The fill order below is load-bearing, and it is the same
# ordering rule in all four programs. fill() rescans the
# line it just composed, so anything substituted early is
# itself searched for the placeholders substituted after
# it. Author-supplied text therefore goes in LAST: the
# derived values (pub_date, permalink, category_url,
# category) first, then title, then body. Before this, a
# post whose body mentioned {{permalink}} -- a post about
# grampa's own template syntax, on a blog whose README
# invites people to read the Makefile -- published the real
# URL in place of the example.
#
# What this does NOT close: whatever is filled last is
# still injectable into everything filled before it. The
# leak needs no template line carrying both markers --
# every fill() runs on every line, so the title fill puts
# {{body}} into the <h4> line and the body fill consumes it
# there. Verified against the stock post.txt, where
# {{title}} and {{body}} are on different lines: a post
# titled `On {{body}} markers` renders
# <h4>On <p>the whole body</p> markers</h4>.
#
# Siblings, same class, all reproduced: a title containing
# {{main}} puts the entire rendered fragment in the page's
# <title>; the title/{{body}} leak fires in the feed too,
# via RENDER_ITEM; and a url= containing {{title}} puts the
# post title inside every *item's* <link> and <guid>. Not
# the channel <link>: WRAP_IN_CHANNEL fills link first, so
# that one takes the blog name instead.
#
# Closing these needs a single-pass fill that never rescans
# a substituted value -- a real change to fill()'s signature
# and to all four call sites, and it would also drop the
# documented "first {{key}} on a line only" behaviour.
# Deferred: the body is the large author-controlled blob and
# the realistic case, and it is now closed. Guarded by the
# four test_placeholders_* tests.
#
define RENDER_POST
BEGIN {
    post_output = "";
}
$(PARSE_FRONT_MATTER)
END {
    while ((rc = (getline line < "templates/post.txt")) > 0){
        new_line = fill(line, "pub_date", pub_date);
        new_line = fill(new_line, "permalink", permalink);
        new_line = fill(new_line, "category_url", category_url);
        new_line = fill(new_line, "category", category);
        new_line = fill(new_line, "title", title);
        new_line = fill(new_line, "body", body);
        post_output = post_output new_line "\n";
    }
    if (rc < 0){
        print "grampa: cannot read templates/post.txt" > "/dev/stderr";
        exit 1;
    }
    print post_output;
}
$(FILL_FN)
endef

#
# Renders one post into an RSS <item> via
# templates/rss-item.txt. Shares its front-matter parse
# with RENDER_POST via PARSE_FRONT_MATTER -- the parse is
# the same, but the escaping policy differs between the
# two, and a general renderer with an escape flag is the
# wrong abstraction to reach for from one example, so
# rendering stays a separate program.
#
# The template read is guarded and the -1 case exits 1,
# for the reasons spelled out above RENDER_POST.
#
define RENDER_ITEM
BEGIN {
    item_output = "";
}
$(PARSE_FRONT_MATTER)
END {
    link = ENVIRON["SITE_URL"] item_path;
    while ((rc = (getline line < "templates/rss-item.txt")) > 0){
        new_line = fill(line, "link", xml_escape(link));
        new_line = fill(new_line, "pub_date", pub_date);
        new_line = fill(new_line, "category", xml_escape(category));
        new_line = fill(new_line, "title", xml_escape(title));
        new_line = fill(new_line, "body", xml_escape(body));
        item_output = item_output new_line "\n";
    }
    if (rc < 0){
        print "grampa: cannot read templates/rss-item.txt" > "/dev/stderr";
        exit 1;
    }
    print item_output;
}
$(FILL_FN)
$(XML_ESCAPE_FN)
endef

#
# Wraps a rendered fragment in templates/base.txt.
# Both the post pages and the index use this; the only
# thing that differs is $$PAGE_TITLE, which each recipe
# puts in the environment.
#
# The template read is guarded and the -1 case exits 1,
# for the reasons spelled out above RENDER_POST.
#
define WRAP_IN_BASE
BEGIN {
    html_output = "";
    main_output = "";
    new_line = "";
}
{
    main_output = main_output $$0 "\n"
}
END {
    while ((rc = (getline line < "templates/base.txt")) > 0){
        new_line = fill(line, "page_title", ENVIRON["PAGE_TITLE"]);
        new_line = fill(new_line, "main", main_output);
        html_output = html_output new_line "\n";
    }
    if (rc < 0){
        print "grampa: cannot read templates/base.txt" > "/dev/stderr";
        exit 1;
    }
    print html_output;
}
$(FILL_FN)
endef

#
# Wraps the concatenated items in templates/rss.txt. The
# structural twin of WRAP_IN_BASE, kept separate because
# base.txt must not escape its page title and rss.txt must
# -- sharing one program would mean an escape flag inside
# a general renderer, which is the abstraction this design
# defers until there is more than one example to draw it
# from.
#
# {{items}} is not escaped: those are already-escaped XML.
#
# The template read is guarded and the -1 case exits 1,
# for the reasons spelled out above RENDER_POST.
#
define WRAP_IN_CHANNEL
BEGIN {
    xml_output = "";
    items_output = "";
}
{
    items_output = items_output $$0 "\n";
}
END {
    while ((rc = (getline line < "templates/rss.txt")) > 0){
        new_line = fill(line, "link", xml_escape(ENVIRON["SITE_URL"]));
        new_line = fill(new_line, "title", xml_escape(ENVIRON["BLOG_NAME"]));
        new_line = fill(new_line, "description", xml_escape(ENVIRON["BLOG_NAME"]));
        new_line = fill(new_line, "items", items_output);
        xml_output = xml_output new_line "\n";
    }
    if (rc < 0){
        print "grampa: cannot read templates/rss.txt" > "/dev/stderr";
        exit 1;
    }
    print xml_output;
}
$(FILL_FN)
$(XML_ESCAPE_FN)
endef

#
# Splits a post into its front matter and its body, one
# file each, for the staging step below. This is the only
# awk program here that writes files rather than stdout,
# because Markdown.pl has to be handed the body alone and
# the pieces glued back together afterwards.
#
# It shares nothing with PARSE_FRONT_MATTER even though the
# two recognise the same delimiter: that one accumulates a
# title and a body into variables for a renderer, this one
# routes lines to two files and keeps no state but `seen`.
# Factoring them together would couple the staging step to
# the renderers to save one regex.
#
# Only the FIRST delimiter splits. Later ones are body text
# -- a post about grampa's own post format has them -- which
# is what the !seen guard is for.
#
# The END block is load-bearing, and in both directions.
# awk creates a redirect's file on first write, so a post
# with no body would leave no body file at all and
# Markdown.pl would be handed a missing argument, while a
# post whose delimiter is on line 1 would leave no head file
# and the reassembly cat would fail on it. Both were
# confirmed by deleting this block: exit 2 either way.
# printf "" creates the file when nothing was
# written and appends nothing when something was, since awk
# holds the redirect open -- so it cannot truncate what came
# before it.
#
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

#
# Passed to awk through the environment, so nothing in
# a template or a post title has to survive shell
# quoting on the way in.
#
export RENDER_POST
export RENDER_ITEM
export WRAP_IN_BASE
export WRAP_IN_CHANNEL
export SPLIT_STAGED


#
# Default build. Ensure the config file is
# there and then start building.
#
# This does not clean first, so a rebuild only
# touches the posts that actually changed.
#
# Phony for hygiene rather than for a live bug: a file
# named `all` does not currently break this, because the
# prerequisite `build` is itself phony and so always out
# of date, which drags `all` along with it. Declaring it
# means that keeps working if build ever stops being
# phony. Guarded by
# test_default_build_works_with_a_file_named_all, which
# passes both with and without this line today.
#
.PHONY: all
all: config build
	@echo "All done."

#
# Both generated directories get wiped.
#
# Phony because this one does break: `clean` names nothing
# on disk, so a file that happens to be called `clean` --
# one stray shell redirect -- makes the target up to date
# and make runs no recipe at all. It prints
# `'clean' is up to date` and wipes nothing, which reads
# exactly like success. Guarded by
# test_clean_works_with_a_file_named_clean.
#
.PHONY: clean
clean:
	@echo "Cleaning";
	@rm -rf $(BUILD_DIR) $(WORK_DIR);

#
# The only phony rule that builds all the index files
#
# templates/post.txt and templates/rss-item.txt are listed
# here even though nothing in this rule reads them, and
# that is load-bearing. They are otherwise named only in
# the %.tmp and %.rssitem *pattern* rules, and make 3.81
# does not consider a pattern rule's missing prerequisite
# a file that ought to exist -- it just drops the rule
# from consideration. Delete either template and the
# matching rule becomes inapplicable, the stale fragment
# sitting in work/ is taken as-is with no dependency
# check, and the build exits 0 serving the old body.
#
# templates/base.txt and templates/rss.txt never had this
# problem, because they are prerequisites of the explicit
# build/index.html and build/rss.xml rules. Naming these
# two here gives them the same standing, so a deleted
# template stops the build with
#
#   No rule to make target 'templates/post.txt'
#
# This is unconditional, so rss-item.txt has to exist even
# with url= unset and no feed being built. That is a real
# asymmetry with rss.txt, which is only required when the
# feed is on. Gating it on SITE_URL is the wrong cure: a
# prerequisite list is expanded during the initial parse,
# which is the same one-build-late trap FEED_PAGES already
# has. A template make setup always installs is cheap to
# require.
#
# Guarded by tests/run.sh's two deleted-template tests.
#
.PHONY: build
build: templates/post.txt templates/rss-item.txt
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html $(CATEGORY_PAGES) $(FEED_PAGES)
	@if [ -z "$$SITE_URL" ]; then echo "No url= in config; skipping rss.xml. A previously built build/rss.xml, if any, is left in place."; fi
	@echo "Build completed."

#
# One archive page per category, every post in it,
# newest first. Prerequisites are exact -- only the
# fragments in this category -- because make knows the
# categories at parse time.
#
# Two pattern rules match build/category/notes.html:
# this one and the %.html rule below. On GNU make 3.81,
# when a target's prerequisites are satisfiable under
# more than one pattern rule, make uses the first such
# rule in the order it appears in the makefile -- NOT
# the shortest stem, despite what the manual implies.
#
# Both are satisfiable here: tmp_for_page returns empty
# for a category stem, since no single fragment maps to a
# category page, and an empty prerequisite list is
# trivially satisfiable. So a %.html rule defined first
# would claim build/category/notes.html.
#
# That used to mean a wrong page and no error -- a
# base.txt document nested inside another one, titled
# with the blog name instead of the category. It no
# longer does: the unknown-page guard in that rule sees
# an empty tmp_for_page and stops with
#
#   build/category/notes.html: no post in posts/ builds this page
#
# So the ordering constraint is still real -- category
# pages will not build in the wrong order -- but the
# failure is loud rather than silent. Verified
# empirically in both orders. Keep this rule above the
# %.html rule below it.
#
$(BUILD_DIR)category/%.html: $$(call tmp_files_in_category,$$*) templates/base.txt config
	@echo "Building $@"
	@mkdir -p $(dir $@)
	@PAGE_TITLE="$(call category_display,$*) - $$BLOG_NAME" \
		awk "$$WRAP_IN_BASE" $(call tmp_files_in_category,$*) > $@;

#
# This builds almost everything. The stem of a target
# like build/2026/08/06/a-post.html is the y/m/d/name
# path, and tmp_for_page searches TMP_FILES for the one
# fragment that path came from.
#
# It is a search and not a substitution because the
# category lives in the filename but not in the URL:
# nothing in the stem 2026/08/06/a-post says the fragment
# is work/2026-08-06-home_a-post.tmp. Turning the slashes
# back into hyphens did name it, before categories moved
# into filenames.
#
# The post's own title comes from its front matter --
# the .tmp fragment has already baked it into HTML --
# so the source post is a prerequisite too. It is
# already an indirect one via the .tmp file, so this
# costs no extra rebuilds.
#
# A stem no post maps to -- a typo'd target on the command
# line -- leaves tmp_for_page empty, which makes the
# prerequisite list satisfiable anyway (see the note above)
# and would otherwise wrap templates/base.txt in itself and
# exit 0. Say so and stop instead. sed keeps a /dev/null
# operand for the same reason cat has one below: with no file
# to read it would sit on stdin.
#
# The sed quits at the delimiter, the way
# tools/migrate-categories.sh does for category:. Without
# that it reads title: from anywhere in the file, so a post
# with no front-matter title but a body line beginning
# title: -- a post about this very format -- took that line
# as its <title> while its <h4> rendered empty.
#
$(BUILD_DIR)%.html: $$(call tmp_for_page,$$*) $$(call post_for_page,$$*) templates/base.txt config
	@if [ -z "$(call tmp_for_page,$*)" ]; \
		then \
		echo "$@: no post in posts/ builds this page" >&2; \
		exit 1; \
	fi

	@echo "Building $(@)"
	@mkdir -p $(dir $(@))

	@title=$$(sed -n '/^-----------------------------------/q; s/^title:[[:space:]]*//p' $(call post_for_page,$*) /dev/null | head -1); \
	if [ -n "$$title" ]; \
		then \
		export PAGE_TITLE="$$title - $$BLOG_NAME"; \
	else \
		export PAGE_TITLE="$$BLOG_NAME"; \
	fi; \
	awk "$$WRAP_IN_BASE" $< > $@;

#
# If just building the index. cat needs /dev/null in
# case there are no posts yet, or it would sit and
# read stdin.
#
$(WORK_DIR)index.tmp: $(RECENT_FILES)
	@mkdir -p $(WORK_DIR)
	@cat /dev/null $(RECENT_FILES) > $@

#
# The staging step: split the front matter off the body,
# run just the body through Markdown.pl, then put it back
# together. Every intermediate is named after the post so
# that make -j can't have two posts clobber each other.
#
# This is a target of its own rather than part of %.tmp
# below because the RSS items need the same rendered body
# *and* the post's individual fields -- title, body, date
# -- which the .tmp fragment has already dissolved into
# HTML. Kept by .SECONDARY, so Markdown.pl runs once per
# post rather than once per consumer.
#
# The steps below are chained with && rather than ;, and
# that is load-bearing. With ; the compound's exit status
# is the last command's -- rm -f, which essentially always
# succeeds -- so a failing Markdown.pl was invisible: make
# exited 0, .DELETE_ON_ERROR never fired, and a .staged
# file holding front matter and nothing else was trusted
# by every downstream consumer, publishing a fully
# rendered page with an empty body. Do not relax these
# back to ; -- tests/run.sh's failing-stub test guards it.
#
# There is no pipe anywhere in the chain, and there should
# not be one: && reports a failing step but never a failing
# stage of a pipe, so `a | b` hides a's failure behind b's
# status. That is exactly how a delimiter-less post used to
# fail silently, back when the body was reassembled with
# `cat chunks | tail -n +2`.
#
# Every scratch name is an exact filename, never a glob. It
# used to be `split -p` plus $*.a[b-z]*, which was wrong
# twice: the glob stopped at .az, so a body with more than
# 25 delimiter lines was silently truncated, and $*.a[a-z]*
# reached onto a same-date sibling's outputs -- stem
# ...home_x matching ...home_x.ab.staged -- and deleted them
# mid-build.
#
# The rm at the *head* of the chain is hygiene now rather
# than correctness, which is a demotion. Under the old glob
# it was load-bearing: a failed run left chunks behind and
# the reassembly globbed up whatever it found, so a post
# that later split into fewer chunks swept the stale ones
# back in. Exact filenames cannot do that. All three are
# truncated before they are read -- awk's `print >`
# truncates on first write, the END block's printf truncates
# even when nothing else is written, and the shell's `>`
# truncates .mdbody before Markdown.pl starts -- so no stale
# byte survives into $@. Verified by neutering this rm: the
# failing-stub test and the parallel test both still pass.
# It stays because a persistently failing install should not
# accumulate scratch, and because that truncation argument
# holds only as long as nothing in the chain is reordered.
#
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

#
# This builds all the .tmp files used for
# posts and for the index.tmp which is used
# by the index.html
#
$(WORK_DIR)%.tmp: $(WORK_DIR)%.staged templates/post.txt
	@echo "Building $@"
	@mkdir -p $(WORK_DIR)

	@awk -v pub_date="$(call date_from_filename, $@)" \
		-v permalink="/$(call page_for,$@).html" \
		-v category="$(call category_display,$(call category_slug,$@))" \
		-v category_url="$(call category_url,$@)" \
		"$$RENDER_POST" $< > $@;
	@echo "Done";

#
# One RSS <item> per post, built from the same staged file
# as the .tmp fragment.
#
# config is a prerequisite because the item bakes the
# absolute URL in, so changing url= has to rebuild every
# item -- the same reason config is a prerequisite of both
# HTML rules.
#
$(WORK_DIR)%.rssitem: $(WORK_DIR)%.staged templates/rss-item.txt config
	@echo "Building $@"
	@mkdir -p $(WORK_DIR)

	@awk -v pub_date="$(call rfc822_from_filename, $@)" \
		-v item_path="/$(call page_for,$@).html" \
		-v category="$(call category_display,$(call category_slug,$@))" \
		"$$RENDER_ITEM" $< > $@;
	@echo "Done";

#
# The feed's items, concatenated. cat needs /dev/null in
# case there are no posts yet, or it would sit and read
# stdin -- the same reason index.tmp's does.
#
$(WORK_DIR)rss.tmp: $(RECENT_ITEMS)
	@mkdir -p $(WORK_DIR)
	@cat /dev/null $(RECENT_ITEMS) > $@

#
# Building rss.xml requires work/rss.tmp, exactly as
# index.html requires work/index.tmp.
#
$(BUILD_DIR)rss.xml: $(WORK_DIR)rss.tmp templates/rss.txt config
	@echo "Building rss.xml"
	@mkdir -p $(dir $@)
	@awk "$$WRAP_IN_CHANNEL" $< > $@;

#
# Building the index.html file requires
# the work/index.tmp file to be built.
#
$(BUILD_DIR)index.html: $(WORK_DIR)index.tmp templates/base.txt config
	@echo "Building index.html"
	@mkdir -p $(dir $@)
	@PAGE_TITLE="$$BLOG_NAME" awk "$$WRAP_IN_BASE" $< > $@;

config:
	@yes n | cp -i .source/config.example config

#
# config.mk is generated, not copied: setup probes date(1)
# and always (re)writes it, the one deliberate exception to
# the non-clobbering cp -i above, because it is derived from
# the machine rather than authored. Re-running setup is what
# re-fixes the dialect if a checkout ever moves between OSes.
#
.PHONY: setup
setup: config
	@mkdir -p $(BUILD_DIR);
	@mkdir -p $(WORK_DIR);
	@mkdir -p posts;
	@mkdir -p templates;
	-@yes n | cp -i .source/templates/* templates/ 2>/dev/null
	-@yes n | cp -i .source/deploy.sh.example deploy.sh 2>/dev/null
	@if date -v1d >/dev/null 2>&1; then dialect=bsd; \
	elif date -d 2026-01-15 >/dev/null 2>&1; then dialect=gnu; \
	else echo "grampa: no supported date dialect (need BSD 'date -v' or GNU 'date -d')" >&2; exit 1; fi; \
	echo "DATE_DIALECT := $$dialect" > config.mk; \
	echo "Configured date dialect: $$dialect"

#
# deploy: all, and not a bare deploy, because
# make clean && make deploy handed deploy.sh an empty
# build/ at exit 0 with no warning -- and deploy.sh is
# user-supplied, with an rsync in the example. A --delete
# in it makes that sequence unpublish the site. The cost is
# one incremental no-op build, which is quiet and measured
# in tenths of a second.
#
# It builds first; it does not set up first. A directory
# where make setup has never run still fails on the missing
# templates, which is unchanged and correct. Where deploy
# does now create config is the narrower case of setup
# having been run and config deleted afterwards -- not a
# fresh install, which has one already, since setup: config.
#
# What being a non-leaf target does and does not change,
# because the obvious guess is wrong. A page you DELETED
# from build/ is regenerated before shipping, and a page
# whose source is newer is rebuilt. A page you hand-EDITED
# is not: your edit made it newer than its prerequisites, so
# make considers it up to date and deploy ships the edit.
# Make cannot tell an edit from a build. So ./deploy.sh
# build/ and make deploy send the same bytes in that case,
# and build/ is no safer a scratchpad than it was.
#
# A failing build now stops the ship, which is the change
# with the most teeth. It sounds like a loss -- the old
# form would have shipped the last good build/ -- but that
# last good build/ is largely a myth: .DELETE_ON_ERROR
# removes a half-written page, so a build that fails partway
# leaves a site with a page MISSING, and the old deploy
# shipped exactly that at exit 0. Verified. Refusing is
# strictly better.
#
# Guarded by test_deploy_builds_first.
#
.PHONY: deploy
deploy: all
	@./deploy.sh $(BUILD_DIR)

#
# Runs the test suite in tests/tmp sandboxes. Never
# touches your real posts/ or build/.
#
.PHONY: test
test:
	@./tests/run.sh
