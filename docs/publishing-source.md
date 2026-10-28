# Making this repository public

Checklist before flipping visibility on GitHub. Inherited from
`workout-logger/docs/publishing-source.md`.

## Already handled in-repo

- [x] **Copyright posture:** no root `LICENSE` by decision (SPEC §13), so all
      rights reserved. `NOTICE.md`, `CONTRIBUTING.md`, `SECURITY.md` and the
      README all say so in the same words.
- [x] **Secrets gitignored:** `project.local.yml`, signing assets, `build/`,
      `*.xcodeproj/`, `ExportOptionsLocal.plist`, fetched fonts — see
      [.gitignore](../.gitignore).
- [x] **Example config only:** [project.local.yml.example](../project.local.yml.example)
      uses the `YOUR_TEAM_ID_HERE` placeholder; [ExportOptions.plist](../ExportOptions.plist)
      carries no team id.
- [x] **Privacy policy:** [docs/privacy.md](privacy.md) matches App Store
      Connect and the live page.
- [x] **Attributions:** [NOTICE.md](../NOTICE.md) for fonts, the seed vocabulary
      and build tooling.
- [x] **History scan** (run October 2026, before 012):
      ```bash
      git log --all -- project.local.yml                                   # empty
      git grep -h -E -o 'DEVELOPMENT_TEAM[":= ]+[A-Z0-9]{10}\b' $(git rev-list --all)   # nothing
      ```

## Before you click "Public" on GitHub

1. Re-run the history scan above if anything was committed since.
2. Set the **About** description (it still reads "A simple iOS app"), the
   website `https://lukefwalton.com/recipe-to-grocery-list/`, and topics:
   `ios`, `swift`, `swiftui`, `privacy`, `grocery-list`, `recipes`, `local-first`.
3. **Keep Issues enabled**; the product page links to them.
4. Visibility is "Public". Actions minutes on a public repo are free, so
   `ios-tests.yml` keeps running on every PR.

## After going public

- Do not commit `project.local.yml` or signing assets (`.p12`, `.mobileprovision`).
- App Store releases stay tied to your signing identity and Apple Developer account.
- Choosing the source license is a single PR that touches `LICENSE`,
  `NOTICE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `lfwdesignsystem/LICENSE`,
  `NSHumanReadableCopyright` and the README together (009).
