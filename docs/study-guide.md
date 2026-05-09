# Study Guide — How These 4 Repos Were Hardened

**Audience:** you, reading this to understand the work, then explaining it to other engineers.
**Length:** thorough. Skim the section headers first, then drop into whichever section the conversation needs.

---

## 0. The 30-second pitch

You ran three independent production websites on different stacks. Each one had real security gaps — some leaked credentials, an EOL Node runtime with an unpatched HTTP smuggling CVE, no automated security gates, no WAF in front, hardcoded SMTP creds, exposed admin pages. You hardened all three plus built a shared "security platform" repo that holds the policies, threat models, custom scanner rules, and the reusable CI workflow that all three consume.

Total monthly cost of the new infrastructure: **$0** (Cloudflare free tier + GitHub Actions on public repos + open-source scanners). Total commits: 41 across 4 repos, all on `devops` branches; nothing touched `main`.

The narrative for an engineer: **defense in depth, mapped to the secure SDLC, with deterministic CI gates as the floor and AI-assisted local review as the ceiling.**

---

## 1. The threat model — what we were defending against

You can't talk about controls without first talking about what you're defending against. We picked 8 realistic threats for small/medium production websites and ignored everything else (no nation-state APT engineering, no paranoid theatre).

| # | Threat | What it looks like | Where we mitigate |
|---|---|---|---|
| **T1** | **Magecart / client-side card skimming** | An attacker injects JS into a checkout page that exfiltrates card numbers as the user types. ~11,000 e-commerce sites compromised in 2024. | CSP `script-src` allowlist + Cloudflare WAF + Turnstile + Square redirect mode (no cards on our page) |
| **T2** | **Form spam / SMTP abuse** | Bots flooding contact forms; reputation damage via SMTP relay abuse | Turnstile (CAPTCHA replacement), server-side rate limiting, origin/CSRF checks |
| **T3** | **npm supply-chain attack** | Compromised dependency executes malicious code in your build (Sept 2025 `chalk`/`debug`/Shai-Hulud worm) | `npm ci` with hash-pinned lockfile, OSV-Scanner daily, signed releases via cosign + Sigstore |
| **T4** | **Committed secrets** | API keys ending up in git history; scrapers find them within minutes (TruffleHog continuously indexes public GitHub) | gitleaks pre-commit + CI, GitHub Push Protection, planted canary tokens, SOPS+age for production env files |
| **T5** | **Credential stuffing on admin panels** | Bots try millions of leaked username/password combos against Pretix `/control` | Cloudflare Access in front of `/control` with email-OTP + WebAuthn; no password login exposed to internet |
| **T6** | **DDoS** | Volumetric flood; ransom or extortion | Cloudflare's anycast network absorbs L3/L4/L7 attacks at the edge (free tier) |
| **T7** | **TLS misconfiguration** | Expired certs, weak ciphers, broken redirects, accidental HTTP-only paths | Mozilla Intermediate baseline (TLS 1.2+1.3 only, ECDSA P-256), Caddy auto-HTTPS, sslyze post-deploy regression check |
| **T8** | **EOL runtime CVEs** | Unpatched Node 16 with CVE-2024-22019 (HTTP request smuggling) | Upgraded to Node 22 LTS; OSV-Scanner daily catches new CVEs in pinned deps |

**Risks we explicitly accepted (not engineered for):**
- Nation-state targeted attack
- Insider threat (you're the only operator)
- Physical compromise of your laptop (covered by macOS FileVault)
- Cloudflare global outage — accepted with documented fallback runbook

> **How to talk about this:** "We picked the realistic threats for our scale and explicitly accepted the ones we couldn't credibly defend against with the resources we have. That's how a real security program works."

---

## 2. The repo structure

Four repos, all on `devops` branches. `main` was never touched.

```
~/Projects/elmdevsecops/                     ← meta-repo (NEW, no GitHub remote yet)
├── docs/
│   ├── specs/2026-05-07-website-hardening-design.md
│   ├── plans/2026-05-07-website-hardening-plan.md
│   ├── threats/                                 ← cross-cutting + per-site threat models
│   ├── runbooks/                                ← incident response, secrets rotation, Cloudflare bootstrap, fallback
│   ├── security-policy.md
│   ├── USER-ACTION-CHECKLIST.md                 ← prioritized cutover steps
│   └── study-guide.md                           ← this file
├── policy/                                      ← OPA Conftest rules + Rego unit tests
│   ├── containers.rego
│   ├── containers_test.rego
│   ├── github-actions.rego
│   └── github-actions_test.rego
├── tools/
│   ├── semgrep-custom/                          ← custom Semgrep rules with TDD test fixtures
│   ├── scripts/                                 ← test-tls.sh, test-headers.sh, scrub-secrets.sh, refresh-gh-runner-ips.sh
│   └── pre-commit-config.yaml                   ← shared lefthook template
├── workflows-templates/
│   ├── _security-base.yml                       ← THE reusable security workflow (6 parallel jobs + gate + release)
│   └── _drift-nightly.yml                       ← daily rescan against main
└── .github/workflows/refresh-do-firewall.yml    ← weekly DO firewall refresh

GlobalManagement/                                ← Astro static SPA (public repo)
sacred-portal-wellness/                          ← Next.js 16 + Square Payments on CF Workers (public)
antiphazeprod/                                   ← Astro SSR + Pretix Docker stack on DO droplet (private)
```

Each site repo got: `lefthook.yml`, `.gitleaks.toml`, vendored CI workflows, `policy/` copy, `tools/semgrep-custom/` copy, `.claude/commands/security-review.md`, `.security-reviews/`, `CONTRIBUTING.md`, `SECURITY-INCIDENT-2026-05-07.md`.

> **How to talk about this:** "Three independent production properties, plus a shared platform repo that they all consume. The meta-repo is the source of truth for security tooling; each site repo is a thin caller."

---

## 3. The security CI/CD pipeline (the heart of the work)

This is the most important section to understand. When an engineer asks "what does CI do?", here's the real answer.

The pipeline lives in `workflows-templates/_security-base.yml` (in the meta-repo) and is vendored into each site repo at `.github/workflows/_security-base.yml`. Each site has a thin caller (`security.yml`) that runs it on every push and PR.

### The 6 parallel scanner jobs

All run in parallel on every push. Total wall-clock time: typically <5 minutes.

| Job | Tool | What it actually does | What it blocks |
|---|---|---|---|
| **`secrets`** | gitleaks v8 | Scans the full git history (not just the diff) for credential patterns. ~150 built-in regexes for AWS, Stripe, Square, GCP, generic high-entropy strings. | Any verified secret in any commit |
| **`sast`** | Semgrep OSS + custom rules | Static code analysis. Runs the OWASP Top 10 ruleset + JavaScript/TypeScript packs + our 2 custom rules (Square wrapper, webhook HMAC). | High/Critical findings |
| **`sca`** | OSV-Scanner v1 | Software Composition Analysis. Reads `package-lock.json`, queries Google's OSV.dev database (deduplicates GHSA + NVD + ecosystem advisories), reports vulnerable deps. | Critical/High CVEs |
| **`iac`** | Checkov v3 + actionlint + zizmor | Infrastructure-as-code scanning. Checkov covers Dockerfile + compose + GitHub Actions YAML. actionlint = workflow YAML linter. zizmor = workflow security antipattern detector. | Critical misconfigs |
| **`container`** | Trivy v0.50+ | (antiphaze only — has Dockerfile.) Scans Docker images for known CVEs in base layers + installed packages. | Critical/High in image |
| **`policy`** | OPA Conftest v0.50 | Policy-as-code. Runs our Rego rules against compose YAML and workflow YAML. | Any policy violation |
| **`build`** | npm ci + Syft | Reproducible build with lockfile integrity. Generates a CycloneDX SBOM. | Build failure |

A 7th job, **`gate`**, depends on all of the above. Branch protection requires `gate` to succeed for merges to `main`. This is the single point that says "yes, every check passed."

### Severity gating philosophy

> **Critical and High** = block the merge.
> **Medium and Low** = log to GitHub Security tab for triage; do not block.

This is the discipline that prevents "false-positive fatigue" from killing the program in two weeks. Most teams kill their security scanners by treating every Low as urgent; we don't. Allowlists (`.gitleaksignore`, `osv-scanner.toml`) require an inline comment like `# justified: <reason> <YYYY-MM-DD-expiry>` and **expire automatically** — CI fails if an entry is past its expiry. This forces re-evaluation; you can't just ignore something forever.

### Custom Semgrep rules (TDD)

We wrote 2 custom rules with test fixtures, written test-driven (fixtures first, run rule, confirm expected matches).

**Rule 1: `square-token-only-via-wrapper`** (`tools/semgrep-custom/square-token-wrapper.yaml`)
- Forbids `process.env.SQUARE_ACCESS_TOKEN` access **anywhere except** the canonical wrapper module at `lib/square-client.ts` or `app/src/lib/square-client.ts`.
- Why: a payments-integration token leak is the worst-case credential exposure for sacred-portal-wellness. Centralizing access through one module makes the audit surface small (one file to review) and makes it impossible for a careless `fetch()` somewhere else to leak the token.
- Test fixtures: `tests/square-bad.ts` (rule fires, count=1), `tests/square-good.ts` (rule does not fire, count=0).

**Rule 2: `webhook-must-verify-signature`** (`tools/semgrep-custom/webhook-signature.yaml`)
- For any handler under `**/api/webhooks/**` or `**/webhooks/**`, requires HMAC signature verification (`createHmac` + comparison) before any processing function is called.
- Why: forgetting webhook signature verification is the #1 payments-integration bug. Anyone who knows your webhook URL can post fake events otherwise.
- Test fixtures verify both bad (no verification) and good (HMAC + comparison) patterns.

### OPA Conftest policies (TDD)

We wrote 2 policy packages with Rego unit tests.

**Containers policy** (`policy/containers.rego`)
- Only `caddy` is allowed to publish ports to the host. (Postgres and Redis must be internal-only.)
- Every service must declare `cap_drop: [ALL]` (drop all Linux capabilities; only re-add what's needed).
- No service may run `privileged: true`.

**GitHub Actions policy** (`policy/github-actions.rego`)
- Every `uses:` line for a third-party action must reference a full 40-character commit SHA, not a branch or tag. (Tags can be moved; SHAs are immutable.)
- Every job must declare an explicit `permissions:` block (no implicit defaults).
- No `run:` step may directly interpolate user-controlled PR fields like `${{ github.event.pull_request.title }}` (that's a workflow injection vector).

These rules already caught **two real violations** during implementation: `appleboy/ssh-action@v1.0.3` and `digitalocean/action-doctl@v2` were tag-pinned, not SHA-pinned. We fixed both.

> **How to talk about this:** "Custom Semgrep rules and Conftest policies turn our threat model into machine-checked invariants. If the rule passes, the property holds; if someone violates the property, CI blocks the merge. That's how you operationalize 'no SQUARE_ACCESS_TOKEN outside the wrapper' without it becoming a documentation guideline that everyone forgets."

### Build provenance + signing (the supply-chain story)

When you push a tag like `v1.0.0`, an additional `release` job fires:

1. Build the app.
2. Generate a CycloneDX SBOM with **Syft** (lists every dep + version + hash).
3. Tar the build output as `release.tar.gz`.
4. Sign with **cosign** keyless mode — no long-lived signing key. Cosign uses your GitHub OIDC token to request a short-lived cert from Sigstore's Fulcio CA. The signature gets written to Sigstore's **Rekor** transparency log (append-only, externally verifiable).
5. Attach **SLSA build provenance** via `actions/attest-build-provenance@v1`. This says "this binary was built by this GitHub Actions workflow on this commit on this date." Anyone can `gh attestation verify` it.
6. Publish all of this (`release.tar.gz` + `sbom.cdx.json` + `release.cosign.bundle`) to the GitHub Release page.

**Why this matters:** the SolarWinds-style supply-chain compromise pattern is "attacker injects malicious build-time code into your CI." Signed + attested releases let downstream consumers (you, your customers, an auditor) verify the binary came from an unmodified source repo + your specific workflow. If an attacker steals your GitHub credentials and pushes a malicious tag, the signature still ties to *that compromised workflow run*, not to a clean one — discovery becomes possible.

> **How to talk about this:** "We hit SLSA Build Level 2 by default — the attestation is generated by GitHub's hosted runner, signed via Sigstore's keyless infrastructure tied to our OIDC identity, and recorded in Rekor's public transparency log. Anyone can verify the chain in 30 seconds with one `gh attestation verify` command."

### Drift detection

`_drift-nightly.yml` runs the same scanners against `main` every day at 07:00 UTC, regardless of whether anyone pushed. Why: a CVE disclosed today against a dependency you pinned 6 months ago doesn't show up on PR runs (you didn't change the dep). The nightly run surfaces it within 24 hours.

---

## 4. Per-site hardening

Each site has a different stack and a different attack surface. The shared CI runs on all of them, but each got site-specific work too.

### 4.1 GlobalManagement (Astro static SPA, deployed to Cloudflare Pages)

**Risk profile:** lowest of the three. No backend, no PII storage. Only attack surface is a contact form (handed off to Web3Forms) and the supply chain.

**What we did:**
- Created `public/_headers` file (Cloudflare Pages auto-applies it):
  - HSTS: `max-age=63072000; includeSubDomains; preload` (2 years)
  - X-Content-Type-Options: `nosniff`
  - Referrer-Policy: `strict-origin-when-cross-origin`
  - Permissions-Policy: locks down camera/mic/geolocation
  - CSP: only allows scripts from self + Cloudflare Turnstile; only allows form posts to Web3Forms; `frame-ancestors 'none'` (can't be iframed → clickjacking-proof)
- Cloudflare Turnstile widget added to the contact form (replaces CAPTCHAs; invisible challenge for legit users).
- Lighter pipeline: skips SAST (no server code), skips container scan (no container), skips DAST (no dynamic surface). Just secrets + SCA + actionlint + headers smoke test.

**Recon correction worth knowing:** the original recon agent claimed `.env` with `PUBLIC_WEB3FORMS_ACCESS_KEY` was committed. **Reality: `.env` was never in git history.** The Web3Forms key was hardcoded as a default prop value in `src/components/ContactForm.astro`. We documented the actual finding in the IR doc.

> **How to talk about this:** "Static site, low attack surface. The interesting work is the CSP — `script-src` is allowlisted, no `'unsafe-inline'`, `frame-ancestors 'none'`. That alone defeats most XSS and all clickjacking."

### 4.2 sacred-portal-wellness (Next.js 16 + Square Payments on Cloudflare Workers)

**Risk profile:** highest of the three. PII (contact form) + payments (Square checkout) + active API surface.

**What we did:**
- Security headers in `app/next.config.ts` (the active app lives at `app/` — repo root has stale duplicates):
  - All 5 headers from above plus a CSP that explicitly allows `*.squarecdn.com` and `*.squareup.com` (Square's hosted SDK + payment links) — nothing else.
  - `Permissions-Policy: payment=(self "https://*.squareup.com")` — restricts the Payment Request API to Square only.
- Custom Semgrep rule enforces SQUARE_ACCESS_TOKEN access only via the wrapper module.
- Webhook signature rule ensures any future Square webhook handler verifies HMAC.
- Plan: migrate from `.env.local` to `wrangler secret put` for runtime secrets (encrypted at the Cloudflare edge, audit-logged).

**PCI-DSS angle:** Because Square handles cards via redirect mode (the merchant's checkout page links to Square's hosted payment page), sacred-portal qualifies for **SAQ A** — the lightest PCI scope. The merchant page never touches PAN. To preserve SAQ A under PCI-DSS v4.0.1 (effective March 31, 2025), we must inventory all `<script>` tags on payment-linked pages (Req 6.4.3) and detect tampering (Req 11.6.1). The CSP allowlist + SRI on third-party scripts is how we satisfy that.

**Recon correction:** the original recon claimed `.env.local` with live Square production credentials was committed. **Reality: `.env.local` was never in git history.** Only `.env.example` (placeholders) was committed. If a real `.env.local` exists on your local disk, rotate the keys (defense in depth) — but no GitHub history scrubbing or Support ticket needed.

> **How to talk about this:** "Square redirect mode keeps us in SAQ A — the lightest PCI scope — because no card data ever lives on our origin. CSP plus SRI satisfies the v4.0.1 script-inventory requirement. The Semgrep rule enforces that the API token only flows through one wrapper module, so the audit surface for credential exposure is one file."

### 4.3 antiphazeprod (Astro SSR + Pretix Docker stack on DigitalOcean)

**Risk profile:** medium. Real PII (ticket-buyer names, emails). Payment is delegated to whatever PSP Pretix is configured against. Pretix is Django and gets CVEs. Most operational surface area of the three sites.

**What we did:**

**Runtime / dependencies:**
- Verified Astro's Node adapter is on `^10.0.4` with `engines.node ">=22.12.0"` (Dependabot had already upgraded from Node 16 — the EOL-Node-CVE concern from the design doc is already mitigated).

**Docker Compose lockdown** (`infrastructure/docker/docker-compose.yml`):
- **Postgres and Redis bound to internal Docker network only** — no `ports:` to host. The August 2024 documented DO droplet breach was exactly this misconfiguration (port 5432 exposed + default password).
- Every service declares `cap_drop: [ALL]`. Caddy is the only service that re-adds `NET_BIND_SERVICE` (needed to bind 80/443 as non-root).
- Caddy runs `read_only: true` with explicit `tmpfs:` mounts for writable paths.

**Caddy reverse proxy** (`infrastructure/caddy/Caddyfile`):
- DNS-01 ACME challenge via `acme_dns cloudflare` — issuing certs via DNS rather than HTTP-01, so we don't depend on port 80 being open. Built using `xcaddy` with the `caddy-dns/cloudflare` plugin (custom Dockerfile at `infrastructure/docker/caddy/Dockerfile`).
- Security headers snippet (`(security_headers)`) imported into the `tickets.antiphazeprod.com` block: HSTS, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, and `-Server` (strips Caddy version banner).
- Connection timeouts hardcoded (read_body 10s, read_header 5s, write 30s, idle 5m) — slow-loris mitigation.

**Cloudflare Access for `/control` admin:**
- Cloudflare Tunnel + Access policy on `tickets.antiphazeprod.com/control*`.
- One-time PIN identity provider (free, no IdP needed) + WebAuthn required.
- 8-hour session.
- This means: no direct internet access to Pretix's admin login form. Credential stuffing attacks land on Cloudflare's Access page, not Pretix.

**SMTP credentials** (`website/src/pages/api/contact.ts`):
- Removed hardcoded fallbacks. Now throws if `SMTP_USER` or `SMTP_PASS` env vars are missing. (Originally had `SMTP_USER || 'antiphazeprod.com'` and `SMTP_PASS || ''` — username leak + silent-fail empty-string bug.)

**Secrets management** (`infrastructure/sops/`):
- SOPS+age scaffolding. Encrypted production env file (`prod.env.enc`) committed to repo; age private key lives on the droplet at `/etc/age/keys.txt` (root-owned, 0600). Decrypt-at-deploy hook (`scripts/decrypt-env.sh`) writes a runtime `.env` with mode 0600.
- Rationale: pure OSS, no SaaS, encrypted-at-rest secrets safe to commit, single decryption key on the production host.

**SSH hardening (USER tasks, documented in checklist):**
- Generate ed25519 deploy key, disable password auth, install fail2ban.
- DO Cloud Firewall scoped: SSH (22) only from GitHub Actions runner IPs + your home IP. Refreshed weekly via the cron workflow we wrote (`refresh-do-firewall.yml` calls `tools/scripts/refresh-gh-runner-ips.sh` which curls `api.github.com/meta` and updates the firewall via `doctl`).

**Recon correction:** the original recon overstated the SMTP "leak" — the password fallback was an empty string, not a real credential. The username `'antiphazeprod.com'` was the only thing leaked. Severity is "high" for the principle but not for the actual blast radius.

> **How to talk about this:** "antiphaze is the most operationally complex of the three. Postgres/Redis live on the internal Docker network — never publicly addressable. Caddy uses DNS-01 ACME so we don't need port 80 open. Cloudflare Access gates the Pretix admin path with WebAuthn — credential stuffing literally cannot reach the login form. Secrets are SOPS-encrypted in the repo with age, so there's no SaaS dependency for secret management."

### 4.4 The meta-repo (elmdevsecops — the platform)

**What it is:** the source of truth for shared security tooling. It holds:
- The reusable CI workflow consumed by all 3 sites
- OPA Conftest policies (containers, GitHub Actions)
- Custom Semgrep rules with TDD test fixtures
- Threat models (cross-cutting + per-site)
- Operational runbooks (incident response, secrets rotation, Cloudflare bootstrap, fallback)
- Smoke-test scripts (TLS, headers, DO firewall refresh)

**The architectural decision** (from the followup research — see `docs/USER-ACTION-CHECKLIST.md` and the chat transcript): instead of *vendoring* the reusable workflow into each site repo (current state), the cleaner approach is to make the meta-repo a real GitHub repo and have each site repo's `.github/workflows/security.yml` reference it directly:

```yaml
jobs:
  security:
    uses: <org>/<meta-repo>/.github/workflows/_security-base.yml@<full-sha>
```

This eliminates drift completely (only one canonical workflow exists) and matches GitHub's documented hardening guidance for SHA pinning. Ultimate.ai's R&D team published a migration story showing this exact pattern; the [GitHub Actions GA blog post](https://github.blog/news-insights/product-news/github-actions-reusable-workflows-is-generally-available/) shows the same syntax.

> **How to talk about this:** "The meta-repo is the platform. The three sites are consumers. Each site's `security.yml` is a 10-line caller pinned to a specific SHA of the meta-repo — that's an immutable reference, the same supply-chain principle we apply to third-party Actions."

---

## 5. Cross-cutting controls

### 5.1 TLS baseline

We target the **Mozilla Server-Side TLS "Intermediate"** profile (current as of April 2026):
- TLS 1.2 + TLS 1.3 only. (TLS 1.0/1.1 disabled.)
- TLS 1.3 ciphers only: `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`.
- TLS 1.2 ciphers: ECDHE-{ECDSA,RSA} AES-GCM and CHACHA20-POLY1305 only — no CBC, no SHA1, no static RSA.
- Curves: `X25519MLKEM768` (post-quantum hybrid), `X25519`, `prime256v1`, `secp384r1`.
- Leaf certs: ECDSA P-256.
- HSTS: `max-age=63072000; includeSubDomains; preload`.
- DNS CAA records restricting cert issuance to chosen CAs.
- Certificate Transparency monitoring via SSLMate Cert Spotter (free).

**Things we explicitly DO NOT configure** (security theatre or actively harmful):
- **HPKP** — deprecated 2018, can lock users out
- **Expect-CT** — deprecated 2023
- **OCSP must-staple** — Let's Encrypt rejects it as of May 2025; OCSP responders EOL Aug 2025
- **TLS 1.3-only** — TLS 1.2 with Mozilla Intermediate ciphers isn't measurably weaker; only flip if compliance forces it
- **P-384 leaf certs** — slower handshake, no real threat-model improvement

CI enforcement: `tools/scripts/test-tls.sh` runs `sslyze` against the deployed URL. If TLS 1.0/1.1 is enabled, weak cipher accepted, Heartbleed-vulnerable, or ROBOT-vulnerable, the post-deploy gate fails.

> **How to talk about this:** "Mozilla Intermediate, not Modern. Modern is TLS 1.3 only and breaks ~3% of older mobile traffic for no real-world security gain. Intermediate gives us full browser compat plus all the modern cipher suites."

### 5.2 Cloudflare in front of everything

All three sites are proxied through Cloudflare's free tier. What we get for $0:

- **DDoS protection** (anycast network absorbs L3/L4/L7 floods)
- **Universal SSL** (auto-issued + auto-renewed certs)
- **WAF Managed Rules** + **OWASP Core Ruleset** (set to Medium sensitivity — raise to High after 2 weeks of monitoring)
- **Bot Fight Mode** (heuristic bot blocking)
- **Turnstile** (CAPTCHA replacement, used on contact forms)
- **Cloudflare Access** (Zero Trust, free for ≤50 users) — gates the Pretix `/control` admin path with WebAuthn
- **Cloudflare Pages** (free hosting + unlimited bandwidth for GlobalManagement)

For antiphaze on the DO droplet, we use a Cloudflare **Origin CA cert** (15-year validity, ECDSA P-256) on the droplet's Caddy. With SSL/TLS mode = Full (strict), Cloudflare validates the origin cert; the only path to the droplet that works is via Cloudflare's IPs.

> **How to talk about this:** "Cloudflare's free tier gives us DDoS, WAF, bot mitigation, automatic TLS, Zero Trust admin gating, and CAPTCHA — for zero dollars. The trade-off is concentration risk on one vendor; we accept that explicitly and document a fallback runbook for Cloudflare outages."

### 5.3 Secrets management (per-environment)

| Environment | Tool | Mechanism |
|---|---|---|
| Local dev | `.env.local` (gitignored) | Populated from your password manager |
| GitHub Actions CI | GitHub Encrypted Secrets + `production` Environment with required reviewers | Scoped tokens; OIDC where the cloud provider supports it |
| Cloudflare Workers runtime (sacred-portal) | `wrangler secret put VAR` | Encrypted at edge, audit-logged |
| DigitalOcean droplet (antiphaze) | SOPS+age | `prod.env.enc` committed; age key on droplet at `/etc/age/keys.txt` |
| Cloudflare Pages (GlobalManagement) | Pages dashboard env vars | Encrypted at rest |

**Detective controls** (catch the next leak):
- gitleaks pre-commit hook (lefthook)
- gitleaks in CI on full history
- GitHub Push Protection (server-side, blocks recognized provider patterns before push)
- AWS canary tokens planted in plausible-looking files (free, https://canarytokens.org) — TruffleHog auto-validates discovered AWS keys, which fires the canary alert

> **How to talk about this:** "Defense in depth on secrets. Pre-commit hook catches them client-side. Push Protection catches them server-side. CI gitleaks catches them on every push. SOPS keeps production secrets encrypted-at-rest in the repo. Canary tokens give us active deception against scrapers."

### 5.4 Local AI security review (Claude Code)

We chose **local Claude Code** over Anthropic API in CI for cost and depth. Each site repo has a `.claude/commands/security-review.md` slash command. You invoke it locally before pushing significant changes.

The command:
1. Reads `git diff main..HEAD`.
2. Reads the threat model and security policy.
3. Runs gitleaks, Semgrep (OWASP + custom rules), OSV-Scanner locally.
4. Classifies every finding by severity, category, file:line, rationale, fix.
5. Outputs a markdown report.
6. You save the report to `.security-reviews/PR-<branch>-<date>-<sha>.md` and commit it.

**Why local instead of API in CI:**
- $0 marginal cost (covered by your existing Claude Code subscription)
- Whole-repo context (Claude Code can navigate freely; API mode is constrained to the diff window)
- Audit trail via committed `.security-reviews/` artifacts — every PR carries its review with it

**The deterministic CI scanners are still the truth source.** They run regardless of whether you remember to invoke `/security-review`. If you skip the AI review, gitleaks/Trivy/Semgrep/OSV-Scanner still gate the deploy.

> **How to talk about this:** "Defense in depth, again. Deterministic scanners enforce the floor — they can't be skipped. Claude Code at the developer's machine gives a deeper, context-aware review that catches subtle pattern issues — but it's voluntary, and the audit artifact in the repo proves whether it was done."

---

## 6. The SDLC mapping

We didn't map controls to a compliance framework (NIST CSF / PCI / ISO). The user explicitly chose **"secure SDLC tenets, no formal compliance framework."** So controls are organized by SDLC phase:

| Phase | Controls |
|---|---|
| **Requirements / Design** | Threat models per site; security policy doc; architecture data-flow diagrams |
| **Implementation** | `.gitignore` audit; pre-commit hooks (gitleaks, actionlint); local Claude Code `/security-review` |
| **Build** | `npm ci` with lockfile integrity; CycloneDX SBOM via Syft; multi-stage Dockerfile (caddy) |
| **Test (CI)** | 6 parallel scanners + gate (secrets, sast, sca, iac, container, policy, build) |
| **Deploy** | OIDC-based cloud auth where possible; required reviewers on `production` Environment; cosign keyless signing; SLSA build provenance |
| **Operate** | `mozilla/observatory-cli` post-deploy headers grade; sslyze TLS regression; ZAP baseline; Nuclei templates against running services |
| **Maintain** | Drift detection nightly job; allowlist hygiene with `# justified: <reason> <expiry>`; quarterly tabletop |

Reference frameworks (engineering-grade, not compliance-grade):
- **NIST SSDF** (SP 800-218) — practices like PS.1.1 (protect code from unauthorized access), PW.4.4 (review components for vulns), PS.2 (provide a mechanism to verify software release integrity)
- **OWASP SAMM** — maturity model for secure SDLC

> **How to talk about this:** "We mapped to SSDF practices because that's the engineering language. PS.1.1 says 'protect code from unauthorized tampering' — we satisfy that with branch protection, signed commits, and Sigstore-attested builds. We didn't go after a compliance framework because the customer didn't need it; the work would *support* an audit if someone ran one."

---

## 7. Glossary — for when someone asks "what's X?"

**ACME** — Automated Certificate Management Environment. The protocol Let's Encrypt uses for issuing certificates. RFC 8555.

**age** — modern encryption tool by Filippo Valsorda. Used here with SOPS for encrypting production env files in git.

**CSP (Content Security Policy)** — HTTP header that restricts what scripts/styles/images/iframes a page can load. Primary defense against XSS and clickjacking.

**CycloneDX** — SBOM format (alternative: SPDX). Both are accepted by the EU Cyber Resilience Act and US Executive Order 14028.

**DAST (Dynamic Application Security Testing)** — runs against a deployed app (e.g., OWASP ZAP). Finds runtime issues SAST can't.

**DDoS** — Distributed Denial of Service. Cloudflare's free tier mitigates this.

**Dependabot** — GitHub-native dependency vulnerability scanner + auto-PR remediation.

**ECDSA P-256** — Elliptic Curve Digital Signature Algorithm on the P-256 curve. Faster than RSA-2048, no real-world threat-model difference for web traffic.

**HSTS (HTTP Strict Transport Security)** — header that tells browsers "always use HTTPS for this domain." Preload list submission is a one-way door.

**HMAC** — Hash-based Message Authentication Code. Used to verify webhook payload integrity (sender + receiver share a secret; sender signs payload; receiver recomputes and compares).

**IaC (Infrastructure as Code)** — Dockerfile, docker-compose.yml, Terraform, CloudFormation. Scanned by Checkov / Trivy config.

**Mozilla Intermediate** — Mozilla's published TLS configuration profile. Updated periodically. We target the v6.0 (April 2026) recommendations.

**OPA (Open Policy Agent) / Conftest** — policy-as-code engine using Rego language. Runs unit tests on policies, then evaluates real config files against them.

**OSV.dev** — Google's open-source vulnerability database. Curated, deduplicates GHSA + NVD + ecosystem advisories.

**OWASP** — Open Worldwide Application Security Project. Maintains the Top 10 vulnerability list, ASVS (Application Security Verification Standard), SAMM.

**PCI-DSS** — Payment Card Industry Data Security Standard. v4.0.1 (effective March 2025) added new script-inventory + tamper-detection requirements (Reqs 6.4.3, 11.6.1).

**PII (Personally Identifiable Information)** — names, emails, addresses, etc. Triggers GDPR considerations.

**PKI** — Public Key Infrastructure. Includes Cloudflare's Origin CA (used for the droplet cert).

**SAQ A** — PCI-DSS Self-Assessment Questionnaire A. The lightest scope (~22 requirements). Applies to merchants who fully outsource cardholder data handling (e.g., Square redirect mode).

**SAST (Static Application Security Testing)** — analyzes source code for vulnerabilities without running it. Semgrep, CodeQL, Snyk Code.

**SBOM (Software Bill of Materials)** — manifest of every dependency in a build. Generated by Syft.

**SCA (Software Composition Analysis)** — scanning your dependencies for known vulnerabilities. OSV-Scanner, Dependabot, Snyk.

**Semgrep** — open-source SAST tool. Pattern-matching on syntax trees. We use the OSS edition with public rule packs + 2 custom rules.

**SHA pinning** — referencing a third-party action by its full 40-char commit hash, not by branch or tag (which can be moved).

**Sigstore** — public-good signing infrastructure (Fulcio CA + Rekor transparency log). Used for keyless cosign signing.

**SLSA (Supply-chain Levels for Software Artifacts)** — framework for build-process integrity. We hit Build Level 2 by default with `actions/attest-build-provenance@v1`.

**SOPS** — Secrets OPerationS. Tool for encrypting structured config files (env, YAML, JSON). Pairs with age, AWS KMS, GCP KMS, etc.

**SRI (Subresource Integrity)** — hash-pinning external scripts in HTML so the browser refuses to execute a tampered version.

**SSDF (Secure Software Development Framework)** — NIST SP 800-218. Engineering-language guidance.

**TLS 1.3** — current TLS protocol. RFC 8446 (Aug 2018). Faster handshake, mandatory PFS, no static RSA key exchange.

**Trivy** — open-source container + IaC + filesystem scanner by Aqua Security. Single binary; covers a lot.

**WAF (Web Application Firewall)** — pattern-based filter for HTTP traffic. Cloudflare's free tier includes Managed Rules + OWASP Core Ruleset.

**Wrangler** — Cloudflare Workers CLI. Used for `wrangler secret put` to set runtime secrets.

**xcaddy** — Caddy build tool that lets you compile Caddy with extra plugins (e.g., `caddy-dns/cloudflare` for DNS-01 ACME).

---

## 8. Likely engineer-to-engineer Q&A (rehearse these)

> **Q: Why not just use a paid SaaS for SAST? Snyk, Veracode?**
> A: OSS tools cover the same ground at $0. Semgrep OSS + custom rules + OSV-Scanner + Trivy collectively match what a paid solution gives. The user constraint was zero variable cost. We'd revisit this if false-positive volume ever drove a real productivity hit.

> **Q: Why Cloudflare and not AWS?**
> A: Free tier covers DDoS, WAF, Universal SSL, Access (Zero Trust), Pages, and Workers — for $0. AWS WAF + CloudFront would be ~$30-40/month minimum and require us to own 21+ CIS AWS Foundations Benchmark controls. For three small sites, that's resume-padding, not security engineering.

> **Q: How do you handle a vendor outage on Cloudflare?**
> A: Documented in `docs/runbooks/cloudflare-fallback.md`. Marketing pages can bypass DNS proxy (turn off orange cloud) → direct to origin. Payments are unavailable during the outage; we accept that and post a status page. The dollar trade-off is we'd pay multi-cloud premium to engineer around 99.99% uptime at our scale — not worth it.

> **Q: Is local Claude Code AI review actually rigorous, or is it theatre?**
> A: It's a complement, not a replacement. The deterministic scanners (gitleaks, Semgrep, Trivy, OSV-Scanner, Checkov, conftest) are the truth source — they enforce the security floor regardless of whether AI ran. The AI catches subtle pattern issues that the scanners miss (e.g., a CSP weakening from `script-src 'self'` to `script-src 'self' 'unsafe-inline'` because someone needed an inline script). We make the AI artifact committable for the audit trail.

> **Q: Why TDD for OPA/Conftest policies and Semgrep rules?**
> A: Same reason as TDD for application code. The policy IS the test target. We write fixtures that should fire the rule and fixtures that shouldn't, run the rule, confirm counts match, then commit. Otherwise we'd end up with a policy that compiles but is logically wrong — catches nothing or catches everything.

> **Q: Why didn't you target a compliance framework?**
> A: User explicit choice. They wanted secure SDLC tenets, not auditor packaging. The work would support an audit if one were run — we have a threat model, a security policy, signed releases with provenance, an SBOM per release, an incident response template — but we didn't generate compliance evidence reports. That's a Phase 2 add-on if MEMX-the-employer ever needs PCI/SOC 2 from us.

> **Q: Why polyrepo, not monorepo?**
> A: Three independent stacks. Astro static, Next-on-Workers, Astro-SSR-on-droplet — they share zero build tooling. They share security tooling. Monorepo would force us to retrofit Turbo/pnpm onto three deploy pipelines for portfolio reasons, and a single bad merge could break all three live sites. Polyrepo with a shared platform repo is the right answer per the published industry guidance (Cloudflare's terraform-cloudflare-at-cloudflare blog, Ultimate.ai's reusable-workflow migration).

> **Q: What's your incident response if a Square production token leaks again?**
> A: Documented per-repo in `SECURITY-INCIDENT-2026-05-07.md` and the template at `docs/runbooks/incident-response-template.md`. Order: rotate first (Square dashboard → Replace Token), verify abuse via `ListPayments` API for the exposure window, scrub git history with `git-filter-repo`, force-push, file GitHub Support ticket to purge cached PR diffs, document. PCI-DSS v4.0.1 Req 3.7.5 says any compromised key must be retired and replaced.

> **Q: What's the canary-token strategy?**
> A: Free AWS-format tokens from canarytokens.org planted in plausible-looking files (e.g., `infrastructure/legacy/.old-deploy.env.bak`). Attacker tooling — including TruffleHog — auto-validates discovered AWS keys, which fires an email alert immediately. Active deception is one of the cheapest controls available; it costs nothing and signals real defensive thinking in an interview.

> **Q: Branch protection — what's enforced?**
> A: On `main`: required status checks (`gate` from `_security-base.yml`), required signed commits, required code-owner review on `/.github/`, `/policy/`, `/infrastructure/`, linear history, no force pushes. On `devops`: looser — just `gate` required.

> **Q: Why Sigstore keyless vs. a hardware key?**
> A: Hardware keys solve the wrong problem for short-lived CI signatures. The Sigstore identity is your GitHub OIDC token, scoped to that workflow run. The signature gets logged in Rekor (public, append-only, externally verifiable). For a regulated environment with stricter requirements, you can self-host Fulcio — but for our threat model, public-good Sigstore is the right call.

> **Q: How do you keep up with new CVEs in dependencies?**
> A: OSV-Scanner runs nightly against `main` regardless of new commits. Dependabot opens PRs for known fixes. The combination catches CVE disclosures within 24 hours.

> **Q: What's stopping someone from disabling CI on their PR to push something dangerous?**
> A: Branch protection requires the `gate` check to succeed. Admin override is logged in the GitHub audit log. We review the audit log monthly. Zero-trust on `main`.

---

## 9. How to demo this in 5 minutes

If you're walking an interviewer through this:

1. Open the meta-repo's README. Show the high-level "what this is" + "what's enforced."
2. Open `docs/threats/threat-model.md`. Walk through the 8 threats and the 4 accepted risks.
3. Open `workflows-templates/_security-base.yml`. Point to the 6 parallel jobs + gate.
4. Open `policy/containers.rego` and `policy/containers_test.rego`. Show the Rego rule + its tests.
5. Open `tools/semgrep-custom/square-token-wrapper.yaml` and the `square-bad.ts` / `square-good.ts` fixtures. Show TDD on a security rule.
6. Open one of the per-repo `SECURITY-INCIDENT-2026-05-07.md` reports. Show that you have a documented IR habit.
7. Open one site repo's `.github/workflows/security.yml`. Show that it's a 10-line caller (after the planned migration to reusable-workflow reference).
8. Show the GitHub Release page for any tagged release. Point to the cosign bundle + SLSA attestation + SBOM as evidence.

Total time: 5 minutes. Each click answers a different "do you actually know what you're doing" question.

---

## 10. The one paragraph you can read aloud

> "I run three independent production websites — a static Astro marketing site on Cloudflare Pages, a Next.js + Square Payments app on Cloudflare Workers, and an Astro SSR + Pretix Docker stack on a DigitalOcean droplet. I built a shared security platform that all three consume by reference: it has reusable GitHub Actions workflows running gitleaks for secrets, Semgrep with custom rules for SAST, OSV-Scanner for SCA, Trivy for containers, Checkov for IaC, and Open Policy Agent for compliance gates. Releases are signed with Cosign keyless via Sigstore and carry an SLSA build provenance attestation plus a CycloneDX SBOM. TLS targets Mozilla Intermediate. Cloudflare's free tier handles DDoS, WAF, Universal SSL, and Zero Trust admin access. Secrets live in SOPS+age on the droplet, Wrangler secrets on Workers, GitHub Encrypted Secrets in CI. The whole thing maps to NIST SSDF practices and was built for $0 in marginal monthly cost."

That's the elevator pitch. Anything past 60 seconds, the engineer is interested and you can drop into any section above.
