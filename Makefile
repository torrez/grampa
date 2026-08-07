#
# Default to the right shell
#
SHELL := /bin/bash

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
POST_NAMES = $(shell ls posts 2>/dev/null | grep '\.txt$$' | sort -t- -k1,1n -k2,2n -k3,3n)
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
# Unlike .staged, the .rssitem entry is insurance rather
# than load-bearing: RECENT_ITEMS names these files as
# explicit prerequisites of the explicit target
# work/rss.tmp, and make only reaps files it never sees
# mentioned. Removing it from .SECONDARY changes nothing
# observable today -- verified. It is kept so that a later
# change to how rss.tmp collects its inputs can't silently
# reintroduce a full feed rebuild.
#
.SECONDARY: $(TMP_FILES) $(STAGED_FILES) $(RSSITEM_FILES)

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
# Creates a formatted date from a file name.
#
date_from_filename = $(shell date $(join $(addprefix -v, $(wordlist 1, 3, $(subst -, , $(notdir $(1))))), y m d) "+%B %d, %Y")

#
# The same date in RFC-822, which is what RSS pubDate
# wants. Two things here are load-bearing:
#
# LC_ALL=C -- RFC 822 day and month names are literal
# English tokens, and $(shell) inherits the user's locale.
# Without it a French machine emits "jeu., 06 aout 2026",
# which is silently invalid.
#
# -v0H -v0M -v0S -- date -v with only y/m/d keeps the
# current clock time, so without pinning to midnight every
# build would emit different pubDates and rss.xml would
# look changed on every deploy.
#
rfc822_from_filename = $(shell LC_ALL=C date $(join $(addprefix -v, $(wordlist 1, 3, $(subst -, , $(notdir $(1))))), y m d) -v0H -v0M -v0S "+%a, %d %b %Y %H:%M:%S %z")

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
# A malformed filename is a parse-time error, so the
# build stops before any recipe runs. Assigning with
# := forces the check to happen now; the result is
# discarded.
#
check_post_name = \
	$(if $(word 3,$(call underscore_split,$(1))),$(error posts/$(1): more than one _ in filename; expected y-m-d-category_title.txt))\
	$(if $(word 2,$(call underscore_split,$(1))),,$(error posts/$(1): no category in filename; expected y-m-d-category_title.txt))\
	$(if $(call category_slug,$(1)),,$(error posts/$(1): empty category in filename; expected y-m-d-category_title.txt))
CHECKED_POST_NAMES := $(foreach f,$(POST_NAMES),$(call check_post_name,$(f)))

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
define RENDER_POST
BEGIN {
    post_output = "";
}
$(PARSE_FRONT_MATTER)
END {
    while (getline < "templates/post.txt"){
        new_line = fill($$0, "title", title);
        new_line = fill(new_line, "body", body);
        new_line = fill(new_line, "pub_date", pub_date);
        new_line = fill(new_line, "permalink", permalink);
        new_line = fill(new_line, "category_url", category_url);
        new_line = fill(new_line, "category", category);
        post_output = post_output new_line "\n";
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
# The template read is guarded with > 0 because getline
# on a missing file returns -1, which is truthy, so an
# unguarded loop spins forever. Nothing in the normal
# build reaches that -- the template is a prerequisite,
# so make stops first -- but the guard costs nothing and
# the unguarded form is a trap worth not copying.
#
define RENDER_ITEM
BEGIN {
    item_output = "";
}
$(PARSE_FRONT_MATTER)
END {
    link = ENVIRON["SITE_URL"] item_path;
    while ((getline line < "templates/rss-item.txt") > 0){
        new_line = fill(line, "title", xml_escape(title));
        new_line = fill(new_line, "link", xml_escape(link));
        new_line = fill(new_line, "pub_date", pub_date);
        new_line = fill(new_line, "category", xml_escape(category));
        new_line = fill(new_line, "body", xml_escape(body));
        item_output = item_output new_line "\n";
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
    while (getline < "templates/base.txt"){
        new_line = fill($$0, "main", main_output);
        new_line = fill(new_line, "page_title", ENVIRON["PAGE_TITLE"]);
        html_output = html_output new_line "\n";
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
# The template read is guarded with > 0 for the same
# reason as RENDER_ITEM's: getline returns -1 on a missing
# file, which is truthy.
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
    while ((getline line < "templates/rss.txt") > 0){
        new_line = fill(line, "title", xml_escape(ENVIRON["BLOG_NAME"]));
        new_line = fill(new_line, "description", xml_escape(ENVIRON["BLOG_NAME"]));
        new_line = fill(new_line, "link", xml_escape(ENVIRON["SITE_URL"]));
        new_line = fill(new_line, "items", items_output);
        xml_output = xml_output new_line "\n";
    }
    print xml_output;
}
$(FILL_FN)
$(XML_ESCAPE_FN)
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


#
# Default build. Ensure the config file is
# there and then start building.
#
# This does not clean first, so a rebuild only
# touches the posts that actually changed.
#
all: config build
	@echo "All done."

#
# Both generated directories get wiped.
#
clean:
	@echo "Cleaning";
	@rm -rf $(BUILD_DIR) $(WORK_DIR);

#
# The only phony rule that builds all the index files
#
.PHONY: build
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html $(CATEGORY_PAGES) $(FEED_PAGES)
	@if [ -z "$$SITE_URL" ]; then echo "No url= in config; skipping rss.xml."; fi
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
# would claim build/category/notes.html and build it out
# of templates/base.txt -- a base.txt document nested
# inside another one, titled with the blog name instead
# of the category. No error, just a wrong page.
#
# Verified empirically in both orders. Reordering these
# two rules breaks the build silently, so this rule must
# stay above the %.html rule below it.
#
$(BUILD_DIR)category/%.html: $$(call tmp_files_in_category,$$*) templates/base.txt config
	@echo "Building $@"
	@mkdir -p $(dir $@)
	@PAGE_TITLE="$(call category_display,$*) - $$BLOG_NAME" \
		awk "$$WRAP_IN_BASE" $(call tmp_files_in_category,$*) > $@;

#
# This builds almost everything. The stem of a target
# like build/2026/08/06/a-post.html is the y/m/d/name
# path, so turning the slashes back into hyphens names
# the one .tmp file this page is built from.
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
$(BUILD_DIR)%.html: $$(call tmp_for_page,$$*) $$(call post_for_page,$$*) templates/base.txt config
	@if [ -z "$(call tmp_for_page,$*)" ]; \
		then \
		echo "$@: no post in posts/ builds this page" >&2; \
		exit 1; \
	fi

	@echo "Building $(@)"
	@mkdir -p $(dir $(@))

	@title=$$(sed -n 's/^title:[[:space:]]*//p' $(call post_for_page,$*) /dev/null | head -1); \
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
$(WORK_DIR)%.staged: posts/%.txt
	@mkdir -p $(WORK_DIR)

	@if [ -x Markdown.pl ]; \
		then \
		split -p----------------------------------- $< $(WORK_DIR)$*. ; \
		cat $(WORK_DIR)$*.a[b-z]* | tail -n +2 > $(WORK_DIR)$*.body; \
		./Markdown.pl $(WORK_DIR)$*.body > $(WORK_DIR)$*.mdbody; \
		cat $(WORK_DIR)$*.aa .source/splitter.txt $(WORK_DIR)$*.mdbody > $@; \
		rm -f $(WORK_DIR)$*.a[a-z]* $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody; \
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

.PHONY: setup
setup: config
	@mkdir -p $(BUILD_DIR);
	@mkdir -p $(WORK_DIR);
	@mkdir -p posts;
	@mkdir -p templates;
	-@yes n | cp -i .source/templates/* templates/ 2>/dev/null
	-@yes n | cp -i .source/deploy.sh.example deploy.sh 2>/dev/null

.PHONY: deploy
deploy:
	@./deploy.sh $(BUILD_DIR)

#
# Runs the test suite in tests/tmp sandboxes. Never
# touches your real posts/ or build/.
#
.PHONY: test
test:
	@./tests/run.sh
