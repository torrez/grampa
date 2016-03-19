# grampa

Grampa is an idea that’s been kicking around in my head for a few years:

Can you build a resonably okay blogging tool out of common shell commands?

The answer is: I think? Yeah.

## installation

Check out this repo and run `make setup`. The `config` file doesn’t actually do anything yet. But if you have files in the `posts/` directory you’re good to go. See below for post file format. It’s super fragile and won’t work unless it’s exactly as specified.

## post format

A post file name _must_ be in the format: y-m-d-title-of-post.txt

Your file’s title can be as long as you like and contain at least one word.

The contents of the post _must_ be in this format:

	title: A text title
	tags: these, aint, used, yet
	-----------------------------------
	<p>
	Body of your post.
	</p>

## things i still need to do

1. Atom feed (duh)
1. Markdown format option (duh)
1. Better deployment examples

## welp

So yeah, this is my idea. I don’t think it’s totally ready for use but here it is! I wrote it while my kid napped and it feels good to have it done but I don’t know when I’ll be able to update it. Plus it gave me a chance to learn how to make a Makefile and how to make inline awk scripts that sort of do what I want. I didn’t know either before sitting down to do this.

