<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# Xrash

Read, symbolicate, and share the crash reports on your iPhone, iPad, or Mac. Install Xrash on a supported system environment to open every report the system writes, not only your own app’s.

![Preview](./Documents/banner.png)

## Install

On a supported device, add the OwnGoal Studio repository in your preferred package manager:

**[apt.owngoal.dev](https://apt.owngoal.dev/)**

Packages are also on [GitHub Releases](https://github.com/owngoal-dev/Xrash/releases). Choose the file that matches your bootstrap.

| Installation | Package |
| --- | --- |
| [roothide](https://github.com/roothide) bootstrap | `iphoneos-arm64e` `.deb` |
| Rootless bootstrap (`/var/jb`) | `iphoneos-arm64` `.deb` |
| Mac (Apple silicon or Intel) | `macos` `.zip` |

On a Mac, unzip and move Xrash to Applications. The app is ad-hoc signed, so clear the quarantine flag once with `xattr -dr com.apple.quarantine /Applications/Xrash.app`, then allow its helper in **Login Items** if macOS asks. A Mac’s reports are already readable by you, so the helper there runs as you, not as root.

Requires iOS 15 or later. The `.deb` installs the app together with a small root helper and a launchd job that starts it on demand. The helper opens report files, binaries, and the system symbol cache and hands them to the app; it reads nothing itself, keeps nothing running in the background, and exits when idle. Xrash injects into no process and installs no hooks: it reads what the system already wrote.

## Features

- **Every report**: Crashes, hangs, memory (Jetsam) events, kernel panics, and diagnostics, including the reports the system has already marked as synced. Reports are grouped into Apps, Services, Jetsam, and Others, with search, filters, and sorting.
- **Plain words**: The exception, signal, and termination reason are explained in a sentence, next to the raw codes.
- **Symbolication**: Turn addresses into function names using the binaries on the device and the system’s own symbol cache. Swift and C++ names are demangled. Symbolicate again at any time after adding symbols.
- **Your dSYMs**: Import a `.dSYM` folder or a zip of them to get file names and line numbers for your own code, or pick a tag from a project’s GitHub releases and Xrash downloads the dSYMs published with it. Xrash lists the symbols a recent report is still missing.
- **Suspects**: See which tweak or injected library sits on the crashed thread, the package that installed it, and when. Suspects are ranked with reasons, never given as a bare verdict.
- **Three views**: Switch between a summary, the full classic crash log, and the original file, with find, soft wrap, and text size.
- **Report a crash**: Combine the crash with related reports from other processes — Xrash suggests the ones that belong together — add notes, and export a single `.xrashreport` file containing the reports, a PDF, and optionally the binaries involved. Open a `.xrashreport` on another device to read it exactly as it was filed.
- **Import and export**: Open `.ips` and `.crash` files from Files or another app. Share a report as a crash log, the original file, JSON, or Markdown.
- **Cleanup**: Delete reports one by one, by selection, or all at once, or let Xrash delete reports older than an age you choose.

The interface is available in 13 languages: Arabic, English, French, German, Italian, Japanese, Korean, Portuguese (Brazil), Russian, Simplified Chinese, Spanish, Traditional Chinese, and Vietnamese.

## Using Xrash

Open **Reports** and tap a report. The summary shows what happened, the suspects, and the crashed thread; the report’s ••• menu switches to the full log or the original file. Tap **Symbolicate** to name the frames.

To name system frames in every report, open **Symbols** and extract the system symbols once per system version. To get line numbers for your own app, import its dSYM in the same place; the UUID must match the build that crashed.

To send a crash to a developer, open the report, choose **Report Crash…**, link any related reports, and export. Exported files are kept under **Saved**. Include binaries only when the developer asks for them: they make the file much larger.

## Build from Source

```sh
make check            # project and packaging validation
make harness          # the test suite, on the Mac
make deb-all          # roothide and rootless .deb
make deb              # roothide .deb
make sim              # Debug build onto the booted simulator
make audit-floor      # audit the built products against iOS 15
make vphone           # install the rootless .deb on a vphone over iproxy
make mac-run          # the Mac app and its helper, built and opened
make mac-zip          # the Mac app, signed and zipped
```

`make check` needs xcodebuild, ldid, and dpkg-deb.

Contributor notes are in [AGENTS.md](AGENTS.md).

## License

Xrash is available under the [MIT License](LICENSE).

The `.deb` packages are not for the App Store.

Join the community on [Discord](https://discord.gg/vqhDEep2mN).
