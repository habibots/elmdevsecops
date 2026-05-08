# Runbook: Secrets Management

This runbook is the operator's reference for **where every secret lives** and **how to handle one** in day-to-day work. For rotation cadence and procedures, see `secrets-rotation.md`.

## Per-environment integration

| Surface | Tool | Mechanism | Audit |
|---|---|---|---|
| **Local dev** | `.env.local` (gitignored) | Populated from password manager; never committed | `.gitignore` + lefthook gitleaks pre-commit |
| **CI** | GitHub Encrypted Secrets + GitHub Environments | Secrets scoped to the `production` environment with required reviewers; OIDC where possible (AWS); short-lived scoped tokens elsewhere | GitHub UI shows last-used timestamp; required-reviewer log |
| **CF Workers runtime** | `wrangler secret put` | Encrypted at edge; injected as environment variables into the Worker; not visible in `wrangler tail` logs | Cloudflare audit log |
| **DO droplet runtime** | SOPS + age | `infrastructure/docker/prod.env.enc` is committed; the age key lives at `/etc/age/keys.txt` on the droplet (mode 0400); SOPS decrypts at compose-up time | Droplet filesystem audit; SOPS commit history shows who changed what |
| **CF Pages runtime** | Pages dashboard env vars | Encrypted at rest; per-environment (preview / production) | Cloudflare audit log |

## Per-secret inventory

| Secret | Where it lives | Rotation cadence | Notes |
|---|---|---|---|
| `SQUARE_ACCESS_TOKEN` (prod) | Wrangler secret + droplet SOPS | Quarterly | Wrapper-module-only access, Semgrep-enforced |
| `SQUARE_ACCESS_TOKEN` (sandbox) | Wrangler secret (`--env staging`) | On request | Lower blast radius; do not mix with prod |
| `SQUARE_WEBHOOK_SIGNATURE_KEY` | Wrangler secret | Quarterly | HMAC-verified on every webhook, Semgrep-enforced |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASSWORD` | Droplet SOPS (`prod.env.enc`) | Quarterly (password) | SMTP2GO; antiphaze contact form |
| `CLOUDFLARE_API_TOKEN` (deploy) | GitHub Encrypted Secret per repo | Quarterly | Scoped: Workers Edit + Pages Edit + Account Read |
| `WRANGLER_API_TOKEN` | GitHub Encrypted Secret (sacred-portal) | Quarterly | Scoped to Workers only |
| `DO_API_TOKEN` | GitHub Encrypted Secret (antiphazeprod) | Quarterly | Scoped to App Platform read+write |
| `DROPLET_SSH_KEY` (private, deploy) | GitHub Encrypted Secret + operator laptop | Annual | Used by the `update-pretix.yml` workflow |
| `age` key | Droplet `/etc/age/keys.txt` + offline operator backup | Annual | **Critical** — decrypts every droplet secret |
| `WEB3FORMS_ACCESS_KEY` | Public in repo (intentional) | On suspected abuse | Server-side validation by Web3Forms |
| GitHub PAT (operator, for `gh` CLI) | macOS Keychain via `gh auth` | Annual or on rotation reminder | Scoped: `repo`, `workflow` |
| Pretix admin WebAuthn | In Pretix DB on droplet | On personnel change | No password ever; WebAuthn only |
| GitHub Encrypted Secrets per environment | GitHub Environments (`production` w/ required reviewer) | N/A | The store itself; rotation = rotate the underlying secret |

## Workflow rules

### Adding a new secret

1. Decide on the surface (local / CI / Workers / droplet / Pages) and the rotation cadence. Document both before adding the secret.
2. Add to the table above in the same PR that introduces the code that reads the secret.
3. Add a corresponding entry to `.env.example` (for local) with placeholder + a one-line comment explaining what the value is.
4. Use the tool appropriate for the surface. **Never** paste a secret into chat, email, ticket, or repo file.
5. Add a Semgrep rule if access should be restricted to a specific module (see `SQUARE_ACCESS_TOKEN` precedent in `tools/semgrep-custom/square-token-wrapper.yaml`).

### Reading a secret in code

- **Local + CI**: `process.env.MY_SECRET` (Node) or `import.meta.env.MY_SECRET` (Astro/Vite, server-only).
- **CF Workers**: `env.MY_SECRET` from the Worker's bound environment (typed via `wrangler.toml`).
- **Droplet**: read from the env injected by docker-compose; SOPS decrypts on compose-up.

Never log the secret. Never include it in error messages. Never embed it in client-side code (Astro/Next, anything `import.meta.env` without `server-only` discipline).

### Detecting a leak

- **Pre-commit**: lefthook runs gitleaks on staged diff. Fast feedback (<5s).
- **Server-side push**: GitHub Push Protection on the org rejects pushes containing recognised patterns.
- **CI**: gitleaks job runs against full history on every PR.
- **Nightly**: scheduled drift scan via `_drift-nightly.yml` re-runs all scanners against `main`.
- **Active deception**: a canary token deliberately committed to the repo; any inbound hit on its endpoint is treated as confirmed compromise — see `incident-response-template.md`.

### Responding to a suspected leak

1. **Treat as compromised** unless proven otherwise.
2. Rotate immediately per `secrets-rotation.md`.
3. Identify exposure window: search Git history (`git log --all -S '<token-prefix>'`); check provider audit logs for unexpected use.
4. Document in incident log (`docs/runbooks/incident-response-template.md`).

## Rotation log

This is where every rotation is recorded. Append-only. Each entry: date — secret — operator — reason — validation outcome.

```
YYYY-MM-DD  SECRET_NAME  operator  routine|incident  pass|fail  notes
```

(Initial state — no rotations recorded yet; populated during operator follow-up.)
