# elmdevsecops — Workspace

Meta-repo for the three production sites managed under the Echoes Lab umbrella, plus the shared DevOps tooling that hardens them.

## What's here

| Repo (subdir) | Stack | Hosting | Purpose |
|---|---|---|---|
| `GlobalManagement/` | Astro static SPA | Cloudflare Pages | Marketing site for Global Management |
| `sacred-portal-wellness/` | Next.js (App Router) + Square | Cloudflare Workers (OpenNext adapter) | Sacred Portal Wellness — content + Square checkout |
| `antiphazeprod/` | Astro SSR + Pretix (Docker Compose) | DigitalOcean App Platform (marketing) + DO droplet behind Caddy (Pretix tickets) | Anti Phaze Productions marketing + ticketing |

The three sites are independent git repos, vendored as subdirectories of this meta-workspace so cross-cutting hardening can be applied uniformly. Each site repo has its own `main` and `devops` branches and is deployable independently.

## Hardening goals

This workspace is in the middle of a multi-phase security hardening exercise. The aim is portfolio-grade DevSecOps coverage across the three sites at zero recurring cost (open-source scanners + free-tier infrastructure):

- Pre-commit gates (lefthook + gitleaks + actionlint) for fast feedback.
- A reusable GitHub Actions workflow with 7 parallel jobs (secrets / SAST / SCA / IaC / container / policy / build) gated by an aggregator job.
- Custom Semgrep rules and OPA Conftest policies for site-specific invariants (Square wrapper rule, webhook HMAC, container hardening, Action SHA-pinning).
- Cosign keyless signing + SBOM + SLSA build provenance on every tagged release.
- Local AI security review (`/security-review` slash command in Claude Code) before every push, audited via `.security-reviews/`.
- Threat models, security policy, and runbooks treating ops as a discipline, not folklore.

The full design lives in `docs/specs/2026-05-07-website-hardening-design.md`; the execution plan in `docs/plans/2026-05-07-website-hardening-plan.md`.

## Repo layout

```
elmdevsecops/
├── GlobalManagement/             # Astro static site (vendored sub-repo)
├── sacred-portal-wellness/       # Next.js + Square (vendored sub-repo)
├── antiphazeprod/                # Astro SSR + Pretix (vendored sub-repo)
├── workflows-templates/          # Source of truth for reusable GH Actions
│   ├── _security-base.yml        # 7 parallel jobs + gate + release
│   └── _drift-nightly.yml        # daily rescan against main
├── policy/                       # OPA Conftest policies
│   ├── containers.rego           # docker-compose hardening rules
│   ├── containers_test.rego
│   ├── github-actions.rego       # SHA-pin, permissions, injection rules
│   └── github-actions_test.rego
├── tools/
│   ├── semgrep-custom/           # custom SAST rules
│   ├── headers/                  # TLS/headers smoke-test scripts
│   └── (other shared tooling)
├── docs/
│   ├── specs/                    # design docs
│   ├── plans/                    # execution plans
│   ├── threats/                  # cross-cutting + per-site threat models
│   ├── security-policy.md        # what's enforced by tooling vs discipline
│   └── runbooks/                 # operational procedures
│       ├── cloudflare-bootstrap.md
│       ├── cloudflare-fallback.md
│       ├── incident-response-template.md
│       ├── secrets-management.md
│       ├── secrets-rotation.md
│       └── verify-release.md
├── lefthook.yml                  # shared pre-commit template
├── .gitleaks.toml                # shared gitleaks config
├── README.md                     # (this file)
└── CONTRIBUTING.md               # workflow rules at meta-level
```

The `_security-base.yml` and `_drift-nightly.yml` templates in `workflows-templates/` are vendored verbatim into each site repo's `.github/workflows/`. The same applies to `policy/`, `tools/semgrep-custom/`, `lefthook.yml`, and `.gitleaks.toml`. Updates flow meta → sites by re-copying.

## Quickstart

```bash
git clone https://github.com/<owner>/elmdevsecops.git
cd elmdevsecops

# Initialise lefthook in each site repo (one-time per clone)
for r in GlobalManagement sacred-portal-wellness antiphazeprod; do
  (cd "$r" && lefthook install)
done

# In Claude Code, before every push from any site repo:
/security-review
# then commit the generated .security-reviews/PR-*.md alongside your change
```

## Status

This workspace is in **active hardening**. Phases 0–8 (agent-doable subset) are complete:

- **Phase 0** — incident response templates, secret-scrub script, .gitignore audits ✅
- **Phase 1** — Node 22 LTS, DB lockdown, SMTP fallback removal ✅
- **Phase 2** — Cloudflare bootstrap runbook ✅
- **Phase 3** — Headers + TLS baseline + smoke-test scripts ✅
- **Phase 4** — SOPS scaffolding + .env.example templates ✅
- **Phase 5a** — Custom Semgrep rules + OPA Conftest policies (TDD) ✅
- **Phase 5b** — Reusable `_security-base.yml` workflow + per-site callers ✅
- **Phase 6** — Cosign keyless signing + SBOM + SLSA provenance + verification runbook ✅
- **Phase 7** — Local Claude Code `/security-review` slash command per repo ✅
- **Phase 8** — Documentation (threat models, security policy, runbooks, READMEs) ✅

### What works

- All CI scanners run on every PR, gated, < 5 minutes.
- Pre-commit hooks block secret leaks and broken Action workflows before they reach the server.
- Tagged releases produce a signed tarball, an SBOM, and a SLSA provenance attestation.
- Every site has a `/security-review` slash command and an audit trail under `.security-reviews/`.
- Threat models, security policy, and operational runbooks are committed and referenced from the slash command.

### What's pending (operator follow-up — not agent-doable)

These tasks need account-level access and cannot be automated:

- Branch-protection rules in the GitHub UI for each site repo (the rule set is documented in `docs/security-policy.md` §2).
- Cloudflare Access policies on the antiphaze `/control` admin (documented in `docs/runbooks/cloudflare-bootstrap.md`).
- `gitsign` setup for signed commits on `main` (commits currently use `--no-gpg-sign`).
- First quarterly secrets rotation (run `docs/runbooks/secrets-rotation.md`).
- Backfill the secret rotation log in `docs/runbooks/secrets-management.md`.
- DNS TTL adjustments per `docs/runbooks/cloudflare-fallback.md` "Step 5".

## Reference docs

- Design: `docs/specs/2026-05-07-website-hardening-design.md`
- Plan: `docs/plans/2026-05-07-website-hardening-plan.md`
- Threat model: `docs/threats/threat-model.md` (cross-cutting) + per-site addenda
- Security policy: `docs/security-policy.md`
- Runbooks: `docs/runbooks/`
