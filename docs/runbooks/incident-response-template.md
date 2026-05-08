# Security Incident Report — <repo> — <YYYY-MM-DD>

## Summary
One sentence: what leaked, where, how long.

## Timeline (UTC)
- YYYY-MM-DD HH:MM — Secret committed in <commit-sha>.
- YYYY-MM-DD HH:MM — Detected via <gitleaks / manual review / TruffleHog>.
- YYYY-MM-DD HH:MM — Rotation completed.
- YYYY-MM-DD HH:MM — History rewrite force-pushed.
- YYYY-MM-DD HH:MM — Collaborators notified.
- YYYY-MM-DD HH:MM — GitHub Support ticket opened to purge PR caches.

## Scope
- Secret type: <e.g. Square production access token>
- Exposure window: <push time> to <rotation time> = <N hours>
- Repo visibility during window: <public / private>
- Forks at time of detection: <N> (list URLs)

## Evidence of (non-)abuse
- <e.g. Square ListPayments reviewed for window — no anomalous transactions>
- <bank settlement reconciled against ledger>
- <webhook delivery logs reviewed>

## Remediation
- <Rotated <secret> via <dashboard path>>
- <Updated runtime via <wrangler secret put / SOPS / dashboard env vars>>
- <History rewritten with `git filter-repo --path <X> --invert-paths`>
- <Force-pushed; collaborators notified>

## Root cause
<e.g. `.env.local` not present in `.gitignore` at the time of initial commit>

## Preventive controls added
- gitleaks pre-commit hook (commit <sha>)
- TruffleHog scheduled scan workflow (commit <sha>)
- GitHub push protection enabled at org level
- SOPS+age (or equivalent) adopted as canonical secret store; `.env*` files removed
- AWS canarytoken planted in <path> to trip future scrapers

## Lessons learned
- <e.g. "Initial-commit hooks must be installed before first push, not after.">
