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

# Not a pipeline: `error` has to run in this shell or the `fail` it sets is lost.
forbid() {
    local message="$1" hits="$2"
    [[ -n "$hits" ]] || return 0
    error "$message"
    echo "$hits" >&2
}

ui_root="$root/Xrash"

forbid "layout must use SnapKit; found NSLayoutConstraint / autoresizing-mask / anchor.constraint:" \
    "$(search 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints|[A-Za-z]+Anchor\.constraint\(' "$ui_root")"

forbid "alerts must use AlertController; found UIAlertController / UIAlertAction:" \
    "$(search 'UIAlertController|UIAlertAction' "$ui_root")"

# A share sheet is a popover on an iPad and raises without an anchor.
# `ReportShare.present` is the one place that makes and anchors one.
forbid "share sheets go through ReportShare.present, which anchors the popover:" \
    "$(search 'UIActivityViewController\(' "$ui_root" | grep -v 'Shared/ReportShare\.swift' || true)"

# Even an unknown bundle id can enter IconServices' Core Image compositor and
# crash before returning nil. Icons must come from bundle files instead. Every
# door into it counts: UIKit's icon methods, LSApplicationProxy's icon data, a
# class looked up by name however it is looked up, and the framework itself.
forbid "app icons must be read from bundle files, not rendered through IconServices:" \
    "$(search '_applicationIconImageForBundleIdentifier|_iconForResourceProxy|[iI]conDataForVariant|"IS(Icon|BundleIcon|Compositor|ImageDescriptor)[A-Za-z]*"|IconServices\.framework' "$ui_root")"

# Every alert card carries a message under its title. An empty or missing
# `message:` is a bare title over a text field, which reads as unfinished.
# Kept in a variable: this producer is the one that can fail, and `set -e` only
# sees a command substitution's status when it stands as an assignment.
alert_message_hits="$(perl -0777 -ne '
    while (/\bAlert(?:Input)?ViewController\(([^{]*?)\)\s*\{/sg) {
        my ($args, $offset) = ($1, $-[0]);
        next if $args =~ /\bmessage:\s*+(?!"")/;
        next if $args =~ /^contentViewController:/;
        my $line = 1 + (substr($_, 0, $offset) =~ tr/\n//);
        print "$ARGV:$line: $&\n";
    }' $(find "$ui_root" -name '*.swift'))"
forbid "every AlertViewController / AlertInputViewController needs a non-empty message:" "$alert_message_hits"

forbid "deletion uses the standard trash symbol:" "$(search '"trash\.slash"' "$ui_root")"

# Nothing third-party links into the daemon, and the wire layer it links stays
# Foundation-only.
forbid "third-party modules must not link into xrashd or XrashProtocol:" \
    "$(search '^import (SnapKit|Then|AlertController|SPIndicator|Runestone[A-Za-z]*|MachOKit|ArchiveKit)' \
        "$root/xrashd" \
        "$root/Packages/XrashKit/Sources/XrashProtocol")"

if [[ "$fail" -ne 0 ]]; then
    exit 65
fi
echo "ui libraries: SnapKit layout, AlertController alerts, clean daemon"
