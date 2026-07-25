#!/usr/bin/env bash
#
# One-command setup on a Mac:
#
#     ./scripts/bootstrap.sh
#
# Checks the tools, generates Tally.xcodeproj from project.yml, and reports anything that still
# needs a decision from you. It changes nothing except the generated project, and it is safe to
# re-run.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

bold=$(tput bold 2>/dev/null || true)
plain=$(tput sgr0 2>/dev/null || true)
problems=0
notes=0

step()  { printf '\n%s==> %s%s\n' "$bold" "$1" "$plain"; }
ok()    { printf '  ✓ %s\n' "$1"; }
note()  { printf '  • %s\n' "$1"; notes=$((notes + 1)); }
fail()  { printf '  ✗ %s\n' "$1"; problems=$((problems + 1)); }

# ── Tools ────────────────────────────────────────────────────────────────────────────────

step "Checking tools"

if [ "$(uname -s)" != "Darwin" ]; then
    fail "This script sets up the iOS app, which needs macOS. On Linux you can still run the
      package tests: source scripts/dev-env.sh && swift test"
    exit 1
fi

# Xcode 16.3 is the floor, because it is the first Xcode carrying a Swift 6.1 toolchain.
# That floor comes from GRDB rather than from taste: its manifest declares
# swift-tools-version:6.1, and on Swift 6.0 SPM resolves *backwards* to a GRDB release that
# then fails to link (the long version is in Package.swift). Xcode 16.0 through 16.2 ship
# Swift 6.0, so "Xcode 16" is not enough — the version is checked, not just the presence.
#
# Checked here, before anything is generated, because XcodeGen writes the Xcode 16 project
# format (objectVersion 77) and an older Xcode declines to open it with a message about a
# "future Xcode project file format (77)" that never mentions which Xcode would work.
if ! xcodebuild -version >/dev/null 2>&1; then
    fail "Xcode not found. Install it from the App Store, then run:
      sudo xcode-select --switch /Applications/Xcode.app"
else
    swift_version=$(xcrun swift -version 2>/dev/null \
        | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)

    if [ -z "$swift_version" ]; then
        note "Could not read a Swift version out of 'xcrun swift -version', so the toolchain
    could not be checked. Tally needs Xcode 16.3 or newer (Swift 6.1). Continuing anyway."
    elif [ "${swift_version%%.*}" -lt 6 ] ||
         { [ "${swift_version%%.*}" -eq 6 ] && [ "${swift_version##*.}" -lt 1 ]; }; then
        fail "$(xcodebuild -version | head -1) is too old — it ships Swift $swift_version.
      Tally needs Swift 6.1, which means Xcode 16.3 or newer.

      Update Xcode from the App Store — note that Xcode 16.3+ itself requires macOS 15
      (Sequoia). If you keep several Xcodes installed, point the tools at the new one:
        sudo xcode-select --switch /Applications/Xcode.app"
    else
        ok "$(xcodebuild -version | head -1) (Swift $swift_version)"
    fi
fi

if command -v xcodegen >/dev/null 2>&1; then
    ok "XcodeGen $(xcodegen --version 2>/dev/null | tr -d '\n')"
else
    fail "XcodeGen not found. Install it with:  brew install xcodegen"
fi

if [ "$problems" -gt 0 ]; then
    printf '\n%sFix the tool problems above, then run this again.%s\n' "$bold" "$plain"
    exit 1
fi

# ── Local configuration ──────────────────────────────────────────────────────────────────

step "Loading configuration"

# Must happen before xcodegen: XcodeGen substitutes ${DEVELOPMENT_TEAM} and ${BUNDLE_ID_PREFIX}
# from the environment as it generates, which is how account-specific values reach the build
# without ever being written to a tracked file.
# shellcheck source=scripts/load-env.sh
source scripts/load-env.sh

if [ -f .env ]; then
    ok "Read .env"
else
    note "No .env yet. The simulator needs none, so this is fine. For a device:
      cp .env.example .env, fill it in, and re-run this script."
fi

# ── Guard against leaking any of it ───────────────────────────────────────────────────────

# Installed rather than merely offered: the values this repository must not carry are easy to
# add back by accident — a team ID pasted into project.yml to "just try it" is the usual way.
# --no-verify still bypasses it, deliberately; the hook is a safety net, not a lock.
if [ -d .git ] && [ ! -e .git/hooks/pre-commit ]; then
    cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/bootstrap.sh. Blocks commits carrying account-specific values.
exec "$(dirname "$0")/../../scripts/check-secrets.sh" --staged
HOOK
    chmod +x .git/hooks/pre-commit
    ok "Installed the pre-commit secret check"
elif [ -e .git/hooks/pre-commit ]; then
    ok "pre-commit hook already present"
fi

# ── Generate the project ─────────────────────────────────────────────────────────────────

step "Generating Tally.xcodeproj"
# Not committed on purpose: a .pbxproj is unreviewable and merges badly, so it is rebuilt from
# project.yml instead. Re-run this after adding or removing source files.
if xcodegen generate; then
    ok "Tally.xcodeproj is up to date"
else
    fail "xcodegen failed — see the output above"
    exit 1
fi

# ── Things only you can decide ───────────────────────────────────────────────────────────

step "Checking configuration"

# Reported from the environment, which is where these now come from. The fallback prefix is
# project.yml's own build setting, so it is read from there rather than assumed.
prefix=${BUNDLE_ID_PREFIX:-$(grep -E '^\s*BUNDLE_ID_PREFIX:' project.yml | head -1 | sed 's/.*: *//' | tr -d '"')}
team=${DEVELOPMENT_TEAM:-}

if [ "$prefix" = "com.example" ]; then
    note "Bundle prefix is still the placeholder '$prefix'. Fine for the simulator. To run on a
    device, set BUNDLE_ID_PREFIX in .env to something you own, then re-run this script."
else
    ok "Bundle prefix: $prefix"
fi

if [ -z "$team" ]; then
    note "DEVELOPMENT_TEAM is empty. Fine for the simulator. For a device, set it in .env to
    your 10-character Apple Developer Team ID (Xcode › Settings › Accounts)."
else
    # Masked: bootstrap output scrolls past in terminals and gets pasted into issues.
    ok "Development team: ${team:0:4}••••••"
fi

if [ -n "${BUNDLE_ID_PREFIX:-}" ] || [ -n "$team" ]; then
    note "Register the App Group 'group.$prefix.tally' in the developer portal and enable App
    Groups on both targets, or the widget silently gets its own empty container."
fi

fonts_found=$(find App/Resources/Fonts -iname 'Archivo*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$fonts_found" = "0" ]; then
    note "Archivo font files are missing, so the app will fall back to the system font and look
    noticeably wrong. Download from https://fonts.google.com/specimen/Archivo and put the .ttf
    files in App/Resources/Fonts/ (see README, 'Fonts')."
else
    ok "Found $fonts_found Archivo font file(s)"
fi

# ── Done ─────────────────────────────────────────────────────────────────────────────────

step "Ready"
printf '  Open the project:      %sxed Tally.xcodeproj%s\n' "$bold" "$plain"
printf '  Or build and test:     %s./scripts/run-tests.sh%s\n' "$bold" "$plain"

if [ "$notes" -gt 0 ]; then
    printf '\n  %s note(s) above — none of them block running on the simulator.\n' "$notes"
fi
