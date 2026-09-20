#!/usr/bin/env bash
# Fail make check when a call site bypasses SnapKit or AlertController, or when
# a UI library reaches the daemon. Fila's check, cut down to what Xrash has.
# The SF Symbol floor is check-symbol-availability.py; the XPC macro grep lives
# in the Makefile.

set -Eeuo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

error() {
    echo "error: $*" >&2
    fail=1
}

search() {
    local pattern="$1"
    shift
    grep -Rn --include='*.swift' -E "$pattern" "$@" 2>/dev/null || true
}

ui_roots=("$root/Xrash")

layout_hits="$(search 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints|[A-Za-z]+Anchor\.constraint\(' "${ui_roots[@]}")"
if [[ -n "$layout_hits" ]]; then
    error "layout must use SnapKit; found NSLayoutConstraint / autoresizing-mask / anchor.constraint:"
    echo "$layout_hits" >&2
fi

alert_hits="$(search 'UIAlertController|UIAlertAction' "${ui_roots[@]}")"
if [[ -n "$alert_hits" ]]; then
    error "alerts must use AlertController; found UIAlertController / UIAlertAction:"
    echo "$alert_hits" >&2
fi

# A share sheet is a popover on an iPad and raises without an anchor.
# `ReportShare.present` is the one place that makes and anchors one.
share_hits="$(search 'UIActivityViewController\(' "${ui_roots[@]}" | grep -v 'Shared/ReportShare\.swift' || true)"
if [[ -n "$share_hits" ]]; then
    error "share sheets go through ReportShare.present, which anchors the popover:"
    echo "$share_hits" >&2
fi

# Every alert card carries a message under its title. An empty or missing
# `message:` is a bare title over a text field, which reads as unfinished.
alert_message_hits="$(perl -0777 -ne '
    while (/\bAlert(?:Input)?ViewController\(([^{]*?)\)\s*\{/sg) {
        my ($args, $offset) = ($1, $-[0]);
        next if $args =~ /\bmessage:\s*+(?!"")/;
        next if $args =~ /^contentViewController:/;
        my $line = 1 + (substr($_, 0, $offset) =~ tr/\n//);
        print "$ARGV:$line: $&\n";
    }' $(find "${ui_roots[@]}" -name '*.swift'))"
if [[ -n "$alert_message_hits" ]]; then
    error "every AlertViewController / AlertInputViewController needs a non-empty message:"
    echo "$alert_message_hits" >&2
fi

delete_icon_hits="$(search '"trash\.slash"' "${ui_roots[@]}")"
if [[ -n "$delete_icon_hits" ]]; then
    error "deletion uses the standard trash symbol:"
    echo "$delete_icon_hits" >&2
fi

# Nothing third-party links into the daemon, and the wire layer it links stays
# Foundation-only.
daemon_hits="$(search '^import (SnapKit|Then|AlertController|SPIndicator|Runestone[A-Za-z]*|MachOKit|LibArchive)' \
    "$root/xrashd" \
    "$root/Packages/XrashKit/Sources/XrashProtocol")"
if [[ -n "$daemon_hits" ]]; then
    error "third-party modules must not link into xrashd or XrashProtocol:"
    echo "$daemon_hits" >&2
fi

if [[ "$fail" -ne 0 ]]; then
    exit 65
fi
echo "ui libraries: SnapKit layout, AlertController alerts, clean daemon"
