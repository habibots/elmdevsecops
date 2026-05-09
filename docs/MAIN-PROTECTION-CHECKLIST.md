# `main` Protection Checklist

**Goal:** ensure `main` never receives a stray commit, push, or merge across all 4 repos. The `devops` branch is the only working branch. `main` only changes via reviewed PR with CI gates passing.

**Before you do anything else: run this verification once now to confirm the current state.**

```bash
~/Projects/echoeslabwebsite/tools/scripts/verify-main-isolation.sh
```

(Created in step A.0 below.) Expected output: every repo on `devops`, every `main` matching origin, no uncommitted changes, devops commits ahead of main only.

---

## A. Local guardrails (prevent your laptop from committing/pushing to main)

These are belt-and-suspenders alongside the server-side rules in section B. They catch mistakes before they leave your machine.

### A.0 — Install the verification script

**Files affected:** `tools/scripts/verify-main-isolation.sh` (new, in meta-repo)

Already provided in this commit; runs the state check above. Make it part of muscle memory.

### A.1 — Configure each repo's git defaults

For **each of the 3 site repos** (and optionally the meta-repo once it has a remote), run:

```bash
cd ~/Projects/echoeslabwebsite/<repo>

# Push the current branch to its same-named upstream — never push other branches by accident
git config push.default current

# Make `git pull` a fast-forward only by default — refuse if main has diverged
git config pull.ff only

# Refuse to push if the local branch isn't tracking a remote (forces explicit `-u` first time)
git config push.autoSetupRemote false
```

Verify with `git config --list | grep -E '^(push|pull)\.'`.

### A.2 — Install a pre-push hook that blocks pushes to main

Create `~/Projects/echoeslabwebsite/tools/git-hooks/pre-push` (one shared hook copied into each repo's `.git/hooks/`):

```bash
#!/usr/bin/env bash
# Block direct pushes to main. To override (e.g., during initial setup), set ALLOW_MAIN_PUSH=1.
set -euo pipefail

protected_branch='main'
allow=${ALLOW_MAIN_PUSH:-0}

while read -r local_ref local_sha remote_ref remote_sha; do
  if [[ "$remote_ref" == "refs/heads/$protected_branch" ]]; then
    if [[ "$allow" != "1" ]]; then
      echo "❌ Direct push to '$protected_branch' is blocked by pre-push hook." >&2
      echo "   To override (rare!): ALLOW_MAIN_PUSH=1 git push <args>" >&2
      echo "   Normal flow: push to 'devops', open a PR." >&2
      exit 1
    fi
    echo "⚠️  ALLOW_MAIN_PUSH=1 — pushing to $protected_branch as authorized override." >&2
  fi
done

exit 0
```

Then in each site repo:

```bash
cd ~/Projects/echoeslabwebsite/<repo>
mkdir -p .git/hooks
cp ~/Projects/echoeslabwebsite/tools/git-hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

(Repeat for all 3 site repos and the meta-repo.)

Test it works:

```bash
git checkout main
git push origin main --dry-run   # Expect: ❌ Direct push to 'main' is blocked
git checkout devops
```

### A.3 — Lefthook integration (already installed in Phase 5b)

Lefthook's `pre-push` section already has a reminder; we'll add a hard branch-protection check to it. Edit each site repo's `lefthook.yml`:

```yaml
pre-push:
  commands:
    block-main-push:
      run: |
        if git symbolic-ref --short HEAD 2>/dev/null | grep -qx 'main'; then
          echo "❌ Refusing to push: HEAD is on 'main'. Switch to 'devops' first."
          exit 1
        fi
    reminder:
      run: echo "Reminder — run /security-review in Claude Code before significant pushes."
```

This is a second line of defense alongside the `.git/hooks/pre-push` hook in A.2.

---

## B. Server-side guardrails (the real safety net) — GitHub Branch Protection

The local hooks can be bypassed with `--no-verify`. **The server-side rules cannot.** These are what actually prevent main from being touched.

For each of the **3 site repos** at GitHub:

### B.1 — `habibots/GlobalManagement` (public)

Settings → **Branches** → **Add rule** → branch pattern: `main`

Required settings:
- ☑ **Require a pull request before merging**
  - ☑ Require approvals: `1` (you can approve your own PRs since you're the only collaborator)
  - ☑ Dismiss stale pull request approvals when new commits are pushed
  - ☑ Require review from Code Owners (after CODEOWNERS file is added — section C)
- ☑ **Require status checks to pass before merging**
  - ☑ Require branches to be up to date before merging
  - Add required status check: `gate` (the final job from `_security-base.yml`)
- ☑ **Require conversation resolution before merging**
- ☑ **Require linear history** (no merge commits — squash or rebase only)
- ☐ **Require deployments to succeed** (skip — we don't have deploy jobs gated by environments yet)
- ☑ **Lock branch** = OFF (we still need PRs to merge, just not direct pushes)
- ☑ **Do not allow bypassing the above settings** (so even admins can't accidentally bypass)
- ☑ **Restrict who can push to matching branches** → leave empty (nobody can push directly; everyone goes through PR)
- ☑ **Allow force pushes**: OFF
- ☑ **Allow deletions**: OFF

### B.2 — `habibots/sacred-portal-wellness` (public)

Same settings as B.1.

### B.3 — `echoeslabmusic/antiphazeprod` (private)

Same settings as B.1. Note: GitHub Free plan supports branch protection on private repos as of 2023.

### B.4 — Meta-repo (after you create it on GitHub)

Whatever org you put it under (`echoeslabmusicsoftware` per the recommendation). Same settings as B.1.

### B.5 — Tag protection (prevents accidental release tags on main)

Settings → **Tags** → **Add rule** → tag pattern: `v*`. Restrict to repo admins only.

This way the cosign signing + SLSA provenance release job only fires for tags you intentionally create.

---

## C. CODEOWNERS files (require review on sensitive paths)

For each of the 4 repos, create `.github/CODEOWNERS` so the protected `main` branch requires *your* review (or your organization's security person's review) on changes to security-sensitive files.

For the **3 site repos**:

```
# .github/CODEOWNERS

# Security-sensitive paths require review from @habibots
/.github/                    @habibots
/policy/                     @habibots
/tools/semgrep-custom/       @habibots
/.gitleaks.toml              @habibots
/lefthook.yml                @habibots

# Site-specific (adapt per repo):
# antiphazeprod:
/infrastructure/             @habibots
/website/src/pages/api/      @habibots

# sacred-portal-wellness:
/app/src/app/api/            @habibots
/app/src/lib/square-client.ts @habibots

# GlobalManagement:
/public/_headers             @habibots
```

For the **meta-repo**, even more important:

```
# .github/CODEOWNERS

*                            @habibots
/policy/                     @habibots
/tools/semgrep-custom/       @habibots
/workflows-templates/        @habibots
/docs/security-policy.md     @habibots
```

The CODEOWNERS file ties to the "Require review from Code Owners" setting in branch protection (B.1).

---

## D. Verify CI never pushes to main

The current workflows don't push to main, but verify there's no future drift:

### D.1 — Audit every workflow

```bash
cd ~/Projects/echoeslabwebsite

# Search for any workflow that pushes, merges, or modifies main directly:
for r in . GlobalManagement sacred-portal-wellness antiphazeprod; do
  echo "=== $r ==="
  grep -rE 'git push|git merge|gh pr merge|peter-evans/create-pull-request' "$r/.github/workflows/" 2>/dev/null || echo "  (none — good)"
done
```

Expected: only the `refresh-do-firewall.yml` workflow runs, which calls `doctl` (no git operations) and the existing `update-pretix.yml` does an SSH deploy (no git operations on main).

### D.2 — Verify the release job triggers only on tags, not main pushes

Open `workflows-templates/_security-base.yml` and confirm the release job is gated:

```yaml
  release:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: [gate]
    # ...
```

`refs/tags/v*` means it ONLY runs when you explicitly push a tag like `v1.0.0`. A push to `main` will run the scanners + gate + build, but **NOT** the release/sign job. Combined with B.5 (tag protection), only you can trigger a release.

### D.3 — Verify no auto-merge bots are configured

```bash
# Each repo:
cd ~/Projects/echoeslabwebsite/<repo>
# No Dependabot auto-merge:
cat .github/dependabot.yml 2>/dev/null | grep -i 'automerge' || echo "no automerge in dependabot config"
# No Mergify config:
ls .mergify* mergify.yml 2>/dev/null || echo "no mergify config"
```

If you ever add Dependabot auto-merge later, it MUST go to `devops`, not `main`.

---

## E. Daily working pattern (operational hygiene)

Internalize these. Make them muscle memory.

### E.1 — Starting work

```bash
cd ~/Projects/echoeslabwebsite/<repo>
git fetch origin
git checkout devops
git pull --ff-only origin devops    # safe pull (refuses if diverged)
```

### E.2 — Making changes

```bash
# Option A: small change, commit directly to devops
git status
git add <files>
git commit -m "feat: ..."

# Option B: bigger change, branch off devops
git checkout -b feat/my-feature devops
# work, commit, push:
git push -u origin feat/my-feature
# open PR: feat/my-feature → devops
```

### E.3 — Pushing

```bash
# Verify you're not on main:
git branch --show-current   # should be 'devops' or a feature branch

# Push:
git push origin <your-branch>
```

The pre-push hook (A.2) will block if you accidentally try to push to main.

### E.4 — Periodically syncing devops with origin/main

If `main` ever does receive a commit (e.g., a hotfix from someone else), bring devops up to date:

```bash
cd ~/Projects/echoeslabwebsite/<repo>
git checkout devops
git fetch origin
git rebase origin/main           # OR: git merge --no-ff origin/main
git push --force-with-lease origin devops    # only if you rebased
```

`--force-with-lease` is safer than `--force` — it refuses if the remote has new commits you don't have.

### E.5 — Promoting devops → main (when ready)

```bash
# 1. Push devops:
git push origin devops

# 2. Open PR on GitHub (CLI):
gh pr create --base main --head devops --title "Production hardening" --body "..."

# 3. Wait for CI gate to pass.

# 4. Merge via GitHub UI (squash recommended). Branch protection enforces all rules.

# 5. Delete the PR's source branch only if you want — usually keep devops as the long-lived working branch.
```

You **never** type `git push origin main`. Never. The branch protection (B.1) blocks it server-side; the local hooks (A.2, A.3) block it client-side.

---

## F. Pre-push pre-flight check (run this every time before pushing)

Save as `~/Projects/echoeslabwebsite/tools/scripts/preflight.sh`. Source it or run it before any push.

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
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
  echo "  ⚠ no origin/main yet (acceptable for meta-repo before push)"
fi

# 3. Working tree clean
if [[ -n "$(git status --porcelain)" ]]; then
  echo "  ⚠ uncommitted changes:"
  git status --short
  echo "  (commit or stash before pushing)"
  exit 1
fi
echo "  ✓ working tree clean"

# 4. Have you run /security-review for this branch?
LATEST_REVIEW=$(ls -1t .security-reviews/PR-${BRANCH}-*.md 2>/dev/null | head -1)
if [[ -z "$LATEST_REVIEW" ]]; then
  echo "  ⚠ no .security-reviews/PR-${BRANCH}-*.md found — run /security-review in Claude Code first"
fi

echo "  ✓ preflight OK — safe to push"
```

Make executable. Run before any `git push`.

---

## G. Status as of 2026-05-08 (verified before this checklist was written)

```
Repo                                     Current   main matches      devops    Working
                                         branch    origin/main       ahead     tree
─────────────────────────────────────────────────────────────────────────────────────
echoeslabwebsite (meta)                  devops    n/a (no remote)   24        clean
GlobalManagement                         devops    YES               7         clean
sacred-portal-wellness                   devops    YES               8         clean
antiphazeprod                            devops    YES               11        clean
```

All 4 repos are properly isolated. Nothing on `main` has changed locally. The 41 commits live exclusively on `devops` branches.

---

## H. The "go/no-go" gate before each push session

Run this 5-step gate before pushing anything:

1. ☐ `verify-main-isolation.sh` shows all repos on devops, main = origin/main
2. ☐ Pre-push hook installed in this repo (`ls .git/hooks/pre-push`)
3. ☐ Branch protection rule exists on origin/main (verify in GitHub Settings → Branches)
4. ☐ Latest `.security-reviews/PR-<branch>-*.md` exists for this branch
5. ☐ `preflight.sh` exits 0

If any box is unchecked: stop, fix it, re-run.

---

## I. The recovery procedure if main DOES get touched

You should never need this, but if a commit accidentally lands on main:

```bash
cd ~/Projects/echoeslabwebsite/<repo>
git fetch origin

# 1. See what's there:
git log --oneline origin/main..main
git log --oneline main..origin/main

# 2. If local main has unwanted commits and remote doesn't yet:
git checkout main
git reset --hard origin/main      # destructive — only if you're certain

# 3. If unwanted commits already pushed to origin/main:
#    — branch protection should have prevented this; if it didn't, your protection is misconfigured.
#    — `git revert` the bad commits (creates new commits that undo them)
#    — DO NOT force-push to overwrite history on main; that breaks everyone's clones.
```

Document any near-miss in `docs/runbooks/incident-response-template.md` per the IR habit established in Phase 0.
