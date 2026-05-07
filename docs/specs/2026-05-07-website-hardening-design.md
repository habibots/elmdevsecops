# Website Hardening — Design Document

**Date:** 2026-05-07
**Author:** Munib Hosny
**Status:** Draft, awaiting approval before implementation plan
**Scope:** GlobalManagement, sacred-portal-wellness, antiphazeprod
**Workspace:** `~/Projects/echoeslabwebsite/`
**All work on `devops` branch in each repo. `main` is not touched.**

---

## 1. Overview

Three production websites need hardened cloud infrastructure with automated TLS and a CI/CD security pipeline that validates security baselines on every push. The deliverable is engineering-grade — mapped to the secure SDLC tenets (NIST SSDF, OWASP SAMM as engineering references), no formal compliance framework. All tooling is OSS or free-tier; no new monthly spend.

**Three sites in scope:**

| Site | Stack | Current host | Risk profile |
|---|---|---|---|
| **GlobalManagement** | Astro 5 SSG + React 19, Web3Forms contact | Static (probably nothing / Netlify) | Low — no backend, no PII storage |
| **sacred-portal-wellness** | Next.js 16 SSR via OpenNext on Cloudflare Workers + Square Payments | Cloudflare Workers | High — payments + PII surface |
| **antiphazeprod** | Astro SSR (Node 16 — EOL) + Docker Compose: Caddy + Pretix + Postgres 16 + Redis 7 | DigitalOcean droplet (`129.212.164.31`, NYC3) | Medium — PII, ticketing, EOL runtime |

---

## 2. Goals and non-goals

### Goals

1. **Every site is shielded** by Cloudflare for DDoS, WAF, automatic TLS, and bot mitigation — at zero cost (free tier).
2. **Every push triggers automated security gates** in GitHub Actions: secret scanning, dependency CVE scanning, SAST, IaC scanning, container scanning (where applicable), security header smoke tests, TLS config verification.
3. **The deploy is blocked** if any critical/high gate fails. Severity gating is explicit and tunable.
4. **Every release artifact** is signed and attested with cosign + Sigstore Rekor, with an SBOM (CycloneDX) attached.
5. **AI-assisted security review** of branches via local Claude Code (free, covered by existing subscription) — output saved as a committed audit artifact per PR.
6. **Urgent vulnerabilities are remediated** before any of the above is wired up: leaked Square production credentials, leaked Web3Forms key, hardcoded SMTP credentials, EOL Node 16 runtime.
7. **Total new monthly spend: $0.** Existing $24/mo DigitalOcean droplet unchanged.

### Non-goals

- No re-hosting or re-architecture of any application. Code stays where it is.
- No formal compliance framework (PCI/SOC 2/ISO/NYDFS). The engineering work would *support* such an audit if one were required, but auditor packaging is out of scope.
- No paid SaaS tooling (no Doppler, no Snyk, no Cloudflare Pro). Strict OSS + free-tier only.
- No Anthropic API in CI. AI review happens locally via Claude Code.
- No multi-cloud abstraction. Cloudflare concentration risk is accepted with a documented fallback runbook.
- No load testing, no performance optimization beyond what TLS/CDN gives for free.

---

## 3. Threat model

A short, opinionated threat model. We defend against what actually attacks small business sites. We *do not* engineer for nation-state APTs.

| # | Threat | Realism for these sites | Primary mitigation |
|---|---|---|---|
| **T1** | **Magecart / client-side card skimming** | High for sacred-portal (Square checkout). Akamai reports +103% growth 2024–2025. | CSP `script-src` allowlist + SRI on all `<script>` tags + Cloudflare WAF managed rules + (optional) Page Shield equivalent via SRI manifest |
| **T2** | **Form-spam and SMTP abuse** | Universal. All three sites have forms. | Cloudflare Turnstile, server-side rate limiting (already implemented in antiphaze contact API), origin/CSRF check (already in sacred-portal), honeypots |
| **T3** | **npm supply-chain compromise** | High and rising. Sept 2025 `chalk`/`debug` worm; Shai-Hulud; April 2026 Vercel breach via OAuth pivot. | `npm ci` with hash-pinned lockfiles, OSV-Scanner gate, Dependabot alerts, signed releases (cosign), SBOM per release |
| **T4** | **Credential leak via committed secrets** | Already happened (Square, Web3Forms, SMTP). | Push protection + gitleaks pre-commit + scheduled TruffleHog with verifiers + canarytokens for active deception |
| **T5** | **Credential stuffing on admin panels** | Pretix `/control` is the relevant admin surface. | Cloudflare Access in front of `/control` with WebAuthn (Zero Trust free tier ≤ 50 users). No password login exposed to internet |
| **T6** | **DDoS extortion** | Low absolute likelihood, high impact if it happens. | Cloudflare proxy on all three sites; free tier provides unmetered DDoS protection |
| **T7** | **TLS/cert misconfiguration** | Common ops failure (expired certs, weak ciphers, broken redirects). | Caddy automatic HTTPS on droplet; Cloudflare Universal SSL on edge sites; sslyze in CI as a regression gate |
| **T8** | **Outdated runtime CVEs** | Currently exploitable: Node 16 EOL with CVE-2024-22019 in antiphaze. | Upgrade to Node 22 LTS now; OSV-Scanner runs daily on `main` to surface new CVEs in pinned deps |

We accept these risks (do not engineer against them):

- Nation-state targeted attack
- Insider threat (single operator)
- Physical compromise of operator's laptop (covered by macOS FileVault + sensible password manager use; out of project scope)
- Cloudflare global outage (Nov 2025 / Jun 2025 / Mar 2025) — accepted with documented fallback

---

## 4. SDLC mapping — controls by phase

The hardening maps to the secure SDLC phases. Each phase has named controls; each control has a tool.

### 4.1 Requirements / Design

- **Threat model document** (`docs/threats/threat-model.md`) — STRIDE-style, kept in sync with architecture changes
- **Security policy** (`docs/security-policy.md`) — what we won't do, what reviewers must check
- **Data flow diagram** per site, with trust boundaries marked

### 4.2 Implementation

- **`.gitignore` audit** — `.env`, `.env.local`, `.env.*.local`, `*.pem` in every repo
- **Pre-commit hooks** (lefthook v1.x or pre-commit v3.x) — fast checks only:
  - `gitleaks protect` (staged diff)
  - `actionlint` for any GitHub Actions changes
  - `prettier` / `eslint`
- **Local Claude Code security review** — `.claude/commands/security-review.md` slash command in each repo, invoked before push

### 4.3 Build

- **Reproducible builds** — `npm ci` with `package-lock.json` integrity check
- **SBOM generation** — Syft → CycloneDX 1.5 per release artifact
- **Container build** (antiphaze only) — multi-stage Dockerfile, distroless base where possible, `cap_drop: [ALL]`, `read_only: true`

### 4.4 Test (CI gates on every PR — parallel jobs, target <5 min)

| Job | Tool | Blocks merge on |
|---|---|---|
| `secrets` | gitleaks v8 (full history) + GitHub Push Protection (server-side) | Any verified secret |
| `sast` | Semgrep OSS + `p/owasp-top-ten` + `p/javascript` + `p/typescript` + `p/nextjs` + `p/react` | High severity |
| `sca` | OSV-Scanner v1 against `package-lock.json` | Critical/High CVE |
| `iac` | Checkov v3 + `actionlint` + `zizmor` (GitHub Actions security) | Any Critical |
| `container` | Trivy `image` + `config` (antiphaze only) | Critical CVE in image |
| `headers` | Static parse of `next.config.js` headers / `_headers` / Caddyfile against expected baseline | Any expected header missing |
| `build` | Build + SBOM (Syft) | Build failure |
| `policy` | OPA + Conftest against `policy/*.rego` | Any violation |

### 4.5 Deploy

- **OIDC-based cloud auth** where possible — no long-lived tokens in GitHub Secrets for AWS/GCP. (Cloudflare doesn't support OIDC for Wrangler yet — use a scoped Wrangler API token: `Workers Scripts: Edit` only.)
- **Branch protection** on `main`:
  - Required status checks: `secrets`, `sast`, `sca`, `iac`, `policy`, `build` (and `container` for antiphaze)
  - Required signed commits via `gitsign` (Sigstore keyless, ties signature to GitHub OIDC identity)
  - Required code owner review on `/.github/`, `/infra/`, anything touching auth or payments
  - Linear history, no force-push to `main`
- **Artifact signing** — `cosign sign --keyless` (Sigstore public-good Fulcio + Rekor). `gh attestation verify` confirms provenance.
- **Build provenance** — `actions/attest-build-provenance@v1` for SLSA Build L2.

### 4.6 Operate

- **Post-deploy smoke tests:**
  - `mozilla/observatory-cli` against the production URL — fail if grade drops below B (sites 1, 3) or A− (site 2)
  - `sslyze` — fail if TLS 1.0/1.1 enabled, weak cipher, or chain issue
  - OWASP ZAP baseline (passive only, ~5 min)
  - Nuclei templates against running services (catches known-CVE versions of Caddy, Pretix, Postgres)
- **Cert expiry monitoring** — Prometheus blackbox exporter on the DO droplet; Cloudflare's own dashboard alerts on the edge sites
- **CT log monitoring** — SSLMate Cert Spotter free tier, alerts on any cert issued for the customer's domains
- **Logs centralization** — Caddy + Pretix + Postgres logs shipped via Vector → Grafana Cloud free tier (50 GB/mo). Cloudflare doesn't expose Logpush on free tier, so for the edge sites we accept the platform-native log retention (~3 days for free Workers; longer if we use `wrangler tail` with a script)

### 4.7 Maintain

- **Drift detection** — nightly job re-runs all scanners on `main` regardless of diff. Catches CVEs newly disclosed against unchanged dependencies.
- **Allowlist hygiene** — `.gitleaksignore`, `.trivyignore`, `osv-scanner.toml` entries require `# justified: <reason> <expiry-date>`. CI fails when an entry is past its expiry.
- **Quarterly tabletop** — pick a recently-disclosed CVE, walk through "is any of our three sites affected?" using SBOM + scanner output, target <10 minutes to answer.

---

## 5. Per-site target architecture

### 5.1 GlobalManagement (Astro static)

**Hosting:** Cloudflare Pages (free tier — unlimited bandwidth, 500 builds/mo)

**TLS:** Universal SSL (auto, free)

**Edge config:** `_headers` file in `public/`:

```
/*
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  Content-Security-Policy: default-src 'self'; script-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; form-action https://api.web3forms.com; frame-ancestors 'none'
```

**Form spam:** Add Cloudflare Turnstile widget to the contact form. Web3Forms accepts the Turnstile token in its payload.

**WAF:** Cloudflare free-tier Managed Rules + OWASP Core Ruleset.

**Pipeline scope:** lighter — no SAST (no server code), no container scan, no DAST beyond headers/TLS check. Run gitleaks, OSV-Scanner, actionlint, Mozilla Observatory.

### 5.2 sacred-portal-wellness (Next.js + Square)

**Hosting:** stays on Cloudflare Workers + OpenNext (already correct).

**TLS:** Cloudflare Universal SSL on the custom domain. HSTS set in `next.config.js` `headers()` so it's diffable in PRs (single source of truth — disable the dashboard HSTS toggle to avoid double headers).

**Headers (in `next.config.js`):**

```js
const securityHeaders = [
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), payment=(self "https://*.squareup.com")' },
  { key: 'Content-Security-Policy', value: "default-src 'self'; script-src 'self' 'nonce-{NONCE}' https://*.squareup.com https://*.squarecdn.com; img-src 'self' data: https://*.squarecdn.com; connect-src 'self' https://*.squareup.com; frame-ancestors 'none'; form-action 'self' https://*.squareup.com" },
];
```

**WAF:** Cloudflare Managed Rules + Bot Fight Mode (free).

**Square integration discipline:**
- Confirm the integration is Square-hosted-payment-link redirect (SAQ A friendly), not the Web Payments SDK iframe (which would require the harder PCI v4.0.1 6.4.3/11.6.1 evidence). If it's the SDK form, we either accept the additional script-inventory work or migrate to the redirect mode.
- Webhook signature verification: confirm `/api/webhooks/square` (if exists) HMAC-verifies against the configured webhook signing key. Custom Semgrep rule to flag any webhook handler that doesn't.
- All Square API calls flow through a single wrapper module; raw `process.env.SQUARE_ACCESS_TOKEN` access outside that module is a Semgrep error.

**Secrets:** migrate from `.env.local` to `wrangler secret put` (encrypted at edge, audit-logged). `.env*` removed from disk and git history.

**Pipeline scope:** full — secrets, SAST (with custom Square rules), SCA, IaC (`wrangler.toml`), headers, build, sign, SBOM. ZAP baseline + Nuclei post-deploy.

### 5.3 antiphazeprod (Astro SSR + Pretix on DigitalOcean droplet)

**Hosting:** stays on the existing DO droplet. **Front it with Cloudflare** as a reverse proxy (proxy DNS through CF). Free tier.

**Critical fix #1 — Node 16 → 22 LTS:**

```jsonc
// website/package.json
"@astrojs/node": "^9.x"  // Node 22 compatible (current is older Node 16 adapter)
```
And update `Dockerfile` `FROM node:22-alpine`. CVE-2024-22019 (high-severity llhttp HTTP request smuggling) is unpatched on Node 16 and exploitable today.

**Critical fix #2 — DB/Redis exposure:**

In `infrastructure/docker-compose.yml`:
```yaml
services:
  postgres:
    # NO `ports:` mapping. Internal Docker network only.
  redis:
    # NO `ports:` mapping. Internal Docker network only.
  caddy:
    ports:
      - "80:80"
      - "443:443"
    # Only Caddy is publicly reachable.
```

**Caddy hardening** (note: requires building Caddy with the Cloudflare DNS plugin via `xcaddy build --with github.com/caddy-dns/cloudflare` — the stock `caddy:2-alpine` image doesn't include it; we'll publish our own image):

```Caddyfile
{
    email ops@antiphazeprod.com
    acme_dns cloudflare {env.CF_DNS_API_TOKEN}   # DNS-01 challenge — no port 80 dependency
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
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
        -Server
    }
}

antiphazeprod.com, www.antiphazeprod.com {
    import security_headers
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

**Pretix `/control` admin protection:** Cloudflare Tunnel + Cloudflare Access with email-OTP + WebAuthn. `/control/*` requires authentication via Access before reaching the origin. Free tier covers up to 50 users.

**Secrets:** Pretix config (`pretix.cfg`) and Caddyfile env vars managed via SOPS + age. `prod.env.enc` committed; age private key on droplet at `/etc/age/keys.txt` (root-owned, 0600), backed up to a 1Password secure note. SMTP credentials moved to env (no hardcoded fallback in `contact.ts`).

**SSH hardening:** ed25519 deploy key, password auth disabled, fail2ban running, DigitalOcean Cloud Firewall restricting port 22 to GitHub Actions runner IP ranges (refreshed weekly via a cron/action that pulls https://api.github.com/meta).

**Logs:** Vector ships Caddy + Pretix + Postgres logs to Grafana Cloud free tier (50 GB/mo, 14-day retention).

**Pipeline scope:** full — including Trivy on the Pretix image, Checkov on docker-compose + Dockerfile, custom Conftest rules on the Caddyfile (TLS min 1.2, HSTS present, `-Server` header). `docker-bench-security` runs weekly on the droplet itself (not CI), uploads results to Grafana.

---

## 6. CI/CD security pipeline architecture

### 6.1 Layout

```
echoeslabwebsite/
├── docs/
│   ├── specs/
│   │   ├── 2026-05-07-website-hardening-design.md   ← this doc
│   │   └── 2026-05-07-website-hardening-plan.md     ← implementation plan (next)
│   ├── threats/
│   │   ├── threat-model.md
│   │   ├── globalmanagement.md
│   │   ├── sacred-portal.md
│   │   └── antiphaze.md
│   ├── security-policy.md
│   └── runbooks/
│       ├── secrets-rotation.md
│       ├── incident-response-template.md
│       └── cloudflare-fallback.md
├── .github/                          ← shared org-level workflows (lives in `org/.github` repo)
│   └── workflows/
│       ├── _security-base.yml        ← reusable workflow_call, parametrized per site
│       └── _drift-nightly.yml        ← scheduled
├── policy/
│   ├── containers.rego
│   ├── github-actions.rego
│   └── *_test.rego
├── tools/
│   ├── pre-commit-config.yaml
│   ├── gitleaks.toml
│   ├── osv-scanner.toml
│   ├── semgrep-custom/
│   │   └── square-token-wrapper.yaml
│   └── conftest-config/
└── (site repos, each with its own .git)
    ├── GlobalManagement/
    ├── sacred-portal-wellness/
    └── antiphazeprod/
```

Each site repo gets a thin `.github/workflows/security.yml` that calls the shared `_security-base.yml` with site-specific inputs (`scan-containers: true|false`, `dast-target-url: …`).

### 6.2 Reusable workflow shape

```yaml
name: _security-base
on:
  workflow_call:
    inputs:
      scan-containers: { type: boolean, default: false }
      dast-target-url: { type: string, required: false }
      site-type:       { type: string, required: true }   # static | next | astro-ssr

jobs:
  secrets:    # gitleaks
  sast:       # semgrep
  sca:        # osv-scanner
  iac:        # checkov + actionlint + zizmor
  container:  # trivy (conditional on scan-containers)
  headers:    # static parse of expected headers
  build:      # actual build + syft SBOM
  policy:     # opa/conftest

  # All above run in parallel.

  gate:
    needs: [secrets, sast, sca, iac, container, headers, build, policy]
    runs-on: ubuntu-latest
    steps:
      - run: echo "All security gates passed"
```

Branch protection on `main` requires the `gate` job to succeed.

### 6.3 Drift detection (nightly)

```yaml
name: _drift-nightly
on:
  schedule: [{ cron: '0 7 * * *' }]   # daily 07:00 UTC
jobs:
  rescan: { uses: ./.github/workflows/_security-base.yml, ... }
```

Re-runs all scanners against `main`. New CVEs in unchanged dependencies surface within 24 hours.

### 6.4 Severity gating philosophy

- Block merge on **Critical** and **High** by default
- **Medium** and **Low** go to GitHub Security tab for triage; do not block
- Allowlists (`.gitleaksignore`, `.trivyignore`, `osv-scanner.toml`) require `# justified: <reason> <YYYY-MM-DD-expiry>` and expire automatically

This is the discipline that prevents false-positive fatigue from killing the program in two weeks.

---

## 7. Local AI security review workflow

### 7.1 The pattern

Before pushing significant changes:

1. Run `claude` in the repo (Claude Code interactive)
2. Type `/security-review` (custom slash command)
3. Claude reads the diff + repo context, runs scanners locally, and reports findings in your terminal
4. Address findings, iterate
5. Save the review output to `.security-reviews/PR-<branch>-<YYYY-MM-DD>.md`
6. `git push`

### 7.2 The slash command (per-repo)

Each repo gets `.claude/commands/security-review.md`:

```markdown
---
name: security-review
description: Pre-push security review of the current branch's diff
---

You are a senior security reviewer for this repo. Your job:

1. Run `git diff main..HEAD` and analyze every change.
2. Read these reference docs:
   - docs/threats/threat-model.md
   - docs/security-policy.md
3. Run these scanners and incorporate their findings:
   - `gitleaks detect --source . --no-git`
   - `npx semgrep --config p/owasp-top-ten --json`
   - `npx osv-scanner --lockfile package-lock.json --format json`
4. For each finding, classify severity (Critical / High / Medium / Low / Info), file:line, rationale, suggested fix.
5. Pay extra attention to:
   - Auth / authz changes
   - Cryptographic operations
   - CSP / HSTS / security header changes
   - CORS widening
   - Webhook signature verification
   - Secret handling (env access, secrets in logs)
   - Square API surface (sacred-portal only)
   - Rate-limiting / abuse-prevention changes
6. Output a markdown report with:
   - Summary (pass / pass-with-findings / block)
   - Findings table
   - Recommended actions before push
```

### 7.3 The audit artifact

```bash
# After /security-review:
mkdir -p .security-reviews
# Save the review output to:
# .security-reviews/PR-<branch>-<YYYY-MM-DD>-<short-sha>.md
git add .security-reviews/
git commit -m "Security review for $(git branch --show-current)"
git push
```

Every PR carries its review with it. Audit trail is committed to git, signed (because all commits are signed), and tied to its diff. This is interview-demoable: "here's a PR, here's the AI security review I ran before pushing, here's how I addressed each finding."

### 7.4 Why not Claude API in CI

We considered putting Claude into the CI pipeline directly via the Anthropic API. Trade-off table:

| | Claude API in CI | Claude Code locally |
|---|---|---|
| Cost | $1–5/mo at typical activity | $0 (existing subscription) |
| Enforcement | Automatic, can't bypass | Discipline-dependent |
| Per-review depth | ~200K-token diff + cached docs | Whole repo, tool use, deep navigation |
| Audit trail | Comment on PR | Committed `.security-reviews/` artifact |

We chose local for cost reasons. The deterministic CI scanners are the truth source — they enforce the floor regardless of whether the AI review happened. The pipeline is structured so flipping to API-in-CI later is a single feature-flag change.

---

## 8. TLS baseline (cross-cutting)

Target the **Mozilla Server-Side TLS Intermediate** profile (v6.0, Apr 2026):

- TLS 1.2 + 1.3 only. TLS 1.0/1.1 disabled.
- TLS 1.3 ciphers: `TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256`.
- TLS 1.2 ciphers: ECDHE-ECDSA / ECDHE-RSA AES-GCM and CHACHA20-POLY1305 only.
- Curves: `X25519MLKEM768, X25519, prime256v1, secp384r1`.
- Leaf cert: ECDSA P-256.
- HSTS: `max-age=63072000; includeSubDomains; preload`.
- HSTS preload submission **only after** every subdomain is verified HTTPS-clean. Submission is a one-way door.
- CAA records on every apex restricting issuance to chosen CAs (Let's Encrypt + Cloudflare's pki.goog).
- CT monitoring via SSLMate Cert Spotter free tier.

**Do not configure** (security theatre or actively harmful):
- HPKP (deprecated 2018, can lock users out)
- Expect-CT (deprecated 2023)
- OCSP must-staple (Let's Encrypt rejects it as of May 2025; OCSP responders EOL Aug 2025)
- TLS 1.3-only ("for security") — TLS 1.2 with Mozilla Intermediate is not measurably weaker for a public site
- P-384 leaf certs (slower handshake, no real-world threat-model improvement over P-256)

CI enforcement: `sslyze` against the deployed URL fails the post-deploy gate if any baseline regresses.

---

## 9. Secrets remediation runbook (urgent — execute before pipeline rollout)

### 9.1 Severity-ranked

| # | Repo / Secret | Severity | TTM target |
|---|---|---|---|
| 1 | sacred-portal — Square production access token, app ID, location ID | **Critical** | <1 hour |
| 2 | antiphaze — SMTP2GO user/pass hardcoded in `contact.ts` | **High** | <4 hours |
| 3 | GlobalManagement — Web3Forms `PUBLIC_WEB3FORMS_ACCESS_KEY` | **Low** (designed to be public) | <24 hours |

### 9.2 Order

1. **Rotate first** — at the issuing platform (Square Developer Dashboard → Replace Token; SMTP2GO dashboard → reset password; Web3Forms dashboard → regenerate key)
2. **Verify abuse during exposure window** — Square `ListPayments`, SMTP2GO Activity report, Web3Forms inbox
3. **Update runtime secrets** — `wrangler secret put` for sacred-portal; SOPS-encrypted env file for antiphaze; build-time env via Cloudflare Pages dashboard for GlobalManagement
4. **Rewrite git history** — `git-filter-repo --path .env.local --invert-paths --force`, then `git filter-repo --replace-text` for any literal token strings
5. **Force-push** with collaborator coordination (in this case: solo, so simpler)
6. **Open follow-up PR** documenting the IR — `SECURITY-INCIDENT-2026-05-07.md` per repo using the standard template

### 9.3 Going-forward secrets management (zero cost)

| Surface | Tool | Mechanism |
|---|---|---|
| Local dev | `.env` in `.gitignore` + `.env.example` template | Standard pattern, no SaaS |
| GitHub Actions CI | GitHub Encrypted Secrets + Environments with required reviewers for production | Free, native |
| CF Workers runtime | `wrangler secret put` | Encrypted at edge, audit-logged |
| DO droplet | SOPS + age, decrypt to `/etc/antiphaze/.env` at deploy time, systemd `EnvironmentFile=` | OSS, no SaaS dependency |

### 9.4 Detective controls

- **GitHub Push Protection** enabled at org/repo level (free)
- **gitleaks pre-commit hook** in every repo
- **TruffleHog scheduled action** (daily, `--results=verified` so only live creds alert)
- **Canarytokens** — plant 2–3 fake AWS-key tokens (free, canarytokens.org) in plausible-looking files (`infra/old-deploy.sh.bak`). Attacker tooling auto-validates discovered AWS keys, which fires the alert. Active deception.

---

## 10. Cost summary

| Item | Cost |
|---|---|
| Cloudflare DNS, CDN, WAF, Universal SSL, Access ≤50 users, Turnstile, Bot Fight Mode | $0 (free tier) |
| Cloudflare Pages (GlobalManagement) | $0 (free, unlimited bandwidth) |
| Cloudflare Workers (sacred-portal) | $0 if <100k req/day; $5/mo if exceeded |
| GitHub Actions | $0 (free for public repos; 2000 min/mo for private) |
| All OSS scanners (gitleaks, Trivy, Semgrep OSS, OSV-Scanner, Checkov, ZAP, Nuclei, Syft, cosign) | $0 |
| SOPS + age (secrets) | $0 |
| Sigstore (cosign keyless signing + Rekor log) | $0 (public-good infrastructure) |
| SSLMate Cert Spotter | $0 (free tier) |
| Grafana Cloud (logs, 50 GB/mo) | $0 (free tier) |
| Anthropic API in CI | $0 (not used; local Claude Code instead) |
| Existing DigitalOcean droplet | $24/mo (unchanged) |
| **Total NEW monthly spend** | **$0** |

---

## 11. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | False-positive flood erodes developer trust | High | High | Severity gating (block H/C only); 90-day expiring allowlists with mandatory `# justified:` comments; weekly triage budget |
| R2 | GitHub Action supply-chain compromise (e.g., tj-actions/changed-files-style attack March 2025) | Medium | Critical | Pin all third-party actions to commit SHA via `pinact`; StepSecurity Harden-Runner egress monitoring |
| R3 | Cloudflare global outage darks all 3 sites | Medium | High | Logpush-equivalent (manual export to R2 free tier or local); documented static-fallback runbook for marketing pages; accept payment downtime during CF outage |
| R4 | Local Claude Code review skipped under deadline pressure | High | Medium | Deterministic CI gates are the floor; Claude review is value-add not foundation; pre-push hook prints reminder |
| R5 | Cosign keyless signing depends on Sigstore public-good infra | Low | Medium | Tolerate; Sigstore has SLAs and a self-hosted Fulcio path if needed |
| R6 | Pretix Postgres backup not encrypted at rest, droplet snapshotted | Medium | High | `pg_dump` to a file encrypted with `age` before upload; backups go to off-droplet S3-compatible storage (DO Spaces, $5/mo if we bend on cost-zero — flag this) |
| R7 | EOL Node 16 patch breaks the Astro build | Low | Medium | Upgrade in a feature branch first; smoke-test contact form end-to-end before merging |
| R8 | Branch protection bypassed via admin override | Low | High | Require admin override events to be logged; review monthly via `gh api /repos/.../audit-log` |
| R9 | Secrets management complexity gap (3 different per-environment patterns) | Medium | Medium | Document each path in `docs/runbooks/secrets-management.md`; one runbook, three clearly-labeled sections |
| R10 | The user (sole operator) being unavailable during an incident | Medium | Medium | Out of scope — single-operator project; document so a successor could take over via the runbooks |

---

## 12. Open questions / explicit non-decisions

1. **HSTS preload submission timing.** Preload list addition is a one-way door. Submit only after confirming every subdomain (including any internal staging) serves HTTPS-only. Defer submission until 2 weeks after the last config change.
2. **Cloudflare zone migration cutover.** The DNS proxy switch for antiphaze.com (currently direct to droplet IP) is a real cutover. Plan a low-traffic window, document a rollback path (revert NS records).
3. **Square integration mode confirmation.** Need to verify whether sacred-portal uses Square redirect (SAQ A) or Web Payments SDK iframe (additional 6.4.3/11.6.1 work). Bias toward redirect; flag if SDK is in use.
4. **GitHub repo visibility.** Public repos get free unlimited Actions minutes and free Push Protection. Private repos have 2000 min/mo cap. Confirm intent — if private, watch the minute usage.
5. **Audit trail retention.** Free tiers retain logs for days-to-weeks. For longer retention, R2 Object Storage at $0.015/GB/mo is the cheapest option — accept this if/when needed.
6. **DO Spaces for encrypted Pretix backups.** $5/mo. Flagged because it would break the strict $0 budget. Alternative: ship encrypted backups to a free GitHub release artifact (per-day, autoexpired).

---

## 13. Phased rollout (high-level milestones)

The detailed implementation plan is the next document. This is the rough shape:

**Phase 0 — Urgent IR (day 1, before anything else):**
- Rotate Square / SMTP / Web3Forms credentials
- Verify no abuse during exposure window
- Scrub git history (filter-repo)
- Force-push, document IR per repo

**Phase 1 — Stabilize antiphaze runtime (day 2–3):**
- Upgrade Node 16 → 22 LTS, smoke-test
- Bind Postgres / Redis to internal Docker network only
- Enable DO Cloud Firewall (SSH restricted to GitHub IP ranges + your IP)

**Phase 2 — Cloudflare in front of all 3 sites (day 4–5):**
- DNS proxy for antiphazeprod.com; cutover during low-traffic window
- Cloudflare Pages deploy for GlobalManagement
- Verify sacred-portal Workers config; migrate `.env.local` to `wrangler secret`
- Enable WAF + Bot Fight Mode + Turnstile on contact forms
- Cloudflare Access in front of Pretix `/control`

**Phase 3 — TLS / headers baseline (day 6):**
- Caddyfile updated (DNS-01, hardened headers, Pretix admin path)
- `next.config.js` headers updated for sacred-portal
- `_headers` file for GlobalManagement
- Mozilla Observatory and sslyze checks pass for all 3

**Phase 4 — CI/CD pipeline (day 7–9):**
- *Prerequisite: confirm sacred-portal's Square integration mode (redirect vs. SDK) — open question Q3.*
- Reusable `_security-base.yml` workflow
- Per-repo `security.yml` calling it
- Branch protection rules
- Pre-commit hooks (`gitleaks`, `actionlint`)
- Custom Semgrep rules (Square wrapper, webhook-signature)
- Conftest policies

**Phase 5 — Audit + signing (day 10):**
- Cosign keyless signing on release artifacts
- `actions/attest-build-provenance@v1` for SLSA Build L2
- SBOM generation per release (Syft → CycloneDX)
- Drift detection nightly job

**Phase 6 — Local Claude Code workflow (day 11):**
- `.claude/commands/security-review.md` per repo
- `.security-reviews/` directory convention
- Document in CONTRIBUTING.md

**Phase 7 — Documentation + runbooks (day 12):**
- `docs/threats/*.md` per site
- `docs/security-policy.md`
- `docs/runbooks/` (secrets rotation, Cloudflare fallback, IR template)

Total: ~2 weeks of focused effort. Detailed plan with checkable tasks comes next document.

---

## 14. Appendix — what we explicitly chose NOT to do

- **No Anthropic API in CI** — cost-driven; local Claude Code is the AI layer
- **No Doppler / 1Password / Vault** — SOPS+age and GitHub Encrypted Secrets cover the need at $0
- **No Snyk / Mend / Veracode** — Trivy + OSV-Scanner + Semgrep OSS cover SCA/SAST/container at $0
- **No re-host of any application** — harden in place; migration is risk and not value at this stage
- **No multi-cloud / vendor diversification** — Cloudflare concentration accepted with documented fallback
- **No HPKP, Expect-CT, OCSP must-staple, P-384 certs, TLS 1.3-only** — security theatre or actively harmful
- **No formal compliance framework artifacts** — engineering work would support an audit if needed; auditor packaging is out of scope
- **No load testing, performance optimization** — TLS/CDN gives free wins; further optimization is out of scope
- **No mTLS for the Pretix admin path** — Cloudflare Access with WebAuthn is the lower-friction equivalent
