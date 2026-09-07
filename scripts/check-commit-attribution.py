#!/usr/bin/env python3
"""Reject attribution trailers and known AI identities before committing."""
import argparse
import re
import subprocess
import sys
from pathlib import Path

TRAILER = re.compile(r"^\s*(?:co-authored-by|claude-session)\s*:", re.I | re.M)
AI_IDENTITY = re.compile(r"\b(?:claude|anthropic|codex|copilot|openai)\b", re.I)


def git(*args):
    return subprocess.check_output(["git", *args], text=True)


def violations(message, author, committer):
    errors = []
    if TRAILER.search(message):
        errors.append("Co-Authored-By and Claude-Session trailers are not allowed")
    for role, identity in (("author", author), ("committer", committer)):
        if AI_IDENTITY.search(identity):
            errors.append(f"{role} must not use a known AI identity: {identity.strip()}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--message-file", type=Path)
    group.add_argument("--range", dest="revision_range")
    args = parser.parse_args()
    failed = False
    if args.message_file:
        records = [("pending commit", args.message_file.read_text(),
                    git("var", "GIT_AUTHOR_IDENT"), git("var", "GIT_COMMITTER_IDENT"))]
    else:
        records = []
        for sha in git("rev-list", args.revision_range).splitlines():
            author, committer, message = git(
                "show", "-s", "--format=%an <%ae>%x00%cn <%ce>%x00%B", sha
            ).split("\0", 2)
            records.append((sha, message, author, committer))
    for label, message, author, committer in records:
        for error in violations(message, author, committer):
            print(f"{label}: {error}", file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
