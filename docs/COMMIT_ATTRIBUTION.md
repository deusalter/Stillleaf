# Commit attribution

Stillleaf does not accept `Co-Authored-By` or `Claude-Session` trailers, or known AI identities as commit authors or committers. Do not add AI attribution footers to PR descriptions. These metadata rules do not identify whether code was written with AI assistance.

## Local setup

Run `scripts/install-git-hooks.sh` once per clone. Python 3 is required. The installer refuses to replace a configured hook directory or hide existing executable hooks. Git worktrees share the clone's local configuration, but the checked-out branch must contain `.githooks` and its checker.

The `commit-msg` hook rejects forbidden trailers case-insensitively and checks Git's effective author and committer, including environment overrides. The checker also accepts `--range origin/main..HEAD` to inspect commits already created. A clean-message amend can retain an old author: explicitly correct the author when repairing that case.

AI agent instructions and settings (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.agents/`) stay out of the repository and are ignored. Keep them in your local checkout. To stop Claude Code adding attribution, put this in a local `.claude/settings.json`:

```json
{"attribution": {"commit": "", "pr": "", "sessionUrl": false}}
```

Local settings and hooks are convenience guards: `--no-verify`, plumbing commands, amended authors, or changing hooks can evade them.

## GitHub enforcement

The `commit-attribution` job inspects every PR commit's message, author, and committer, plus the PR title and body. It runs through `pull_request_target`, using the base branch's workflow, without checking out or executing PR code. A PR cannot disable its own check by changing the workflow. PRs exceeding the API's commit-list limit fail closed.

After the workflow reaches `main`, require the `commit-attribution` check from GitHub Actions, require a pull request, and apply protection to administrators as well. Keep the existing required checks. Reopen existing PRs to trigger the new workflow if needed. These protections gate `main`; they do not reject bad metadata on feature-branch pushes. Review changes to the workflow itself before merging them.

The GitHub API rejected a native commit-message ruleset during setup. A native metadata restriction, where supported, can additionally reject commits when pushed. The proposed rule is case-insensitive and forbids lines beginning with `Co-Authored-By:` or `Claude-Session:`.

The PR check cannot validate a final squash/merge message edited after the check runs. Keep that message free of attribution. Known-name detection is not a universal AI detector, and these checks are not identity verification.

For a stronger boundary, run agents with a repository-scoped credential that can write contents and PRs but cannot administer the repository or bypass protections. Keep owner credentials and SSH keys out of that agent environment. A restricted token provides no isolation if an agent can also read unrestricted credentials on the same machine. Settings cannot make a fully privileged local agent tamper-proof.

Existing history is unaffected. Cleaning old attribution is a separate history-rewrite operation.
