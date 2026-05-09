#!/usr/bin/env bash
# Verifies that `main` has not been touched in any of the 4 repos.
# Exits 0 if all clean; exits 1 with details if any repo has drift.
set -uo pipefail

REPOS=(
  "/Users/uspharoh/Projects/elmdevsecops"
  "/Users/uspharoh/Projects/elmdevsecops/GlobalManagement"
  "/Users/uspharoh/Projects/elmdevsecops/sacred-portal-wellness"
  "/Users/uspharoh/Projects/elmdevsecops/antiphazeprod"
)

FAIL=0

printf "%-45s %-9s %-18s %-8s %s\n" "REPO" "BRANCH" "MAIN_MATCHES_ORIGIN" "AHEAD" "DIRTY"
printf "%-45s %-9s %-18s %-8s %s\n" "----" "------" "-------------------" "-----" "-----"

for r in "${REPOS[@]}"; do
  name=$(basename "$r")
  if [[ ! -d "$r/.git" ]]; then
    printf "%-45s %s\n" "$name" "MISSING (.git not found)"
    FAIL=1
    continue
  fi
  cd "$r"

  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
  main_local=$(git rev-parse --verify main 2>/dev/null || echo "")
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    main_remote=$(git rev-parse --verify origin/main)
    has_remote=1
  else
    main_remote=""
    has_remote=0
  fi
  ahead=$(git rev-list --count main..devops 2>/dev/null || echo "?")
  dirty=$(git status --porcelain | wc -l | tr -d ' ')

  if [[ "$has_remote" == "0" ]]; then
    main_status="N/A (no remote)"
  elif [[ "$main_local" == "$main_remote" ]]; then
    main_status="YES"
  else
    main_status="NO — DRIFT"
    FAIL=1
  fi

  if [[ "$branch" != "devops" && "$branch" != "DETACHED" ]]; then
    branch_marker="$branch ⚠"
  else
    branch_marker="$branch"
  fi

  if [[ "$dirty" != "0" ]]; then
    dirty_marker="$dirty changes ⚠"
  else
    dirty_marker="clean"
  fi

  printf "%-45s %-9s %-18s %-8s %s\n" "$name" "$branch_marker" "$main_status" "$ahead" "$dirty_marker"
done

echo
if [[ "$FAIL" == "0" ]]; then
  echo "✓ All repos isolated. main is unchanged. Safe to continue working on devops."
  exit 0
else
  echo "✗ One or more repos have drift. Investigate before pushing."
  exit 1
fi
