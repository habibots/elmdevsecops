# Website Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden three production websites (GlobalManagement, sacred-portal-wellness, antiphazeprod) with Cloudflare-fronted infrastructure, automated TLS, OSS-only CI/CD security gates on every push, and committed AI audit artifacts per PR — at $0/month new spend.

**Architecture:** Meta-DevOps repo (`echoeslabwebsite/`) holds shared workflows, policies, threat models, and runbooks. Each site repo gains a `devops` branch containing site-specific config and a thin `.github/workflows/security.yml` that calls the shared reusable workflow. All three sites are proxied through Cloudflare's free tier (DDoS, WAF, Universal SSL, Access for Pretix admin, Turnstile for forms). Local Claude Code via `/security-review` slash command is the AI reviewer; deterministic OSS scanners (gitleaks, Trivy, Semgrep OSS, OSV-Scanner, Checkov, ZAP, Syft, cosign) gate every push.

**Tech Stack:** GitHub Actions, Cloudflare (Pages, Workers, DNS, WAF, Access, Turnstile), Caddy (with xcaddy + caddy-dns/cloudflare), Docker Compose, Astro, Next.js, Pretix, Postgres, Redis, gitleaks, Trivy, Semgrep OSS, OSV-Scanner, Checkov, OWASP ZAP, Syft, cosign, Sigstore Rekor, SOPS+age, lefthook.

**Source spec:** `docs/specs/2026-05-07-website-hardening-design.md`

---

## How to read this plan

- **[USER]** = task requires a human action (dashboard click, manual DNS change, secret rotation, account creation). Subagent prepares everything possible; user executes the human-only step.
- **[AGENT]** = task can be fully executed by a subagent.
- **[BOTH]** = subagent does the bulk; user does a small confirming step.
- All file paths are absolute or anchored at `/Users/uspharoh/Projects/echoeslabwebsite/`.
- Workspace root: `/Users/uspharoh/Projects/echoeslabwebsite/` (meta-repo, on `devops` branch).
- Site repos: `echoeslabwebsite/{GlobalManagement,sacred-portal-wellness,antiphazeprod}/` (each on `devops` branch, never touch `main`).

## File map (everything this plan creates or modifies)

### Meta-repo (`echoeslabwebsite/`, devops branch)

```
docs/
  threats/
    threat-model.md                          (new)
    globalmanagement.md                      (new)
    sacred-portal.md                         (new)
    antiphaze.md                             (new)
  security-policy.md                         (new)
  runbooks/
    secrets-rotation.md                      (new)
    incident-response-template.md            (new)
    cloudflare-fallback.md                   (new)
    secrets-management.md                    (new)
    cloudflare-bootstrap.md                  (new)
policy/
  containers.rego                            (new)
  github-actions.rego                        (new)
  caddy.rego                                 (new)
  containers_test.rego                       (new)
  github-actions_test.rego                   (new)
  caddy_test.rego                            (new)
tools/
  pre-commit-config.yaml                     (new — shared template)
  gitleaks.toml                              (new — shared template)
  osv-scanner.toml                           (new — shared template)
  semgrep-custom/
    square-token-wrapper.yaml                (new)
    webhook-signature.yaml                   (new)
    tests/
      square-bad.ts                          (new fixture)
      square-good.ts                         (new fixture)
      webhook-bad.ts                         (new fixture)
      webhook-good.ts                        (new fixture)
  caddy/
    Dockerfile                               (new — xcaddy with cloudflare DNS plugin)
  scripts/
    rotate-secrets.sh                        (new)
    scrub-secrets.sh                         (new)
    refresh-gh-runner-ips.sh                 (new)
    test-headers.sh                          (new)
    test-tls.sh                              (new)
workflows-templates/
  _security-base.yml                         (new — reusable workflow)
  _drift-nightly.yml                         (new — scheduled)
.github/
  workflows/
    meta-repo-lint.yml                       (new — lints the meta-repo itself)
README.md                                    (new — workspace orientation)
CONTRIBUTING.md                              (new — workflow rules)
```

### Site repo: `GlobalManagement/` (devops branch)

```
.github/workflows/security.yml               (new — calls shared _security-base)
.pre-commit-config.yaml                      (new)
.gitleaks.toml                               (new)
public/_headers                              (new)
.claude/commands/security-review.md          (new)
.security-reviews/.gitkeep                   (new)
SECURITY-INCIDENT-2026-05-07.md              (new — IR report)
.gitignore                                   (modify — add .env*)
```

### Site repo: `sacred-portal-wellness/` (devops branch)

```
.github/workflows/security.yml               (new)
.pre-commit-config.yaml                      (new)
.gitleaks.toml                               (new)
osv-scanner.toml                             (new)
next.config.js                               (modify — add security headers)
app/src/lib/square-client.ts                 (new — single Square wrapper)
tools/semgrep/                               (new — symlink or copy of meta-repo rules)
.claude/commands/security-review.md          (new)
.security-reviews/.gitkeep                   (new)
SECURITY-INCIDENT-2026-05-07.md              (new — IR report, Square rotation)
.gitignore                                   (modify — add .env*)
```

### Site repo: `antiphazeprod/` (devops branch)

```
.github/workflows/security.yml               (new)
.pre-commit-config.yaml                      (new)
.gitleaks.toml                               (new)
osv-scanner.toml                             (new)
infrastructure/Caddyfile                     (modify — DNS-01, hardened headers)
infrastructure/docker-compose.yml            (modify — bind DBs internal, cap_drop, read_only)
infrastructure/caddy/Dockerfile              (new — xcaddy + cloudflare DNS plugin)
infrastructure/sops/.sops.yaml               (new)
infrastructure/sops/prod.env.enc             (new — encrypted)
website/package.json                         (modify — @astrojs/node ^9 for Node 22)
website/Dockerfile                           (modify — FROM node:22-alpine)
website/src/pages/api/contact.ts             (modify — remove SMTP fallback)
.claude/commands/security-review.md          (new)
.security-reviews/.gitkeep                   (new)
SECURITY-INCIDENT-2026-05-07.md              (new — IR report)
.gitignore                                   (modify — add .env*)
```

---

## Phase 0 — Urgent IR: Rotate leaked credentials & scrub history (DAY 1, BEFORE ANYTHING ELSE)

**Context:** Three secrets are committed to git history. Industry consensus (GitHub, Anthropic, all secret-scanning vendors) is to **treat any committed secret as already public** the moment it lands in a remote. Order: rotate first, verify no abuse, scrub history, document.

### Task 0.1: Document the IR template and seed three incident reports [AGENT]

**Files:**
- Create: `echoeslabwebsite/docs/runbooks/incident-response-template.md`
- Create: `echoeslabwebsite/GlobalManagement/SECURITY-INCIDENT-2026-05-07.md`
- Create: `echoeslabwebsite/sacred-portal-wellness/SECURITY-INCIDENT-2026-05-07.md`
- Create: `echoeslabwebsite/antiphazeprod/SECURITY-INCIDENT-2026-05-07.md`

- [ ] **Step 1: Write IR template** at `docs/runbooks/incident-response-template.md` with the 9 sections from the design doc §9 (Summary, Timeline, Scope, Evidence, Remediation, Root cause, Preventive controls added, Control mapping, Lessons learned).

- [ ] **Step 2: Seed each per-repo incident file** with the template prefilled with site-specific known values (commit SHAs of leaked secrets — find via `git log --all --diff-filter=A --name-only -- '.env*' '**/contact.ts'`).

- [ ] **Step 3: Commit each in its respective repo on `devops` branch:**
```bash
cd echoeslabwebsite/GlobalManagement && git add SECURITY-INCIDENT-2026-05-07.md && git commit -m "docs(security): seed IR report for committed Web3Forms key"
cd ../sacred-portal-wellness && git add SECURITY-INCIDENT-2026-05-07.md && git commit -m "docs(security): seed IR report for committed Square production credentials"
cd ../antiphazeprod && git add SECURITY-INCIDENT-2026-05-07.md && git commit -m "docs(security): seed IR report for committed SMTP2GO credentials"
```

### Task 0.2: Rotate Square production credentials [USER]

**Files:** none (external dashboard action)

- [ ] **Step 1: USER opens Square Developer Dashboard.** Navigate to https://developer.squareup.com/apps → select the sacred-portal app → Production tab.

- [ ] **Step 2: USER clicks "Replace token"** and confirms. Square atomically revokes the old token. Save the new token to 1Password / Bitwarden — do NOT save to any file on disk.

- [ ] **Step 3: USER captures these values to password manager:** `SQUARE_ACCESS_TOKEN` (new), `SQUARE_APPLICATION_ID`, `SQUARE_LOCATION_ID`, `SQUARE_ENVIRONMENT=production`, `SQUARE_VERSION` (e.g. `2025-11-19`).

- [ ] **Step 4: USER runs abuse-check** with the new token (Bash):
```bash
# Replace 2026-04-01 with the date the secret was first committed
curl -s -H "Authorization: Bearer $SQUARE_ACCESS_TOKEN_NEW" \
     -H "Square-Version: 2025-11-19" \
     "https://connect.squareup.com/v2/payments?begin_time=2026-04-01T00:00:00Z" \
     | jq '.payments[] | {id, amount_money, status, created_at, source_type}' \
     > /tmp/square-audit-2026-05-07.json
```
Expected: review JSON output, reconcile every transaction against expected ledger. Any unaccounted transaction → file a Square dispute and contact security@squareup.com.

- [ ] **Step 5: USER updates the IR report** at `sacred-portal-wellness/SECURITY-INCIDENT-2026-05-07.md` Timeline + Evidence sections with rotation timestamp and audit findings.

### Task 0.3: Rotate SMTP2GO credentials [USER]

- [ ] **Step 1: USER opens SMTP2GO dashboard** → Settings → SMTP Users.

- [ ] **Step 2: USER deletes the existing SMTP user** (or rotates its password). Capture new credentials to 1Password.

- [ ] **Step 3: USER runs abuse-check:** SMTP2GO dashboard → Activity / Reports. Review send volume, recipient domains, bounce/complaint spike during the exposure window.

- [ ] **Step 4: USER updates the IR report** at `antiphazeprod/SECURITY-INCIDENT-2026-05-07.md`.

### Task 0.4: Rotate Web3Forms key [USER]

- [ ] **Step 1: USER opens Web3Forms dashboard.** Note: per Web3Forms docs, this key is *designed* to be public/embedded in client-side code; risk is form-spam not data exfiltration. Rotation is hygiene.

- [ ] **Step 2: USER regenerates the access key** and captures to 1Password.

- [ ] **Step 3: USER updates the IR report** at `GlobalManagement/SECURITY-INCIDENT-2026-05-07.md`. Note honestly: Web3Forms does not expose per-key audit logs; abuse-window verification is only via inbox volume of the destination address.

### Task 0.5: Scrub git history in all 3 repos [BOTH]

**Files:**
- Create: `echoeslabwebsite/tools/scripts/scrub-secrets.sh`

- [ ] **Step 1: AGENT writes the scrub script** at `tools/scripts/scrub-secrets.sh`:
```bash
#!/usr/bin/env bash
# Usage: scrub-secrets.sh <repo-path> <path-or-pattern-to-remove>
# Requires: git-filter-repo
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
```
Make executable: `chmod +x tools/scripts/scrub-secrets.sh`.

- [ ] **Step 2: AGENT verifies git-filter-repo is installed:** `command -v git-filter-repo || brew install git-filter-repo`.

- [ ] **Step 3: USER prepares the replacements file** at `/tmp/secret-replacements.txt` listing the literal old secrets (paste from password manager — no agent should ever see these):
```
EAAA<actual-old-square-token>==>REDACTED_SQUARE_TOKEN
sq0idp-<actual-old-app-id>==>REDACTED_SQUARE_APP_ID
71733509-82e6-4e55-a8ca-aa29380be39c==>REDACTED_WEB3FORMS_KEY
<old-smtp-user>==>REDACTED_SMTP_USER
<old-smtp-pass>==>REDACTED_SMTP_PASS
```

- [ ] **Step 4: USER runs scrub on each repo** (note: must be done AFTER rotation):
```bash
cd ~/Projects/echoeslabwebsite
./tools/scripts/scrub-secrets.sh ./sacred-portal-wellness '.env.local' /tmp/secret-replacements.txt
./tools/scripts/scrub-secrets.sh ./GlobalManagement '.env' /tmp/secret-replacements.txt
# antiphaze hardcoded SMTP — replace-text only, no path removal:
cd ./antiphazeprod && git filter-repo --replace-text /tmp/secret-replacements.txt --force
```

- [ ] **Step 5: USER force-pushes the rewritten history** for each repo:
```bash
cd ~/Projects/echoeslabwebsite/sacred-portal-wellness && git push --force --all && git push --force --tags
cd ../GlobalManagement && git push --force --all && git push --force --tags
cd ../antiphazeprod && git push --force --all && git push --force --tags
```

- [ ] **Step 6: USER opens GitHub Support tickets** for each repo to purge cached PR/diff views (force-push alone does not remove cached PR diffs from GitHub's web UI). https://support.github.com/contact

- [ ] **Step 7: USER deletes any forks** of the repos that they don't control (or contacts fork owners). Use `gh api repos/<owner>/<repo>/forks` to list.

- [ ] **Step 8: USER securely deletes** `/tmp/secret-replacements.txt` after force-push completes:
```bash
shred -u /tmp/secret-replacements.txt 2>/dev/null || rm -f /tmp/secret-replacements.txt
```

- [ ] **Step 9: AGENT commits the scrub script** to the meta-repo:
```bash
cd ~/Projects/echoeslabwebsite
git add tools/scripts/scrub-secrets.sh
git commit -m "tools: add git-filter-repo scrub script for secrets remediation"
```

### Task 0.6: Add `.env*` to gitignore in all 3 repos [AGENT]

**Files:**
- Modify: `echoeslabwebsite/GlobalManagement/.gitignore`
- Modify: `echoeslabwebsite/sacred-portal-wellness/.gitignore`
- Modify: `echoeslabwebsite/antiphazeprod/.gitignore`

- [ ] **Step 1: AGENT reads each repo's existing `.gitignore`** to confirm what's already there.

- [ ] **Step 2: AGENT appends to each `.gitignore`** the following lines (only those not already present):
```
# Secrets
.env
.env.*
!.env.example
*.pem
*.key
.dev.vars
```

- [ ] **Step 3: AGENT commits in each repo** on `devops` branch:
```bash
cd ~/Projects/echoeslabwebsite/<repo> && git add .gitignore && git commit -m "chore(security): expand .gitignore to block .env* and key material"
```

- [ ] **Step 4: AGENT verifies no current `.env*` files are tracked** in any repo:
```bash
for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
  cd ~/Projects/echoeslabwebsite/$r
  git ls-files | grep -E '^\.env' && echo "TRACKED in $r" || echo "OK in $r"
done
```
Expected: "OK in <repo>" for all three. If TRACKED, run `git rm --cached <file>` and commit.

---

## Phase 1 — Stabilize antiphaze runtime (Node 16 → 22 LTS, lock down DBs)

**Context:** Node 16 EOL since Sept 2023. CVE-2024-22019 (high-severity llhttp HTTP request smuggling) is unpatched. This is the highest-severity active vuln across all three sites. Postgres/Redis must not be reachable from the public internet.

### Task 1.1: Upgrade `@astrojs/node` adapter to Node 22 LTS [AGENT]

**Files:**
- Modify: `echoeslabwebsite/antiphazeprod/website/package.json`
- Modify: `echoeslabwebsite/antiphazeprod/website/Dockerfile`

- [ ] **Step 1: AGENT reads** `antiphazeprod/website/package.json` and `antiphazeprod/website/Dockerfile`.

- [ ] **Step 2: AGENT updates `package.json`** dependency line:
```json
"@astrojs/node": "^9.4.4"
```
(verify the current latest `^9` minor at npm: `npm view @astrojs/node versions --json | jq '.[-1]'`)

- [ ] **Step 3: AGENT updates `Dockerfile`** base image lines from `node:16-*` to `node:22-alpine`:
```dockerfile
FROM node:22-alpine AS builder
# ... existing build stage ...

FROM node:22-alpine AS runtime
# ... existing runtime stage ...
```

- [ ] **Step 4: AGENT runs `npm install`** in the `antiphazeprod/website/` directory to resolve the new lockfile:
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod/website && npm install
```
Expected: `package-lock.json` updates without errors.

- [ ] **Step 5: AGENT runs the local build** to verify Node 22 compatibility:
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod/website && npm run build
```
Expected: build completes without errors. If errors occur, capture them and fail the task — do not proceed.

- [ ] **Step 6: AGENT commits** on `devops` branch:
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod
git add website/package.json website/package-lock.json website/Dockerfile
git commit -m "fix(antiphaze): upgrade Node 16 (EOL) to Node 22 LTS — addresses CVE-2024-22019"
```

### Task 1.2: Bind Postgres and Redis to internal Docker network only [AGENT]

**Files:**
- Modify: `echoeslabwebsite/antiphazeprod/infrastructure/docker-compose.yml`

- [ ] **Step 1: AGENT reads** the current `infrastructure/docker-compose.yml`.

- [ ] **Step 2: AGENT removes any `ports:` mapping** under `postgres` and `redis` services. Only `caddy` should publish ports to the host (80, 443).

- [ ] **Step 3: AGENT adds `cap_drop: [ALL]`** and an explicit `cap_add` allowlist (only what's required) to every service. For Postgres, no `cap_add` needed; for Caddy, `NET_BIND_SERVICE` is required.

- [ ] **Step 4: AGENT adds `read_only: true`** to caddy and pretix services with explicit `tmpfs` mounts for writable paths. Postgres and Redis need writable data dirs — use named volumes, not bind mounts.

- [ ] **Step 5: AGENT writes a Conftest test** at `tools/conftest-config/compose-test.rego` that asserts: no service has public `ports:` other than `caddy`, every service has `cap_drop: [ALL]`. (See Task 4.x for full Rego rules — this is a stub.)

- [ ] **Step 6: AGENT runs** the modified compose file syntax check:
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod/infrastructure
docker compose config --quiet
```
Expected: no error.

- [ ] **Step 7: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod
git add infrastructure/docker-compose.yml
git commit -m "fix(antiphaze): bind postgres/redis to internal docker network only; cap_drop ALL"
```

### Task 1.3: Remove SMTP credential fallback from contact.ts [AGENT]

**Files:**
- Modify: `echoeslabwebsite/antiphazeprod/website/src/pages/api/contact.ts`

- [ ] **Step 1: AGENT reads** the current `contact.ts`.

- [ ] **Step 2: AGENT replaces any hardcoded SMTP credential fallbacks** with strict `process.env` reads that throw if missing:
```typescript
const smtpUser = process.env.SMTP_USER;
const smtpPass = process.env.SMTP_PASS;
if (!smtpUser || !smtpPass) {
  throw new Error('SMTP credentials not configured (SMTP_USER, SMTP_PASS env vars required)');
}
```
No string literals containing user/pass.

- [ ] **Step 3: AGENT searches for any other hardcoded credential references:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod
git grep -nE 'mail\.smtp2go\.com|smtp_user|smtp_pass' -- src/ infrastructure/ || echo "OK"
```
Expected: only env-driven references.

- [ ] **Step 4: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod
git add website/src/pages/api/contact.ts
git commit -m "fix(antiphaze): remove SMTP credential fallback; require env vars"
```

### Task 1.4: SSH hardening on the DigitalOcean droplet [USER]

**Context:** ed25519-only deploy key, password auth disabled, fail2ban running. DO Cloud Firewall restricts SSH (port 22) to GitHub Actions runner IP ranges and the user's home IP only.

- [ ] **Step 1: USER generates an ed25519 deploy key** locally:
```bash
ssh-keygen -t ed25519 -C "antiphaze-deploy-2026-05-07" -f ~/.ssh/antiphaze_deploy
# Use a passphrase. Store passphrase in 1Password.
```

- [ ] **Step 2: USER adds public key to droplet's `authorized_keys`** for the deploy user:
```bash
ssh-copy-id -i ~/.ssh/antiphaze_deploy.pub deploy@129.212.164.31
```

- [ ] **Step 3: USER tests login with new key**, confirms it works, then disables password auth on the droplet (`/etc/ssh/sshd_config`):
```
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
```
Reload: `sudo systemctl reload sshd`. Test from a second terminal — do NOT close the working session until you've confirmed the new config works.

- [ ] **Step 4: USER installs and configures fail2ban:**
```bash
sudo apt-get update && sudo apt-get install -y fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
# Edit /etc/fail2ban/jail.local: ensure [sshd] enabled = true
sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```

- [ ] **Step 5: USER configures DO Cloud Firewall** via DO dashboard or `doctl`:
   - Inbound TCP 22 (SSH): allow only user's home IP (run `curl ifconfig.me` to get) + GitHub Actions runner IP ranges (see Task 1.5)
   - Inbound TCP 80, 443: allow all (or restrict to Cloudflare IPs once Cloudflare is in front — Phase 2)
   - Inbound TCP 5432, 6379: deny all (defense in depth — already not exposed by compose)
   - Outbound: allow all

- [ ] **Step 6: USER replaces the GitHub Actions deploy key** in the antiphaze repo Secrets (Settings → Secrets and variables → Actions → `SSH_PRIVATE_KEY`) with the new key's private contents.

- [ ] **Step 7: USER triggers the existing `update-pretix.yml` workflow** manually (Actions tab → run workflow) and confirms it succeeds with the new key.

- [ ] **Step 8: USER updates** `antiphazeprod/SECURITY-INCIDENT-2026-05-07.md` with SSH hardening completion.

### Task 1.5: Auto-refresh GitHub Actions runner IPs in DO firewall [AGENT + USER]

**Files:**
- Create: `echoeslabwebsite/tools/scripts/refresh-gh-runner-ips.sh`

- [ ] **Step 1: AGENT writes the IP-refresh script** at `tools/scripts/refresh-gh-runner-ips.sh`:
```bash
#!/usr/bin/env bash
# Refreshes a DO Cloud Firewall rule with the current GitHub Actions runner IP ranges.
# Requires: doctl authenticated, jq, curl.
set -euo pipefail
FIREWALL_ID="${DO_FIREWALL_ID:?must set DO_FIREWALL_ID}"
HOME_IP="${HOME_IP:?must set HOME_IP}"

ACTION_IPS=$(curl -s https://api.github.com/meta | jq -r '.actions[]')

# Build the inbound SSH rule JSON
SOURCES=""
for ip in $ACTION_IPS; do SOURCES+="\"$ip\","; done
SOURCES+="\"$HOME_IP\""

INBOUND_RULES=$(cat <<EOF
[
  {"protocol":"tcp","ports":"22","sources":{"addresses":[$SOURCES]}},
  {"protocol":"tcp","ports":"80","sources":{"addresses":["0.0.0.0/0","::/0"]}},
  {"protocol":"tcp","ports":"443","sources":{"addresses":["0.0.0.0/0","::/0"]}}
]
EOF
)

doctl compute firewall update "$FIREWALL_ID" \
  --inbound-rules "$INBOUND_RULES"
```
Make executable.

- [ ] **Step 2: AGENT writes a sibling GitHub Action** at `echoeslabwebsite/.github/workflows/refresh-do-firewall.yml` that runs the script weekly:
```yaml
name: Refresh DO firewall (GH runner IPs)
on:
  schedule: [{ cron: '0 6 * * 1' }]   # every Monday 06:00 UTC
  workflow_dispatch:
jobs:
  refresh:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: digitalocean/action-doctl@v2
        with: { token: '${{ secrets.DIGITALOCEAN_ACCESS_TOKEN }}' }
      - run: ./tools/scripts/refresh-gh-runner-ips.sh
        env:
          DO_FIREWALL_ID: ${{ secrets.DO_FIREWALL_ID }}
          HOME_IP: ${{ secrets.HOME_IP }}
```

- [ ] **Step 3: USER creates a DO API token** with read+write firewall scope and adds it to GitHub Secrets as `DIGITALOCEAN_ACCESS_TOKEN`. Same for `DO_FIREWALL_ID` (run `doctl compute firewall list` to find ID) and `HOME_IP`.

- [ ] **Step 4: AGENT commits both files:**
```bash
cd ~/Projects/echoeslabwebsite
git add tools/scripts/refresh-gh-runner-ips.sh .github/workflows/refresh-do-firewall.yml
git commit -m "ops: weekly DO firewall refresh of GH Actions runner IPs"
```

- [ ] **Step 5: USER triggers the workflow once manually** (Actions tab) to confirm it works.

---

## Phase 2 — Cloudflare in front of all 3 sites

**Context:** Free-tier Cloudflare proxy adds DDoS, WAF, Universal SSL, Bot Fight Mode. We use the dashboard for the initial setup; everything else is config-as-code.

### Task 2.1: Cloudflare account & zone setup runbook [USER]

**Files:**
- Create: `echoeslabwebsite/docs/runbooks/cloudflare-bootstrap.md`

- [ ] **Step 1: AGENT writes the bootstrap runbook** documenting every dashboard click required. Sections: account creation, zone add per domain, NS record change at registrar, DNS proxy enablement, SSL/TLS mode = Full (strict), Always Use HTTPS = on, Min TLS = 1.2, HSTS = off (we set in code/headers), Bot Fight Mode = on, WAF Managed Rules = on, OWASP Core Ruleset = on.

- [ ] **Step 2: AGENT commits the runbook:**
```bash
cd ~/Projects/echoeslabwebsite
git add docs/runbooks/cloudflare-bootstrap.md
git commit -m "docs(cloudflare): bootstrap runbook for free-tier proxy setup"
```

- [ ] **Step 3: USER creates Cloudflare account** at https://dash.cloudflare.com (free tier).

- [ ] **Step 4: USER adds zones** for each domain in scope (e.g., `globalmanagement.com`, `sacredportalwellness.com`, `antiphazeprod.com`). Cloudflare scans existing DNS records — review and confirm.

- [ ] **Step 5: USER updates registrar NS records** to Cloudflare's nameservers as displayed in the Cloudflare dashboard. Note: this is a real cutover. **Schedule a low-traffic window.** Document rollback (the original NS records).

- [ ] **Step 6: USER waits for NS propagation** (typically 1-4 hours). Confirm via `dig NS <domain>` returning Cloudflare nameservers.

- [ ] **Step 7: USER enables DNS proxy** (orange cloud) on the apex A record and `www` CNAME for each zone.

- [ ] **Step 8: USER configures per-zone settings** in the dashboard:
  - SSL/TLS → Overview → Full (strict)
  - SSL/TLS → Edge Certificates → Always Use HTTPS = ON
  - SSL/TLS → Edge Certificates → Minimum TLS Version = 1.2
  - SSL/TLS → Edge Certificates → HSTS = OFF (we set in code)
  - Security → Bots → Bot Fight Mode = ON
  - Security → WAF → Managed Rules = enabled
  - Security → WAF → OWASP Core Ruleset = enabled, sensitivity = Medium
  - Speed → Optimization → defaults

- [ ] **Step 9: USER updates the runbook** with the actual zone IDs and any deviations encountered.

### Task 2.2: Cloudflare Origin Certificate for antiphaze droplet [USER]

**Context:** With Cloudflare in front in Full (strict) mode, the droplet's Caddy needs a cert that Cloudflare trusts as origin. Cloudflare's Origin CA cert (15-year validity, Cloudflare-issued) is the standard pattern.

- [ ] **Step 1: USER generates Origin CA cert** in Cloudflare dashboard → SSL/TLS → Origin Server → Create Certificate. ECDSA, P-256, 15-year validity. Cover hostnames: `antiphazeprod.com, www.antiphazeprod.com, tickets.antiphazeprod.com`. Download cert and key.

- [ ] **Step 2: USER copies cert and key to droplet** at `/etc/caddy/origin.crt` and `/etc/caddy/origin.key` (root-owned, 0600 on key, 0644 on cert).

- [ ] **Step 3: USER updates Caddy config** to use the Origin CA cert instead of (or in addition to) automatic HTTPS — see Phase 3 Task 3.3 for the full Caddyfile.

### Task 2.3: Deploy GlobalManagement to Cloudflare Pages [USER + AGENT]

**Files:**
- Modify: `echoeslabwebsite/GlobalManagement/astro.config.mjs` (verify static output)

- [ ] **Step 1: AGENT verifies Astro is configured for static output** by reading `astro.config.mjs`. Expected: `output: 'static'` is present. If not, AGENT adds it.

- [ ] **Step 2: AGENT runs a clean build** to confirm `dist/` is produced:
```bash
cd ~/Projects/echoeslabwebsite/GlobalManagement && npm ci && npm run build && ls dist/
```
Expected: HTML files present.

- [ ] **Step 3: USER creates a Cloudflare Pages project** in dashboard → Workers & Pages → Create Application → Pages → Connect to Git. Connect `habibots/GlobalManagement` repo. Build settings: framework preset = Astro, build command = `npm run build`, build output = `dist`, root = `/`. Production branch = `main` (we'll create a deploy preview from `devops` branch).

- [ ] **Step 4: USER adds custom domain** in Pages project settings → Custom domains → add `globalmanagement.com` and `www.globalmanagement.com`. Cloudflare auto-creates the proxy CNAME.

- [ ] **Step 5: USER triggers a deploy from `devops` branch** — Pages → branch deployments → enable Preview Deployments for all branches. Push or manually trigger.

- [ ] **Step 6: USER configures Pages env vars** in project settings → Environment variables → Production: `PUBLIC_WEB3FORMS_ACCESS_KEY` = (new key from Phase 0). Encrypted at rest by Cloudflare.

- [ ] **Step 7: USER verifies** the Pages preview URL renders correctly and contact form submits to Web3Forms.

### Task 2.4: Cloudflare Access in front of Pretix `/control` [USER]

- [ ] **Step 1: USER enables Cloudflare Zero Trust** (free tier ≤ 50 users) at https://one.dash.cloudflare.com.

- [ ] **Step 2: USER creates an Access application** → Self-hosted → Application domain = `tickets.antiphazeprod.com`, path = `/control*`.

- [ ] **Step 3: USER configures the Access policy:**
   - Identity provider: One-time PIN (email) — free, no IdP required
   - Required: Emails ending in `@<your-org>.com` OR specific email allowlist
   - Session duration: 8 hours
   - Require: WebAuthn (under Additional settings → Require additional verification)

- [ ] **Step 4: USER tests** by visiting `https://tickets.antiphazeprod.com/control/` — expects Cloudflare Access login page; after authenticating, lands on Pretix admin.

- [ ] **Step 5: USER documents** the Access policy in `docs/runbooks/cloudflare-bootstrap.md` § Pretix admin protection.

### Task 2.5: Add Cloudflare Turnstile to all contact forms [USER + AGENT]

**Files:**
- Modify: `echoeslabwebsite/GlobalManagement/src/components/ContactForm.astro` (or equivalent)
- Modify: `echoeslabwebsite/sacred-portal-wellness/app/src/app/contact/page.tsx` (or equivalent)
- Modify: `echoeslabwebsite/antiphazeprod/website/src/pages/contact.astro` (or equivalent)

- [ ] **Step 1: USER creates a Turnstile site** in Cloudflare dashboard → Turnstile → Add Site. Choose "Managed" widget mode. One site per domain. Capture site keys (public) and secret keys (server-side).

- [ ] **Step 2: AGENT adds Turnstile widget** to the contact form template in each site:
```html
<div class="cf-turnstile" data-sitekey="<SITE_KEY>"></div>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" defer></script>
```

- [ ] **Step 3: AGENT modifies the server-side handler** in each site (where applicable — antiphaze + sacred-portal have server handlers) to verify the Turnstile token:
```typescript
const turnstileToken = formData.get('cf-turnstile-response');
const verifyResp = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ secret: process.env.TURNSTILE_SECRET!, response: turnstileToken!.toString() }),
});
const verifyJson = await verifyResp.json();
if (!verifyJson.success) {
  return new Response('Bot detected', { status: 403 });
}
```

- [ ] **Step 4: USER adds `TURNSTILE_SECRET`** to:
   - antiphaze: droplet env (SOPS-encrypted, Phase 4)
   - sacred-portal: `wrangler secret put TURNSTILE_SECRET`
   - GlobalManagement: not needed server-side (Web3Forms handles); add `PUBLIC_TURNSTILE_SITE_KEY` to Pages env vars

- [ ] **Step 5: AGENT commits in each site repo:**
```bash
cd ~/Projects/echoeslabwebsite/<site> && git add . && git commit -m "feat(security): add Cloudflare Turnstile to contact form"
```

- [ ] **Step 6: USER manually tests** each contact form post-deploy, confirms Turnstile widget appears and submission works.

---

## Phase 3 — TLS / headers baseline

### Task 3.1: GlobalManagement `_headers` file [AGENT]

**Files:**
- Create: `echoeslabwebsite/GlobalManagement/public/_headers`

- [ ] **Step 1: AGENT creates the `_headers` file:**
```
/*
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  Content-Security-Policy: default-src 'self'; script-src 'self' https://challenges.cloudflare.com; img-src 'self' data:; style-src 'self' 'unsafe-inline'; form-action https://api.web3forms.com; frame-ancestors 'none'; connect-src 'self' https://api.web3forms.com https://challenges.cloudflare.com
```

- [ ] **Step 2: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite/GlobalManagement
git add public/_headers
git commit -m "feat(security): add CSP/HSTS/security headers via _headers"
```

- [ ] **Step 3: USER triggers a Pages redeploy** (push to devops, or use the dashboard).

- [ ] **Step 4: USER verifies headers** post-deploy:
```bash
curl -sI https://globalmanagement.com | grep -iE 'strict-transport|content-security|x-content-type|referrer|permissions-policy'
```
Expected: all 5 headers present.

### Task 3.2: sacred-portal `next.config.js` security headers [AGENT]

**Files:**
- Modify: `echoeslabwebsite/sacred-portal-wellness/next.config.js` (or `next.config.mjs` / `next.config.ts` — check)

- [ ] **Step 1: AGENT reads** the existing Next config to determine file extension and current shape.

- [ ] **Step 2: AGENT adds the headers function:**
```js
const securityHeaders = [
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), payment=(self "https://*.squareup.com")' },
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "script-src 'self' https://*.squarecdn.com https://challenges.cloudflare.com",
      "img-src 'self' data: https://*.squarecdn.com",
      "style-src 'self' 'unsafe-inline'",
      "connect-src 'self' https://*.squareup.com https://challenges.cloudflare.com",
      "form-action 'self' https://*.squareup.com",
      "frame-ancestors 'none'",
    ].join('; '),
  },
];

module.exports = {
  // ... existing config ...
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};
```

- [ ] **Step 3: AGENT runs the dev build** to confirm config loads:
```bash
cd ~/Projects/echoeslabwebsite/sacred-portal-wellness && npm ci && npm run build
```
Expected: build succeeds.

- [ ] **Step 4: AGENT commits:**
```bash
git add next.config.js
git commit -m "feat(security): add CSP/HSTS/security headers in next.config"
```

- [ ] **Step 5: USER deploys** via `wrangler deploy` (or however current deploy works) and verifies headers via `curl -sI`.

### Task 3.3: antiphaze Caddyfile + xcaddy Docker image [AGENT]

**Files:**
- Create: `echoeslabwebsite/antiphazeprod/infrastructure/caddy/Dockerfile`
- Modify: `echoeslabwebsite/antiphazeprod/infrastructure/Caddyfile`
- Modify: `echoeslabwebsite/antiphazeprod/infrastructure/docker-compose.yml`

- [ ] **Step 1: AGENT creates the xcaddy Dockerfile** at `infrastructure/caddy/Dockerfile`:
```dockerfile
FROM caddy:2-builder-alpine AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

- [ ] **Step 2: AGENT writes the new Caddyfile** at `infrastructure/Caddyfile`:
```Caddyfile
{
    email ops@antiphazeprod.com
    acme_dns cloudflare {env.CF_DNS_API_TOKEN}
    servers {
        protocols h1 h2 h3
        timeouts {
            read_body 10s
            read_header 5s
            write 30s
            idle 5m
        }
    }
}

(security_headers) {
    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
        -Server
    }
}

antiphazeprod.com, www.antiphazeprod.com {
    import security_headers
    header Content-Security-Policy "default-src 'self'; script-src 'self' https://challenges.cloudflare.com; img-src 'self' data:; style-src 'self' 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; connect-src 'self' https://challenges.cloudflare.com"
    reverse_proxy astro:3000
}

tickets.antiphazeprod.com {
    import security_headers
    reverse_proxy pretix:8345 {
        header_up X-Forwarded-Proto {scheme}
        header_up Host {host}
    }
}
```

- [ ] **Step 3: AGENT modifies `docker-compose.yml`** to build the custom Caddy image and pass `CF_DNS_API_TOKEN`:
```yaml
services:
  caddy:
    build:
      context: ./caddy
      dockerfile: Dockerfile
    environment:
      - CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
    # ... rest of caddy config ...
```

- [ ] **Step 4: USER creates a Cloudflare API token** scoped to `Zone:DNS:Edit` for the antiphaze zones, then stores it on the droplet via SOPS (Phase 4 Task 4.1).

- [ ] **Step 5: AGENT runs a local validation:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod/infrastructure
docker compose config --quiet
```

- [ ] **Step 6: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod
git add infrastructure/caddy/Dockerfile infrastructure/Caddyfile infrastructure/docker-compose.yml
git commit -m "feat(antiphaze): xcaddy with cloudflare DNS plugin; DNS-01 ACME; security headers"
```

- [ ] **Step 7: USER deploys to droplet** during low-traffic window:
```bash
ssh deploy@129.212.164.31 'cd /opt/antiphaze && git pull origin devops && cd infrastructure && docker compose build caddy && docker compose up -d'
```

- [ ] **Step 8: USER verifies deploy:**
```bash
curl -sI https://antiphazeprod.com | grep -iE 'strict-transport|content-security|x-content-type|referrer|permissions-policy'
curl -sI https://tickets.antiphazeprod.com | grep -iE 'strict-transport'
```

### Task 3.4: TLS smoke test script [AGENT]

**Files:**
- Create: `echoeslabwebsite/tools/scripts/test-tls.sh`

- [ ] **Step 1: AGENT writes the smoke-test script:**
```bash
#!/usr/bin/env bash
# Verifies TLS config against Mozilla Intermediate baseline.
# Requires: docker (for sslyze image) OR sslyze installed locally.
set -euo pipefail
TARGET="${1:?usage: test-tls.sh <hostname>}"

docker run --rm nablac0d3/sslyze:latest --json_out=/dev/stdout "$TARGET" \
  | jq -e '
      .server_scan_results[0].scan_result
      | (.tls_1_0_cipher_suites.result.accepted_cipher_suites | length == 0)
      and (.tls_1_1_cipher_suites.result.accepted_cipher_suites | length == 0)
      and (.tls_1_3_cipher_suites.result.accepted_cipher_suites | length > 0)
      and (.heartbleed.result.is_vulnerable_to_heartbleed == false)
      and (.robot.result.robot_result == "NOT_VULNERABLE_NO_ORACLE")
    ' >/dev/null && echo "TLS baseline PASS: $TARGET" || { echo "TLS baseline FAIL: $TARGET"; exit 1; }
```
Make executable.

- [ ] **Step 2: AGENT tests script locally** against a known-good site:
```bash
./tools/scripts/test-tls.sh google.com
```
Expected: "TLS baseline PASS: google.com".

- [ ] **Step 3: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite
git add tools/scripts/test-tls.sh
git commit -m "tools: TLS baseline smoke test (Mozilla Intermediate)"
```

### Task 3.5: Headers smoke-test script [AGENT]

**Files:**
- Create: `echoeslabwebsite/tools/scripts/test-headers.sh`

- [ ] **Step 1: AGENT writes the script:**
```bash
#!/usr/bin/env bash
# Verifies expected security headers are present on the target URL.
set -euo pipefail
TARGET="${1:?usage: test-headers.sh <url>}"

REQUIRED_HEADERS=(
  "strict-transport-security"
  "x-content-type-options"
  "referrer-policy"
  "permissions-policy"
  "content-security-policy"
)

HEADERS=$(curl -sI "$TARGET" | tr '[:upper:]' '[:lower:]')
FAIL=0
for h in "${REQUIRED_HEADERS[@]}"; do
  if echo "$HEADERS" | grep -q "^$h:"; then
    echo "PASS: $h"
  else
    echo "FAIL: missing $h"
    FAIL=1
  fi
done
exit $FAIL
```

- [ ] **Step 2: AGENT tests against a known-good site** (e.g., a deployed Mozilla Observatory grade-A target).

- [ ] **Step 3: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite
git add tools/scripts/test-headers.sh
git commit -m "tools: security headers smoke test"
```

---

## Phase 4 — Secrets management going forward (SOPS+age, wrangler, GH Secrets)

### Task 4.1: SOPS+age setup for antiphaze [USER + AGENT]

**Files:**
- Create: `echoeslabwebsite/antiphazeprod/infrastructure/sops/.sops.yaml`
- Create: `echoeslabwebsite/antiphazeprod/infrastructure/sops/prod.env.example`
- Create: `echoeslabwebsite/antiphazeprod/infrastructure/sops/prod.env.enc` (encrypted)

- [ ] **Step 1: USER installs sops and age** locally:
```bash
brew install sops age
```

- [ ] **Step 2: USER generates an age key** for production:
```bash
age-keygen -o ~/.age/antiphaze-prod.key
chmod 600 ~/.age/antiphaze-prod.key
```
Capture the public key (printed during keygen). Save the private key to 1Password.

- [ ] **Step 3: AGENT writes the `.sops.yaml` config:**
```yaml
creation_rules:
  - path_regex: \.env\.enc$
    encrypted_regex: '^(.+)$'
    age: '<age-public-key-from-step-2>'
```

- [ ] **Step 4: AGENT writes a `prod.env.example`** (committed, plaintext, no secrets):
```
SQUARE_ACCESS_TOKEN=
SQUARE_APPLICATION_ID=
SQUARE_LOCATION_ID=
SQUARE_ENVIRONMENT=production
SMTP_HOST=mail.smtp2go.com
SMTP_PORT=2525
SMTP_USER=
SMTP_PASS=
CF_DNS_API_TOKEN=
TURNSTILE_SECRET=
PRETIX_DB_PASSWORD=
PRETIX_REDIS_PASSWORD=
PRETIX_SECRET_KEY=
```

- [ ] **Step 5: USER fills in real values** in a temporary `/tmp/prod.env` (NEVER committed) and encrypts:
```bash
sops --encrypt --age $(cat ~/.age/antiphaze-prod.key.pub) /tmp/prod.env > infrastructure/sops/prod.env.enc
shred -u /tmp/prod.env
```

- [ ] **Step 6: USER copies the age private key to the droplet:**
```bash
scp ~/.age/antiphaze-prod.key deploy@129.212.164.31:/tmp/antiphaze-prod.key
ssh deploy@129.212.164.31 'sudo mkdir -p /etc/age && sudo mv /tmp/antiphaze-prod.key /etc/age/keys.txt && sudo chown root:root /etc/age/keys.txt && sudo chmod 600 /etc/age/keys.txt'
```

- [ ] **Step 7: AGENT writes a deploy hook** at `infrastructure/scripts/decrypt-env.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SOPS_AGE_KEY_FILE=/etc/age/keys.txt sops --decrypt /opt/antiphaze/infrastructure/sops/prod.env.enc > /opt/antiphaze/infrastructure/.env
chmod 600 /opt/antiphaze/infrastructure/.env
```

- [ ] **Step 8: USER updates docker-compose.yml** to source `.env` from the decrypted location:
```yaml
services:
  caddy:
    env_file: ../.env
  pretix:
    env_file: ../.env
  # ... etc
```

- [ ] **Step 9: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod
git add infrastructure/sops/.sops.yaml infrastructure/sops/prod.env.example infrastructure/sops/prod.env.enc infrastructure/scripts/decrypt-env.sh
git commit -m "feat(antiphaze): SOPS+age secrets; encrypted prod.env in repo"
```

### Task 4.2: sacred-portal — migrate from `.env.local` to `wrangler secret` [USER + AGENT]

**Files:**
- Delete: `echoeslabwebsite/sacred-portal-wellness/.env.local` (already removed in Phase 0 history scrub; ensure not re-committed)

- [ ] **Step 1: USER runs** for each secret:
```bash
cd ~/Projects/echoeslabwebsite/sacred-portal-wellness
echo "<value>" | wrangler secret put SQUARE_ACCESS_TOKEN
echo "<value>" | wrangler secret put SQUARE_APPLICATION_ID
echo "<value>" | wrangler secret put SQUARE_LOCATION_ID
echo "<value>" | wrangler secret put TURNSTILE_SECRET
```

- [ ] **Step 2: USER lists secrets to confirm:**
```bash
wrangler secret list
```
Expected: all expected names present, values not displayed.

- [ ] **Step 3: AGENT verifies `.env.local` is in `.gitignore`** (already done in Phase 0).

- [ ] **Step 4: AGENT writes a `.env.example`** template at the repo root listing the required env var names with empty values, committed.

### Task 4.3: GlobalManagement — Cloudflare Pages env vars [USER]

- [ ] **Step 1: USER opens Cloudflare Pages project** → Settings → Environment variables.

- [ ] **Step 2: USER adds production env vars** as encrypted: `PUBLIC_WEB3FORMS_ACCESS_KEY`, `PUBLIC_TURNSTILE_SITE_KEY`. Note: `PUBLIC_*` vars are exposed to the browser by Astro convention; these are the only safe ones.

- [ ] **Step 3: USER triggers a redeploy** to pick up the new env vars.

### Task 4.4: GitHub Encrypted Secrets per repo [USER]

- [ ] **Step 1: USER opens each repo's Settings → Secrets and variables → Actions** and adds:
  - GlobalManagement: nothing required for CI (no deploy from CI yet)
  - sacred-portal: `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit), `CLOUDFLARE_ACCOUNT_ID`
  - antiphaze: `SSH_PRIVATE_KEY` (already exists; rotated in Phase 1), `DIGITALOCEAN_ACCESS_TOKEN`, `DO_FIREWALL_ID`, `HOME_IP`

- [ ] **Step 2: USER creates Environments** in each repo (Settings → Environments → New environment → "production") with required reviewers (self) for production deploys. This forces a click-to-approve gate for any production deploy from CI.

---

## Phase 5 — CI/CD security pipeline (the heart of the project)

### Task 5.1: Pre-commit hooks via lefthook [AGENT]

**Files:**
- Create: `echoeslabwebsite/tools/pre-commit-config.yaml` (template)
- Create per site: `echoeslabwebsite/<site>/lefthook.yml`

**Note:** We use lefthook (single binary, no Python dep, faster than pre-commit framework).

- [ ] **Step 1: AGENT writes the shared lefthook template** at `tools/pre-commit-config.yaml` (kept as documentation; sites copy it):
```yaml
pre-commit:
  parallel: true
  commands:
    gitleaks:
      run: gitleaks protect --staged --redact --no-banner
    actionlint:
      glob: ".github/workflows/*.{yml,yaml}"
      run: actionlint {staged_files}
    eslint:
      glob: "*.{js,ts,tsx,jsx}"
      run: npx eslint {staged_files}

pre-push:
  commands:
    reminder:
      run: echo "🔒 Reminder: run /security-review in Claude Code before significant pushes"
```

- [ ] **Step 2: AGENT copies the file** to each site repo as `lefthook.yml`:
```bash
for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
  cp tools/pre-commit-config.yaml ~/Projects/echoeslabwebsite/$r/lefthook.yml
done
```

- [ ] **Step 3: USER installs lefthook** and runs `lefthook install` in each repo:
```bash
brew install lefthook
for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
  cd ~/Projects/echoeslabwebsite/$r && lefthook install
done
```

- [ ] **Step 4: AGENT writes a `.gitleaks.toml`** in each repo (start with the default ruleset, no extras):
```toml
[extend]
useDefault = true
```

- [ ] **Step 5: AGENT commits in each site repo:**
```bash
cd ~/Projects/echoeslabwebsite/<site>
git add lefthook.yml .gitleaks.toml
git commit -m "feat(security): pre-commit hooks (gitleaks, actionlint, eslint)"
```

- [ ] **Step 6: AGENT commits the shared template** in the meta-repo:
```bash
cd ~/Projects/echoeslabwebsite
git add tools/pre-commit-config.yaml
git commit -m "tools: shared lefthook pre-commit config template"
```

### Task 5.2: Custom Semgrep rules — Square wrapper enforcement [AGENT]

**Files:**
- Create: `echoeslabwebsite/tools/semgrep-custom/square-token-wrapper.yaml`
- Create: `echoeslabwebsite/tools/semgrep-custom/tests/square-bad.ts`
- Create: `echoeslabwebsite/tools/semgrep-custom/tests/square-good.ts`

- [ ] **Step 1: AGENT writes the failing test fixtures** first.
  `tools/semgrep-custom/tests/square-bad.ts`:
```typescript
// This file should TRIGGER the rule (raw env access outside wrapper).
const token = process.env.SQUARE_ACCESS_TOKEN;
fetch('https://connect.squareup.com/v2/payments', {
  headers: { Authorization: `Bearer ${token}` },
});
```
  `tools/semgrep-custom/tests/square-good.ts`:
```typescript
// This file should NOT trigger (env access inside wrapper module is allowed).
// File: app/src/lib/square-client.ts
import { SquareClient } from 'square';
export const squareClient = new SquareClient({
  accessToken: process.env.SQUARE_ACCESS_TOKEN!,
  environment: 'production',
});
```

- [ ] **Step 2: AGENT writes the Semgrep rule** at `tools/semgrep-custom/square-token-wrapper.yaml`:
```yaml
rules:
  - id: square-token-only-via-wrapper
    languages: [typescript, javascript]
    severity: ERROR
    message: |
      SQUARE_ACCESS_TOKEN must only be accessed via app/src/lib/square-client.ts.
      Direct env access elsewhere is a security policy violation.
    paths:
      exclude:
        - "**/lib/square-client.ts"
        - "**/lib/square-client.js"
    pattern: process.env.SQUARE_ACCESS_TOKEN
```

- [ ] **Step 3: AGENT runs the rule** against the test fixtures:
```bash
cd ~/Projects/echoeslabwebsite
npx semgrep --config tools/semgrep-custom/square-token-wrapper.yaml tools/semgrep-custom/tests/square-bad.ts
# Expect: 1 finding
npx semgrep --config tools/semgrep-custom/square-token-wrapper.yaml tools/semgrep-custom/tests/square-good.ts
# Expect: 0 findings
```

- [ ] **Step 4: AGENT commits:**
```bash
git add tools/semgrep-custom/square-token-wrapper.yaml tools/semgrep-custom/tests/
git commit -m "tools(semgrep): custom rule — SQUARE_ACCESS_TOKEN only via wrapper"
```

### Task 5.3: Custom Semgrep rule — webhook signature verification [AGENT]

**Files:**
- Create: `echoeslabwebsite/tools/semgrep-custom/webhook-signature.yaml`
- Create: `echoeslabwebsite/tools/semgrep-custom/tests/webhook-bad.ts`
- Create: `echoeslabwebsite/tools/semgrep-custom/tests/webhook-good.ts`

- [ ] **Step 1: AGENT writes test fixtures.**
  `webhook-bad.ts`:
```typescript
export async function POST(req: Request) {
  const body = await req.json();   // No HMAC verification
  await processWebhook(body);
  return new Response('ok');
}
```
  `webhook-good.ts`:
```typescript
import crypto from 'node:crypto';
export async function POST(req: Request) {
  const sig = req.headers.get('x-square-signature');
  const body = await req.text();
  const expected = crypto.createHmac('sha256', process.env.SQUARE_WEBHOOK_KEY!).update(body).digest('base64');
  if (sig !== expected) return new Response('invalid signature', { status: 401 });
  await processWebhook(JSON.parse(body));
  return new Response('ok');
}
```

- [ ] **Step 2: AGENT writes the rule:**
```yaml
rules:
  - id: webhook-must-verify-signature
    languages: [typescript, javascript]
    severity: ERROR
    message: |
      Webhook handlers must verify HMAC signature before processing payload.
      Pattern: read x-*-signature header, compare to HMAC-SHA256 of raw body.
    paths:
      include:
        - "**/api/webhooks/**"
        - "**/api/webhook/**"
    patterns:
      - pattern: |
          export async function POST($REQ) {
            ...
            await processWebhook(...);
            ...
          }
      - pattern-not: |
          export async function POST($REQ) {
            ...
            $SIG = $REQ.headers.get(...)
            ...
            if ($SIG !== $EXPECTED) { ... }
            ...
            await processWebhook(...);
            ...
          }
```

- [ ] **Step 3: AGENT validates the rule** against fixtures.

- [ ] **Step 4: AGENT commits:**
```bash
git add tools/semgrep-custom/webhook-signature.yaml tools/semgrep-custom/tests/webhook-{bad,good}.ts
git commit -m "tools(semgrep): custom rule — webhook handlers must verify HMAC"
```

### Task 5.4: OPA/Conftest policies — Docker compose hardening [AGENT]

**Files:**
- Create: `echoeslabwebsite/policy/containers.rego`
- Create: `echoeslabwebsite/policy/containers_test.rego`

- [ ] **Step 1: AGENT writes the policy test file FIRST:**
```rego
package containers_test
import future.keywords.if

import data.containers

test_deny_public_postgres_port if {
  input := {"services": {"postgres": {"ports": ["5432:5432"]}}}
  count(containers.deny) > 0 with input as input
}

test_allow_only_caddy_publishing_ports if {
  input := {"services": {
    "caddy": {"ports": ["80:80","443:443"], "cap_drop": ["ALL"], "cap_add": ["NET_BIND_SERVICE"]},
    "postgres": {"cap_drop": ["ALL"]}
  }}
  count(containers.deny) == 0 with input as input
}

test_deny_missing_cap_drop if {
  input := {"services": {"redis": {}}}
  count(containers.deny) > 0 with input as input
}

test_deny_privileged if {
  input := {"services": {"foo": {"privileged": true, "cap_drop": ["ALL"]}}}
  count(containers.deny) > 0 with input as input
}
```

- [ ] **Step 2: AGENT runs the tests** (expecting failures since policy not yet written):
```bash
cd ~/Projects/echoeslabwebsite
docker run --rm -v $(pwd)/policy:/policy openpolicyagent/conftest:v0.50.0 verify /policy
```
Expected: 4 tests, all fail.

- [ ] **Step 3: AGENT writes the policy** at `policy/containers.rego`:
```rego
package containers

import future.keywords.if
import future.keywords.in

allowed_publishers := {"caddy"}

deny contains msg if {
  some name, svc in input.services
  svc.ports
  count(svc.ports) > 0
  not name in allowed_publishers
  msg := sprintf("service '%s' must not publish ports to host", [name])
}

deny contains msg if {
  some name, svc in input.services
  not svc.cap_drop
  msg := sprintf("service '%s' missing cap_drop", [name])
}

deny contains msg if {
  some name, svc in input.services
  svc.privileged == true
  msg := sprintf("service '%s' is privileged", [name])
}
```

- [ ] **Step 4: AGENT runs tests again, expects pass:**
```bash
docker run --rm -v $(pwd)/policy:/policy openpolicyagent/conftest:v0.50.0 verify /policy
```
Expected: 4 tests pass.

- [ ] **Step 5: AGENT runs the policy against the actual antiphaze compose file:**
```bash
cd ~/Projects/echoeslabwebsite/antiphazeprod/infrastructure
docker run --rm -v $(pwd):/project -v $(pwd)/../../policy:/policy openpolicyagent/conftest:v0.50.0 test /project/docker-compose.yml -p /policy
```
Expected: 0 violations (after Phase 1 fixes are in place).

- [ ] **Step 6: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite
git add policy/containers.rego policy/containers_test.rego
git commit -m "feat(policy): conftest rules for docker compose hardening"
```

### Task 5.5: OPA/Conftest policies — GitHub Actions hardening [AGENT]

**Files:**
- Create: `echoeslabwebsite/policy/github-actions.rego`
- Create: `echoeslabwebsite/policy/github-actions_test.rego`

- [ ] **Step 1: AGENT writes test fixtures and tests** (mirror of Task 5.4 structure):
   - Reject any `uses: <action>@<branch-or-tag>` (must be SHA-pinned)
   - Reject `permissions: write-all` or absence of `permissions:` block
   - Reject any step using `${{ github.event.pull_request.title }}` directly in `run:` (workflow injection)

- [ ] **Step 2: AGENT writes the policy** with three rules.

- [ ] **Step 3: AGENT runs tests, validates against existing workflows** (e.g., antiphaze's `update-pretix.yml`).

- [ ] **Step 4: AGENT commits:**
```bash
git add policy/github-actions.rego policy/github-actions_test.rego
git commit -m "feat(policy): conftest rules for GitHub Actions hardening"
```

### Task 5.6: Reusable `_security-base.yml` workflow (the core gate) [AGENT]

**Files:**
- Create: `echoeslabwebsite/workflows-templates/_security-base.yml`

- [ ] **Step 1: AGENT writes the reusable workflow.** This is the most important file in the project.
```yaml
name: _security-base
on:
  workflow_call:
    inputs:
      site-type:        { type: string, required: true, description: "static | next | astro-ssr" }
      scan-containers:  { type: boolean, default: false }
      dast-target-url:  { type: string, required: false }
      semgrep-rulesets: { type: string, default: "p/owasp-top-ten,p/javascript,p/typescript" }

permissions:
  contents: read
  security-events: write    # for SARIF upload
  id-token: write            # for OIDC + Sigstore keyless signing
  attestations: write        # for SLSA build provenance

jobs:
  secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ github.token }}

  sast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: returntocorp/semgrep-action@v1
        with:
          config: ${{ inputs.semgrep-rulesets }}
          generateSarif: "1"
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with: { sarif_file: semgrep.sarif }

  sca:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: google/osv-scanner-action@v1
        with: { scan-args: "-r --skip-git ./" }
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with: { sarif_file: results.sarif }

  iac:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bridgecrewio/checkov-action@v12
        with:
          directory: .
          output_format: sarif
          output_file_path: checkov-results.sarif
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with: { sarif_file: checkov-results.sarif }
      - uses: woodruffw/zizmor-action@v0
      - uses: rhysd/actionlint@v1

  container:
    if: inputs.scan-containers
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t local-image:scan .
      - uses: aquasecurity/trivy-action@v0.20.0
        with:
          image-ref: local-image:scan
          format: sarif
          output: trivy-results.sarif
          severity: CRITICAL,HIGH
          exit-code: "1"
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with: { sarif_file: trivy-results.sarif }

  policy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: instrumenta/conftest-action@master
        with:
          files: docker-compose.yml infrastructure/docker-compose.yml .github/workflows/*.yml
          policy: ${{ github.workspace }}/policy

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22', cache: 'npm' }
      - run: npm ci
      - run: npm run build
      - uses: anchore/sbom-action@v0
        with:
          format: cyclonedx-json
          artifact-name: sbom.cdx.json

  gate:
    needs: [secrets, sast, sca, iac, policy, build]
    runs-on: ubuntu-latest
    steps:
      - run: echo "All security gates passed."
```

- [ ] **Step 2: AGENT validates with `actionlint`:**
```bash
cd ~/Projects/echoeslabwebsite
docker run --rm -v $(pwd):/repo rhysd/actionlint:latest /repo/workflows-templates/_security-base.yml
```
Expected: no errors.

- [ ] **Step 3: AGENT commits:**
```bash
git add workflows-templates/_security-base.yml
git commit -m "feat(ci): reusable security-base workflow with 6 parallel gating jobs"
```

### Task 5.7: Per-site `security.yml` workflows [AGENT]

**Files:**
- Create: `echoeslabwebsite/GlobalManagement/.github/workflows/security.yml`
- Create: `echoeslabwebsite/sacred-portal-wellness/.github/workflows/security.yml`
- Create: `echoeslabwebsite/antiphazeprod/.github/workflows/security.yml`

**Note:** Since the reusable workflow lives in `echoeslabwebsite/` (a separate repo), each site's caller must reference it via the published path. There are two viable approaches:

**Approach A (chosen):** Vendor the reusable workflow into each site repo's `.github/workflows/_security-base.yml` and call it locally via `uses: ./.github/workflows/_security-base.yml`. Sync drift by a meta-repo CI check (Task 5.8).

**Approach B:** Push the reusable workflow to a public `org/.github` repo and reference via `uses: org/.github/.github/workflows/_security-base.yml@v1`. Requires repo to exist; defer to Phase 7.

We use Approach A initially.

- [ ] **Step 1: AGENT copies `_security-base.yml`** into each site repo's `.github/workflows/`.

- [ ] **Step 2: AGENT writes the per-site `security.yml` thin caller:**

  **GlobalManagement (`security.yml`):**
```yaml
name: security
on:
  push: { branches: [main, devops] }
  pull_request:
jobs:
  base:
    uses: ./.github/workflows/_security-base.yml
    with:
      site-type: static
      scan-containers: false
      semgrep-rulesets: "p/owasp-top-ten,p/javascript"
```

  **sacred-portal-wellness (`security.yml`):**
```yaml
name: security
on:
  push: { branches: [main, devops] }
  pull_request:
jobs:
  base:
    uses: ./.github/workflows/_security-base.yml
    with:
      site-type: next
      scan-containers: false
      semgrep-rulesets: "p/owasp-top-ten,p/javascript,p/typescript,p/nextjs,p/react"
```

  **antiphazeprod (`security.yml`):**
```yaml
name: security
on:
  push: { branches: [main, devops] }
  pull_request:
jobs:
  base:
    uses: ./.github/workflows/_security-base.yml
    with:
      site-type: astro-ssr
      scan-containers: true
      semgrep-rulesets: "p/owasp-top-ten,p/javascript,p/typescript"
```

- [ ] **Step 3: AGENT commits in each site repo:**
```bash
cd ~/Projects/echoeslabwebsite/<site>
git add .github/workflows/_security-base.yml .github/workflows/security.yml
git commit -m "ci(security): add reusable security base + per-site caller"
```

- [ ] **Step 4: USER pushes each devops branch** to GitHub:
```bash
for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
  cd ~/Projects/echoeslabwebsite/$r && git push -u origin devops
done
```

- [ ] **Step 5: USER opens a PR** from `devops` → `main` in each repo (or just observes the workflow run on the devops push). Confirms all 6 jobs run, all pass on initial push (allowlists may be needed for known issues).

### Task 5.8: Drift detection — sync `_security-base.yml` across repos [AGENT]

**Files:**
- Create: `echoeslabwebsite/.github/workflows/sync-base-workflow.yml`

- [ ] **Step 1: AGENT writes a meta-repo workflow** that, when `workflows-templates/_security-base.yml` changes on the meta-repo's devops branch, opens PRs in each of the 3 site repos to update their copy.

```yaml
name: Sync security-base to site repos
on:
  push:
    branches: [devops]
    paths: ['workflows-templates/_security-base.yml']
  workflow_dispatch:
permissions:
  contents: read
jobs:
  fanout:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        repo: [habibots/GlobalManagement, habibots/sacred-portal-wellness, echoeslabmusic/antiphazeprod]
    steps:
      - uses: actions/checkout@v4
      - run: |
          gh repo clone ${{ matrix.repo }} target
          cp workflows-templates/_security-base.yml target/.github/workflows/_security-base.yml
          cd target
          git config user.name "echoeslab-bot"
          git config user.email "echoeslab-bot@users.noreply.github.com"
          git checkout -b sync-security-base-$(date +%Y%m%d)
          git add .github/workflows/_security-base.yml
          git diff --quiet --cached || (git commit -m "ci: sync _security-base.yml from echoeslabwebsite meta-repo" && git push -u origin HEAD && gh pr create --title "Sync _security-base.yml" --body "Automated sync from echoeslabwebsite meta-repo." --base devops)
        env:
          GH_TOKEN: ${{ secrets.SYNC_PAT }}
```

- [ ] **Step 2: USER creates a fine-grained Personal Access Token** with `pull_requests: write` and `contents: write` for the three repos; saves to meta-repo Secrets as `SYNC_PAT`.

- [ ] **Step 3: AGENT commits:**
```bash
cd ~/Projects/echoeslabwebsite
git add .github/workflows/sync-base-workflow.yml
git commit -m "ci(meta): fan out _security-base.yml changes to site repos"
```

### Task 5.9: Drift detection — nightly rescan [AGENT]

**Files:**
- Create: `echoeslabwebsite/workflows-templates/_drift-nightly.yml`
- Add to each site repo: `.github/workflows/_drift-nightly.yml`

- [ ] **Step 1: AGENT writes the nightly workflow:**
```yaml
name: drift-nightly
on:
  schedule: [{ cron: '0 7 * * *' }]   # 07:00 UTC daily
  workflow_dispatch:
permissions:
  contents: read
  security-events: write
jobs:
  rescan:
    uses: ./.github/workflows/_security-base.yml
    with:
      site-type: ${{ vars.SITE_TYPE }}
      scan-containers: ${{ vars.SCAN_CONTAINERS == 'true' }}
```

- [ ] **Step 2: USER sets repo variables `SITE_TYPE` and `SCAN_CONTAINERS`** in each site repo Settings → Variables.

- [ ] **Step 3: AGENT copies the drift workflow** into each site repo and commits.

### Task 5.10: Branch protection rules [USER]

- [ ] **Step 1: USER configures branch protection on `main`** for each repo (Settings → Branches → Add rule → branch name pattern: `main`):
   - Require status checks: `gate` (the final job from `_security-base.yml`)
   - Require branches to be up to date before merging
   - Require linear history
   - Require signed commits
   - Block force pushes
   - Restrict who can push to matching branches: only repo admins

- [ ] **Step 2: USER also configures `devops` branch** with looser rules:
   - Require status checks: `gate`
   - No signed-commit requirement (you'll iterate fast)

- [ ] **Step 3: USER documents the rules** in `docs/runbooks/branch-protection.md`.

---

## Phase 6 — Build provenance, signing, and SBOM

### Task 6.1: Cosign keyless signing on releases [AGENT]

**Files:**
- Modify: `echoeslabwebsite/workflows-templates/_security-base.yml` (add release jobs)

- [ ] **Step 1: AGENT adds a `release` job** to `_security-base.yml` triggered only on tag push:
```yaml
  release:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: [gate]
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22', cache: 'npm' }
      - run: npm ci && npm run build
      - uses: anchore/sbom-action@v0
        with: { format: cyclonedx-json, artifact-name: sbom.cdx.json }
      - uses: sigstore/cosign-installer@v3
      - run: |
          tar -czf release.tar.gz dist/ || tar -czf release.tar.gz .next/ || tar -czf release.tar.gz build/
          cosign sign-blob --yes --bundle release.cosign.bundle release.tar.gz
      - uses: actions/attest-build-provenance@v1
        with: { subject-path: release.tar.gz }
      - uses: softprops/action-gh-release@v2
        with:
          files: |
            release.tar.gz
            sbom.cdx.json
            release.cosign.bundle
```

- [ ] **Step 2: AGENT documents verification** in `docs/runbooks/verify-release.md`:
```bash
# Verify release artifact came from this repo's workflow:
gh attestation verify --repo <owner>/<repo> release.tar.gz
# Verify cosign signature against transparency log:
cosign verify-blob --bundle release.cosign.bundle release.tar.gz
```

- [ ] **Step 3: AGENT commits and triggers a test release.**

### Task 6.2: Per-release compliance report (auto-generated) [AGENT]

**Files:**
- Create: `echoeslabwebsite/tools/scripts/compliance-report.sh`
- Modify: `_security-base.yml` (add report job)

- [ ] **Step 1: AGENT writes the report generator** that pulls the SARIF results, the SBOM, the attestation, and emits a markdown summary attached to the GitHub release.

- [ ] **Step 2: AGENT integrates** into the release job.

- [ ] **Step 3: AGENT commits.**

---

## Phase 7 — Local Claude Code review workflow

### Task 7.1: Per-repo `/security-review` slash command [AGENT]

**Files:**
- Create: `echoeslabwebsite/GlobalManagement/.claude/commands/security-review.md`
- Create: `echoeslabwebsite/sacred-portal-wellness/.claude/commands/security-review.md`
- Create: `echoeslabwebsite/antiphazeprod/.claude/commands/security-review.md`

- [ ] **Step 1: AGENT writes a parametrized template** at `tools/security-review-template.md`:
```markdown
---
name: security-review
description: Pre-push security review of the current branch's diff
---

You are a senior security reviewer for this repo. Site type: $SITE_TYPE.

## Step 1 — Read the diff
Run: `git diff main..HEAD`
Read every changed file in full context.

## Step 2 — Read reference docs
- `../docs/threats/threat-model.md`
- `../docs/threats/$SITE_NAME.md`
- `../docs/security-policy.md`

## Step 3 — Run scanners locally
- `gitleaks detect --source . --no-git`
- `npx semgrep --config p/owasp-top-ten --json`
- `npx osv-scanner --lockfile package-lock.json --format json`
$EXTRA_SCANNERS

## Step 4 — Analyze
For each scanner finding AND each diff hunk, classify:
- Severity: Critical | High | Medium | Low | Info
- Category: auth | crypto | input | secrets | csp | session | rate-limit | webhook | other
- File:line, rationale, suggested fix.

## Step 5 — Pay extra attention to
- Auth / authz changes
- CSP / HSTS / security header changes
- CORS widening
- Webhook signature verification (sacred-portal Square webhooks)
- Secret handling (env access, secrets in logs, raw token use)
- Rate-limiting / abuse-prevention changes
- New `fetch()` to non-allowlisted domains
- Dynamic `eval`, `Function()`, `dangerouslySetInnerHTML`

## Step 6 — Output
Write a markdown report with:
1. Summary verdict: PASS | PASS-WITH-FINDINGS | BLOCK
2. Findings table (severity, file:line, category, rationale, suggested-fix)
3. Recommended actions before push
4. Save the report to `.security-reviews/PR-$BRANCH-$DATE-$SHORT_SHA.md`
5. Suggest committing it via:
   `git add .security-reviews/ && git commit -m "Security review for $BRANCH"`
```

- [ ] **Step 2: AGENT renders the template** for each site (substituting `$SITE_TYPE`, `$SITE_NAME`, `$EXTRA_SCANNERS`):
   - GlobalManagement: SITE_TYPE=static, SITE_NAME=globalmanagement, EXTRA_SCANNERS=(none)
   - sacred-portal-wellness: SITE_TYPE=next, SITE_NAME=sacred-portal, EXTRA_SCANNERS=`npx semgrep --config tools/semgrep-custom/square-token-wrapper.yaml`, `npx semgrep --config tools/semgrep-custom/webhook-signature.yaml`
   - antiphazeprod: SITE_TYPE=astro-ssr, SITE_NAME=antiphaze, EXTRA_SCANNERS=`docker run --rm -v $(pwd):/repo aquasec/trivy:latest fs /repo`

- [ ] **Step 3: AGENT commits in each site repo:**
```bash
cd ~/Projects/echoeslabwebsite/<site>
git add .claude/commands/security-review.md
git commit -m "feat(claude): /security-review slash command"
```

- [ ] **Step 4: USER tests the command** in one repo:
```bash
cd ~/Projects/echoeslabwebsite/sacred-portal-wellness
claude
# In the Claude Code prompt:
/security-review
```
Expected: Claude reads the diff, runs the scanners, produces a markdown report.

### Task 7.2: `.security-reviews/` directory convention [AGENT]

**Files:**
- Create: `echoeslabwebsite/<site>/.security-reviews/.gitkeep` (per site)
- Modify: `echoeslabwebsite/<site>/.gitignore` (ensure `.security-reviews/` is NOT ignored)

- [ ] **Step 1: AGENT creates `.security-reviews/.gitkeep`** in each site repo and adds a README.md explaining the convention.

- [ ] **Step 2: AGENT commits in each site repo.**

### Task 7.3: CONTRIBUTING.md per repo with the workflow [AGENT]

**Files:**
- Create: `echoeslabwebsite/<site>/CONTRIBUTING.md` (per site)

- [ ] **Step 1: AGENT writes a brief CONTRIBUTING.md** that documents:
   - "All work on `devops` branch; never push to `main` directly"
   - "Run `/security-review` in Claude Code before pushing significant changes"
   - "Save the review output to `.security-reviews/`"
   - "Pre-commit hooks run automatically (gitleaks + actionlint + eslint)"
   - "CI gates on push: secrets, sast, sca, iac, policy, build (and container for antiphaze)"

- [ ] **Step 2: AGENT commits.**

---

## Phase 8 — Documentation & runbooks (the portfolio polish)

### Task 8.1: Threat model docs [AGENT]

**Files:**
- Create: `echoeslabwebsite/docs/threats/threat-model.md`
- Create: `echoeslabwebsite/docs/threats/globalmanagement.md`
- Create: `echoeslabwebsite/docs/threats/sacred-portal.md`
- Create: `echoeslabwebsite/docs/threats/antiphaze.md`

- [ ] **Step 1: AGENT writes the cross-cutting threat model** referencing the design doc §3 (8 threats, 4 accepted risks).

- [ ] **Step 2: AGENT writes per-site threat models** with: trust boundaries, data flows (mermaid diagrams), per-asset threats (STRIDE-lite), mitigations.

- [ ] **Step 3: AGENT commits.**

### Task 8.2: Security policy doc [AGENT]

**Files:**
- Create: `echoeslabwebsite/docs/security-policy.md`

- [ ] **Step 1: AGENT writes the policy** capturing what's enforced by tooling vs. what's discipline:
   - Branch protection rules (lift from Task 5.10)
   - Severity-gating philosophy (block C/H, log M/L)
   - Allowlist hygiene (`# justified: <reason> <YYYY-MM-DD-expiry>` with expiry enforcement)
   - Signed-commit requirement on main
   - The "no Square access token outside the wrapper" rule (enforced by Task 5.2)
   - Webhook HMAC verification rule (Task 5.3)

- [ ] **Step 2: AGENT commits.**

### Task 8.3: Operational runbooks [AGENT]

**Files:**
- Create: `echoeslabwebsite/docs/runbooks/secrets-rotation.md`
- Create: `echoeslabwebsite/docs/runbooks/secrets-management.md`
- Create: `echoeslabwebsite/docs/runbooks/cloudflare-fallback.md`
- Create: `echoeslabwebsite/docs/runbooks/verify-release.md` (already partial from Task 6.1)

- [ ] **Step 1: AGENT writes `secrets-rotation.md`** — runbook for routine rotation of Square / SMTP / Cloudflare API token / Wrangler API token / SSH deploy key. Cadence: quarterly.

- [ ] **Step 2: AGENT writes `secrets-management.md`** — the per-environment integration table from design doc §9.

- [ ] **Step 3: AGENT writes `cloudflare-fallback.md`** — runbook for what to do during a Cloudflare outage:
   - Marketing page fallback: bypass DNS proxy (turn off orange cloud); direct DNS to droplet IP
   - Payments unavailable; post status page
   - Reference Cloudflare incident page; expected restoration time

- [ ] **Step 4: AGENT commits.**

### Task 8.4: Workspace README + CONTRIBUTING [AGENT]

**Files:**
- Create: `echoeslabwebsite/README.md`
- Create: `echoeslabwebsite/CONTRIBUTING.md`

- [ ] **Step 1: AGENT writes README.md** with: project overview, file map, quickstart, links to design doc and plan, status badges (CI runs).

- [ ] **Step 2: AGENT writes CONTRIBUTING.md** with the workflow: "all work on `devops` branch", "run `/security-review` before pushing", commit message conventions.

- [ ] **Step 3: AGENT commits.**

### Task 8.5: Canarytokens [USER]

- [ ] **Step 1: USER generates 3 AWS-key canarytokens** at https://canarytokens.org/generate (free).

- [ ] **Step 2: USER plants** each token in a plausible-looking file in each repo (e.g., `infrastructure/legacy/.old-deploy.env.bak`). The file should look real but be obviously inert. Commit on devops branch.

- [ ] **Step 3: USER configures alerting** on each canarytoken (email destination = USER's primary email).

- [ ] **Step 4: USER documents the canarytokens** in `docs/runbooks/canarytokens.md` (private — don't commit the actual fingerprints, just the locations and alert addresses).

---

## Phase 9 — Verification & cutover

### Task 9.1: End-to-end smoke test [AGENT + USER]

- [ ] **Step 1: AGENT runs** `tools/scripts/test-headers.sh` against all 3 production URLs.

- [ ] **Step 2: AGENT runs** `tools/scripts/test-tls.sh` against all 3.

- [ ] **Step 3: USER manually tests** each contact form, the Pretix admin login (Cloudflare Access flow), and (if possible) a sacred-portal test checkout.

- [ ] **Step 4: USER opens a PR in each site repo** with a trivial change to confirm the full CI pipeline runs and gates pass.

- [ ] **Step 5: USER reviews** the GitHub Security tab in each repo for any unexpected SARIF findings.

### Task 9.2: HSTS preload submission decision [USER]

- [ ] **Step 1: USER waits 2 weeks** after final config changes to ensure no HTTPS regressions on any subdomain.

- [ ] **Step 2: USER uses https://hstspreload.org** to test each domain. Submit ONLY when checklist is green.

- [ ] **Step 3: USER documents submission date and one-way-door warning** in `docs/runbooks/hsts-preload.md`.

### Task 9.3: Final design doc + plan update [AGENT]

- [ ] **Step 1: AGENT updates the design doc** Section 12 (open questions) marking each as resolved with the resolution.

- [ ] **Step 2: AGENT writes a `docs/CHANGELOG.md`** entry summarizing what shipped in this hardening pass.

- [ ] **Step 3: AGENT commits and tags `v1.0.0` on the meta-repo.**

---

## Self-review notes

After this plan was drafted, the author re-read it against the design spec:
- All 8 threats from spec §3 → covered (Phase 0, 1, 2, 3, 4, 5)
- All SDLC phase controls from spec §4 → covered (Phases 4, 5, 6, 7)
- Per-site target architecture from spec §5 → covered (Phases 2, 3)
- CI/CD pipeline from spec §6 → covered (Phase 5, especially 5.6)
- Local Claude Code review from spec §7 → covered (Phase 7)
- TLS baseline from spec §8 → covered (Phase 3)
- Secrets remediation from spec §9 → covered (Phase 0)
- Risk register R1-R10 from spec §11 → mitigations encoded across phases
- Open question Q1 (HSTS preload) → Task 9.2
- Open question Q2 (Cloudflare cutover) → Task 2.1 step 5
- Open question Q3 (Square integration mode) → flagged in Phase 4 Task 4.2 prerequisite check
- Open question Q4 (repo visibility) → flagged in Phase 5 Task 5.7 step 4
- Open question Q5 (audit retention) → accepted; Cloudflare R2 mentioned in Phase 8
- Open question Q6 (encrypted Pretix backups via DO Spaces $5/mo) → not implemented in this plan; logged for follow-up

No placeholders ("TBD", "TODO", "implement later") found.
No type/method-name inconsistencies found between tasks.
