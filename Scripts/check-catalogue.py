#!/usr/bin/env python3
"""Assert the string catalogue and the code still agree.
usage: check-catalogue.py [--fix] [--report]

Run from the repository root; `mise run lint` does.

Rule 9 says every string a user reads goes through `.reachy(_:)`, and nothing
checked that the key it names is actually *in* the catalogue. Nothing had to:
a missing key falls back to the English key and renders perfectly, in English,
for ever. That is how 139 keys accumulated outside `Localizable.xcstrings`
while the catalogue read as complete, and why translating it was a bigger job
than its 424 entries suggested. This is the check that keeps the gap shut.

Four assertions, and one report:

1. **Coverage** — the plain `.reachy("…")` literals in the sources are exactly
   the catalogue's keys. A missing key ships English; a stale key is dead copy
   a translator is still paid to read.
2. **Completeness** — every language in LANGUAGES has a unit for every key, in
   both catalogues. A half-translated language is worse than an absent one:
   the fallback is per *string*, so one screen comes out bilingual.
3. **Canonical form** — the file round-trips byte for byte through the emitter
   below, so a hand-edit or a merge cannot leave it in a shape the next tool
   silently rewrites. `--fix` writes that form.
4. **Collisions** — no two keys derive the same Swift symbol. `xcstringstool`
   makes that a hard *build* error, so catching it here is the difference
   between a lint failure on any machine and a broken build on a Mac.
5. **Bare literals** — no `Text("…")`, `Button("…")`, `.navigationTitle("…")`,
   `?? "…"` or the like carries prose that never went through `.reachy(_:)`.
   Such a string renders perfectly in English and can never be translated,
   which is exactly the failure rule 9 exists to prevent. What this cannot
   see is a `String`-typed slot fed by a literal elsewhere (`case .running:
   "Running"`), so it is a fence for the future rather than a proof; the
   known exemptions (a dash, an ellipsis, a middle dot) live in
   BARE_LITERAL_ALLOWLIST, extended here and never inline.

`--report` prints the offending keys instead of just counting them, which is
what the initial reconciliation was driven from.

**The scanner strips comments first, and that is not a nicety.** Two shapes in
this repository each produced a wrong answer without it:

  - `.reachy(` and its literal can be separated by a `// swiftlint:disable:next
    line_length` (`ReachyUI/Onboarding/OnboardingWelcomeStep.swift`). Skipping
    only whitespace reported nine *live* onboarding sentences as stale — copy a
    reconciliation would then have deleted.
  - `.reachy(_:)` written in a doc comment (`ReachyWidgetUI/RobotMoveIntents.swift`
    and three others) is not a call site, and read as one it looks like a key
    the scanner failed to parse.

Stripping has to be literal-aware in turn, or a `//` inside a URL eats the rest
of the line.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

# The languages this app ships. Both catalogues must cover every one of them;
# adding a language here is what makes the check demand it everywhere.
LANGUAGES = ("de", "es", "fr", "ru")

CATALOGUES = (
    pathlib.Path("Sources/ReachyDesign/Resources/Localizable.xcstrings"),
    pathlib.Path("Apps/ReachyMini/Resources/InfoPlist.xcstrings"),
)

# Only the first is keyed by `.reachy(_:)`; InfoPlist keys are plist names the
# system reads, so coverage says nothing about them.
CODE_CATALOGUE = CATALOGUES[0]

SOURCE_ROOTS = ("Sources", "Apps")

# `Previews/` and `Tests/` are developer surface — a preview's caption is never
# read by a user and should not be translated. `Generated/` is the storybook
# playbook, `DerivedData/` is Xcode's. The two Tuist manifests are `.swift` and
# mention `.reachy(_:)` in prose.
SKIP_DIRS = {"Previews", "Tests", "Generated", "DerivedData", ".build", ".venv-sim"}
SKIP_FILES = {pathlib.Path("Apps/Project.swift"), pathlib.Path("Apps/Tuist.swift")}

CALL = ".reachy("


def strip_comments(source: str) -> str:
    """Blank out `//` and `/* */` comments without touching string literals."""
    out: list[str] = []
    i, n = 0, len(source)
    while i < n:
        if source[i] == '"':
            if source.startswith('"""', i):
                end = source.find('"""', i + 3)
                end = n if end < 0 else end + 3
            else:
                end = i + 1
                while end < n and source[end] != '"':
                    end += 2 if source[end] == "\\" else 1
                end = min(end + 1, n)
            out.append(source[i:end])
            i = end
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            end = source.find("*/", i)
            i = n if end < 0 else end + 2
            out.append(" ")
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def read_literal(source: str, start: int) -> str | None:
    """`source[start]` is `"`. Return the raw body, or None if it is multiline."""
    if source.startswith('"""', start):
        return None
    body: list[str] = []
    i = start + 1
    while i < len(source):
        if source[i] == "\\":
            body.append(source[i : i + 2])
            i += 2
            continue
        if source[i] == '"':
            return "".join(body)
        body.append(source[i])
        i += 1
    return None


def unescape(raw: str) -> str:
    """The key as the catalogue stores it — Swift's escapes resolved."""
    return json.loads(f'"{raw}"')


def swift_sources() -> list[pathlib.Path]:
    files = []
    for root in SOURCE_ROOTS:
        for path in sorted(pathlib.Path(root).rglob("*.swift")):
            if SKIP_DIRS & set(path.parts) or path in SKIP_FILES:
                continue
            files.append(path)
    return files


def scan() -> tuple[set[str], set[str], list[str]]:
    """Return (plain keys, interpolating keys, non-literal call sites)."""
    plain: set[str] = set()
    interpolating: set[str] = set()
    non_literal: list[str] = []

    for path in swift_sources():
        source = strip_comments(path.read_text(encoding="utf-8"))
        i = 0
        while (i := source.find(CALL, i)) >= 0:
            j = i + len(CALL)
            while j < len(source) and source[j].isspace():
                j += 1
            raw = read_literal(source, j) if j < len(source) and source[j] == '"' else None
            if raw is None:
                non_literal.append(f"{path}:{source.count(chr(10), 0, i) + 1}")
            elif "\\(" in raw:
                interpolating.add(raw)
            else:
                plain.add(unescape(raw))
            i = j
    return plain, interpolating, non_literal


# The SwiftUI entry points that take a `LocalizedStringKey` from a bare
# literal, plus the two spellings a fallback takes (`?? "…"`). `Text(verbatim:`
# never matches: the parenthesis has to be followed by the quote itself.
BARE_LITERAL = re.compile(
    r'(?<![\w.])(?:Text|Button|Label|Toggle|Section|LabeledContent|TextField|SecureField|Picker|'
    r'NavigationLink|ContentUnavailableView)\(\s*"((?:[^"\\]|\\.)*)"'
    r'|\.(?:navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|help)\(\s*"((?:[^"\\]|\\.)*)"'
    r'|\?\?\s*"((?:[^"\\]|\\.)*)"'
)

# Fallbacks a reader never has to translate: punctuation, and the identifiers
# a log source or a profile is filed under (`?? "robot"` names a journal unit,
# `?? "default"` an audio profile, `"— (sim)"` a diagnostic column).
BARE_LITERAL_ALLOWLIST = frozenset({"—", "…", "·", "?", "— (sim)", "robot", "bluetooth", "default"})


def is_prose(body: str) -> bool:
    """Three letters is where a placeholder stops being a glyph and starts being a word."""
    return body not in BARE_LITERAL_ALLOWLIST and len(re.findall(r"[A-Za-z]", body)) >= 3


# Only the targets that link `ReachyDesign` can spell `.reachy(_:)`; the rest
# (`ReachyKit`, `ReachySSH`, …) carry plain English by construction, and their
# fallbacks are not a rule-9 failure.
BARE_LITERAL_ROOTS = (
    pathlib.Path("Sources/ReachyDesign"),
    pathlib.Path("Sources/ReachyUI"),
    pathlib.Path("Sources/ReachyWidgetUI"),
    pathlib.Path("Apps"),
)


def bare_literals() -> list[str]:
    """`path:line: "…"` for every literal handed straight to a SwiftUI text slot."""
    found: list[str] = []
    for path in swift_sources():
        if not any(path.is_relative_to(root) for root in BARE_LITERAL_ROOTS):
            continue
        source = strip_comments(path.read_text(encoding="utf-8"))
        for match in BARE_LITERAL.finditer(source):
            body = next(group for group in match.groups() if group is not None)
            if is_prose(body):
                found.append(f"{path}:{source.count(chr(10), 0, match.start()) + 1}: {body!r}")
    return found


def symbol(key: str) -> str:
    """Approximate the Swift symbol `xcstringstool` derives from a key.

    Alphanumeric runs, camel-cased — which is enough to reproduce both
    collisions this repository has actually hit ("Bluetooth is switched off"
    against "…off.", and "Starting" against "Starting…"). It is an
    approximation of a tool we cannot run on Linux, so it may over-report; a
    false positive costs one copy edit, a false negative costs a red build on a
    Mac, and that asymmetry is the right way round.
    """
    parts = re.findall(r"[A-Za-z0-9]+", key)
    if not parts:
        return "_"
    return parts[0][:1].lower() + parts[0][1:] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def emit(catalogue: dict) -> str:
    """The catalogue's canonical text.

    Key *order* is the file's own and is deliberately preserved rather than
    sorted. The seeded file is byte-sorted with five case-insensitive
    exceptions — the fingerprint of entries Xcode's editor inserted into a
    hand-written list — so imposing either single rule would produce a diff
    that the other tool undoes the next time anyone opens the catalogue.
    Formatting is what this normalises; ordering is left alone.
    """
    lines = ["{", f'  "sourceLanguage": {json.dumps(catalogue["sourceLanguage"])},', '  "strings": {']
    entries = []
    for key, value in catalogue["strings"].items():
        body = json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True)
        body = body.replace("\n", "\n    ")
        entries.append(f"    {json.dumps(key, ensure_ascii=False)}: {body}")
    lines.append(",\n".join(entries))
    lines.append("  },")
    lines.append(f'  "version": {json.dumps(catalogue["version"])}')
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    fix = "--fix" in argv
    report = "--report" in argv
    for arg in argv[1:]:
        if arg not in ("--fix", "--report"):
            print(f"usage: {argv[0]} [--fix] [--report]", file=sys.stderr)
            return 2

    failures: list[str] = []
    notes: list[str] = []

    loaded: dict[pathlib.Path, dict] = {}
    for path in CATALOGUES:
        if not path.exists():
            failures.append(f"{path}: missing")
            continue
        text = path.read_text(encoding="utf-8")
        catalogue = json.loads(text)
        loaded[path] = catalogue

        # 3. Canonical form.
        canonical = emit(catalogue)
        if canonical != text:
            if fix:
                path.write_text(canonical, encoding="utf-8")
                notes.append(f"{path}: rewritten in canonical form")
            else:
                failures.append(f"{path}: not in canonical form — run check-catalogue.py --fix")

        # 2. Completeness.
        for language in LANGUAGES:
            untranslated = [
                key
                for key, entry in catalogue["strings"].items()
                if not (entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value"))
            ]
            if untranslated:
                failures.append(f"{path}: {len(untranslated)} keys with no {language} translation")
                if report:
                    for key in untranslated[:20]:
                        failures.append(f"      {key!r}")

    if CODE_CATALOGUE in loaded:
        keys = set(loaded[CODE_CATALOGUE]["strings"])
        plain, interpolating, non_literal = scan()

        # 1. Coverage.
        missing, stale = sorted(plain - keys), sorted(keys - plain)
        if missing:
            failures.append(f"{CODE_CATALOGUE}: {len(missing)} keys used in code but absent — they ship in English")
            if report:
                for key in missing:
                    failures.append(f"      {key!r}")
        if stale:
            failures.append(f"{CODE_CATALOGUE}: {len(stale)} keys with no call site left — dead copy")
            if report:
                for key in stale:
                    failures.append(f"      {key!r}")

        # 4. Collisions, over what the catalogue will hold.
        groups: dict[str, list[str]] = {}
        for key in keys | plain:
            groups.setdefault(symbol(key), []).append(key)
        for name, clashing in sorted(groups.items()):
            if len(clashing) > 1:
                failures.append(
                    f"{CODE_CATALOGUE}: keys {sorted(clashing)} all derive `{name}` — "
                    "xcstringstool fails the build over this. Fix the copy, not the tooling."
                )

        # 5. Bare literals.
        bare = bare_literals()
        if bare:
            failures.append(
                f"{len(bare)} bare literals bypass `.reachy(_:)` — route them through it, "
                "or `Text(verbatim:)` for something a reader never translates"
            )
            for site in bare[: 20 if report else 5]:
                failures.append(f"      {site}")

        # A `.reachy(_:)` whose argument is not a literal cannot be checked at
        # all, so it is reported rather than asserted: rule 9 expects literals.
        if non_literal:
            failures.append(f"{len(non_literal)} `.reachy(…)` call sites take a non-literal key: {non_literal}")

        notes.append(
            f"{len(plain)} plain keys in code, {len(interpolating)} interpolating "
            f"(absent by design — see Sources/ReachyDesign/AGENTS.md)"
        )

    for note in notes:
        print(f"  {note}")
    if failures:
        print("Catalogue check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    total = sum(len(c["strings"]) for c in loaded.values())
    print(f"Catalogue OK: {total} keys across {len(loaded)} catalogues, {', '.join(LANGUAGES)} complete")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
