#!/usr/bin/env python3
"""Prüft, ob alle übersetzbaren Texte der App eine englische Übersetzung haben.

Die deutschen Texte im Code sind zugleich die Schlüssel in `Localizable.strings`.
Gesucht werden Texte in typischen SwiftUI-Aufrufen (Text, Button, Label, …) sowie in
`String(localized: …)`. Interpolationen wie `\\(count)` werden – wie von Swift – in
Platzhalter umgewandelt (`%lld` für Zahlen, `%@` für Text).

Aufruf: python3 scripts/check_localization.py [--list]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "Sources" / "ExifDataManager", ROOT / "Sources" / "ExifCore"]
STRINGS = ROOT / "Resources" / "Localization" / "en.lproj" / "Localizable.strings"

# Ein Swift-String-Literal, auch mit Interpolationen, die selbst Anführungszeichen enthalten.
LITERAL = r'"((?:\\\((?:[^()]|\((?:[^()])*\))*\)|[^"\\]|\\.)*)"'

# Aufrufe, deren erstes Text-Argument übersetzt wird.
CONTEXT = re.compile(
    r'(?:\bText|\bButton|\bLabel|\bToggle|\bSection|\bPicker|\bDatePicker|\bLabeledContent|'
    r'\bTextField|\bContentUnavailableView|\.help|\bMarker|\bCommandMenu|\.alert|'
    r'String\(localized:|prompt:\s*Text|description:\s*Text|placeholder:|title:)\s*\(?\s*'
    r'(?:[^"()]*\?\s*)?' + LITERAL
)
ANY_LITERAL = re.compile(LITERAL)

# Interpolationen, die Zahlen sind (alles andere wird %@).
NUMERIC = re.compile(r'count|added|failed|done|number|renamed|skipped|removed', re.IGNORECASE)
SKIP = {"%lld", "%@?", "OK", "EXIF Data Manager", "?", ""}


def to_key(literal: str) -> str:
    def repl(match):
        expr = match.group(1)
        return "%lld" if NUMERIC.search(expr) else "%@"
    key = re.sub(r'\\\(((?:[^()]|\([^()]*\))*)\)', repl, literal)
    return key.replace('\\n', '\n').replace('\\"', '"')


def keys_in_source():
    found = {}
    for base in SOURCES:
        for path in sorted(base.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for lineno, line in enumerate(text.splitlines(), 1):
                if line.strip().startswith("//"):
                    continue
                stripped = line.strip()
                literals = [m.group(1) for m in CONTEXT.finditer(line)]
                # Ternär-Ausdrücke mit LocalizedStringKey: alle Literale der Zeile bzw.
                # Fortsetzungszeilen, die mit „? "“ oder „: "“ beginnen.
                if "as LocalizedStringKey" in line or re.match(r'^[?:]\s*"', stripped):
                    literals += [m.group(1) for m in ANY_LITERAL.finditer(line)]
                for literal in literals:
                    key = to_key(literal)
                    if key in SKIP or not re.search(r"[A-Za-zÄÖÜäöüß]{2,}", key):
                        continue
                    found.setdefault(key, f"{path.relative_to(ROOT)}:{lineno}")
    return found


def parse_strings(path):
    text = path.read_text(encoding="utf-8")
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    unescape = lambda s: s.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')
    return {unescape(k): unescape(v) for k, v in pairs}


def main():
    source = keys_in_source()
    if "--list" in sys.argv:
        for key, where in source.items():
            print(f"{where}\t{key!r}")
        return
    translations = parse_strings(STRINGS)
    missing = {k: w for k, w in source.items() if k not in translations}
    for key, where in missing.items():
        print(f"FEHLT: {where}: {key!r}")
    for key, value in translations.items():
        if key.count("%") != value.count("%"):
            print(f"PLATZHALTER passen nicht: {key!r} -> {value!r}")
            missing[key] = "placeholder"
    print(f"{len(source)} Texte im Code, {len(translations)} Übersetzungen, {len(missing)} Probleme")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
