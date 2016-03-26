# grampa

Grampa is an idea that’s been kicking around in my head for a few years:

Can you build a resonably okay blogging tool out of common shell commands?

The answer is: I think? Yeah.

## installation

Check out this repo and run `make setup`. The `config` file doesn’t actually do anything yet. But if you have files in the `posts/` directory you’re good to go. See below for post file format. It’s super fragile and won’t work unless it’s exactly as specified. Just run `make` and get excited!

## post format

A post file name _must_ be in the format: y-m-d-title-of-post.txt

Your file’s title can be as long as you like and contain at least one word.

The contents of the post _must_ be in this format:

	title: A text title
	category: example
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
