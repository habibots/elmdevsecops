# Security Policy

This document is the source of truth for **what is enforced by tooling vs what is enforced by discipline** across the three site repos (`GlobalManagement`, `sacred-portal-wellness`, `antiphazeprod`) and the meta-repo (`elmdevsecops`).

## 1. Scope and intent

This policy applies to every commit, every PR, and every deploy across the three sites. It is intentionally minimal — every rule below has a corresponding scanner, policy file, or branch-protection setting that enforces it automatically. Discipline-only rules (those that depend on a human reading the diff) are clearly labelled.

The threat model in `docs/threats/threat-model.md` is the *why*; this document is the *what we do about it*. If a rule here cannot be traced to a threat there, it is a candidate for removal.

## 2. Branch protection rules

On `main` for every site repo:

- **Required status checks** (must all pass to merge):
  - `secrets` (gitleaks)
  - `sast` (Semgrep OSS + custom rules)
  - `sca` (OSV-Scanner)
  - `iac` (Checkov + actionlint + zizmor)
  - `container` (Trivy — antiphaze only)
  - `policy` (OPA Conftest)
  - `build` (npm ci + build + SBOM)
  - `gate` (aggregator)
- **Signed commits required** via `gitsign` (Sigstore keyless, ties signature to GitHub OIDC identity). *(Pending operator setup; see open follow-up in meta-repo `CONTRIBUTING.md`.)*
- **Linear history** — no merge commits; squash-merge or rebase-and-merge only.
- **No force push** to `main`.
- **Code owner review** required on changes to `.github/`, `infra/`, `tools/headers/`, anything under a `square` directory, and any `webhooks` route.

On `devops`: the same status checks; reviews not strictly required at the meta-repo (single-operator project) but enforced at site-repo level.

## 3. Severity gating philosophy

- **Critical** and **High** findings: **block merge**. No exceptions without an allowlist entry (see §4).
- **Medium** findings: emit to GitHub Security tab for triage; do not block merge.
- **Low** / **Info**: emit; not surfaced unless the operator queries the Security tab.

This is deliberately stricter than "noisy CI everyone ignores" and looser than "CI blocks on every Info finding." The bet is that High+ in any of {gitleaks, Semgrep, OSV-Scanner, Trivy, Checkov, conftest} means a real problem worth solving before merge.

## 4. Allowlist hygiene

Every allowlist entry (in `.gitleaksignore`, `osv-scanner.toml`, Semgrep `.semgrepignore`, Checkov `.checkov.yaml` skip lists) **must** carry an inline justification with an explicit expiry date:

```
# justified: <reason in plain prose> <YYYY-MM-DD-expiry>
```

Examples:
```
# justified: vendor lib pins to lodash 4.17.20; CVE-2021-23337 patched in 4.17.21 but vendor releases lag <2026-09-01>
```

**Auto-expiry** is enforced by the `_drift-nightly.yml` workflow: the nightly job parses justifications, surfaces any past-due entry as a CI failure on `main`. Past-due allowlist entries become a hard block on the next PR; the operator must either remove the allowlist (problem fixed) or push the expiry forward with a fresh justification.

## 5. Signed-commit requirement on `main`

`main` requires signed commits. We use **`gitsign`** (Sigstore keyless) — the operator authenticates with GitHub OIDC; no GPG keys to manage. Verification is `gh attestation verify-commit` or `git verify-commit`. Locally, `gitsign` can be installed once via `brew install sigstore/tap/gitsign` and configured in the meta-repo's `.gitconfig` include.

**Until `gitsign` is installed** (operator follow-up), meta-repo commits use `git -c commit.gpgsign=false commit ...`. Site-repo commits should use `gitsign` as soon as it is set up.

## 6. Secrets policy

- **Never commit `.env*`** files (except `.env.example`). The `.gitignore` files in every repo already block these; lefthook's gitleaks hook is the second line.
- **Per-environment secret store:**
  | Surface | Store | Mechanism |
  |---|---|---|
  | Local dev | `.env.local` (gitignored) | Populated from password manager |
  | CI | GitHub Encrypted Secrets + GitHub Environments (`production`) with required reviewers | OIDC where possible (AWS); scoped tokens elsewhere |
  | Workers runtime | `wrangler secret put` | Encrypted at edge, audit-logged |
  | Droplet runtime | SOPS+age | `infrastructure/docker/prod.env.enc` committed; age key on droplet at `/etc/age/keys.txt` |
  | Pages runtime | Cloudflare Pages dashboard env vars | Encrypted at rest |
- **Quarterly rotation** of every long-lived credential, per `docs/runbooks/secrets-rotation.md`.
- **Detective controls:** scheduled TruffleHog with verifiers + a deliberately-leaked canary token; an inbound canary hit is treated as confirmed compromise.

## 7. The "no `SQUARE_ACCESS_TOKEN` outside the wrapper" rule

Only the module `app/lib/square/index.ts` (in `sacred-portal-wellness`) may read `process.env.SQUARE_ACCESS_TOKEN` or `env.SQUARE_ACCESS_TOKEN`. All other code must call into the wrapper module's exported functions.

**Enforced by** `tools/semgrep-custom/square-token-wrapper.yaml`. Violation blocks the SAST CI gate. Adding the rule was a Phase-5a deliverable.

The rationale is that compromise blast-radius for the access token is the entire production Square account. Centralising every token-bearing call into one auditable file lets us:
- log every Square call with consistent metadata,
- enforce timeouts and idempotency keys uniformly,
- review changes to that file with extra scrutiny (CODEOWNERS).

## 8. The "webhooks must verify HMAC" rule

Every file matching `app/api/webhooks/*/route.ts` (sacred-portal) and equivalent paths in other sites must call a HMAC verifier on the raw request body **before** any side effect. Specifically: the verifier call must precede any DB write, any external HTTP request, and any state mutation.

**Enforced by** `tools/semgrep-custom/webhook-signature.yaml`. Violation blocks the SAST CI gate.

This addresses the "attacker forges a 'payment complete' webhook" threat directly; without HMAC verification, the side effect runs on attacker-controlled input.

## 9. The "no privileged containers, internal-only Postgres/Redis" rule

In any `docker-compose.yml` (primarily `antiphazeprod/infrastructure/docker/docker-compose.yml`):
- **No service may set `privileged: true`.**
- **Every service must declare `cap_drop: [ALL]`** and explicitly opt back in via `cap_add` for what it actually needs.
- **No service may publish host ports except `caddy`.** Postgres, Redis, Pretix, etc. communicate over the internal docker network only.

**Enforced by** `policy/containers.rego` via Conftest in the `policy` CI job. Violation blocks merge.

## 10. The "all third-party GitHub Actions must be SHA-pinned" rule

In any `.github/workflows/*.yml`:
- A `uses:` value referring to a third-party owner (i.e. not `actions/*` or `github/*`) must be pinned to a 40-character commit SHA, **not** a tag or branch.
- The required pattern is `owner/repo@<40-hex-sha> # vN` so the human-readable version is preserved alongside the cryptographic identity.
- First-party (GitHub-owned) actions may use major-version tags.

**Enforced by** `policy/github-actions.rego` via Conftest. Violation blocks merge.

Additional rules in the same policy file:
- Every job must declare an explicit `permissions` block (top-level or job-level). Implicit defaults are forbidden.
- No user-controllable PR fields (`pull_request.title`, `head_ref`, etc.) may be interpolated into `run:` shell. Pass via `env:` instead.

## 11. Incident response

If any of the following happens, treat as a security incident and follow `docs/runbooks/incident-response-template.md`:
- A scanner-blocked finding ships to production via merge override.
- An allowlist past expiry is detected.
- A canary-token hit.
- A failed `cosign verify-blob` on a release artifact.
- Suspected compromise of any credential listed in §6.

The IR template covers: identify, contain, eradicate, recover, and post-mortem. Rotation runbooks are linked from the template.

## 12. Living document

This policy is reviewed at minimum quarterly, and whenever a new asset (new payment provider, new admin panel, new third-party script) is added. Changes to this document must come with a corresponding change to the enforcement layer (Semgrep rule, Conftest policy, or branch-protection setting) — a policy with no enforcement is just a wish.
