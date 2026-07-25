#!/usr/bin/env bash
#
# Fails if anything account-specific or secret is about to be committed:
#
#     ./scripts/check-secrets.sh            # scan tracked files
#     ./scripts/check-secrets.sh --staged   # scan what is staged (used by the pre-commit hook)
#
# This repository is public. The values below are not all "secrets" in the password sense — an
# Apple Team ID is not confidential — but each of them identifies a person or an account, and
# once pushed they are in the history for good. Catching them here is much cheaper than a
# history rewrite afterwards.
#
# Runs in CI too, so a leak fails the build rather than depending on anyone remembering to run
# this locally.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

bold=$(tput bold 2>/dev/null || true)
plain=$(tput sgr0 2>/dev/null || true)
findings=0

scope=${1:-}
if [ "$scope" = "--staged" ]; then
    files=$(git diff --cached --name-only --diff-filter=ACM)
    reader() { git show ":$1" 2>/dev/null; }
else
    files=$(git ls-files)
    reader() { cat "$1" 2>/dev/null; }
fi

report() {
    findings=$((findings + 1))
    printf '\n%s✗ %s%s\n' "$bold" "$1" "$plain"
    printf '  %s\n' "$2"
    [ -n "${3:-}" ] && printf '  %s\n' "$3"
}

# A file that should never be tracked at all, whatever it contains.
for path in $files; do
    case "$path" in
        .env|.env.local|.env.*)
            [ "$path" = ".env.example" ] && continue
            report "$path is tracked" \
                "Local configuration must stay out of version control." \
                "Fix: git rm --cached $path"
            ;;
        *.p12|*.p8|*.mobileprovision|Secrets.xcconfig)
            report "$path is tracked" \
                "Signing material never belongs in the repository." \
                "Fix: git rm --cached $path"
            ;;
    esac
done

# The files worth grepping: everything tracked except the two that describe the patterns rather
# than containing them. Filtered here, outside any command substitution — macOS ships bash 3.2,
# which cannot parse a `case` inside `$( )`.
scannable=""
for path in $files; do
    if [ "$path" != "scripts/check-secrets.sh" ] && [ "$path" != ".env.example" ]; then
        scannable="$scannable $path"
    fi
done

# Content patterns. Each is paired with the reason it matters, because a bare regex name in a
# CI log tells the next person nothing.
scan() {
    local label=$1 pattern=$2 advice=$3
    local hits
    hits=$(for path in $scannable; do
        reader "$path" | grep -nEI "$pattern" 2>/dev/null | sed "s|^|$path:|"
    done)
    if [ -n "$hits" ]; then
        report "$label" "$advice" ""
        printf '%s\n' "$hits" | head -10 | sed 's/^/    /'
    fi
}

# Anthropic keys. sk-ant-test and friends are fixtures in the parser tests and are meant to be
# there, so only flag things long enough to be real.
scan "Possible Anthropic API key" \
    'sk-ant-[A-Za-z0-9_-]{20,}' \
    "Keys are entered in-app and stored in the keychain; none should ever be in a file."

# DEVELOPMENT_TEAM with an actual value. The placeholder empty string and the ${DEVELOPMENT_TEAM}
# reference are the two forms that are allowed to appear.
scan "Apple Team ID committed" \
    'DEVELOPMENT_TEAM[[:space:]]*[:=][[:space:]]*"?[A-Z0-9]{10}"?' \
    "Set DEVELOPMENT_TEAM in .env instead — project.yml substitutes it at generation time."

# A concrete App Group or keychain group, rather than the $(APP_GROUP_ID) indirection. This is
# the one that silently ties the public repo to one developer account.
scan "Hardcoded App Group" \
    '<string>group\.[a-zA-Z0-9]' \
    "Entitlements should use \$(APP_GROUP_ID) so every clone gets its own."

# Personal contact details in tracked files. Deliberately narrow: an address in a LICENSE or a
# vendored dependency is normal, so only look at first-party sources.
scan "Email address in a tracked source file" \
    '[a-zA-Z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud|me|proton(mail)?)\.[a-z]{2,}' \
    "Use a role address or a GitHub noreply address rather than a personal one."

if [ "$findings" -gt 0 ]; then
    printf '\n%s%s problem(s) found — nothing was committed.%s\n' "$bold" "$findings" "$plain"
    exit 1
fi

printf 'No secrets or account-specific values found in %s files.\n' \
    "$(printf '%s\n' "$files" | grep -c .)"
