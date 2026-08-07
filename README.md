# grampa

Grampa is an idea that’s been kicking around in my head for a few years:

Can you build a reasonably okay blogging tool out of common shell commands?

The answer is: I think? Yeah.

## installation

Check out this repo and run `make setup`. See `## config` below for what the `config` file does. If you have files in the `posts/` directory you’re good to go. See below for post file format. It’s super fragile and won’t work unless it’s exactly as specified. Just run `make` and get excited!

## config

Two keys, both optional:

	name=My Weblog
	url=https://example.com

`name=` goes in the title tags — the front page gets `My Weblog`, a post page gets
`Post Title - My Weblog`. Unset, it falls back to `Grampa`.

`url=` is the absolute address of your site. Setting it turns on an RSS feed at
`/rss.xml`; leaving it out means no feed gets built, and no error either. It has to be
absolute because a feed reader has no page to resolve a relative link against. A trailing
slash is fine, it gets stripped.

Blank lines and lines starting with `#` are ignored, and if you set a key twice the last
one wins.

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

Two posts can’t share a date and title slug, even in different categories — since the
category isn’t in the URL they’d both want the same page, and `make` will stop and tell you
which two files to sort out.

## category pages

Every category you use gets its own page at `/category/<slug>.html` — so `home` above
becomes `/category/home.html` — listing every post in it, newest first, full bodies. The
front page still stops at ten posts, but category pages don’t, so nothing ever falls off the
end of the site. Each post links to its own category page from the posted-on line, and you
don’t have to do anything to make any of this happen: the categories come out of your
filenames.

The contents of the post _must_ be in this format:

	title: A text title
	-----------------------------------
	<p>
	Body of your post.
	</p>

If you put `Markdown.pl` from [this zip file](https://daringfireball.net/projects/markdown/) in the root directory then every body will be run through it.

It has to be **executable** — `chmod +x Markdown.pl`. The build tests for an executable
file, so a copy that isn’t one is skipped silently and your bodies stay verbatim HTML. If
your Markdown isn’t being turned into HTML, check that first — and after you fix it, run
`make clean && make`. Posts that have already been staged aren’t rebuilt just because
`Markdown.pl` turned up or changed, so `chmod +x` on its own looks like it did nothing.

## rss

Set `url=` in your config and you get an RSS 2.0 feed at `/rss.xml` — the ten newest posts,
full bodies, same window as the front page.

Every page advertises it, so browsers and readers can find it on their own. If you set up
grampa before the feed existed, your `templates/base.txt` won’t have that line, since
`make setup` never overwrites a template you already have. Add it inside `<head>`:

	<link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml">

**If you’re upgrading, re-run `make setup`.** It copies the two new feed templates into
`templates/` and won’t touch anything you already have. Without them the build has nothing
to render the feed from.

The link tag is there whether or not you’ve set `url=`, so a site with no feed advertises
one that 404s. Set `url=`, or delete the line.

If you had grampa checked out before this feed existed, you’ll have a leftover
`templates/atom.txt` sitting around from the old Atom stub — nothing reads it anymore, so
it’s safe to delete.

## things i still need to do

1. Better deployment examples
1. Location for all static files

## welp

All of this is in flux. I’m not ready to say anyone can use this, but it might be fun to read the Makefile to see how it works.
