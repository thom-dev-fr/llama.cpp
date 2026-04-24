#!/usr/bin/env bash
# Pull the latest upstream llama.cpp master and merge it into the current branch.
# The fork only owns files under apple/, a single guarded block in CMakeLists.txt,
# and Package.swift. Conflicts should be rare and isolated.
#
# Usage:
#   ./apple/scripts/sync-upstream.sh [--remote upstream] [--branch master]

set -euo pipefail

REMOTE="upstream"
BRANCH="master"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) REMOTE="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! git remote | grep -q "^${REMOTE}$"; then
    echo "Remote '${REMOTE}' is not configured." >&2
    echo "Add it with: git remote add ${REMOTE} https://github.com/ggml-org/llama.cpp.git" >&2
    exit 1
fi

echo "Fetching ${REMOTE}/${BRANCH}..."
git fetch "${REMOTE}" "${BRANCH}"

echo "Merging ${REMOTE}/${BRANCH}..."
git merge --no-edit "${REMOTE}/${BRANCH}"

echo "Sync complete. Check the diff in apple/ and rebuild the xcframework if needed."
