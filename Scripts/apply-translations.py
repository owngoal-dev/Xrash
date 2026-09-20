#!/usr/bin/env python3
"""Build Localizable.xcstrings from the extracted keys and one JSON per language.

Translators hand back `<lang>.json`, a flat `{English key: translation}`. This
checks each against the key set, then writes the catalogue in Fila's shape:
every key, every language, `state: translated`, no `extractionState`, and the
English value spelled out as a copy of the key.

    apply-translations.py --verify keys.json <lang>.json...
    apply-translations.py keys.json <catalogue.xcstrings> <lang>.json...

`keys.json` is `{key: anything}`; only its keys are read.
"""

import json
import pathlib
import re
import sys

PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f|%)")


def shape(text):
    """The placeholders of a string, position-independent: sorted types."""
    return sorted(re.sub(r"\d+\$", "", found) for found in PLACEHOLDER.findall(text))


def problems(keys, path):
    language = path.stem
    table = json.loads(path.read_text(encoding="utf-8"))
    found = []
    for key in keys - table.keys():
        found.append(f"{language}: missing {key!r}")
    for key in table.keys() - keys:
        found.append(f"{language}: unknown key {key!r}")
    for key in keys & table.keys():
        value = table[key]
        if not isinstance(value, str) or not value.strip():
            found.append(f"{language}: empty {key!r}")
        elif shape(key) != shape(value):
            found.append(f"{language}: placeholders differ in {key!r} -> {value!r}")
    return table, found


def main(arguments):
    verify_only = arguments[:1] == ["--verify"]
    if verify_only:
        arguments = arguments[1:]
    keys = set(json.loads(pathlib.Path(arguments[0]).read_text(encoding="utf-8")))
    catalogue = None if verify_only else pathlib.Path(arguments[1])
    tables, failed = {}, False
    for name in arguments[1 if verify_only else 2:]:
        path = pathlib.Path(name)
        tables[path.stem], found = problems(keys, path)
        for line in found:
            print(line, file=sys.stderr)
        failed = failed or bool(found)
        if not found:
            print(f"ok {path.stem} {len(keys)}")
    if failed:
        return 1
    if catalogue is None:
        return 0

    def unit(value):
        return {"stringUnit": {"state": "translated", "value": value}}

    strings = {}
    for key in sorted(keys):
        localizations = {"en": unit(key)}
        for language, table in tables.items():
            localizations[language] = unit(table[key])
        strings[key] = {"localizations": dict(sorted(localizations.items()))}
    document = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    # Xcode's own spelling: two spaces, " : " between key and value.
    text = json.dumps(document, ensure_ascii=False, indent=2, separators=(",", " : "))
    catalogue.write_text(text + "\n", encoding="utf-8")
    print(f"wrote {catalogue} ({len(strings)} keys, {len(tables) + 1} languages)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
