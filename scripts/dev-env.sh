#!/usr/bin/env bash
# Sets up the environment for building the Swift package on Linux.
#
#   source scripts/dev-env.sh && swift test
#
# Two things need arranging on Linux that Xcode handles for free on a Mac:
#
#  1. The Swift toolchain, if it isn't already on PATH. Point SWIFT_TOOLCHAIN at an
#     extracted swift.org tarball, or install one however you prefer.
#  2. SQLite development headers. GRDB compiles against <sqlite3.h>, which Ubuntu ships
#     in `libsqlite3-dev` rather than in the base system. On Apple platforms SQLite comes
#     from the SDK, so this is a Linux-only concern.
#
# The clean fix for (2) is `sudo apt-get install -y libsqlite3-dev`. Where root isn't
# available, this script falls back to a copy of the matching-version headers extracted
# under ~/.local/sqlite-dev (see README, "Building on Linux"). It uses CPATH and
# LIBRARY_PATH rather than -Xcc/-Xlinker flags so that plain `swift build` and
# `swift test` work with no extra arguments.
#
# Safe to source repeatedly; it won't duplicate PATH entries.

# --- Swift toolchain -----------------------------------------------------------------

if ! command -v swift >/dev/null 2>&1; then
    _candidates=(
        "${SWIFT_TOOLCHAIN:-}"
        "$HOME"/swift-toolchain/swift-*-RELEASE-ubuntu*/usr
        /usr/share/swift/usr
    )
    for _candidate in "${_candidates[@]}"; do
        if [ -n "$_candidate" ] && [ -x "$_candidate/bin/swift" ]; then
            export PATH="$_candidate/bin:$PATH"
            break
        fi
    done
    unset _candidates _candidate
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "dev-env: no swift found. Install a toolchain from https://swift.org/download," \
         "or set SWIFT_TOOLCHAIN to an extracted tarball's usr/ directory." >&2
fi

# --- SQLite headers ------------------------------------------------------------------

# Only intervene if the system headers really are missing; a proper libsqlite3-dev
# install should always win.
if [ ! -f /usr/include/sqlite3.h ]; then
    _sqlite_local="$HOME/.local/sqlite-dev"
    if [ -f "$_sqlite_local/extracted/usr/include/sqlite3.h" ]; then
        case ":$CPATH:" in
            *":$_sqlite_local/extracted/usr/include:"*) ;;
            *) export CPATH="$_sqlite_local/extracted/usr/include${CPATH:+:$CPATH}" ;;
        esac
        case ":$LIBRARY_PATH:" in
            *":$_sqlite_local/lib:"*) ;;
            *) export LIBRARY_PATH="$_sqlite_local/lib${LIBRARY_PATH:+:$LIBRARY_PATH}" ;;
        esac
    else
        echo "dev-env: sqlite3.h not found. Run 'sudo apt-get install -y libsqlite3-dev'," \
             "or see README 'Building on Linux' for the no-root fallback." >&2
    fi
    unset _sqlite_local
fi
