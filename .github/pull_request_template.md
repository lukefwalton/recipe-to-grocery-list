## What & why

<!--
Heads up: this repo is MIT-licensed, but it doesn't accept unsolicited feature/refactor/dependency PRs — please open an
issue first so we can agree on the change (see CONTRIBUTING.md). For an
agreed-upon fix, describe what changed and why, and link the issue (e.g.
Closes #12). Which SPEC §12 gate does this land or touch?
-->

## Checklist

- [ ] Discussed first in an issue (or it's a small, obvious bug/docs fix)
- [ ] CI passes (iOS tests + the Foundation Models guard + the config guardrails)
- [ ] Tests added or updated for new logic, where it applies
- [ ] Schema change? Includes a `Schema.migrate` step and tests
- [ ] Seed change? Edited `scripts/seed_source.json` and ran `python3 scripts/build_seed.py` (didn't hand-edit `seed_ingredients.json`)
- [ ] Respects the doctrine: local-first, one write path (`RecipeStore.save`), model proposes / app confirms / app writes, per-row never all-or-nothing, honest numbers
- [ ] Privacy copy unchanged — or changed in all four places, site first: https://lukefwalton.com/recipe-to-grocery-list/privacy/ (canonical), `docs/privacy.md`, `PrivacyCopy` in `PrivacyView.swift`, App Store listing
- [ ] No new dependency, entitlement or network path; the extension still never names the database
- [ ] Cited the sibling file/revision for inherited code (`workout-logger@5bffddfb80fc`, `a-new-word-every-day@e829bcc9c0dc`)
- [ ] Docs updated if behavior or setup changed (`docs/learnings/` entry for a changed decision)
