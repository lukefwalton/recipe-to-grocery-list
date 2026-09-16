# LFWDesignSystem

A tiny SwiftUI design system, vendored into this repo — shared visual language
across Luke F. Walton's iOS apps so onboarding and chrome feel like a family.

**This copy is synced FROM `a-new-word-every-day`** (the canonical home of the
package; this repo holds version 2.3.0 from revision `e829bcc9c0dc`). Do not edit
it here: change it in the word repo, run `scripts/sync_designsystem.sh`, and
commit. `scripts/check_designsystem_sync.sh` (run in CI) fails on any hand-edit
that doesn't regenerate `CHECKSUMS.txt`. This README and `LICENSE` are the two
per-repo files the checksum deliberately excludes.

It ships:

- **Palette** — green leads the brand (`LFWColors.{forest, verdigris}`), then the
  ukiyo-e blue lineage (`ocean, deepSea, ukiyoBlue, mist`), then supporting
  `{gold, paper, ink, traveler, nebula, kelp, steel}`, plus semantic status tokens
  `LFWColors.{success, warning, danger}` — reach for these instead of system
  `.green`/`.orange`/`.red` so status reads on-brand. See the word repo's
  `STYLE-GUIDE.md` for the full spec (colors in priority order, fonts by purpose).
- **Metrics** — `LFWRadius.{chip, card, surface}`
- **Onboarding kit** — `LFWOnboardingScaffold`, `LFWHeroIcon`,
  `LFWOnboardingMessage`, `LFWFeatureRow`, `LFWPageDots`
- **Empty states** — `LFWEmptyState` (glyph + optional gold `eyebrow` + title +
  message + action slot; `prominent:` for the hero-scale first-run variant). The
  shared alternative to a bare `Text` / `ContentUnavailableView` or a hand-rolled hero.
- **Cards** — `.lfwCard()` — the family rounded surface (one corner radius on
  `LFWRadius.surface` + a soft `deepSea` shadow) so cards stop drifting per app.
- **Setup steps** — `LFWStepRow` — a numbered gold badge + title/detail row for
  "how to enable this" / permission / multi-step setup screens.
- **Background** — `LFWOnboardingBackground` (the shared moving-blob layer)
- **Buttons** — `LFWCTAButtonStyle` / `.buttonStyle(.lfwCTA)`
- **Variable fonts** — `Font.lfwVariable(_:size:axes:)` + `LFWVariableFont` axis
  tags and `.lfwVariableAxis(...)` for animating an axis. Core Text under the
  hood; SwiftUI has no first-class axis API.
- **Typography** — `LFWTypography.font(_:typeface:)` resolves semantic
  `LFWTextRole`s to a chosen `LFWTypeface`, falling back to a system face when the
  OFL font isn't bundled.
- **Theming** — `LFWThemeConfig` (typeface + `LFWPalette` + accent-hue nudge),
  Codable; `LFWThemedBackground`.

Recipe to Grocery List consumes it as a local Swift Package via XcodeGen
(`packages:` → `path: lfwdesignsystem`) and
`dependencies: [{ package: LFWDesignSystem }]`, with `App/Theme.swift` forwarding
to it. Of the seven `LFWTypeface`s the package knows, this app bundles only
Fraunces and Inter (`Theme.bundledTypefaces`); the rest would render as system
fallbacks, so the picker doesn't offer them.

Copyright Luke F. Walton — see [LICENSE](LICENSE) (same terms as the app; the root
license is an open decision, `docs/SPEC.md` §13).

## Family rule of thumb

If a screen exists to *welcome*, *explain*, or *gate* the user (onboarding,
empty states, permission walls), reach for these components — that's where
family resemblance pays off most. App-specific surfaces (the Confirm row editor,
the grocery list) can still use domain-specific styling; they just shouldn't
pull the family apart at the front door.
