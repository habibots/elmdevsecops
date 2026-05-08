# Contributing — Meta-repo

This is the meta-repo for the three site repos. Contribution rules at this level are about coordinating the cross-cutting tooling (workflows, policies, runbooks). For day-to-day work inside a specific site, see that site's own `CONTRIBUTING.md`.

## Branching

- All meta-repo work happens on **`devops`**.
- `devops` is the working branch. PRs to `main` are squash-merged.
- Each site repo (`GlobalManagement/`, `sacred-portal-wellness/`, `antiphazeprod/`) is an independent git repo, vendored as a subdirectory; site changes happen on that site's own branches per its own `CONTRIBUTING.md`.

## Commit message conventions

Conventional Commits with these accepted scopes:

- `feat(scope): ...` — new capability
- `fix(scope): ...` — bug fix
- `docs(scope): ...` — documentation
- `ci(scope): ...` — CI / GitHub Actions changes
- `chore(scope): ...` — repo housekeeping, deps
- `tools(scope): ...` — shared scripts under `tools/`
- `policy(scope): ...` — OPA / Conftest changes under `policy/`
- `runbook(scope): ...` — runbook changes under `docs/runbooks/`

Examples:
```
feat(ci): release job — cosign keyless sign + SBOM + SLSA provenance
docs(threats): cross-cutting + per-site threat models
policy(github-actions): require explicit permissions on every job
```

## Signed commits

Branch protection on `main` requires signed commits via `gitsign`. **Until `gitsign` is configured** (operator follow-up — see `docs/security-policy.md` §5), use:

```bash
git -c commit.gpgsign=false commit -m "<message>"
```

This is a temporary workaround. The follow-up to install `gitsign` (so commits are Sigstore-keyless-signed and tied to the operator's GitHub OIDC identity) is tracked as a pending operator action.

## Updating shared tooling

When you change anything in `workflows-templates/`, `policy/`, `tools/semgrep-custom/`, `lefthook.yml`, or `.gitleaks.toml`:

1. Make the change in the meta-repo source of truth.
2. Validate locally:
   - YAML: `python3 -c "import yaml; yaml.safe_load(open('<file>'))"`
   - actionlint (if present): `actionlint workflows-templates/*.yml`
   - Conftest: `docker run --rm -v "$(pwd):/workspace" -w /workspace openpolicyagent/conftest:v0.50.0 test workflows-templates/_security-base.yml -p policy/ --namespace github_actions`
3. **Copy the change into each of the 3 site repos' vendored copy** (the file under `<site>/.github/workflows/_security-base.yml`, `<site>/policy/`, etc.).
4. Commit per repo with the appropriate prefix:
   - Meta: `feat(ci): ...`
   - Site: `ci(security): vendor <change>`
5. Open a PR on the meta-repo from `devops` → `main`.
6. Open PRs on each affected site repo from their `devops` → `main`.

## Adding a new shared tool / rule

1. Build the tool in `tools/<area>/` first; add unit tests where applicable.
2. Wire it into `workflows-templates/_security-base.yml`.
3. Update `policy/` if it introduces a new invariant.
4. Document the rule in `docs/security-policy.md` (a rule with no enforcement is just a wish).
5. Update each site's `.security-reviews/README.md` reference if relevant.

## CI on the meta-repo

The meta-repo currently does not have its own GitHub Actions workflows; CI runs only against the site repos. If we add meta-repo CI (e.g. for the policy unit tests), follow the same pattern: SHA-pin third-party Actions, explicit `permissions` block, no implicit defaults.

## Pull requests

- Title: same convention as commit messages (`scope: subject`).
- Body: explain *why*, link to the threat model entry or design doc section it addresses.
- Don't merge your own meta-repo PR without at least re-reading the diff after a coffee break.
- For changes that touch security policy or threat model, run the site-repo CI on a representative branch to confirm the policy changes don't accidentally break enforcement.

## Pending operator follow-up

These cannot be done by an automation agent:

- Configure `gitsign` for signed commits on `main`.
- Set up branch protection rules per `docs/security-policy.md` §2 (GitHub UI).
- Configure GitHub Environments (`production`) with required reviewers.
- Schedule the quarterly rotation reminder per `docs/runbooks/secrets-rotation.md`.
