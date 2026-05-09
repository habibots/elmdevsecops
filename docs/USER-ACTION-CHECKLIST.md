# USER Action Checklist — Final Hardening Cutover

**Date generated:** 2026-05-07
**Status of agent work:** complete (~30 commits across 4 repos, all on `devops` branches, design + plan + final review all APPROVED).

This is everything *you* need to do to finish the project. Each item is something the agent cannot do (dashboard click, secret rotation, NS change, droplet SSH, etc.). Order matters — earlier items unblock later ones.

Estimated total time: **8–12 hours of focused work over 2–3 days**, plus two waiting windows (NS propagation, HSTS preload).

---

## ⚠️ IMPORTANT RECON CORRECTION (read first)

The original recon agent's "leaked credentials" picture was partially wrong, in your favor:

| Original recon claim | Actual git history | Real action needed |
|---|---|---|
| `sacred-portal-wellness/.env.local` with live Square production credentials was committed | **Never in git history.** Only `.env.example` (placeholders) was committed. | If a `.env.local` with real production credentials exists on your local disk, rotate the keys (defense in depth) but **no GitHub history scrubbing is needed and no GitHub Support ticket is needed.** |
| `GlobalManagement/.env` with `PUBLIC_WEB3FORMS_ACCESS_KEY` was committed | Web3Forms key was hardcoded in `src/components/ContactForm.astro` as a default prop value at commit `57bb04c`. The `.env` file itself was never tracked. | Rotate the Web3Forms key. The IR doc accurately reflects this. History scrubbing via `tools/scripts/scrub-secrets.sh` should target the `ContactForm.astro` content, not `.env`. |
| antiphaze SMTP user/pass hardcoded in `contact.ts` | Only the SMTP **username** was leaked (`'antiphazeprod.com'`); password fallback was an empty string (silent-fail bug, not a credential leak). | SMTP password rotation is optional / hygiene. Username rotation is even less urgent. |

**Practical implication:** the urgency of Phase 0 IR is lower than the design doc assumed. Take a breath.

---

## P0 — Today (Phase 0 IR + Phase 1 stabilization)

### ✅ DONE BY AGENT
- Wrote IR template + 3 per-repo incident reports (`SECURITY-INCIDENT-2026-05-07.md`)
- Wrote `tools/scripts/scrub-secrets.sh` (uses `git-filter-repo`)
- Added `.env*` patterns to all 3 repos' `.gitignore`
- Verified Node 22 is already in use in antiphaze (`@astrojs/node ^10.0.4`, `engines.node ">=22.12.0"`)
- Locked down `infrastructure/docker/docker-compose.yml`: `cap_drop: [ALL]`, no public ports for postgres/redis, `read_only: true` + tmpfs for caddy
- Removed SMTP credential fallback from `website/src/pages/api/contact.ts` (now throws if env missing)

### TODO BY YOU

- [ ] **Rotate Web3Forms access key.** https://web3forms.com → dashboard → regenerate key. Save new key to 1Password.
- [ ] **Rotate Square production access token (if you have a live one in your local `.env.local`).** https://developer.squareup.com/apps → sacred-portal app → Production tab → Replace token. Save new values to 1Password. Then run the abuse check:
  ```bash
  curl -s -H "Authorization: Bearer $NEW_TOKEN" -H "Square-Version: 2025-11-19" \
       "https://connect.squareup.com/v2/payments?begin_time=2026-04-01T00:00:00Z" | jq
  ```
  Reconcile every transaction against your expected ledger. Anything unaccounted → file a Square dispute and email security@squareup.com.
- [ ] **Rotate SMTP2GO credentials.** https://app.smtp2go.com → Settings → SMTP Users → reset password (or delete + recreate user). Review Activity report for the exposure window — any unexpected sends?
- [ ] **Run scrub-secrets.sh against ContactForm.astro for GlobalManagement.** First create `/tmp/secret-replacements.txt` with the literal old Web3Forms key:
  ```
  71733509-82e6-4e55-a8ca-aa29380be39c==>REDACTED_WEB3FORMS_KEY
  ```
  Then:
  ```bash
  cd ~/Projects/elmdevsecops
  ./tools/scripts/scrub-secrets.sh ./GlobalManagement '' /tmp/secret-replacements.txt
  ```
  (Empty string for path — only `--replace-text` will run, no path removal.) Then `cd GlobalManagement && git push --force --all`. Then `shred -u /tmp/secret-replacements.txt`.
- [ ] **Update each `SECURITY-INCIDENT-2026-05-07.md`** Timeline + Evidence sections with your actual rotation timestamps and abuse-check findings. Commit on `devops`.

### Phase 1 USER tasks (droplet SSH hardening)

- [ ] **Generate ed25519 deploy key locally:**
  ```bash
  ssh-keygen -t ed25519 -C "antiphaze-deploy-2026-05-07" -f ~/.ssh/antiphaze_deploy
  ```
  Use a passphrase. Save passphrase + private key to 1Password.
- [ ] **Add public key to droplet:**
  ```bash
  ssh-copy-id -i ~/.ssh/antiphaze_deploy.pub deploy@129.212.164.31
  ```
  Test login. Then disable password auth in `/etc/ssh/sshd_config` (`PasswordAuthentication no`, `PubkeyAuthentication yes`, `PermitRootLogin no`) and `sudo systemctl reload sshd`. **Test from a second terminal before closing your working session.**
- [ ] **Install fail2ban:**
  ```bash
  sudo apt-get update && sudo apt-get install -y fail2ban
  sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
  sudo systemctl restart fail2ban
  sudo fail2ban-client status sshd
  ```
- [ ] **Replace GitHub Actions deploy key** in antiphazeprod repo Settings → Secrets → `SSH_PRIVATE_KEY` with the new key's private contents.
- [ ] **Trigger `update-pretix.yml`** manually (Actions tab → Run workflow) to confirm it works with the new key.

---

## P1 — Day 2 (Cloudflare cutover)

### ✅ DONE BY AGENT
- Wrote `docs/runbooks/cloudflare-bootstrap.md` (562 lines, 21 sections — every dashboard click documented)

### TODO BY YOU
Follow `docs/runbooks/cloudflare-bootstrap.md` step by step. High-level:

- [ ] **Create Cloudflare account** (Free plan). Enable 2FA.
- [ ] **Add zones** for `globalmanagement.com`, `sacredportalwellness.com` (or whatever the actual domain is — confirm), `antiphazeprod.com`. Take screenshots of original DNS records for rollback.
- [ ] **Update registrar nameservers** to Cloudflare's. **This is a real cutover — schedule a low-traffic window.** NS propagation is 1–4 hours.
- [ ] **Per-zone settings**: SSL/TLS = Full (strict), Always Use HTTPS = ON, Min TLS = 1.2, **HSTS in dashboard = OFF** (set in code instead), Bot Fight Mode = ON, WAF Managed Rules + OWASP Core Ruleset = ON (Medium sensitivity), HTTP/3 = ON, **0-RTT = OFF** (replay risk).
- [ ] **Create Cloudflare Origin CA cert** for antiphaze, copy to droplet at `/etc/caddy/origin.crt` + `/etc/caddy/origin.key` (key 0600, root-owned).
- [ ] **Cloudflare Pages** for GlobalManagement: connect repo, framework=Astro, build=`npm run build`, output=`dist`, custom domains, env vars (`PUBLIC_WEB3FORMS_ACCESS_KEY`, `PUBLIC_TURNSTILE_SITE_KEY`).
- [ ] **Create Turnstile sites** (3 — one per domain). Capture site keys + secret keys.
- [ ] **Set up Cloudflare Zero Trust Access** for `tickets.antiphazeprod.com/control*`: One-time PIN identity, allowlist your email, require WebAuthn, 8-hour session.
- [ ] **Build and push the new Caddy image** with the Cloudflare DNS plugin (already configured in `infrastructure/docker/caddy/Dockerfile`):
  ```bash
  ssh deploy@129.212.164.31 'cd /opt/antiphaze && git pull origin devops && cd infrastructure/docker && docker compose build caddy && docker compose up -d'
  ```
- [ ] **Verify** with the smoke-test scripts:
  ```bash
  cd ~/Projects/elmdevsecops
  ./tools/scripts/test-headers.sh https://antiphazeprod.com
  ./tools/scripts/test-headers.sh https://tickets.antiphazeprod.com
  ./tools/scripts/test-tls.sh antiphazeprod.com
  ```
  Expected: all 5 headers PASS, TLS baseline PASS.

---

## P2 — Day 3 (Secrets management going forward)

### ✅ DONE BY AGENT
- Wrote SOPS scaffolding for antiphaze: `.sops.yaml`, `prod.env.example`, `infrastructure/scripts/decrypt-env.sh`
- Documented secrets management in `docs/runbooks/secrets-management.md` and `docs/runbooks/secrets-rotation.md`

### TODO BY YOU

- [ ] **Install sops + age locally:** `brew install sops age`
- [ ] **Generate age key:**
  ```bash
  mkdir -p ~/.age
  age-keygen -o ~/.age/antiphaze-prod.key
  chmod 600 ~/.age/antiphaze-prod.key
  ```
  Save the private key contents to 1Password. Note the public key (printed during keygen).
- [ ] **Replace placeholder in `.sops.yaml`:**
  ```bash
  cd ~/Projects/elmdevsecops/antiphazeprod
  sed -i.bak "s|REPLACE_WITH_PRODUCTION_AGE_PUBLIC_KEY|$(cat ~/.age/antiphaze-prod.key.pub)|" infrastructure/sops/.sops.yaml
  rm infrastructure/sops/.sops.yaml.bak
  git add infrastructure/sops/.sops.yaml && git commit -m "ops(antiphaze): set production age public key for SOPS"
  ```
- [ ] **Encrypt the real prod env:**
  ```bash
  cp infrastructure/sops/prod.env.example /tmp/prod.env
  # Edit /tmp/prod.env, fill in REAL values from 1Password
  sops --encrypt --age "$(cat ~/.age/antiphaze-prod.key.pub)" /tmp/prod.env > infrastructure/sops/prod.env.enc
  shred -u /tmp/prod.env
  git add infrastructure/sops/prod.env.enc && git commit -m "ops(antiphaze): encrypted prod env (SOPS+age)"
  ```
- [ ] **Copy the age key to droplet:**
  ```bash
  scp ~/.age/antiphaze-prod.key deploy@129.212.164.31:/tmp/antiphaze-prod.key
  ssh deploy@129.212.164.31 'sudo mkdir -p /etc/age && sudo mv /tmp/antiphaze-prod.key /etc/age/keys.txt && sudo chown root:root /etc/age/keys.txt && sudo chmod 600 /etc/age/keys.txt'
  ```
- [ ] **For sacred-portal: migrate runtime secrets to wrangler:**
  ```bash
  cd ~/Projects/elmdevsecops/sacred-portal-wellness/app
  echo "<value>" | wrangler secret put SQUARE_ACCESS_TOKEN
  echo "<value>" | wrangler secret put SQUARE_APPLICATION_ID
  echo "<value>" | wrangler secret put SQUARE_LOCATION_ID
  echo "<value>" | wrangler secret put TURNSTILE_SECRET
  echo "<value>" | wrangler secret put SQUARE_WEBHOOK_KEY
  wrangler secret list  # verify
  ```
- [ ] **Add GitHub Encrypted Secrets** to each repo (Settings → Secrets and variables → Actions):
  - sacred-portal: `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit), `CLOUDFLARE_ACCOUNT_ID`
  - antiphaze: `DIGITALOCEAN_ACCESS_TOKEN`, `DO_FIREWALL_ID`, `HOME_IP` (your home IP from `curl ifconfig.me`)
  - meta-repo: `DIGITALOCEAN_ACCESS_TOKEN`, `DO_FIREWALL_ID`, `HOME_IP`
- [ ] **Create `production` Environment** in each repo (Settings → Environments → New) with required reviewers (yourself).
- [ ] **Create the DO Cloud Firewall** (if not already): `doctl compute firewall create --name antiphaze-fw --inbound-rules ...` or via dashboard.
- [ ] **Trigger `refresh-do-firewall.yml`** workflow once manually to confirm it works.

---

## P3 — Day 3-4 (Pipeline activation + branch protection)

### ✅ DONE BY AGENT
- Vendored `_security-base.yml`, `_drift-nightly.yml`, `security.yml`, `policy/`, `tools/semgrep-custom/`, `lefthook.yml`, `.gitleaks.toml` into each site repo
- All third-party Actions SHA-pinned (verified live via `gh api`)
- Custom Semgrep rules + OPA policies with TDD test suites — all pass

### TODO BY YOU

- [ ] **Install lefthook locally** and run `lefthook install` in each site repo:
  ```bash
  brew install lefthook
  for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
    cd ~/Projects/elmdevsecops/$r && lefthook install
  done
  ```
- [ ] **Push each site's `devops` branch** to GitHub:
  ```bash
  for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
    cd ~/Projects/elmdevsecops/$r && git push -u origin devops
  done
  ```
  Watch Actions tab for the workflow run. All 6 jobs (or 7 with container for antiphaze) should run in parallel.
- [ ] **Open a PR** from `devops` → `main` in each repo. Confirm `gate` job is present and required.
- [ ] **Configure branch protection on `main`** in each repo (Settings → Branches → Add rule → `main`):
  - Require status checks: `gate` (and `gate / Verify all gates passed`)
  - Require branches up to date before merge
  - Require linear history
  - Require signed commits *(after gitsign setup; defer if you want)*
  - Block force pushes
  - Restrict push: only repo admins
- [ ] **Configure repo variables** for `_drift-nightly.yml` in each site repo (Settings → Variables → Actions):
  - `SITE_TYPE` = `static` / `next` / `astro-ssr`
  - `SCAN_CONTAINERS` = `true` (antiphaze only) / `false` (others)
  - `WORKING_DIRECTORY` = `.` / `app` / `website`

---

## P4 — Optional polish (any time)

- [ ] **Plant 3 AWS canarytokens** at https://canarytokens.org/generate (free). Place each in a plausible-looking file in each repo (e.g., `infrastructure/legacy/.old-deploy.env.bak` content). Configure email alerts to your primary inbox. Document the token locations in a private doc (do NOT commit fingerprints to git).
- [ ] **Set up gitsign** for keyless commit signing:
  ```bash
  brew install sigstore/tap/gitsign
  git config --global commit.gpgsign true
  git config --global gpg.x509.program gitsign
  git config --global gpg.format x509
  ```
  Then your commits will be signed via GitHub OIDC against Sigstore Rekor (publicly verifiable).
- [ ] **Wait 2 weeks** of no-regression operation, then submit each domain to https://hstspreload.org. **One-way door** — make sure every subdomain (including any hidden ones) serves HTTPS-clean before submitting.
- [ ] **Schedule quarterly secrets rotation** in your calendar per `docs/runbooks/secrets-rotation.md` cadence.

---

## Known follow-ups (low-priority cleanup the agent flagged)

These were noted in the final code review as APPROVED_WITH_NITS — non-blocking:

- [ ] **Delete stale `sacred-portal-wellness/next.config.ts` and `package.json` at the repo root** (the active app lives at `app/`; the root files have no security headers and could mislead a developer building from the wrong directory).
- [ ] **Bump `node-version: 20` → `22`** in `sacred-portal-wellness/.github/workflows/ci.yml` (3 occurrences) for consistency with the rest of the project.
- [ ] **Replace truncated Stripe test-mode strings** in `antiphazeprod/docs/planning/implementation-plan.md` (around lines 700-701) with `sk_test_REDACTED` / `pk_test_REDACTED` to silence gitleaks false positives.

---

## Final-state verification (run when everything above is done)

```bash
cd ~/Projects/elmdevsecops

# Smoke-test all 3 production URLs:
./tools/scripts/test-headers.sh https://globalmanagement.com
./tools/scripts/test-headers.sh https://sacredportalwellness.com
./tools/scripts/test-headers.sh https://antiphazeprod.com
./tools/scripts/test-headers.sh https://tickets.antiphazeprod.com

./tools/scripts/test-tls.sh globalmanagement.com
./tools/scripts/test-tls.sh sacredportalwellness.com
./tools/scripts/test-tls.sh antiphazeprod.com
./tools/scripts/test-tls.sh tickets.antiphazeprod.com

# Manually:
# - Submit a contact form on each site
# - Try to access tickets.antiphazeprod.com/control/ from incognito → CF Access login
# - Open a no-op PR in each repo → confirm `gate` job passes
# - Tag a release on one repo (e.g., antiphazeprod v1.0.0) → confirm cosign + SLSA provenance attached to GitHub release
# - Verify the released artifact: `cosign verify-blob --bundle release.cosign.bundle release.tar.gz` and `gh attestation verify --owner echoeslabmusic release.tar.gz`
```

When all of the above pass, **the project is production-hardened.** Tag `v1.0.0` on the meta-repo (`cd ~/Projects/elmdevsecops && git tag v1.0.0 && git push origin v1.0.0`) and you're done.
