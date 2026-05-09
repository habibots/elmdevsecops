#!/usr/bin/env bash
# Pre-push pre-flight check. Run from inside any of the 4 repos before `git push`.
# Exits 0 if safe; exits non-zero if you should investigate.
set -uo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not in a git repo." >&2; exit 2; }
REPO_NAME=$(basename "$REPO")
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")

echo "=== Preflight: $REPO_NAME ==="
echo "  branch: $BRANCH"

# 1. Not on main
if [[ "$BRANCH" == "main" ]]; then
  echo "  ✗ HEAD is on main. Switch to devops or a feature branch first."
  exit 1
fi
echo "  ✓ not on main"

# 2. main matches remote (no local changes leaked to main)
if git rev-parse origin/main >/dev/null 2>&1; then
  if [[ "$(git rev-parse main 2>/dev/null)" == "$(git rev-parse origin/main)" ]]; then
    echo "  ✓ local main matches origin/main"
  else
    echo "  ✗ local main has diverged from origin/main — INVESTIGATE"
    git log --oneline origin/main..main 2>/dev/null
    exit 1
  fi
else
  echo "  ⚠ no origin/main yet (acceptable for meta-repo before first push)"
fi

# 3. Working tree clean
if [[ -n "$(git status --porcelain)" ]]; then
  echo "  ⚠ uncommitted changes:"
  git status --short
  echo "    (commit or stash before pushing)"
  exit 1
fi
echo "  ✓ working tree clean"

# 4. Have you run /security-review for this branch?
LATEST_REVIEW=$(ls -1t .security-reviews/PR-${BRANCH}-*.md 2>/dev/null | head -1)
if [[ -z "$LATEST_REVIEW" ]]; then
  echo "  ⚠ no .security-reviews/PR-${BRANCH}-*.md found — consider running /security-review in Claude Code"
else
  echo "  ✓ security review exists: $LATEST_REVIEW"
fi

# 5. Pre-push hook installed?
if [[ -x .git/hooks/pre-push ]]; then
  if grep -q "Direct push to '\$protected_branch' is blocked" .git/hooks/pre-push 2>/dev/null; then
    echo "  ✓ pre-push hook (main-protection) installed"
  else
    echo "  ⚠ .git/hooks/pre-push exists but doesn't appear to be the main-protection hook"
  fi
else
  echo "  ⚠ no .git/hooks/pre-push hook installed — copy from tools/git-hooks/pre-push"
fi

echo "  ✓ preflight OK — safe to push"
