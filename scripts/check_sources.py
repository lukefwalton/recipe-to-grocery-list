#!/usr/bin/env python3
"""Guard: every Swift file is compiled, and every file imports what it uses.

Purpose:           Catch two build breakages that no test can catch and that a
                   machine without Xcode cannot compile its way into finding.
When to use:       CI (checks.yml); after adding a Swift file or a new framework symbol.
Safe to run in prod?  Yes — reads project.yml and the Swift sources, writes nothing.
Owner:             Luke F. Walton

**1. Orphaned sources.** XcodeGen compiles the directories listed under each
target's `sources:`. A new file in a directory nobody lists is not a build error —
it is silently *absent*, and the symptom is a confusing "cannot find X in scope"
somewhere else. Every `.swift` file must belong to at least one target.

**2. Missing imports.** A file that uses a framework symbol without importing the
framework fails to compile. This one is not hypothetical: `ListModel`,
`RecipesModel` and `ConfirmModel` each declared `ObservableObject` conformance with
`@Published` properties while importing only Foundation. `ObservableObject` lives in
Combine. SwiftUI re-exports Combine, which is why the same pattern compiles in
`AppModel` and why the mistake is easy to make and invisible on review.

**3. Private memberwise initializers.** Swift synthesizes a struct's memberwise
initializer at the access level of its *least* accessible stored property: one
`private` property makes the whole initializer private. `@State`, `@Environment` and
`@EnvironmentObject` properties are conventionally private and are stored properties,
so a SwiftUI view that mixes them with `let` inputs cannot be constructed from
anywhere else — including a sibling type in the same file, since `private` reaches
only the enclosing declaration. Five views here had exactly that shape. The rule does
not apply when every stored property has a default, because Swift then also
synthesizes the plain `init()`, whose access level follows the type.

The symbol table below is deliberately small and unambiguous: one obvious owning
framework each, no generic names, nothing that could be a project type. A symbol
worth adding is one whose module you would have to remember; a symbol not worth
adding is one that would ever produce a false alarm.
"""

from __future__ import annotations

import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI images all ship PyYAML
    sys.exit("::error::check_sources.py needs PyYAML (pip install pyyaml)")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "lfwdesignsystem", "build", "DerivedData", "__pycache__", ".build"}

# Symbol → the framework that declares it.
SYMBOL_MODULE: dict[str, str] = {}


def declare(module: str, *symbols: str) -> None:
    for symbol in symbols:
        SYMBOL_MODULE[symbol] = module


declare("Combine", "ObservableObject", "Published", "AnyCancellable", "PassthroughSubject",
        "CurrentValueSubject", "ObservableObjectPublisher")
declare("SwiftUI", "View", "ViewBuilder", "ViewModifier", "Binding", "StateObject",
        "ObservedObject", "EnvironmentObject", "NavigationStack", "ContentUnavailableView",
        "ToolbarItem", "PreviewProvider", "UIViewControllerRepresentable", "UIViewRepresentable")
declare("UIKit", "UIImage", "UIColor", "UIViewController", "UIApplication", "UIView",
        "UIImagePickerController", "UITabBarAppearance", "UITabBar", "UIDevice", "UIScreen",
        "UILabel", "UIStackView", "UIBarButtonItem", "UINavigationController",
        "UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator", "NSLayoutConstraint")
declare("PhotosUI", "PhotosPicker", "PhotosPickerItem", "PHPickerViewController",
        "PHPickerConfiguration", "PHPickerResult")
declare("Vision", "VNRecognizeTextRequest", "VNImageRequestHandler", "VNRecognizedTextObservation",
        "VNRequestTextRecognitionLevel", "VNRecognizedText")
declare("NaturalLanguage", "NLContextualEmbedding", "NLContextualEmbeddingResult",
        "NLEmbedding", "NLLanguage", "NLTokenizer")
declare("AVFoundation", "AVCaptureDevice", "AVAuthorizationStatus")
declare("UniformTypeIdentifiers", "UTType")
declare("XCTest", "XCTestCase", "XCTAssertEqual", "XCTAssertTrue", "XCTAssertFalse",
        "XCTAssertNil", "XCTAssertNotNil", "XCTUnwrap", "XCTFail", "XCTestExpectation")
declare("FoundationModels", "SystemLanguageModel", "LanguageModelSession", "GenerationOptions")
declare("SQLite3", "sqlite3_open_v2", "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_finalize",
        "sqlite3_exec", "sqlite3_close", "sqlite3_stmt_readonly")

# Importing the key also provides the values (Swift re-exports).
REEXPORTS: dict[str, set[str]] = {
    "SwiftUI": {"Combine", "CoreGraphics", "Foundation"},
    "UIKit": {"Foundation", "CoreGraphics"},
    "PhotosUI": {"Photos"},
    "Vision": {"CoreGraphics"},
}

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def swift_files() -> list[str]:
    found = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name.endswith(".swift"):
                found.append(os.path.relpath(os.path.join(root, name), REPO))
    return sorted(found)


def strip_comments_and_strings(source: str) -> str:
    source = re.sub(r"//[^\n]*", " ", source)
    source = re.sub(r"/\*.*?\*/", " ", source, flags=re.S)
    source = re.sub(r'"""(.*?)"""', " ", source, flags=re.S)
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', " ", source)


# --------------------------------------------------------------------------- #
# 1. Every Swift file is compiled by some target
# --------------------------------------------------------------------------- #

with open(os.path.join(REPO, "project.yml"), encoding="utf-8") as handle:
    project = yaml.safe_load(handle)

target_paths: dict[str, list[str]] = {}
for target, spec in project.get("targets", {}).items():
    paths = []
    for entry in spec.get("sources", []):
        path = entry["path"] if isinstance(entry, dict) else entry
        paths.append(path.rstrip("/"))
    target_paths[target] = paths


def targets_for(path: str) -> list[str]:
    return [
        target for target, paths in target_paths.items()
        if any(path == p or path.startswith(p + "/") for p in paths)
    ]


files = swift_files()
for path in files:
    if not targets_for(path):
        fail(f"{path} is in no target's `sources:` — XcodeGen will silently not compile it; "
             "add its directory to project.yml")

# --------------------------------------------------------------------------- #
# 2. Every file imports the modules its symbols come from
# --------------------------------------------------------------------------- #

for path in files:
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        raw = handle.read()
    imported = set(re.findall(r"^\s*(?:@\w+\s+)?import\s+(\w+)", raw, re.M))
    available = set(imported)
    for module in imported:
        available |= REEXPORTS.get(module, set())

    body = strip_comments_and_strings(raw)
    used = set(re.findall(r"\b(\w+)\b", body))
    for symbol in sorted(used & SYMBOL_MODULE.keys()):
        module = SYMBOL_MODULE[symbol]
        if module not in available:
            fail(f"{path} uses `{symbol}` but never imports {module} "
                 f"(imports: {', '.join(sorted(imported)) or 'none'})")

# --------------------------------------------------------------------------- #
# 3. No struct is built with arguments it cannot expose
# --------------------------------------------------------------------------- #

STRUCT = re.compile(r"\b(?:private |fileprivate |public )?struct\s+([A-Z]\w*)")
PRIVATE_STORED = re.compile(
    r"((?:@\w+(?:\([^)]*\))?\s*)*)(private|fileprivate)\s+(?:static\s+)?(var|let)\s+(\w+)\s*(.*)$"
)
BUILT_WITH_ARGS = re.compile(r"(?<![\w.])([A-Z]\w*)\(\s*\w+\s*:")

structs: dict[str, dict] = {}
sources: dict[str, str] = {}
for path in files:
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        sources[path] = strip_comments_and_strings(handle.read())

for path, text in sources.items():
    for match in STRUCT.finditer(text):
        name = match.group(1)
        brace = text.find("{", match.end())
        if brace < 0:
            continue
        index, depth = brace + 1, 1
        while index < len(text) and depth:
            depth += (text[index] == "{") - (text[index] == "}")
            index += 1
        body = text[brace + 1:index - 1]

        private_stored, depth = [], 0
        for line in body.split("\n"):
            candidate = PRIVATE_STORED.match(line.strip()) if depth == 0 else None
            if candidate:
                prefix = line.split(candidate.group(3))[0]
                # `{` in the tail means a computed property, not a stored one.
                if "{" not in candidate.group(5) and "static" not in prefix:
                    private_stored.append(candidate.group(4))
            depth += line.count("{") + line.count("(") - line.count("}") - line.count(")")

        structs[name] = {
            "file": path,
            "has_init": re.search(r"\binit[?!]?\s*\(", body) is not None,
            "private_stored": private_stored,
        }

for path, text in sources.items():
    seen: set[str] = set()
    for match in BUILT_WITH_ARGS.finditer(text):
        name = match.group(1)
        spec = structs.get(name)
        if not spec or spec["has_init"] or not spec["private_stored"] or name in seen:
            continue
        seen.add(name)
        fail(f"{path} builds `{name}(…:)` with arguments, but {name} "
             f"(declared in {spec['file']}) has private stored properties "
             f"({', '.join(spec['private_stored'])}), so its synthesized memberwise "
             "initializer is private — give it an explicit `init`")

# --------------------------------------------------------------------------- #

if failures:
    print("FAILED — check_sources.py:")
    for failure in failures:
        print(f"  ::error::{failure}")
    raise SystemExit(1)

counts: dict[str, int] = {}
for path in files:
    for target in targets_for(path):
        counts[target] = counts.get(target, 0) + 1
summary = ", ".join(f"{target} {count}" for target, count in sorted(counts.items()))
print(f"✅ Sources OK — {len(files)} Swift files, all compiled ({summary}); "
      f"imports cover {len(SYMBOL_MODULE)} tracked framework symbols; "
      f"{len(structs)} structs checked for reachable initializers")
