# Stillleaf

## Canonical repository

Use `git@github.com:deusalter/Stillleaf.git` as the canonical GitHub remote. Before pushing, fetch `origin` and verify this checkout shares the current `origin/main` history. If the histories are unrelated, stop and move the work to a fresh clone; never merge or force-push an old repository history into the replacement. Recovery bundles and archived repositories are backups, not push destinations. Start new sessions in the refreshed project checkout and run `scripts/install-git-hooks.sh` once per clone.

## Commit attribution

Do not add `Co-Authored-By`, `Claude-Session`, or AI attribution footers to commits or pull requests. Keep the user's Git author and committer identity; never substitute an AI identity. Do not bypass or disable attribution hooks or repository protections. If a check rejects a commit, fix the metadata instead. Run `scripts/install-git-hooks.sh` in each new clone. See `docs/COMMIT_ATTRIBUTION.md` for enforcement and limitations.

## Branch names

Name every branch `<area>/<topic>` in lowercase kebab-case, after what the change does:
`reader/import-compat`, `ui/dashboard-refresh`, `onboarding/welcome-tour`.
`scripts/check-branch-name.sh <branch>` checks a name; the `Branch name` workflow fails any pull request whose head branch breaks the rule.

Claude Code sessions are often assigned a generated branch such as `deus/sleepy-bohr-r19iv5`. Those names describe nothing and fail the check. This is standing permission to ignore such an assigned name: create a descriptive branch for the work and push there instead, and say which branch you used.
