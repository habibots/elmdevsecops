# Cross-cutting Threat Model

This document is the consolidated threat model across all three site repos. It is opinionated. We defend against attacks that **actually target small-business marketing-and-commerce sites**, not nation-state APTs or insider threats.

The threat catalogue below is the source of truth for what each CI scanner exists to catch and what each runbook is meant to address. Per-site addenda (`globalmanagement.md`, `sacred-portal.md`, `antiphaze.md`) refine these threats with site-specific data flows.

## Threats we defend against

| # | Threat | Realism for these sites | Primary mitigation | Where enforced |
|---|---|---|---|---|
| **T1** | **Magecart / client-side card skimming** | High for sacred-portal (Square checkout flow). Akamai reports +103% growth 2024–2025. | Strict CSP `script-src` allowlist; SRI on every external `<script>`; Cloudflare WAF managed rules. | Cloudflare Pages `_headers`, `next.config.js` (sacred-portal), Caddyfile (antiphaze). Verified by `tools/headers/expected-baseline.json` smoke tests. |
| **T2** | **Form spam and SMTP abuse** | Universal. All three sites have at least one form. | Cloudflare Turnstile in front of every form; server-side rate-limit on contact APIs; honeypots; origin/CSRF check on POSTs. | sacred-portal `app/api/contact/route.ts`, antiphaze `website/src/pages/api/contact.ts`. GlobalManagement uses Web3Forms (server-side handled). |
| **T3** | **npm supply-chain compromise** | High and rising — Sept 2025 chalk/debug worm; Shai-Hulud; Apr 2026 Vercel-via-OAuth. | `npm ci` with hash-pinned lockfiles; OSV-Scanner gate on every PR; nightly drift scan; cosign-signed releases with SLSA provenance; SBOM published per release. | `_security-base.yml` jobs `sca` + `build` + `release`; `osv-scanner.toml`; `_drift-nightly.yml`. |
| **T4** | **Credential leak via committed secrets** | Already happened (Square, Web3Forms, SMTP creds in pre-rotation history). | GitHub Push Protection (server-side); gitleaks pre-commit hook (client-side); gitleaks job in CI (full history); scheduled TruffleHog with verifiers; canarytoken for early detection. | `.gitleaks.toml` + `lefthook.yml` (per repo); `_security-base.yml` `secrets` job; `_drift-nightly.yml` daily rescan. |
| **T5** | **Credential stuffing on admin panels** | Pretix `/control` is the only relevant admin surface (antiphaze). | Cloudflare Access in front of `/control` with WebAuthn (Zero Trust free tier ≤ 50 users). No password login exposed to the public internet. | Cloudflare Access policy on `tickets.antiphazeprod.com/control`; `docs/runbooks/cloudflare-bootstrap.md`. |
| **T6** | **DDoS extortion** | Low absolute likelihood, high impact if it materialises. | Cloudflare proxy on all three sites; free tier provides unmetered Layer 3/4/7 DDoS protection. | Cloudflare DNS/proxy config; documented fallback in `docs/runbooks/cloudflare-fallback.md`. |
| **T7** | **TLS / cert misconfiguration** | Common ops failure (expired certs, weak ciphers, broken redirects). | Caddy automatic HTTPS on droplet; Cloudflare Universal SSL on edge sites; sslyze/testssl smoke-test in CI as regression gate; HSTS preload. | `tools/headers/check-tls.sh`; per-repo `_headers` / Caddyfile / `next.config.js`. |
| **T8** | **Outdated runtime CVEs** | Currently exploitable (pre-Phase-1: Node 16 EOL with CVE-2024-22019 in antiphaze). | Pin Node 22 LTS across all repos; OSV-Scanner runs nightly on `main` to surface new CVEs in pinned deps; `engines` field in `package.json`. | Each repo's `package.json` `engines.node`; `_drift-nightly.yml`. |

## Risks we explicitly accept

These are documented and revisited yearly, but we do **not** engineer against them:

- **Nation-state targeted attack.** Out of threat surface for the operator profile (small business, public-facing marketing/commerce sites). Mitigation cost is non-linearly higher than impact reduction.
  *Residual risk:* low absolute likelihood; if it happens, complete compromise is plausible. Accepted.

- **Insider threat (single operator).** Single-operator workspace; an adversarial operator owns the keys regardless. Threat model assumes the operator is benign.
  *Residual risk:* zero protection against malicious operator. Accepted.

- **Physical compromise of operator's laptop.** Covered by macOS FileVault + password-manager hygiene + short auto-lock. Out of project scope.
  *Residual risk:* minor; physical access plus FileVault bypass is high-effort. Accepted.

- **Cloudflare global outage (e.g. Nov 2025, Jun 2025, Mar 2025).** Cloudflare is on the critical path for DNS, CDN, WAF, Turnstile, Workers, Pages, Access. We accept availability dependency in exchange for free-tier coverage.
  *Residual risk:* documented fallback in `docs/runbooks/cloudflare-fallback.md` — orange-cloud bypass for marketing pages, tolerate degraded checkout for sacred-portal. Accepted.

## Out of scope

- WAF rule tuning beyond Cloudflare managed rules
- Anti-bot at the depth of e.g. PerimeterX / DataDome
- Database-encryption-at-rest beyond what DigitalOcean/Square provide by default
- Compliance certifications (SOC 2, PCI DSS — Square handles PCI scope)

## Living document

Threats are revisited quarterly or whenever a new asset (new payment provider, new admin panel, new third-party script) is added. Per-site addenda must be updated in the same PR that introduces the change.
