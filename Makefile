#
# Default to the right shell
#
SHELL := /bin/bash
BUILD_DIR := build/

#
# Starting with posts, we have to generate
# a list of all the .tmp files we need to
# create.
#
POST_FILES = $(wildcard posts/*.txt)
TMP_FILES = $(addprefix $(BUILD_DIR),  $(notdir $(POST_FILES:.txt=.tmp)))

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
# Creates a formatted date from a file name.
#
date_from_filename = $(shell date $(join $(addprefix -v, $(wordlist 1, 3, $(subst -, , $(notdir $(1))))), y m d) "+%B %m, %Y")

#
# Takes a filepath of a (tmp,txt,html) file
# and returns just the file name. Date info
# stripped.
#
post_filename = $(subst $(space),-,$(wordlist 4, $(words $(subst -,$(space) , $(notdir $(1)))), $(subst -,$(space), $(notdir $(1)))))
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
all: clean config build
	@echo "All done."

#
# The build/ directory is the only thing that needs
# to get wiped.
#
clean:
	@echo "Cleaning";
	@rm -rf $(BUILD_DIR)*;

#
# The only phony rule that builds all the index files
#
.PHONY: build
build: $(addprefix $(BUILD_DIR),$(html_post_files)) $(BUILD_DIR)index.html
	@echo "Build completed."

#
# This builds almost everything.
#
%.html: $(TMP_FILES) $(BUILD_DIR)index.tmp $(BUILD_DIR)index.html
	@echo "Building $(@)"
	@mkdir -p $(dir $(@))

	@awk 'BEGIN {\
		html_output = "";\
		post_output = "";\
		new_line = "";\
	}\
	{\
		post_output = post_output $$0 "\r\n"\
	}\
	END {\
		while (getline < "templates/base.txt"){\
			new_line = $$0;\
			sub(/\{\{main\}\}/, post_output, new_line);\
			sub(/\{\{page_title\}\}/, "Dungeon", new_line);\
			html_output = html_output new_line "\r\n";\
		}\
		print html_output;\
	}\
	' $(addprefix $(BUILD_DIR), $(subst /,-, $(@:$(BUILD_DIR)%.html=%.tmp))) > $@;

#
# If just building the index.
#
$(BUILD_DIR)index.tmp: $(TMP_FILES)
	@cat > $(BUILD_DIR)index.tmp $(call reverse, $(wordlist 1, 10, $(TMP_FILES)))

#
# This builds all the .tmp files used for
# posts and for the index.tmp which is used
# by the index.html
#
$(BUILD_DIR)%.tmp: posts/%.txt
	@echo "Building $@"
	@echo "---"
	@echo $(call html_post_filename, $@)
	@echo "---"

	@if [ -x Markdown.pl ]; \
		then \
		split -p----------------------------------- $^ build/; \
		tail -n +2 build/ab > build/ac; \
		./Markdown.pl build/ac > build/ac.md; \
		cat build/aa .source/splitter.txt build/ac.md > build/$(notdir $^); \
		rm build/aa build/ab build/ac build/ac.md; \
	fi;

	@if [ ! -x Markdown.pl ]; \
		then \
		cp $^ build/; \
	fi;

	@awk -v pub_date="$(call date_from_filename, $@)" -v permalink="/$(call path_from_filename, $@)/$(call html_post_filename, $@)" 'BEGIN {\
		post_output = "";\
	}\
	{\
		if (!seen){\
			if($$1 ~ "-----------------------------------"){\
				seen = 1;\
			}else if($$1 ~ "title:"){\
				$$1="";\
				title = $$0;\
			}else if($$1 ~ "category:"){\
				$$1="";\
				category = $$0\
			}\
		}else{\
			body = body "\n" $$0;\
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
	' build/$(notdir $<) > $@;
	@echo "Done";

#
# TBD
#
$(BUILD_DIR)atom.xml:
	@echo "Making atom.xml"

#
# Building the index.html file requires
# the build/index.tmp file to be built.
#
$(BUILD_DIR)index.html: $(BUILD_DIR)index.tmp
	@echo "Building index.html"
	@awk 'BEGIN {\
		html_output = "";\
		index_output = "";\
		new_line = "";\
	}\
	{\
		index_output = index_output $$0\
	}\
	END {\
		while (getline < "templates/base.txt"){\
			new_line = $$0;\
			sub(/\{\{main\}\}/, index_output, new_line);\
			sub(/\{\{page_title\}\}/, "Grampa", new_line);\
			html_output = html_output new_line "\r\n";\
		}\
		print html_output;\
	}\
	' $(BUILD_DIR)index.tmp > $@;

config:
	@yes n | cp -i .source/config.example config

.PHONY: setup
setup: config
	@mkdir -p build;
	@mkdir -p posts;
	@mkdir -p templates;
	@mkdir -p scripts;
	-@yes n | cp -i .source/templates/* templates/ 2>/dev/null
	-@yes n | cp -i .source/deploy.sh.example deploy.sh 2>/dev/null

.PHONY: deploy
deploy:
	@./deploy.sh $(BUILD_DIR)
