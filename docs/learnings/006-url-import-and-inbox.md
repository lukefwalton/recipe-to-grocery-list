# 006 — URL import and the Share Extension inbox (gate 7)

The one place this app touches the network, and the one place two processes touch
each other. Both are deliberately tiny, because both are what a privacy-minded
user will actually ask about.

## The fetch policy is code, not prose

SPEC §5.1 writes the network rule as a sentence: *"When you give it a link, the app
downloads that page, once, and nothing else."* That sentence appears verbatim in
`docs/privacy.md`, the onboarding's second page, the in-app privacy screen and the
README — and every clause of it is a rule in `RecipeFetchPolicy`, which is pure and
therefore testable without a server:

| The sentence | The code |
|---|---|
| "you give it a link" | `validate` — `https` only, real host, no scheme guessing; `http` is refused, never upgraded |
| "downloads that page" | `makeRequest` — a plain GET of the exact URL, no body, two headers |
| "once" | ephemeral session, no cookie storage, no cache, one connection, **no retries** |
| "and nothing else" | no sub-resources are ever requested; the HTML is parsed once and discarded |

Plus the limits the spec sets: at most five redirects, `https`-only targets,
15 seconds, 3 MB. `RecipeFetcher` is the thin plumbing that obeys them — every
decision it makes is a call back into the policy, so the part that can't be
unit-tested contains no judgement of its own. Oversized responses are refused twice
over: on a declared `Content-Length`, and again as bytes arrive, since the declared
length can lie.

A plain `User-Agent` naming the app, not a browser string. The posture should be
visible from the other end of the connection too.

## Extraction: implement the vocabulary, don't vendor a scraper

Recipe sites already publish structured data for search engines. So extraction
reads schema.org JSON-LD first, microdata second, and otherwise reports an honest
nothing — §5.1's dead end with *Paste the ingredients instead* and *Open in Safari*,
rather than guessing at the page's prose. No third-party parser, no per-site rules,
no ML. `docs/prior-art-and-licensing.md` lists what was deliberately not used.

Both halves are hand-written scanners rather than regular expressions, because real
pages vary in every direction the syntax allows: single or double quotes, unquoted
values, attributes in any order, CDATA wrappers, several blocks per page, `@graph`
wrappers, `@type` as a string or an array, `recipeIngredient` as a string or an
array, and the legacy `ingredients` property. Each shape has a fixture. When a page
carries several `Recipe` nodes the one with the most ingredient lines wins — the
main recipe, not the "related recipes" card.

**Two bugs this found before the code ever compiled.** The expected values in the
tests were produced by porting the extractor to Python and running it over the
fixtures, which is the only verification available without a Swift toolchain — and
the port immediately disagreed with the Swift twice:

1. `attributeValue` searched a *lowercased copy* of a tag and then used the
   resulting indices on the original string. `String.Index` values are not portable
   between two different `String`s. Rewritten as a proper character-array tag
   scanner that returns a name and an attribute dictionary.
2. The conventional CDATA wrapper is `//<![CDATA[ … //]]>` — the markers are
   commented out so the block is also valid JavaScript. Unwrapping the markers
   alone leaves a trailing `//` *inside* the JSON, which `JSONSerialization`
   rejects. The `jsonld_two_blocks` fixture extracted nothing until that trailing
   comment opener was trimmed too.

Neither would have been caught by reading. Both are now fixtures.

## The inbox: one file, one direction

The Share Extension's entire job is to append `{kind, value, sharedAt}` to a JSON
file in the App Group container and say "Added. Open Recipe to Grocery List to
finish." It does no parsing, no networking, and never opens the database — the
database isn't even in the App Group (`001`). Extensions run under a hard memory
limit and have no Foundation Models access, so anything clever there would be
fragile for no gain.

`scripts/check_store_boundary.sh` enforces this rather than trusting the comment,
and it earned its keep immediately: it failed the build on a *doc comment* in
`ShareViewController.swift` that merely mentioned the store by name. The comment
was reworded. A guard that only catches real calls would not have caught the day
someone pastes in a real call under a comment.

The app drains on foreground, takes the first item, and **re-appends the rest** so
a second share isn't silently dropped (§1). A missing container, a missing file, or
a corrupt file all read as "empty inbox": the inbox is a convenience, and it must
never be a reason a launch fails. It is capped at twenty — the newest share is the
one the user is waiting on.

## What is device-verified, not tested here

`RecipeFetcher` needs a server; the share sheet needs a device. The policy, the
extraction, the entities and the inbox are all covered offline. The first real
`xcodebuild` is still the verification gate for the plumbing around them.
