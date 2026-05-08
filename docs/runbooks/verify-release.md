# Runbook: Verifying a Release Artifact

How to confirm that a `release.tar.gz` published by one of the three site repos was built from the expected commit by the expected workflow, before deploying it.

## 1. Why verify?

Supply-chain integrity. Cosign keyless signing publishes the signature to the [Sigstore Rekor](https://docs.sigstore.dev/logging/overview/) transparency log — an append-only, externally auditable, tamper-evident log. SLSA build-provenance attestations bind the artifact's hash to the workflow run, the commit SHA, and the runner identity.

Together they answer: **"Was this binary built from this commit by this workflow on the GitHub-hosted runner I trust?"** with cryptographic proof, not just a vendor claim. Without this step, a malicious release uploader could swap in a backdoored tarball and you'd have no way to detect it before deploy.

This is the same primitive Kubernetes, Sigstore itself, the Distroless base images, and an increasing number of npm packages use.

## 2. Prerequisites

```bash
brew install cosign           # the keyless verifier
brew install gh               # GitHub CLI (for SLSA attestation lookup)
brew install rekor-cli        # optional — for transparency-log inspection
gh auth login                 # one-time; needs `repo` scope to read attestations
```

Verify versions:
```bash
cosign version    # >= 2.4
gh --version      # >= 2.50
```

## 3. Verify a release

The release page exposes three artifacts per tag:
- `release.tar.gz` — the build output
- `sbom.cdx.json` — CycloneDX SBOM listing all dependencies and versions
- `release.cosign.bundle` — the cosign signature bundle (cert + signature + Rekor proof, all in one file)

Download all three. Then:

```bash
# 1. Verify the cosign signature against the Sigstore transparency log.
#    The --certificate-identity-regexp pin says: the signing certificate's SAN
#    must match a workflow in this repo, on a tag (no branch builds).
cosign verify-blob \
  --bundle release.cosign.bundle \
  --certificate-identity-regexp "https://github.com/<owner>/<repo>/.github/workflows/.+@refs/tags/v.+" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  release.tar.gz

# Expected output: "Verified OK"

# 2. Verify SLSA build provenance — cryptographic proof of the workflow run
#    that produced this exact byte-for-byte artifact.
gh attestation verify --owner <owner> release.tar.gz

# Expected output: "Loaded N attestations from GitHub API" then per-attestation
#                  "Successfully verified all N attestations"

# 3. Inspect the SBOM — what's actually in the tarball.
jq '.metadata.component.name, (.components | length)' sbom.cdx.json

# Expected: name of the package, then the count of dependency components.

# 4. (Optional) Cross-reference the Rekor transparency-log entry directly.
#    Useful for forensics — proves the signature existed at log time T.
rekor-cli search --artifact release.tar.gz
```

Replace `<owner>/<repo>` with the actual GitHub coordinates (e.g. `your-org/sacred-portal-wellness`).

## 4. What to do if verification fails

**Do NOT deploy.** Treat as supply-chain compromise:

1. Stop the deploy. If a deploy is in flight, roll back to the previous known-good release.
2. Open an incident using `docs/runbooks/incident-response-template.md`.
3. Quarantine the suspect artifact — keep a copy for forensics; do not delete.
4. Notify: repo owner, on-call, security contact (per IR template).
5. Audit recent workflow runs in the relevant repo's Actions tab — look for unauthorized commits, modified workflow YAMLs, or unusual runner identities.
6. Rotate any secrets reachable from the workflow runner (per `docs/runbooks/secrets-rotation.md`).
7. File a CVE/incident note before re-releasing.

A failed verification is **always** a high-severity incident, even if it turns out to be a config error — assume compromise until proven otherwise.

## 5. Limitations and caveats

- **Sigstore public-good infra has SLAs but no contractual guarantee.** The free public Rekor / Fulcio instances are operated by the Linux Foundation as a public good. Status: <https://status.sigstore.dev>. For regulated environments where a vendor SLA matters, document this and plan migration to a self-hosted Sigstore stack or a paid alternative (e.g. Chainguard, Tigera, an internal CA).
- **Keyless certs are short-lived (10 minutes).** That's expected — Rekor anchors the signature at a moment in time, so the cert doesn't need to outlive the build. Don't be alarmed when `cosign verify-blob` shows an expired cert; the Rekor proof is what carries the trust.
- **Verification needs network access** to <https://rekor.sigstore.dev> and the GitHub API. Air-gapped environments need a Sigstore mirror.
- **The signature only covers the artifact's bytes.** It does not cover SBOM accuracy, license compliance, or the absence of vulnerabilities — those are separate scanners (we run them in CI: gitleaks, Semgrep, OSV-Scanner, Trivy, Checkov).
- **Tag immutability is a separate concern.** GitHub tags are mutable by default. Branch protection on `main` plus signed tags (with the upstream maintainer's GPG/Sigstore key) is the way to bind a tag to a commit; the cosign signature alone does not prevent tag-rewrite.

## 6. References

- Sigstore docs: <https://docs.sigstore.dev>
- SLSA framework: <https://slsa.dev>
- GitHub attestations: <https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds>
- Internal: `docs/security-policy.md` (signing requirements), `docs/runbooks/incident-response-template.md`
