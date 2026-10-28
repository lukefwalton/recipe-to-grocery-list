# Recipe to Grocery List — Privacy Policy

_Last updated: 2026-09-16_

> **This file is a mirror, not the source.** The canonical privacy policy is
> https://lukefwalton.com/recipe-to-grocery-list/privacy/ (lukefwalton.com is
> the source of truth for everything public-facing). The same sentences live in
> four places: that page, this file, the in-app Privacy screen
> (`Features/Settings/PrivacyView.swift`, `PrivacyCopy`) and the App Store
> listing. **Edit the site first, then bring the other three to match in one
> PR.** Never edit this file alone.

Recipe to Grocery List is built privacy-first. The short version: **your recipes
and your list stay on your phone.** There is no account, no server of ours, and
no tracking. The app makes exactly one kind of network request, and only when you
ask it to: when you give it a link, the app downloads that page, once, and
nothing else.

## The promise, in five sentences

These are the exact sentences the app shows on its Privacy screen (Settings →
Privacy); the rest of this page explains each of them.

- Your recipes, ingredients and list live in a database on this phone.
- When you give it a link, the app downloads that page, once, and nothing else.
- Photos are read on this phone and never stored.
- On devices with Apple Intelligence, the app may use Apple's on-device model to read ingredient lines. No cloud AI, ever.
- No account, no analytics, no crash reporter, no third-party code.

## What we collect

**Nothing.** Recipe to Grocery List has no analytics, no advertising SDKs, no
crash reporting that leaves the device, and no third-party trackers. We do not
collect a name, an email, an advertising identifier, or any usage data. There is
no sign-up and no login because there is no account. The App Store privacy label
is **Data Not Collected**, and the app's bundled privacy manifest says the same.

## Where your data lives

Everything you save — recipes, their ingredient lines, the ingredient names the
app learns from you, your grocery list and its check-marks, manual items, and
your settings (theme, first-run flag) — is stored on your iPhone in the app's own
private sandbox: a single SQLite database plus the standard app preferences. It
is never uploaded anywhere by the app.

The app also has an **App Group** container, and it is used for one thing only:
the Share Extension's inbox. When you share a link or some text to the app from
another app, the extension writes it into a small file in that container, where
it waits until you open Recipe to Grocery List. The app reads the file, removes
what it took, and opens the Add screen with what you shared filled in; a shared
link is not fetched until you tap. The database itself is not in the App
Group; the extension cannot read your recipes or your list.

Standard iOS device backups (iCloud Backup or an encrypted local backup) may
include the app's data, the same as any other app's local data. That backup is
governed by Apple's privacy terms and your device settings, not by us; we never
transmit your recipes to our own servers because we don't have any.

## The one network request

When you give it a link, the app downloads that page, once, and nothing else.

In detail: the app makes a single `https` request for the exact address you gave
it (plain `http` links are refused). It follows at most five redirects, only to
other `https` addresses. It sends no cookies and stores none, runs no JavaScript,
and never fetches the page's images, scripts or stylesheets. It gives up after
15 seconds or 3 MB. It does not retry unless you tap again. The page is read once
for its ingredient list and then discarded; the app keeps only the ingredient
lines, the recipe's title and yield if the page stated them, and the final
address so you can find the recipe again. The page itself is never stored.

Pasting text and photographing a page involve no network request at all.

## Photos and the camera (optional, opt-in)

The Photo path can read the ingredients off a photographed cookbook page,
entirely on your device (Apple's Vision framework). It runs only when you choose
it. Picking an existing photo uses the out-of-process iOS picker, which needs no
photo-library permission; using the camera instead asks for camera permission in
context, and the reason shown is the true one: to read ingredients off a page.
The image is processed in memory and is **never stored** by the app, never added
to your library by the app, and never uploaded. Recognized text goes through the
same confirm-before-save flow as pasted text.

## On-device parsing (no cloud AI)

Turning an ingredient line into a quantity, a unit and a name is done by
deterministic code on your device. On iPhones where Apple Intelligence is
available and enabled, the app may additionally use **Apple's on-device
Foundation Models** to tidy the parse and suggest which pantry item a line means.
That processing runs entirely on your iPhone using Apple's built-in system model:
no text is sent to us, to Apple's servers by the app, or to any third party.
There is **no cloud AI** of any kind, not even as an option. The model only
*proposes* — nothing is saved until you confirm it, and it never writes to the
database. If Apple Intelligence is unavailable or turned off, the app simply uses
its deterministic parser and a few more rows may need a tap; nothing else changes.

## What Recipe to Grocery List does not do

- No accounts, no servers, no cloud sync operated by us.
- No analytics, no telemetry, no crash reporter, no advertising, no ad
  identifiers, no ATT prompt, no third-party SDKs.
- No selling or sharing of data — there is no data leaving the device to sell.
- No request to any address other than the one you gave it (and the `https`
  redirects it sends you through, five at most), and none at all unless you did.

## Children's privacy

The app collects no personal information from anyone, including children.

## Changes

If this policy changes, the updated version will be published here and the date
above will be revised.

## Contact

Questions about privacy or the app: [luke@lukefwalton.com](mailto:luke@lukefwalton.com),
or a [GitHub Issue](https://github.com/lukefwalton/recipe-to-grocery-list/issues).
Website: [lukefwalton.com](https://lukefwalton.com)
