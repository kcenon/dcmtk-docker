#!/usr/bin/env python3
"""Decide whether CI needs Docker; unknown paths conservatively run tests."""
import argparse
import fnmatch
from pathlib import PurePosixPath
import re
import subprocess
import sys


RUNTIME = ("tests/*", "scripts/*", "config/*", "patches/*", "Dockerfile",
           ".dockerignore", "docker-compose*.yml", "pacs.sh", "env.default",
           ".github/workflows/*")


def needs_runtime(paths):
    for path in paths:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in RUNTIME):
            return True
        if path.startswith("docs/") or PurePosixPath(path).suffix.lower() == ".md" or path == "VERSION":
            continue
        return True
    return False


def git(*args):
    return subprocess.check_output(["git", *args])


def is_commit(sha):
    result = subprocess.run(["git", "cat-file", "-e", sha + "^{commit}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def changed_paths(base, head, event):
    for sha in (base, head):
        if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", sha):
            raise ValueError("Expected full commit SHAs for base and head")
    git("cat-file", "-e", head + "^{commit}")
    if event == "push" and set(base) == {"0"}:
        return None  # A new ref has no previous tree; run every suite.
    if event == "push" and not is_commit(base):
        # A branch moved to a commit that does not descend from its old tip
        # (for example develop re-created from main) leaves the old tip out of
        # the fetched history. Running every suite never approves a skip.
        print(f"Push base {base} is not a commit in the fetched history; running every suite.",
              file=sys.stderr)
        return None
    if event == "pull_request":
        base = git("merge-base", base, head).decode().strip()
    data = git("diff", "--no-renames", "--name-only", "-z", base, head, "--")
    return [p.decode("utf-8", errors="surrogateescape") for p in data.split(b"\0") if p]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--event", choices=("pull_request", "push", "workflow_dispatch"), required=True)
    args = parser.parse_args()
    try:
        paths = None if args.event == "workflow_dispatch" else changed_paths(args.base, args.head, args.event)
        runtime = paths is None or needs_runtime(paths)
    except (ValueError, subprocess.CalledProcessError) as exc:
        print(f"Cannot determine changed paths: {exc}", file=sys.stderr)
        return 1
    print("runtime=" + str(runtime).lower())
    return 0


if __name__ == "__main__":
    sys.exit(main())
