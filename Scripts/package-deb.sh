#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ "$#" -ne 12 ]]; then
    echo "usage: $0 <app> <daemon> <control> <app-entitlements> <daemon-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <flavor> <install-prefix>" >&2
    exit 64
fi

app_bundle="$1"
daemon_binary="$2"
control_template="$3"
app_entitlements="$4"
daemon_entitlements="$5"
launch_plist="$6"
output_deb="$7"
package_id="$8"
version="$9"
architecture="${10}"
flavor="${11}"
install_prefix="${12}"

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" "$launch_plist"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
case "$flavor" in
    roothide) [[ -z "$install_prefix" ]] || { echo "error: roothide packages install at rootful paths" >&2; exit 64; } ;;
    rootless) [[ "$install_prefix" == /var/jb ]] || { echo "error: rootless packages install under /var/jb" >&2; exit 64; } ;;
    *) echo "error: flavor must be roothide or rootless" >&2; exit 64 ;;
esac

case "$architecture:$install_prefix" in
iphoneos-arm64:/var/jb | iphoneos-arm64e:) ;;
*) echo "error: architecture and install prefix name different bootstrap layouts" >&2; exit 64 ;;
esac

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.xrash && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# The app and the daemon make authorization/path decisions on physical paths.
# Rewriting their libc imports independently would change that contract.
for native in "$app_bundle/$app_executable" "$daemon_binary"; do
    if otool -L "$native" | grep -q 'libvroot'; then
        echo "error: $(basename "$native") uses physical paths; unexpected vroot dependency" >&2
        exit 65
    fi
done

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with — refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/xrash-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
app_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/xrash-app-entitlements.XXXXXX.plist")"
daemon_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/xrash-daemon-entitlements.XXXXXX.plist")"
trap 'rm -rf "$staging"; rm -f "$temporary_deb" "$app_signed_entitlements" "$daemon_signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_app="$staging$install_prefix/Applications/Xrash.app"
installed_daemon="$staging$install_prefix/usr/libexec/xrashd"
installed_plist="$staging$install_prefix/Library/LaunchDaemons/wiki.qaq.xrashd.plist"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$app_bundle" "$installed_app"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
sed -e "s|@PREFIX@|$install_prefix|g" "$launch_plist" >"$installed_plist"
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon"
chmod 0644 "$installed_plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/xrashd" ]] || {
    echo "error: launch daemon plist does not point at the installed daemon" >&2
    exit 65
}
# The daemon is on-demand: launchd starts it for a Mach lookup and it exits
# when idle. A KeepAlive or RunAtLoad that slipped in would pin a root process.
for key in KeepAlive RunAtLoad; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$installed_plist" >/dev/null 2>&1; then
        echo "error: launch daemon plist must not set $key" >&2
        exit 65
    fi
done

# Nothing third-party links into the daemon: only the system may appear.
if otool -L "$installed_daemon" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' >/dev/null; then
    echo "error: daemon links a library from outside the system" >&2
    otool -L "$installed_daemon" >&2
    exit 65
fi

for binary in "$installed_app/$app_executable" "$installed_daemon"; do
    /usr/bin/strip -xS "$binary"
    for private_path in "$repository_root" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}"; do
        [[ -z "$private_path" || "$private_path" == / ]] && continue
        if LC_ALL=C grep -aF "$private_path" "$binary" >/dev/null; then
            echo "error: $(basename "$binary") embeds a private build path" >&2
            exit 65
        fi
    done
done

"$repository_root/Scripts/sign-frameworks.sh" "$installed_app"
ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"
ldid -e "$installed_daemon" >"$daemon_signed_entitlements"

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}

# Every boolean key in the entitlement source has to come back out of the
# signed binary: a lost one does not break the build, it makes the daemon
# refuse the app at runtime.
boolean_keys() {
    /usr/bin/plutil -convert json -o - "$1" \
        | /usr/bin/python3 -c 'import json,sys; [print(k) for k,v in json.load(sys.stdin).items() if v is True]'
}
while IFS= read -r entitlement; do
    require_true "$app_signed_entitlements" "$entitlement"
done < <(boolean_keys "$app_entitlements")
while IFS= read -r entitlement; do
    require_true "$daemon_signed_entitlements" "$entitlement"
done < <(boolean_keys "$daemon_entitlements")
for entitlement in platform-application com.apple.private.security.no-sandbox wiki.qaq.xrash.client; do
    require_true "$app_signed_entitlements" "$entitlement"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.xrash.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}

# DEBIAN is still empty at this point, so this measures only the payload.
installed_size="$(du -sk "$staging" | awk '{print $1}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@FLAVOR@/$flavor/g" \
    "$control_template" >"$debian/control"

packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
for script in postinst prerm postrm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$packaging_root/DEBIAN/$script" >"$debian/$script"
    sh -n "$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm" "$debian/postrm"

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]

mv -f "$temporary_deb" "$output_deb"
echo "Packaged Xrash ($flavor): $output_deb"
shasum -a 256 "$output_deb"
