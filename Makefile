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

#
# The .tmp files are made by a pattern rule, which
# make would treat as intermediate and delete on the
# way out. Keeping them is the whole point of
# incremental builds.
#
.SECONDARY: $(TMP_FILES)

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
# Creates a formatted date from a file name.
#
date_from_filename = $(shell date $(join $(addprefix -v, $(wordlist 1, 3, $(subst -, , $(notdir $(1))))), y m d) "+%B %d, %Y")

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
# Renders one post into a fragment via
# templates/post.txt.
#
define RENDER_POST
BEGIN {
    post_output = "";
}
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
# Passed to awk through the environment, so nothing in
# a template or a post title has to survive shell
# quoting on the way in.
#
export RENDER_POST
export WRAP_IN_BASE


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
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html
	@echo "Build completed."

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
$(BUILD_DIR)%.html: $$(call tmp_for_page,$$*) $$(call post_for_page,$$*) templates/base.txt config
	@echo "Building $(@)"
	@mkdir -p $(dir $(@))

	@title=$$(sed -n 's/^title:[[:space:]]*//p' $(call post_for_page,$*) | head -1); \
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
# This builds all the .tmp files used for
# posts and for the index.tmp which is used
# by the index.html
#
$(WORK_DIR)%.tmp: posts/%.txt templates/post.txt
	@echo "Building $@"
	@mkdir -p $(WORK_DIR)

	@#
	@# Split the front matter off the body, run just the
	@# body through Markdown.pl, then put it back together.
	@# Every intermediate is named after the post so that
	@# make -j can't have two posts clobber each other.
	@#
	@if [ -x Markdown.pl ]; \
		then \
		split -p----------------------------------- $< $(WORK_DIR)$*. ; \
		cat $(WORK_DIR)$*.a[b-z]* | tail -n +2 > $(WORK_DIR)$*.body; \
		./Markdown.pl $(WORK_DIR)$*.body > $(WORK_DIR)$*.mdbody; \
		cat $(WORK_DIR)$*.aa .source/splitter.txt $(WORK_DIR)$*.mdbody > $(WORK_DIR)$*.staged; \
		rm -f $(WORK_DIR)$*.a[a-z]* $(WORK_DIR)$*.body $(WORK_DIR)$*.mdbody; \
	fi;

	@if [ ! -x Markdown.pl ]; \
		then \
		cp $< $(WORK_DIR)$*.staged; \
	fi;

	@awk -v pub_date="$(call date_from_filename, $@)" \
		-v permalink="/$(call page_for,$@).html" \
		-v category="$(call category_display,$(call category_slug,$@))" \
		-v category_url="$(call category_url,$@)" \
		"$$RENDER_POST" $(WORK_DIR)$*.staged > $@;
	@rm -f $(WORK_DIR)$*.staged
	@echo "Done";

#
# TBD
#
$(BUILD_DIR)atom.xml:
	@echo "Making atom.xml"

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
