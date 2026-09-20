#!/usr/bin/env bash
# Fail make check when a user-facing string is not something Xcode's extractor
# can see for itself, or when the catalogue drifts from the sibling apps.
#
# Fila's discipline: the catalogue carries no `extractionState`. `manual` means
# "keep this even though I cannot find it", and a catalogue full of `manual`
# keys accumulates orphans invisibly. Without the field, a key that loses its
# last call site is marked `stale` on the next build and someone notices.

set -Eeuo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
catalogue="$root/Xrash/Resources/Localizable.xcstrings"
fail=0

error() {
    echo "error: $*" >&2
    fail=1
}

if [ ! -f "$catalogue" ]; then
    echo "error: Xrash/Resources/Localizable.xcstrings is missing" >&2
    exit 66
fi

# 1. No extraction markers.
if grep -q '"extractionState"' "$catalogue"; then
    error "Xrash/Resources/Localizable.xcstrings carries extraction markers.
    A stale key is either dead — delete it — or its call site hides the literal
    from the extractor; see rule 2. Do not add \"extractionState\" to silence this."
fi

# 2. No bare literal at a `String.LocalizationValue` parameter. These labels are
# AlertController's localized parameters; a literal written straight at one is
# converted implicitly and the extractor records nothing.
labels='title|message|placeholder|cancelButtonText|doneButtonText'
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    error "$hit
    A bare literal here is invisible to Xcode's string extractor.
    Write String.LocalizationValue(\"...\") for an AlertController argument,
    or String(localized: \"...\") for a plain String one."
done < <(
    grep -rlE --include='*.swift' '^import AlertController' "$root/Xrash" 2>/dev/null |
        xargs grep -nE "(^|[( ])($labels): \"[^\"]" 2>/dev/null |
        sed "s|^$root/||" || true
)

# 3. One spelling for localized text, and keys are English sentences.
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    error "$hit
    Use String(localized:) with the English sentence as the key."
done < <(
    grep -rnE --include='*.swift' 'NSLocalizedString|String\(localized: "[A-Z][A-Z0-9]*(_[A-Z0-9]+)+"' \
        "$root/Xrash" "$root/Packages/XrashKit/Sources" 2>/dev/null | sed "s|^$root/||" || true
)

# 3b. Inflection markup is read by AttributedString only; String(localized:)
#     puts `^[1 item](inflect: true)` on screen as written.
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    error "$hit
    Use String(inflecting:) for a phrase carrying inflection markup."
done < <(
    grep -rn --include='*.swift' -B1 'inflect: true' "$root/Xrash" 2>/dev/null |
        grep -E 'localized: ' | sed "s|^$root/||" || true
)

# 4. Every key is translated into every language the sibling apps ship.
python3 - "$catalogue" <<'PY' || fail=1
import json, sys
LANGUAGES = ["ar", "de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "vi", "zh-Hans", "zh-Hant"]
catalogue = json.load(open(sys.argv[1]))
if catalogue.get("sourceLanguage") != "en":
    print("error: sourceLanguage must be en", file=sys.stderr)
    sys.exit(1)

def translated(entry):
    unit = entry.get("stringUnit")
    if unit:
        return unit.get("state") == "translated" and bool(unit.get("value"))
    plural = entry.get("variations", {}).get("plural", {})
    return bool(plural) and all(translated(form) for form in plural.values())

missing = 0
for key, value in sorted(catalogue["strings"].items()):
    if value.get("shouldTranslate") is False:
        continue
    gaps = [code for code in LANGUAGES if not translated(value.get("localizations", {}).get(code, {}))]
    if gaps:
        missing += 1
        print(f"error: \"{key}\" is not translated into: {', '.join(gaps)}", file=sys.stderr)
sys.exit(1 if missing else 0)
PY

if [ "$fail" -ne 0 ]; then
    exit 65
fi
echo "localization: no extraction markers, no unextractable literals, every language translated"
