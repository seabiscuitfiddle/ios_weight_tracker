#!/usr/bin/env bash
#
# Runs everything CI runs, locally on a Mac:
#
#     ./scripts/run-tests.sh
#
# The package tests, then the app and widget build plus their tests on a simulator. Picks an
# installed simulator by UDID rather than by name, for the same reason CI does — a name-based
# destination breaks whenever the installed device set changes.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

bold=$(tput bold 2>/dev/null || true)
plain=$(tput sgr0 2>/dev/null || true)
step() { printf '\n%s==> %s%s\n' "$bold" "$1" "$plain"; }

# Same order CI uses: the cheapest check that can fail the build runs first. A leaked team ID
# or key is worth knowing about before waiting out a simulator run.
step "Secret scan"
if ! ./scripts/check-secrets.sh; then
    exit 1
fi

step "Package tests"
if ! swift test; then
    echo "Package tests failed." >&2
    exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
    step "Skipping app build"
    echo "  The app and widget need macOS and Xcode. Package tests above are the whole story here."
    exit 0
fi

if [ ! -d Tally.xcodeproj ]; then
    step "Generating project"
    # Sourced first so a local .env reaches the generated project, exactly as bootstrap does.
    # shellcheck source=scripts/load-env.sh
    source scripts/load-env.sh
    xcodegen generate || exit 1
fi

step "Choosing a simulator"
udid=$(xcrun simctl list devices available --json | python3 -c '
import json, sys

runtimes = json.load(sys.stdin)["devices"]
candidates = []
for runtime, devices in runtimes.items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            candidates.append((runtime, device["name"], device["udid"]))

if not candidates:
    sys.exit("no available iPhone simulator found — install one in Xcode › Settings › Platforms")

candidates.sort()
runtime, name, udid = candidates[-1]
print(udid)
print(f"  using {name}", file=sys.stderr)
') || exit 1

step "App and widget build + tests"
set -o pipefail
xcodebuild \
    -project Tally.xcodeproj \
    -scheme TallyApp \
    -destination "platform=iOS Simulator,id=$udid" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build test 2>&1 | (xcbeautify 2>/dev/null || cat)
