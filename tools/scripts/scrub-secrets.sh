#!/usr/bin/env bash
# Usage: scrub-secrets.sh <repo-path> <path-or-pattern-to-remove> [<replacements-file>]
# Requires: git-filter-repo (brew install git-filter-repo)
set -euo pipefail
REPO_PATH="$1"
TARGET_PATH="$2"
REPLACEMENTS_FILE="${3:-}"

if ! command -v git-filter-repo >/dev/null; then
  echo "git-filter-repo required: brew install git-filter-repo" >&2
  exit 1
fi

cd "$REPO_PATH"
echo "About to rewrite history of $REPO_PATH to remove $TARGET_PATH"
echo "This is destructive. Continue? (yes/no)"
read -r confirm
[[ "$confirm" == "yes" ]] || exit 1

git filter-repo --path "$TARGET_PATH" --invert-paths --force
if [[ -n "$REPLACEMENTS_FILE" && -f "$REPLACEMENTS_FILE" ]]; then
  git filter-repo --replace-text "$REPLACEMENTS_FILE" --force
fi

echo "History rewritten. Now force-push:"
echo "  git push --force --all"
echo "  git push --force --tags"
