#!/bin/bash
# Branch names say what the work is: <area>/<topic>, lowercase kebab-case,
# e.g. reader/import-compat, ui/dashboard-refresh, onboarding/welcome-tour.
set -euo pipefail
branch="${1:?usage: check-branch-name.sh <branch>}"
case "$branch" in
  main|dependabot/*|renovate/*) exit 0 ;;
esac
word='[a-z0-9]+(-[a-z0-9]+)*'
if [[ ! "$branch" =~ ^$word/$word$ ]]; then
  echo "::error::Branch '$branch' must be <area>/<topic> in lowercase kebab-case, e.g. reader/import-compat." >&2
  exit 1
fi
# Generated session names (adjective-name-random, e.g. deus/sleepy-bohr-r19iv5) describe nothing.
topic="${branch#*/}"
if [[ "$topic" =~ ^[a-z]+-[a-z]+-[a-z0-9]{6}$ && "${topic##*-}" =~ [0-9] ]]; then
  echo "::error::Branch '$branch' is an auto-generated name. Rename it after the change, e.g. onboarding/welcome-tour." >&2
  exit 1
fi
