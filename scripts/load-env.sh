#!/usr/bin/env bash
#
# Loads the local .env into the environment. Source it, don't run it:
#
#     source scripts/load-env.sh
#     xcodegen generate
#
# Everything account-specific lives in .env, which is gitignored, and reaches the build through
# XcodeGen's ${VAR} substitution rather than through a tracked file. That is the whole point:
# this repository is public, and an Apple Team ID or a personal bundle prefix identifies its
# owner. See .env.example.
#
# Absent or incomplete .env is a supported state, not an error — the simulator needs none of it,
# and project.yml carries safe placeholder defaults.
#
# Safe to source repeatedly.

_env_file="${TALLY_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"

if [ -f "$_env_file" ]; then
    # Read line by line rather than `export $(cat ...)`: a value containing a space or a `#`
    # would otherwise be split or truncated, and an API key is exactly the kind of value that
    # eventually contains something surprising.
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        _key=${_line%%=*}
        _value=${_line#*=}
        # Trim surrounding whitespace on the key, and one layer of quotes on the value.
        _key=$(printf '%s' "$_key" | tr -d '[:space:]')
        case "$_value" in
            \"*\") _value=${_value#\"}; _value=${_value%\"} ;;
            \'*\') _value=${_value#\'}; _value=${_value%\'} ;;
        esac
        # An already-exported value wins, so a one-off `DEVELOPMENT_TEAM=... ./script` and CI's
        # environment both override the file rather than being silently ignored.
        if [ -z "${!_key:-}" ]; then
            export "$_key=$_value"
        fi
    done < "$_env_file"
    unset _line _key _value
fi

unset _env_file

# Exported unconditionally so the two substitution paths can never disagree. XcodeGen replaces
# ${DEVELOPMENT_TEAM} at generation time; with the variable unset it would leave the literal
# text in the project file, and Xcode would then expand it to an empty string anyway — this
# just makes the empty case explicit instead of accidental.
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

# Deliberately not defaulted here. project.yml's own APP_BUNDLE_ID build setting is the
# fallback (com.example.tally), and setting an empty one here would override it with nothing.
if [ -n "${APP_BUNDLE_ID:-}" ]; then
    export APP_BUNDLE_ID
fi
