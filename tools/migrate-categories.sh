#!/bin/bash
#
# One-time migration for the filename change that moved
# categories out of front matter and into post names.
#
#   before: posts/2026-08-06-installing-a-doorbell.txt
#           with a "category: Home" line in front matter
#   after:  posts/2026-08-06-home_installing-a-doorbell.txt
#           with that line removed
#
# Post URLs are unaffected -- the category never appears
# in one.
#
# Prints what it would do and changes nothing. Pass
# --apply to actually rename.
#
set -uo pipefail

APPLY=no
if [ "${1:-}" = "--apply" ]; then
	APPLY=yes
fi

if [ ! -d posts ]; then
	echo "no posts/ directory here; run this from your grampa checkout" >&2
	exit 1
fi

changed=0
skipped=0
errors=0

for f in posts/*.txt; do
	[ -e "$f" ] || continue
	base=$(basename "$f" .txt)

	# Category comes from front matter, which ends at the
	# delimiter -- so a "category:" line in the body is
	# not mistaken for it.
	category=$(sed -n '/^-----------------------------------/q; s/^category:[[:space:]]*//p' "$f" | head -1)

	has_underscore=no
	case "$base" in
		*_*) has_underscore=yes ;;
	esac

	# An underscore in the name alone is ambiguous: it's
	# what a migrated name looks like, but nothing in the
	# old format forbade a title containing one either.
	# Front matter breaks the tie -- a migrated post has no
	# category: line left to drop.
	if [ "$has_underscore" = yes ] && [ -z "$category" ]; then
		echo "skip     $f (already has a category in the name, no category: line left)"
		skipped=$((skipped + 1))
		continue
	fi

	if [ "$has_underscore" = yes ] && [ -n "$category" ]; then
		echo "ERROR    $f: name already contains an underscore AND front matter still has a category: line; cannot tell whether this is already migrated or an old-format title containing '_' -- rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	if [ -z "$category" ]; then
		echo "ERROR    $f has no category: line; rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	slug=$(printf '%s' "$category" \
		| tr '[:upper:]' '[:lower:]' \
		| tr ' ' '-' \
		| sed 's/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//')
	if [ -z "$slug" ]; then
		echo "ERROR    $f: category '$category' slugifies to nothing; rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	date_part=$(printf '%s' "$base" | cut -d- -f1-3)
	title_part=$(printf '%s' "$base" | cut -d- -f4-)
	if [ -z "$title_part" ]; then
		echo "ERROR    $f: cannot find a title after the date; rename it by hand" >&2
		errors=$((errors + 1))
		continue
	fi

	new="posts/${date_part}-${slug}_${title_part}.txt"
	if [ -e "$new" ]; then
		echo "ERROR    $f: $new already exists" >&2
		errors=$((errors + 1))
		continue
	fi

	if [ "$APPLY" = yes ]; then
		# Write the migrated content under the new name
		# first -- $f is only ever removed once that has
		# actually succeeded.
		if ! awk '
			/^-----------------------------------/ { seen = 1 }
			{ if (!seen && $0 ~ /^category:/) next; print }
		' "$f" > "$new"; then
			echo "ERROR    $f: failed writing $new; $f left in place" >&2
			rm -f "$new"
			errors=$((errors + 1))
			continue
		fi

		# rm's exit status matters: an unremovable source
		# (read-only, chflags uchg, whatever) must not be
		# reported as a success while both files sit on
		# disk under two names.
		if ! rm "$f"; then
			echo "ERROR    $f: wrote $new but could not remove $f -- both $f and $new now exist; verify $new is correct, then remove $f by hand" >&2
			errors=$((errors + 1))
			continue
		fi
	fi

	echo "rename   $f -> $new"
	changed=$((changed + 1))
done

echo
if [ "$APPLY" = yes ]; then
	echo "renamed $changed, skipped $skipped, errors $errors"
else
	echo "would rename $changed, skip $skipped, errors $errors"
	# posts/ is gitignored, so it is the only thing here git
	# cannot give back. --apply renames in place and has no
	# undo.
	echo "nothing changed. back up posts/ first -- it is not in git,"
	echo "and --apply has no undo:"
	echo "    cp -R posts posts.bak"
	echo "then re-run with --apply to do it."
fi

[ "$errors" -eq 0 ]
