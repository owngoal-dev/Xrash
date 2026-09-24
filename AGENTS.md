# Xrash — Agent Notes

Crash reporter and symbolicator for custom firmware iOS 15.0+ — roothide and
rootless bootstraps both — and the same app built for **Mac Catalyst**, where
the helper ships inside the bundle. On the device the app runs as `mobile`;
with the privileged backend, the bundled `xrashd` LaunchDaemon does the
privileged half as root. Without that backend, the app still works under its
own OS permissions.

The single idea the design hangs off: `xrashd` opens files and does not read
them. It lists the report directories, opens a report, a binary or a dyld
shared cache file as root and hands the descriptor back over XPC; parsing,
symbolication and everything that allocates happen in the app. The daemon is
on-demand — no `KeepAlive`, no `RunAtLoad` — and exits when idle.

## Notifications

The crash reporter posts no event when a report is written (OSAnalytics has no
`notify_post` for it; checked 2026-09-21), so the directory changing is the
event: `WatchPaths` in the daemon's plist has launchd start `xrashd` for it,
which is still on-demand. `ReportAnnouncer` lists, `NoticeLedger` (XrashNotice,
tested on the Mac) decides what is new, `NoticePoster` posts *as the app*
through `UNUserNotificationCenter(bundleIdentifier:)` — the daemon carries
`usernotifications.bundle-identifiers` for it — and the process idles out.

- **The daemon has no settings.** The app sends a `NoticePolicy` (switch,
  filter, unread count) over `setNoticePolicy` whenever one changes. A daemon
  that takes it announces everything, app running or not, and the app then
  posts nothing; `refused` (the Mac's agent) or `invalidRequest` (an older
  daemon) leaves the app announcing on its own. Same identifier — the report's
  path — on both sides.
- **Root still does not read.** The line under the title comes from the report,
  so the daemon opens it with the same guards as `openReport` and spawns itself
  as `xrashd describe`: the child becomes `mobile` for good before it reads
  descriptor 3, decodes and answers with a clamped `NoticeDetail` on stdout,
  against a deadline.
- **A crash is two lines**: `Fila Crashed` over
  `EXC_CRASH (SIGABRT) · 0.2.0 (43)`, the list row's words from
  `Report.reason`. `threadIdentifier` is the process name, so a crash loop is
  one stack.
- **No sender icon.** A communication notification (`INSendMessageIntent`)
  does draw the crashed app's icon with Xrash's as the badge, but the image
  travels as an `intents-remote-image-proxy:` reference, and neither image
  data nor a file URL from the daemon resolves in SpringBoard — the grey
  silhouette is what shows (tried 2026-09-21). Not worth a server.
- **Keys the daemon posts are keys the app spells.** Title and kind are
  `localizedUserNotificationString` keys resolved against the app's catalogue;
  `CrashNotice.post` and `ReportFormat.kindLabel` are where the compiler
  extracts them.
- **`willPresent` shows a report the list has not met.** The daemon's
  notification can beat the app's own refresh.

## Hard rules

- **One app, several wrappers, and the backend is resolved at runtime.** Never a
  build flag, never a compilation condition, never a per-packaging source
  variant. The handshake with the daemon is the only honest answer to "am I
  privileged", and it carries the install root rather than a boolean beside it.
- **The daemon's absence is never surfaced as an error.** A miss means launchd
  has not started it yet. Keep retrying, keep saying *Connecting…*, and fall
  back only after a grace period measured as a duration from the first miss —
  not a timeout, not a count of attempts. `xrashd` is on-demand: `make check`
  and both packaging scripts fail on `KeepAlive` or `RunAtLoad` in its plist.
- **Peer authentication happens before the first request is decoded.** Audit
  token, euid 0 or 501, the client entitlement and `no-sandbox`, then the
  executable on disk (root-owned, not group/world writable). Require
  `platform-application` only if the app actually carries it — match both
  sides.
- **No install prefix is written in Swift.** Derive it from the daemon's own
  `proc_pidpath`; anything that needs it asks the daemon. Packaging fails on
  `libvroot` in the app, daemon or helper.
- **Every path is canonicalised before a decision is made about it.**
  `realpath(3)` first, then compare components; reject an embedded NUL first.
- **Start `ExecutableWatch` once, early in `didFinishLaunching`.** When the
  opened executable loses its last hard link, offer Later or Quit with wording
  covering both update and removal. Keep the registration-time check and the
  cancellation guard; the callback runs once on the main queue. Do not watch
  daemons: postinst restarts them after unpacking finishes. Omit this watch
  for a self-updating installer whose helper owns completion and exit.
- **A cold launch starts with no saved scenes.** `main.swift` deletes this
  bundle's `Library/Saved Application State/<id>.savedState` before
  `UIApplicationMain`. UIKit reads that archive before any scene delegate
  runs; leftover sessions from a previous UI framework or Info.plist restore
  the old delegate. Background resumes do not run `main`. Preferences stay.
  The app delegate is not `@main`.
- **Versions and the deployment target live in `Configuration/*.xcconfig`
  only.** `make check` rejects either in `project.pbxproj`.
- **No project generators.** `project.pbxproj` is hand-written; `objectVersion`
  is pinned and `make check` fails when Xcode rewrites it.
- **No Swift file names the SDK's XPC constant macros.** They come from the C
  shim `Packages/XrashKit/Sources/CXrashXPC` through `XrashXPC`; naming them in
  Swift links a dylib that iOS 15 does not have. `make check` greps for them.
- **No SF Symbol newer than `IPHONEOS_DEPLOYMENT_TARGET`.** It draws nothing on
  the floor and warns nowhere. `make check` checks it against CoreGlyphs.
- **No new dependency without a reason that survives the ladder**: what it
  replaces, and why the hand-written version would be worse rather than merely
  longer. Nothing third-party links into the daemon.
- **The Licenses screen is generated, not written.** The app target's
  **Collect Licenses** build phase runs `Scripts/collect-licenses.py`
  (Irisin's, scanned discipline), which writes `Licenses.json` into the app
  bundle from the repository `LICENSE`, every pin in `Package.resolved`
  (checkouts and binary artifacts, nested notices included) and any vendored
  source under `Packages/`. A pin with no notice or GPL-family text fails the
  build. Vendored code keeps its upstream `LICENSE` beside it and its header
  on each file; MIT / BSD / Apache only. `make check` requires the phase,
  `verify-deb.sh` requires the file. Read the generated list after adding a
  dependency.
- **No absolute build path in a shipped binary.** `#file` is concise
  (`SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE`, prefix maps in `Base.xcconfig`);
  the packager greps every binary for the repository root and fails on a hit.
- **User-facing text is a `String.LocalizationValue` spelled out in English**,
  resolved against `Localizable.xcstrings`. No `NSLocalizedString`, no
  `SHOUTING_KEY` identifiers; `make check` greps for both. Pick one catalogue
  discipline and keep it: compiler `.stringsdata` with no `extractionState`,
  or unseen keys kept as `manual` and pruned by hand.
- **A cell that writes its own `accessibilityLabel` sets
  `isAccessibilityElement`.** UIKit reads the label off a view only when that
  view is an accessibility element, and a cell with subviews is not one by
  default: the sentence the cell assembled is walked past and its subviews are
  read instead, one stop each. Nothing warns, and six of this app's rows were
  silent that way — five since they were written, the sixth copied from one of
  them. `Scripts/check-accessibility.py` (platformize-app-ios', copied
  unchanged) fails `make check` on the next one. The flag hides every subview,
  so a row that owns a control offers it as a `UIAccessibilityCustomAction`
  instead; `RowMenuAction` is the one shape a row's menu is built from, for the
  finger and for the rotor both.

## Layout

```
Xrash/               the app: main.swift (manual UIApplicationMain), Application/,
                     Interface/<feature>/, Resources/ (AppIcon.icon, Assets, strings)
xrashd/              the root LaunchDaemon, product `xrashd`; links XrashProtocol only
Packages/XrashKit/   everything testable on a Mac: CXrashXPC (C shim over the XPC
                     macros), XrashProtocol (wire + service names), and the report,
                     symbolication and bundle modules as they land
Configuration/       Version.xcconfig, Base.xcconfig, Development/Release
Packaging/           DEBIAN/{control,postinst,prerm,postrm}, entitlements, launchd plist,
                     macOS/ (Catalyst entitlements, the bundled agent plist and
                     the harness sidecar)
Scripts/             package-deb.sh, verify-deb.sh, sign-frameworks.sh,
                     run-xcodebuild.sh, apply-version.sh, package-mac.sh,
                     mac-daemon.sh, the two floor gates
Documents/Site/      Pages source: index.html, icon.png, depiction.json
manifest.json        the owngoal-packages entry
```

The app icon is `Xrash/Resources/AppIcon.icon` (Icon Composer): a red fill with
a white SF Rounded X in light, a dark fill with a red X in dark, and the white
X for tinted. There is no `AppIcon.appiconset`; actool emits the fallback PNGs.

## The Mac product

The same app, built for Mac Catalyst, carrying its helper inside the bundle:
`Contents/MacOS/xrashd`, launched by
`Contents/Library/LaunchAgents/wiki.qaq.xrashd.plist` and registered with
`SMAppService` on first launch (`Xrash/Services/MacLaunchAgent.swift`). A
per-user LaunchAgent, not a root daemon, and nothing gates on it: a Mac's
reports are readable by the logged-in user already. The backend is still the
handshake.

- **Nothing on the Mac is signed with an entitlement.** A Catalyst app is an
  iOS-family binary and macOS refuses to launch one carrying an entitlement no
  profile granted, so the macOS peer policy admits by uid and bundle path —
  the app beside the helper in `Contents/MacOS`. Ad-hoc `-` unless a
  `Developer ID` identity is passed in; never a `DEVELOPMENT_TEAM`.
- **The harness and the zip are two paths and must never both be loaded.**
  `make mac-daemon` drops a sidecar plist in `~/Library/LaunchAgents` pointing
  at a DerivedData binary; `make mac-zip` cuts the self-contained app. They
  share the label `wiki.qaq.xrashd`, and `SMAppService` answers
  `kSMErrorInvalidSignature` when it finds a job it does not own. Run
  `make mac-daemon-uninstall` before testing a zip.
- **Login Items is where a Mac's helper stalls,** waiting for a person to allow
  it. Nothing in the app says so any more: Settings has no Service section,
  whatever the helper's state (owner's call, 2026-09-21), and the app reads
  what the user can read without it. `MacLaunchAgent.status` still knows.
- **`LSSupportsOpeningDocumentsInPlace` is `true`.** macOS does not support
  `NO` and warns; no build setting may contradict the plist. Everything that
  takes an external URL brackets it with
  `start/stopAccessingSecurityScopedResource` and copies what it keeps.
- **User-facing words are right on both platforms or they are wrong.** Neutral
  wording, never a per-platform branch: no "this device", no "as root", no
  "iOS version" in a sentence a Mac will also read.

## Build & verify

- `make harness` — the package tests on the Mac. Run this first.
- `make check` — project and packaging validation, including the floor greps.
- `make build` — unsigned app + daemon for iPhoneOS.
- `make sim` — Debug onto the simulator; no LaunchDaemon there and there cannot be.
- `make deb` / `make deb-all` — roothide and rootless packages, verified.
- `make mac-app` — the Mac Catalyst app, signed ad-hoc and re-registered.
- `make mac-daemon` / `make mac-daemon-uninstall` — `xrashd` for macOS, loaded
  and unloaded as a per-user LaunchAgent from the sidecar plist.
- `make mac-run` — both of those, then open the app.
- `make mac-zip-check` / `make mac-zip` — the macOS packaging inputs, and the
  signed, zipped app. `make check` runs `mac-zip-check`; `mac-zip` needs
  nothing but Xcode, so it stands alone.
- `make audit-floor` — the static floor audits over the built app and daemon.
- `make vphone` — rootless package installed on the vphone over `iproxy 2222 22`
  (`sudo dpkg -i` as `mobile`; root login is refused there).

The build scripts and Makefile started from Inspector's (smallest
on-demand daemon) with the CLI removed; `sign-frameworks.sh` is Fila's.

Give every parallel worker its own `DERIVED_DATA=/private/tmp/<name>` — spelled
`/private/tmp`, never `/tmp`, or a package manifest that strips its own
checkout path finds no headers.

## Package Pages

`Documents/Site/depiction.json` is the native depiction page. Keep its Details
copy accurate and use the largest banner referenced by the README as
`headerImage`. The Pages workflow refreshes its Changelog from published GitHub
releases using the shared updater pinned in that workflow; never maintain a
second changelog implementation or edit generated release notes by hand.
The copied publishing workflow must be named `Release` so Pages refreshes after
it succeeds. Deploy from `main`, including when an older release is edited.

Keep the `uikittools` dependency: its triggers register and unregister the app.
Maintainer hooks manage the daemon only; never add explicit `uicache` calls.

That trigger is `uicache -a`, which registers only what is not registered yet.
A package manager re-registers an upgrade itself; a bare `dpkg -i` over an
installed copy does not, and LaunchServices keeps the previous build's
Info.plist — version, document types, URL schemes, every key SpringBoard reads
from the record rather than from disk. After installing by hand, run
`uicache -p <prefix>/Applications/Xrash.app` in the terminal, and respring if
SpringBoard has to read it again. When a plist or entitlement change "does not
take", check the record's `CFBundleVersion` against the bundle's before
anything else.

## Where things get tested

The Mac harness first, the simulator for the visuals, `make mac-run` for the
macOS half, a vphone or a custom firmware device for anything privileged, and
the four floor audits (or an actual device) for the oldest OS this app claims.
Report which of those actually ran.

## Gotchas that bit us

- **A hook that exits 0 with the wrong launchctl label.** A rename replaced
  `/<placeholder> ` and dropped the trailing space, leaving
  `bootout system/wiki.qaq.xrashd2>/dev/null` — valid sh. The hooks now assign
  `label=wiki.qaq.xrashd` once on its own line; `make check`,
  `verify-deb.sh` and the XrashKit tests all reject an id next to a redirect.
- **MachOKit's symbol iterator traps on a real dyld cache.** It casts every
  `n_value` to `Int`; one entry above `Int.max` kills the app, and a test
  capped at four images never meets one. `SystemSymbolStore` reads the nlist
  bytes itself. `XRASH_FULL_CACHE=1 swift test` runs the whole cache.
- **`DSYMStore` reads Mach-O and does not unpack.** Every release attaches a
  zip; `DSYMImport` (the app) unpacks through `BundleArchive.extractZip` for
  both the Files import and the GitHub one. `XRASH_DSYM_DIR=<folder>` runs the
  store against a real release's symbols.
- **A Kit error needs its words in the app.** The Kit has no catalogue, so an
  `Error` enum without a `LocalizedError` conformance reaches an alert as
  "SymbolStoreFailure error 0". The conformances sit beside `DSYMImport`.
- **A red accent tints a split view's primary column.** The column is a
  material and the selected row an accent fill; the list sets an opaque
  grouped background and its rows name their colours in both states.
- **One share sheet, one anchor.** `ReportShare.present` is the only place a
  `UIActivityViewController` is made; `make check` rejects another. Without a
  source view it raises on an iPad.
- **Notifications take two declarations, and the prompt appearing proves
  neither.** A platform binary is refused by `usernotificationsd` without
  `com.apple.private.usernotifications.bundle-identifiers` naming its own id;
  a system app gets no data provider from SpringBoard — *Allow* is tapped and
  authorization still comes back false — without `SBAppUsesLocalNotifications`
  in the Info.plist LaunchServices holds. Both say so in the device log under
  the bundle id.
- **Run `make check` after Xcode has had the project open.** It rewrites
  `objectVersion` on save, silently, and a commit made from a terminal that
  checked earlier carries it.

## Interface shape

Wide: `ReportsSplitViewController` — the report list beside the open report,
two columns and never three; Saved, Symbols and Settings are 555×555 form
sheets off the list's ••• menu (`presentAsFormSheet`, the only place a sheet
is sized — the welcome passes Irisin's own 520×620 and turns the detents off,
which leaves it a plain page sheet on a phone). A sheet presented from inside a
sheet — the welcome from Settings — is never given a size: UIKit resizes a
nested form sheet on every push, so it keeps the system's own. Narrow: the same controller's
`.compact` column is
`RootTabBarController`, four tabs. A report's Summary / Details / Raw switch
is the *View As* submenu at the top of its ••• menu, its subtitle the current
choice; the share formats and *Reveal in Fila* are the *Report File* submenu.
The bar title is the process name.
`LoadBudget` holds a screen back for its first data (1 s at launch, 200 ms per
page) so it comes up finished and un-animated.

## Localization

Fila's discipline: compiler-extracted keys, no `extractionState`, thirteen
languages, every one `translated`. `Scripts/apply-translations.py` builds the
catalogue from the extracted key set and one `{key: translation}` JSON per
language, checking placeholders; the English value is a copy of the key.

## Facts observed on the vphone (2026-09-21)

- Reports live in `/var/mobile/Library/Logs/CrashReporter`: the directory is
  `mobile:_analyticsusers 0770`, the files are `root:_analyticsusers 0660`.
  The app can list but not open them; that open is what `xrashd` is for.
- Most entries are not `*.ips`: 52 of 66 ended in `.synced`
  (`Name-date.ips.synced`, `Analytics-….ips.ca.synced`). A scanner that
  matches only `.ips` misses four reports in five. `Retired/`,
  `DiagnosticLogs/` and `Assistant/` are subdirectories.
- Every `.ips` there had `"bug_type":"309"` on its first line; a
  `panic-full-*` report sat in the same directory.
- The dyld shared cache is split: `/System/Library/Caches/com.apple.dyld/
  dyld_shared_cache_arm64e` plus `.01`, `.02`, … subcaches, all `root 0755`.
- The cache directory is not one place. dyld's own
  `dyld_shared_cache_file_path()` said
  `/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/` on the vphone
  and `/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/` on
  a roothide iPad8,9 running 18.5 (22F76), where none of the other spellings
  exist. `SystemSymbolStore.sharedCacheURL` asks dyld first; the directory
  lists are the fallback and the daemon's allow-list. `mobile` opens the
  files directly on both.
- `xrashd` bootstraps into `system/` and sits `state = not running` until a
  Mach lookup; the app launches from `/var/jb/Applications/Xrash.app`.
