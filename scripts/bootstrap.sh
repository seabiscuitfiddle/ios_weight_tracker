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

if xcodebuild -version >/dev/null 2>&1; then
    ok "$(xcodebuild -version | head -1)"
else
    fail "Xcode not found. Install it from the App Store, then run:
      sudo xcode-select --switch /Applications/Xcode.app"
fi

if command -v xcodegen >/dev/null 2>&1; then
    ok "XcodeGen $(xcodegen --version 2>/dev/null | tr -d '\n')"
else
    fail "XcodeGen not found. Install it with:  brew install xcodegen"
fi

if [ "$problems" -gt 0 ]; then
    printf '\n%sInstall the missing tools above, then run this again.%s\n' "$bold" "$plain"
    exit 1
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

prefix=$(grep -E '^\s*BUNDLE_ID_PREFIX:' project.yml | head -1 | sed 's/.*: *//' | tr -d '"')
team=$(grep -E '^\s*DEVELOPMENT_TEAM:' project.yml | head -1 | sed 's/.*: *//' | tr -d '"')

if [ "$prefix" = "com.example" ]; then
    note "Bundle prefix is still the placeholder '$prefix'. Fine for the simulator. To run on a
    device, set BUNDLE_ID_PREFIX in project.yml to something you own, then re-run this script."
else
    ok "Bundle prefix: $prefix"
fi

if [ -z "$team" ]; then
    note "DEVELOPMENT_TEAM is empty. Fine for the simulator. For a device, set it in project.yml
    to your 10-character Apple Developer Team ID (Xcode › Settings › Accounts)."
else
    ok "Development team: $team"
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
