#!/bin/sh
set -eu
cd "$(git rev-parse --show-toplevel)"
existing=$(git config --get core.hooksPath || true)
if [ -n "$existing" ] && [ "$existing" != .githooks ]; then
    echo "Existing core.hooksPath=$existing; integrate the attribution hook there first." >&2
    exit 1
fi
hooks=$(git rev-parse --git-path hooks)
if [ -z "$existing" ] && [ -d "$hooks" ]; then
    for hook in "$hooks"/*; do
        case "$hook" in *.sample) continue ;; esac
        if [ -f "$hook" ] && [ -x "$hook" ]; then
            echo "Existing active hook $hook; integrate it before changing hooksPath." >&2
            exit 1
        fi
    done
fi
git config --local core.hooksPath .githooks
echo 'Installed Stillleaf commit attribution hook for this clone.'
