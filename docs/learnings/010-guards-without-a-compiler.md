# 010 — Finding compile errors without a compiler

This branch was written where no Swift toolchain exists (`001`). Every earlier entry
records a decision; this one records a *method*, because the method found real bugs
and is now three CI guards rather than a story.

The premise is narrow. Tests cannot run, so tests prove nothing here. What can be
checked is everything a compiler would check structurally: does this symbol exist,
does this file see the module it uses, is this initializer reachable. Those questions
are answerable by reading the source mechanically, and a mistake in any of them is a
build that fails on the owner's Mac on the first `xcodebuild` — the worst possible
moment to discover it.

## Three guards, each written after it found something

### `check_schema.py` — the schema is a string

`Schema.v1` is a Swift multiline string executed once, at first launch, inside a
transaction. The compiler checks that it is a valid *string*. Nothing checked that it
was valid *SQL* until this guard executed it in SQLite. It also diffs the literal
against the SPEC §6 block that duplicates it, and checks that the `category`,
`source_kind` and `resolution` CHECK vocabularies are exactly the raw values of
`IngredientCategory`, `SourceKind` and `RowResolution` — because adding an enum case
and forgetting the CHECK produces a row the save path accepts and the database
rejects, on a device, at write time.

### `check_sources.py` (1) — a file nobody compiles

XcodeGen compiles the directories a target lists. A `.swift` file in a directory no
target lists is not an error; it is silently absent, and the symptom surfaces
somewhere else entirely as "cannot find X in scope". The guard requires every file to
belong to a target. All 92 do.

### `check_sources.py` (2) — `ObservableObject` lives in Combine

`ListModel`, `RecipesModel` and `ConfirmModel` each declared `ObservableObject`
conformance with `@Published` properties while importing only Foundation. That does
not compile. It survived review because the same code *does* compile in `AppModel`,
which imports SwiftUI — and SwiftUI re-exports Combine. The three models import
Combine directly now, deliberately, rather than reaching for SwiftUI: a view model
that owns no view types should not import the view layer to get a protocol.

### `check_sources.py` (3) — the private memberwise initializer

The one worth remembering. Swift synthesizes a struct's memberwise initializer at the
access level of its **least accessible stored property**, so a single `private`
property makes the whole initializer private. `@State`, `@Environment` and
`@EnvironmentObject` are stored properties and are conventionally private. A SwiftUI
view that mixes them with `let` inputs therefore cannot be constructed from anywhere
else — not from another file, and not even from a sibling type in the same file,
because `private` reaches only the enclosing declaration and its own extensions.

Five views had that shape and now spell their initializers out:
`ConfirmRowView`, `IngredientPickerView`, `CategoryPickerSheet`, `AppRoot`,
`RecipeDetailView`.

Two things stop this from being a blanket rule. When *every* stored property has a
default, Swift also synthesizes the plain `init()`, and a default initializer takes
the access level of the type — which is why `ListView()`, `RootTabView()` and
`PrivacyView()` are fine with nothing but private `@EnvironmentObject` properties.
And a view with no private stored properties at all keeps an internal memberwise init,
which is why `ThemedScreen` and `CategoryChooser` needed nothing.

The pattern was already right in one place: `RowEditSheet`, in the same file as
`ConfirmRowView`, was written with an explicit init from the start, as is
`OCRCandidateRow` in `workout-logger`. The rule was known and applied unevenly, which
is exactly the kind of thing a guard is for and a reviewer is bad at.

## Why these became guards instead of fixes

A one-off script that finds a bug and is then deleted buys one bug. The same script in
CI buys every future instance. Each of the three was tested against deliberate
mutations before landing — a misspelled `CREATE TABLE`, a spec/code divergence, an
enum case added without its CHECK, a removed `import Combine`, a directory dropped
from `project.yml`, a deleted initializer — and each fails with a specific message and
a non-zero exit. A guard that cannot fail is not a guard.

## What this does not do

It is not a type checker. It does not know about `async`/`await`, actor isolation,
generic constraints, `Sendable`, or whether `_model = ObservedObject(wrappedValue:)`
is spelled correctly for the SDK in question. Those still fail on the first real
build, and that build is still the gate (`001`, and the checklist in
`009-app-store-readiness.md`). What the guards buy is that the first build fails on
something interesting rather than on a missing import.
