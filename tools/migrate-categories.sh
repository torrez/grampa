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

	# Already migrated?
	case "$base" in
		*_*)
			echo "skip     $f (already has a category in the name)"
			skipped=$((skipped + 1))
			continue
			;;
	esac

	# Category comes from front matter, which ends at the
	# delimiter -- so a "category:" line in the body is
	# not mistaken for it.
	category=$(sed -n '/^-----------------------------------/q; s/^category:[[:space:]]*//p' "$f" | head -1)
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

	echo "rename   $f -> $new"
	changed=$((changed + 1))

	if [ "$APPLY" = yes ]; then
		# Drop the category: line, but only from front matter.
		awk '
			/^-----------------------------------/ { seen = 1 }
			{ if (!seen && $0 ~ /^category:/) next; print }
		' "$f" > "$new" || exit 1
		rm "$f"
	fi
done

echo
if [ "$APPLY" = yes ]; then
	echo "renamed $changed, skipped $skipped, errors $errors"
else
	echo "would rename $changed, skip $skipped, errors $errors"
	echo "nothing changed. re-run with --apply to do it."
fi

[ "$errors" -eq 0 ]
