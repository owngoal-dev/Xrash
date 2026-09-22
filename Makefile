# Xrash Xcode build and custom firmware Debian packaging (roothide + rootless)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/Xrash.xcodeproj
SCHEME              := Xrash
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/xrash-deriveddata
APP_BUNDLE          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/Xrash.app
DAEMON_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/xrashd
SIMULATOR_APP       := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Xrash.app
SIMULATOR           ?= booted
PACKAGE_ID          ?= wiki.qaq.xrash
KIT_PACKAGE         := $(ROOT_DIR)/Packages/XrashKit
PROJECT_OBJECT_VERSION := 77

# FLAVOR selects the bootstrap layout the .deb is built for:
#   roothide - files ship at rootful paths; roothide's dpkg relocates them into
#              the randomized bootstrap root. Architecture iphoneos-arm64e.
#   rootless - files ship under /var/jb, the fixed rootless prefix (Dopamine,
#              palera1n rootless, ...). Architecture iphoneos-arm64.
# The Mach-O slices are identical for both; only the layout differs.
FLAVOR              ?= roothide
ifeq ($(FLAVOR),roothide)
INSTALL_PREFIX      :=
DEFAULT_ARCHITECTURE := iphoneos-arm64e
else ifeq ($(FLAVOR),rootless)
INSTALL_PREFIX      := /var/jb
DEFAULT_ARCHITECTURE := iphoneos-arm64
else
$(error FLAVOR must be roothide or rootless, got '$(FLAVOR)')
endif
PACKAGE_ARCHITECTURE ?= $(DEFAULT_ARCHITECTURE)
CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
BASE_CONFIG         := $(CONFIG_DIR)/Base.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
base_xcconfig_setting = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(BASE_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
BUILD_NUMBER        := $(call xcconfig_setting,CURRENT_PROJECT_VERSION)
MINIMUM_IOS_VERSION := $(call base_xcconfig_setting,IPHONEOS_DEPLOYMENT_TARGET)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
MAC_DAEMON_LOADER   := $(ROOT_DIR)/Scripts/mac-daemon.sh
MAC_PACKAGER        := $(ROOT_DIR)/Scripts/package-mac.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
DEB_VERIFIER        := $(ROOT_DIR)/Scripts/verify-deb.sh
FLOOR_AUDIT         := $(ROOT_DIR)/Scripts/audit-ios-floor.sh
SYMBOL_CHECK        := $(ROOT_DIR)/Scripts/check-symbol-availability.py
ACCESSIBILITY_CHECK := $(ROOT_DIR)/Scripts/check-accessibility.py
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/Xrash.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/Xrashd.entitlements
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/wiki.qaq.xrashd.plist

# The vphone is the custom firmware virtual iPhone: rootless, reached through
# `iproxy $(VPHONE_PORT) 22 -u <udid>` that the developer keeps running.
VPHONE_PORT         ?= 2222
VPHONE_HOST         ?= mobile@127.0.0.1

XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY="" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif
ifeq ($(BUILD_NUMBER),)
$(error CURRENT_PROJECT_VERSION is missing from Configuration/Version.xcconfig)
endif

.PHONY: all help print-version print-build-number print-deb-path print-mac-zip-path print-flavor set-version bump-build check harness build sim deb deb-roothide deb-rootless deb-all audit-floor vphone mac-app mac-daemon mac-daemon-uninstall mac-run mac-zip-check mac-zip clean

all: deb-all

help:
	@echo "Xrash:"
	@echo "  harness     Run the XrashKit tests on macOS (no device)"
	@echo "  check       Validate the Xcode project and packaging inputs"
	@echo "  build       Build the unsigned Xrash.app and xrashd for iPhoneOS"
	@echo "  sim         Debug build onto the booted simulator (no daemon there)"
	@echo "  deb         Build, ad-hoc sign, and package the .deb for FLAVOR (default roothide)"
	@echo "  deb-all     Package both the roothide and the rootless .deb"
	@echo "  audit-floor Audit the built products against the deployment floor"
	@echo "  vphone      Package rootless and install it on the vphone over iproxy"
	@echo "  mac-run     Build the Mac Catalyst app, load xrashd as a LaunchAgent, open the app"
	@echo "  mac-app     Build the Mac Catalyst app only"
	@echo "  mac-daemon  Build xrashd for macOS and (re)load it as a per-user LaunchAgent"
	@echo "  mac-daemon-uninstall  Unload and remove the macOS LaunchAgent"
	@echo "  mac-zip     Build, sign, and zip the distributable macOS app"
	@echo "  mac-zip-check  Validate the macOS packaging inputs"
	@echo "  set-version Write VERSION=x.y.z [BUILD=n] into Configuration/Version.xcconfig"
	@echo "  clean       Remove Xrash derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

print-mac-zip-path:
	@echo "$(MAC_ZIP_OUTPUT)"

print-flavor:
	@echo "$(FLAVOR)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3 [BUILD=42]" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)" $(BUILD)

# Every build gets its own number, so a device can say which build it runs.
# CI is exempt: it builds and publishes the commit's own number, and a bump
# there would ship an artifact that disagrees with the commit that was tested.
bump-build:
	@if [ -n "$${CI:-}" ]; then echo "==> CI: keeping build $(BUILD_NUMBER)"; else \
		"$(VERSION_APPLIER)" "$(APP_VERSION)" $$(( $(BUILD_NUMBER) + 1 )) >/dev/null; \
		echo "==> build $$(( $(BUILD_NUMBER) + 1 ))"; fi

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: Xrash.xcodeproj is missing" >&2; exit 66; }
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@for script in "$(DEB_PACKAGER)" "$(VERSION_APPLIER)" "$(DEB_VERIFIER)" "$(FLOOR_AUDIT)" "$(SYMBOL_CHECK)" "$(ACCESSIBILITY_CHECK)" "$(MAC_PACKAGER)" "$(MAC_DAEMON_LOADER)" "$(ROOT_DIR)/Scripts/sign-frameworks.sh" "$(ROOT_DIR)/Scripts/check-ui-libraries.sh" "$(ROOT_DIR)/Scripts/check-localization.sh"; do \
		test -x "$$script" || { echo "error: $$script is not executable" >&2; exit 66; }; \
	done
	@for xcconfig in Version Base Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@test -x "$(ROOT_DIR)/Scripts/collect-licenses.py" || { echo "error: collect-licenses.py is not executable" >&2; exit 66; }
	@grep -qF 'collect-licenses.py' "$(PROJECT)/project.pbxproj" \
		|| { echo "error: the Collect Licenses build phase is missing from the Xrash target; the Licenses page would be empty" >&2; exit 65; }
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 1.2.3, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: CURRENT_PROJECT_VERSION must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@[[ "$(MINIMUM_IOS_VERSION)" =~ ^[0-9]+\.[0-9]+$$ ]] || { echo "error: IPHONEOS_DEPLOYMENT_TARGET must look like 15.0, got '$(MINIMUM_IOS_VERSION)'" >&2; exit 65; }
	@grep -qE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) =' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: versions must live in Configuration/Version.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -q 'IPHONEOS_DEPLOYMENT_TARGET' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: deployment target must live in Configuration/Base.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -Fq "Depends: firmware (>= $(MINIMUM_IOS_VERSION))" "$(CONTROL_TEMPLATE)" \
		|| { echo "error: Debian firmware dependency must match iOS $(MINIMUM_IOS_VERSION)" >&2; exit 65; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION) so Xcode 16+ and the CI runner can read it, got '$$objver' (newer Xcode rewrites it on save)" >&2; exit 65; }
	@hits="$$(grep -rnE 'XPC_(TYPE|ERROR)_[A-Z]|XPC_ARRAY_APPEND' --include='*.swift' "$(ROOT_DIR)/Xrash" "$(ROOT_DIR)/xrashd" "$(ROOT_DIR)/Packages" 2>/dev/null || true)"; \
		if [[ -n "$$hits" ]]; then \
			echo "error: XPC SDK macros named in Swift link libswiftXPC.dylib, which iOS 15 does not have; use XrashXPC (Packages/XrashKit/Sources/XrashProtocol/XrashXPC.swift), which reads them through the CXrashXPC shim:" >&2; \
			echo "$$hits" >&2; exit 65; \
		fi
	@"$(SYMBOL_CHECK)" "$(MINIMUM_IOS_VERSION)" "$(ROOT_DIR)/Xrash" "$(KIT_PACKAGE)/Sources"
	@"$(ACCESSIBILITY_CHECK)" "$(ROOT_DIR)/Xrash" "$(KIT_PACKAGE)/Sources"
	@"$(ROOT_DIR)/Scripts/check-ui-libraries.sh"
	@"$(ROOT_DIR)/Scripts/check-localization.sh"
	@plutil -lint "$(ENTITLEMENTS)" "$(DAEMON_ENTITLEMENTS)" "$(LAUNCH_DAEMON)"
	@for key in KeepAlive RunAtLoad; do \
		/usr/libexec/PlistBuddy -c "Print :$$key" "$(LAUNCH_DAEMON)" >/dev/null 2>&1 \
			&& { echo "error: xrashd is on-demand; the launchd plist must not set $$key" >&2; exit 65; } || true; \
	done
	@for hook in postinst prerm postrm; do \
		sh -n "$(ROOT_DIR)/Packaging/DEBIAN/$$hook"; \
		grep -nE '[A-Za-z0-9_@]2>' "$(ROOT_DIR)/Packaging/DEBIAN/$$hook" \
			&& { echo "error: $$hook has a word glued to a redirect" >&2; exit 65; } || true; \
		grep -q 'uicache' "$(ROOT_DIR)/Packaging/DEBIAN/$$hook" \
			&& { echo "error: $$hook must not call uicache; uikittools triggers register the app" >&2; exit 65; } || true; \
	done
	@targets="$$(xcodebuild -project "$(PROJECT)" -list)"; \
	grep -F "xrashd" <<<"$$targets" >/dev/null; \
	grep -F "Xrash" <<<"$$targets" >/dev/null
	@# The Mac product's own inputs. Kept behind the same command so the two
	@# platforms cannot drift; `mac-zip-check` still stands alone for a Mac
	@# that has Xcode and none of the device toolchain.
	@$(MAKE) --no-print-directory mac-zip-check

harness:
	swift test --package-path "$(KIT_PACKAGE)"

# CI runs the harness as its own job beside the compile (SKIP_HARNESS=1) and
# releases only when both pass; locally the harness still gates every build.
build: check $(if $(SKIP_HARNESS),,harness) bump-build
	XCBUILD_LABEL=build-ios $(XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS" \
		build
	@python3 Scripts/check-extracted-strings.py "$(DERIVED_DATA)" "$(CONFIGURATION)-iphoneos"

# There is no LaunchDaemon on the simulator and there cannot be: this exercises
# the unprivileged backend and everything visual.
sim:
	XCBUILD_LABEL=build-sim $(XCODEBUILD_WRAPPER) \
		-project "$(PROJECT)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-skipMacroValidation \
		-skipPackagePluginValidation \
		-configuration Debug \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS Simulator" \
		ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
		build
	xcrun simctl install "$(SIMULATOR)" "$(SIMULATOR_APP)"
	xcrun simctl launch "$(SIMULATOR)" wiki.qaq.xrash

deb: build
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(FLAVOR)" \
		"$(INSTALL_PREFIX)"
	"$(DEB_VERIFIER)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(INSTALL_PREFIX)"

deb-roothide:
	@$(MAKE) --no-print-directory deb FLAVOR=roothide

deb-rootless:
	@$(MAKE) --no-print-directory deb FLAVOR=rootless

deb-all: deb-roothide deb-rootless

# The four static floor audits over what was actually built. Run after `build`.
audit-floor:
	"$(FLOOR_AUDIT)" "$(MINIMUM_IOS_VERSION)" "$(APP_BUNDLE)" "$(DAEMON_BINARY)"

# ---------------------------------------------------------------------------
# Mac Catalyst development harness (AGENTS.md, "The Mac product")
#
# The whole stack off-device: xrashd built for macOS and loaded as a per-user
# LaunchAgent through a sidecar plist in ~/Library/LaunchAgents, the app built
# as Mac Catalyst, opened. The backend is still resolved by the handshake —
# nothing here is a build flag; the daemon either answers or the app reads what
# its own user can, which on a Mac is every report either directory holds.
#
# The app is signed with *no* entitlements: a Catalyst app is an iOS-family
# binary and macOS refuses to launch one carrying an entitlement no profile
# granted. The macOS peer policy authenticates by uid and bundle path instead,
# and its harness admission is behind #if DEBUG — which is why the
# configuration is not a knob.
#
# Ad-hoc by default, since that is what every checkout can do. To sign as
# yourself, pass a Developer ID identity — it needs no provisioning profile:
#
#   make mac-run MAC_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
MAC_CONFIGURATION   := Debug
MAC_SIGN_IDENTITY   ?= -
MAC_APP_BUNDLE      := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)-maccatalyst/Xrash.app
MAC_DAEMON_BINARY   := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)/xrashd
MAC_LAUNCH_AGENT    := $(ROOT_DIR)/Packaging/macOS/wiki.qaq.xrashd.plist

MAC_XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY="" \
	ENABLE_DEBUG_DYLIB=NO

mac-app:
	XCBUILD_LABEL=build-mac-app $(MAC_XCODEBUILD) \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		-configuration "$(MAC_CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "platform=macOS,variant=Mac Catalyst" \
		build
	@test -d "$(MAC_APP_BUNDLE)" || { echo "error: $(MAC_APP_BUNDLE) was not built" >&2; exit 66; }
	@# Nested code first (any embedded framework or bundle), then the app.
	@find "$(MAC_APP_BUNDLE)/Contents" -type d \( -name '*.framework' -o -name '*.appex' \) -print0 2>/dev/null \
		| xargs -0 -n1 -I{} codesign --force --sign "$(MAC_SIGN_IDENTITY)" --timestamp=none "{}"
	codesign --force --sign "$(MAC_SIGN_IDENTITY)" --timestamp=none "$(MAC_APP_BUNDLE)"
	@# A bundle rebuilt and re-signed in place can leave LaunchServices with a
	@# stale registration, and `open` then fails with "Launchd job spawn
	@# failed" while running the executable directly works. Re-register it.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(MAC_APP_BUNDLE)"
	@echo "Built and signed $(MAC_APP_BUNDLE)"

mac-daemon:
	XCBUILD_LABEL=build-mac-daemon $(MAC_XCODEBUILD) \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		-configuration "$(MAC_CONFIGURATION)" \
		-scheme xrashd \
		-destination "platform=macOS" \
		build
	"$(MAC_DAEMON_LOADER)" install "$(MAC_DAEMON_BINARY)" "$(MAC_LAUNCH_AGENT)"

mac-daemon-uninstall:
	"$(MAC_DAEMON_LOADER)" uninstall

mac-run: mac-daemon mac-app
	open "$(MAC_APP_BUNDLE)"

# ---------------------------------------------------------------------------
# Distributable macOS build (`make mac-zip`)
#
# A different path from `make mac-run` on purpose. The harness above loads a
# DerivedData binary through a sidecar plist in ~/Library/LaunchAgents; this one
# produces a self-contained app that carries its helper inside the bundle and
# registers it with SMAppService on first launch. The two must never both be
# loaded — they share the label wiki.qaq.xrashd, and SMAppService answers
# kSMErrorInvalidSignature when it finds a job it does not own. Run
# `make mac-daemon-uninstall` before testing a zip.
#
# Deliberately not a dependency of `check`, and it does not depend on it
# either: `check` requires the device toolchain (ldid, dpkg-deb), and a Mac with
# nothing but Xcode has to be able to cut this zip.
#
#   make mac-zip MAC_ZIP_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#                MAC_NOTARY_PROFILE=xrash-notary
MAC_RELEASE_CONFIGURATION := Release
MAC_ARCHS           ?= arm64 x86_64
MAC_ZIP_IDENTITY    ?= -
MAC_NOTARY_PROFILE  ?=
MAC_APP_ENTITLEMENTS    := $(ROOT_DIR)/Packaging/macOS/Xrash.entitlements
MAC_DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/macOS/Xrashd.entitlements
MAC_AGENT_PLIST     := $(ROOT_DIR)/Packaging/macOS/wiki.qaq.xrashd.agent.plist
MAC_ZIP_APP_BUNDLE  := $(DERIVED_DATA)/Build/Products/$(MAC_RELEASE_CONFIGURATION)-maccatalyst/Xrash.app
MAC_ZIP_DAEMON      := $(DERIVED_DATA)/Build/Products/$(MAC_RELEASE_CONFIGURATION)/xrashd
MAC_ZIP_OUTPUT      ?= $(ROOT_DIR)/build/Packages/Xrash-$(APP_VERSION)-macos.zip

mac-zip-check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v codesign >/dev/null || { echo "error: codesign is required" >&2; exit 69; }
	@command -v ditto >/dev/null || { echo "error: ditto is required" >&2; exit 69; }
	@test -x "$(MAC_PACKAGER)" || { echo "error: package-mac.sh is not executable" >&2; exit 66; }
	@test -x "$(MAC_DAEMON_LOADER)" || { echo "error: mac-daemon.sh is not executable" >&2; exit 66; }
	@plutil -lint "$(MAC_AGENT_PLIST)" "$(MAC_LAUNCH_AGENT)" "$(MAC_APP_ENTITLEMENTS)" "$(MAC_DAEMON_ENTITLEMENTS)"
	@# BundleProgram is how the agent finds the helper inside the bundle, and
	@# the label is what SMAppService and mac-daemon.sh both address.
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$(MAC_AGENT_PLIST)")" == "Contents/MacOS/xrashd" ]] \
		|| { echo "error: the bundled agent's BundleProgram must be Contents/MacOS/xrashd" >&2; exit 65; }
	@for plist in "$(MAC_AGENT_PLIST)" "$(MAC_LAUNCH_AGENT)"; do \
		[[ "$$(/usr/libexec/PlistBuddy -c 'Print :Label' "$$plist")" == "wiki.qaq.xrashd" ]] \
			|| { echo "error: $$plist must carry the label wiki.qaq.xrashd" >&2; exit 65; }; \
		for key in KeepAlive RunAtLoad; do \
			/usr/libexec/PlistBuddy -c "Print :$$key" "$$plist" >/dev/null 2>&1 \
				&& { echo "error: xrashd is on-demand; $$plist must not set $$key" >&2; exit 65; } || true; \
		done; \
	done
	@# The App Sandbox is unsupported here, not merely unused: Background Task
	@# Management refuses a sandboxed app's unsandboxed SMAppService job, and
	@# the reports live outside any container.
	@for ent in "$(MAC_APP_ENTITLEMENTS)" "$(MAC_DAEMON_ENTITLEMENTS)"; do \
		if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$$ent" >/dev/null 2>&1; then \
			echo "error: $$ent declares com.apple.security.app-sandbox; the app cannot be sandboxed" >&2; \
			exit 65; \
		fi; \
	done

mac-zip: mac-zip-check
	XCBUILD_LABEL=build-mac-zip-app $(MAC_XCODEBUILD) \
		ARCHS="$(MAC_ARCHS)" ONLY_ACTIVE_ARCH=NO \
		-configuration "$(MAC_RELEASE_CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "platform=macOS,variant=Mac Catalyst" \
		build
	XCBUILD_LABEL=build-mac-zip-daemon $(MAC_XCODEBUILD) \
		ARCHS="$(MAC_ARCHS)" ONLY_ACTIVE_ARCH=NO \
		-configuration "$(MAC_RELEASE_CONFIGURATION)" \
		-scheme xrashd \
		-destination "platform=macOS" \
		build
	"$(MAC_PACKAGER)" \
		"$(MAC_ZIP_APP_BUNDLE)" \
		"$(MAC_ZIP_DAEMON)" \
		"$(MAC_AGENT_PLIST)" \
		"$(MAC_APP_ENTITLEMENTS)" \
		"$(MAC_DAEMON_ENTITLEMENTS)" \
		"$(MAC_ZIP_OUTPUT)" \
		"$(APP_VERSION)" \
		"$(MAC_ZIP_IDENTITY)" \
		"$(MAC_NOTARY_PROFILE)"

# Rootless package onto the vphone. Needs `iproxy $(VPHONE_PORT) 22 -u <udid>`
# running; root login is refused there, so dpkg goes through sudo as mobile.
vphone:
	@$(MAKE) --no-print-directory deb FLAVOR=rootless
	@deb="$$($(MAKE) --no-print-directory print-deb-path FLAVOR=rootless)"; \
	scp -P "$(VPHONE_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$$deb" "$(VPHONE_HOST):/var/mobile/xrash.deb"; \
	ssh -t -p "$(VPHONE_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$(VPHONE_HOST)" \
		'sudo dpkg -i /var/mobile/xrash.deb && rm -f /var/mobile/xrash.deb'

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
