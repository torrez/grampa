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
# Creates a formatted date from a file name.
#
date_from_filename = $(shell date $(join $(addprefix -v, $(wordlist 1, 3, $(subst -, , $(notdir $(1))))), y m d) "+%B %d, %Y")

#
# Takes a filepath of a (tmp,txt,html) file
# and returns just the file name. Date info
# stripped.
#
post_filename = $(subst $(space),-,$(wordlist 4, $(words $(subst -,$(space), $(notdir $(1)))), $(subst -,$(space), $(notdir $(1)))))
html_post_filename = $(call post_filename, $(1:.tmp=.html))

#
# Makes a y/m/d/ for a .tmp file.
#
path_from_filename = $(subst $(space),/,$(wordlist 1, 3, $(subst -,$(space), $(notdir $(1)))))

#
# Generates all the post.html files that
# need to be built.
#
html_post_files = $(foreach f,$(TMP_FILES),$(call path_from_filename, $(f))/$(call post_filename, $(f:.tmp=.html)))


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
$(BUILD_DIR)%.html: $(WORK_DIR)$$(subst /,-,$$*).tmp templates/base.txt
	@echo "Building $(@)"
	@mkdir -p $(dir $(@))

	@awk 'BEGIN {\
		html_output = "";\
		post_output = "";\
		new_line = "";\
	}\
	{\
		post_output = post_output $$0 "\n"\
	}\
	END {\
		while (getline < "templates/base.txt"){\
			new_line = $$0;\
			sub(/\{\{main\}\}/, post_output, new_line);\
			sub(/\{\{page_title\}\}/, "Dungeon", new_line);\
			html_output = html_output new_line "\n";\
		}\
		print html_output;\
	}\
	' $< > $@;

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

	@awk -v pub_date="$(call date_from_filename, $@)" -v permalink="/$(call path_from_filename, $@)/$(call html_post_filename, $@)" 'BEGIN {\
		post_output = "";\
	}\
	{\
		if (!seen){\
			if ($$0 ~ /^-----------------------------------/){\
				seen = 1;\
			}else if ($$0 ~ /^title:/){\
				title = $$0;\
				sub(/^title:[ \t]*/, "", title);\
			}else if ($$0 ~ /^category:/){\
				category = $$0;\
				sub(/^category:[ \t]*/, "", category);\
			}\
		}else{\
			body = (body == "" ? $$0 : body "\n" $$0);\
		}\
	}\
	END {\
		while (getline < "templates/post.txt"){\
			sub(/\{\{title\}\}/, title, $$0);\
			sub(/\{\{body\}\}/, body, $$0);\
			sub(/\{\{pub_date\}\}/, pub_date, $$0);\
			sub(/\{\{permalink\}\}/, permalink, $$0);\
			sub(/\{\{category\}\}/, category, $$0);\
			post_output = post_output $$0 "\n";\
		}\
		print post_output;\
	}\
	' $(WORK_DIR)$*.staged > $@;
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
$(BUILD_DIR)index.html: $(WORK_DIR)index.tmp templates/base.txt
	@echo "Building index.html"
	@mkdir -p $(dir $@)
	@awk 'BEGIN {\
		html_output = "";\
		index_output = "";\
		new_line = "";\
	}\
	{\
		index_output = index_output $$0 "\n"\
	}\
	END {\
		while (getline < "templates/base.txt"){\
			new_line = $$0;\
			sub(/\{\{main\}\}/, index_output, new_line);\
			sub(/\{\{page_title\}\}/, "Grampa", new_line);\
			html_output = html_output new_line "\n";\
		}\
		print html_output;\
	}\
	' $< > $@;

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
