# grampa

Grampa is an idea that’s been kicking around in my head for a few years:

Can you build a resonably okay blogging tool out of common shell commands?

The answer is: I think? Yeah.

## installation

Check out this repo and run `make setup`. The `config` file doesn’t actually do anything yet. But if you have files in the `posts/` directory you’re good to go. See below for post file format. It’s super fragile and won’t work unless it’s exactly as specified. Just run `make` and get excited!

## post format

A post file name _must_ be in the format: y-m-d-category_title-of-post.txt

Anything to the left of the `_` is the date and the category. Anything to the
right is the title of the post. Exactly one `_` per filename, please — neither
the category nor the title may contain one. Categories can contain hyphens, so
`project-ideas` is fine.

	posts/2026-08-06-home_installing-a-doorbell.txt
	posts/2026-07-04-project-ideas_raspberry-pi-backup.txt

Zero-padding the date is optional — posts sort correctly either way — but
`2026-08-06` gives you a tidier URL than `2026-8-6`.

The category never appears in the URL. That post above lives at
`/2026/08/06/installing-a-doorbell.html`.

The contents of the post _must_ be in this format:

	title: A text title
	-----------------------------------
	<p>
	Body of your post.
	</p>

If you put `Markdown.pl` from (this zip file)[https://daringfireball.net/projects/markdown/] in the root directory then every body will be run through it.

## things i still need to do

1. Atom feed
1. Better deployment examples
1. Location for all static files

## welp

All of this is in flux. I’m not ready to say anyone can use this, but it might be fun to read the Makefile to see how it works.
