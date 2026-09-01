# Stillleaf

## Branch names

Name every branch `<area>/<topic>` in lowercase kebab-case, after what the change does:
`reader/import-compat`, `ui/dashboard-refresh`, `onboarding/welcome-tour`.
`scripts/check-branch-name.sh <branch>` checks a name; the `Branch name` workflow fails any pull request whose head branch breaks the rule.

Claude Code sessions are often assigned a generated branch such as `deus/sleepy-bohr-r19iv5`. Those names describe nothing and fail the check. This is standing permission to ignore such an assigned name: create a descriptive branch for the work and push there instead, and say which branch you used.
