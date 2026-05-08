# Runbook: Quarterly Secrets Rotation

Rotate all long-lived production credentials at least quarterly. This runbook lists every credential by name, where it lives, how to rotate it, how to validate, and who to notify. Mark each row done in your password manager / ops journal as you go.

**Cadence:** Q1 / Q2 / Q3 / Q4 — schedule on the 1st of January, April, July, October. Out-of-cycle rotation is required immediately on any suspected compromise (see `incident-response-template.md`).

## Overview matrix

| # | Secret | Owning system | Stored in | Cadence | Re-deploy needed |
|---|---|---|---|---|---|
| 1 | `SQUARE_ACCESS_TOKEN` (prod) | Square | Wrangler secret + droplet SOPS | Q | Yes (Workers + droplet) |
| 2 | Square webhook signing key | Square | Wrangler secret | Q | Yes (Workers) |
| 3 | SMTP2GO password (sender) | SMTP2GO | Droplet SOPS | Q | Yes (droplet) |
| 4 | Cloudflare API token (deploy / Pages / Workers) | Cloudflare | GitHub Encrypted Secrets | Q | No (used by CI only) |
| 5 | Wrangler API token | Cloudflare | GitHub Encrypted Secrets | Q | No |
| 6 | DigitalOcean API token | DigitalOcean | GitHub Encrypted Secrets | Q | No |
| 7 | SSH deploy key (operator → droplet) | OpenSSH | Operator laptop + droplet `~/.ssh/authorized_keys` | Annual | No (manual ssh) |
| 8 | age key (SOPS encryption) | age | Droplet `/etc/age/keys.txt` + offline backup | Annual | Yes (droplet, after re-encrypt) |
| 9 | Web3Forms access key | Web3Forms | Repo (intentionally public) | On suspected abuse | Yes (GlobalManagement) |
| 10 | Pretix admin WebAuthn registration | Pretix | Pretix DB | On personnel change | No |

---

## 1. `SQUARE_ACCESS_TOKEN`

**When:** quarterly, or on any suspected leak.
**How:**
1. Log in to Square Developer Dashboard (<https://developer.squareup.com/apps>).
2. Open the production application → **Credentials** tab.
3. Click **Replace token**. Copy the new token. **Square shows it once.**
4. Update Wrangler secret:
   ```bash
   cd sacred-portal-wellness/app
   wrangler secret put SQUARE_ACCESS_TOKEN --env production
   # paste token, hit enter
   ```
5. Update droplet SOPS file (only if Pretix-Square integration used):
   ```bash
   ssh deploy@<droplet>
   cd /opt/antiphaze/infrastructure/docker
   sops prod.env.enc           # opens decrypted in $EDITOR; replace token; save
   docker compose up -d        # picks up new env on restart
   ```
6. Old token auto-expires in ~24h (Square grace period).

**Validation:** make a $0.01 sandbox order on staging; confirm the order ID appears in the Square dashboard.

**Notify:** operator only (single-operator project).

## 2. Square webhook signing key

**When:** quarterly, or on suspected webhook abuse (failed-HMAC spike).
**How:**
1. Square Developer Dashboard → **Webhooks** → **Subscriptions** → **Rotate signature key**.
2. Square shows old + new key for 24h overlap window.
3. Update Wrangler secret:
   ```bash
   wrangler secret put SQUARE_WEBHOOK_SIGNATURE_KEY --env production
   ```
4. Deploy. Verify webhooks still verify HMAC successfully.
5. After 24h, retire old key in the Square dashboard.

**Validation:** trigger a test webhook from Square's dashboard. Confirm the receiving log line shows `verified=true`.

## 3. SMTP2GO password

**When:** quarterly.
**How:**
1. SMTP2GO dashboard → **Sending** → **SMTP Users** → select sender → **Reset password**.
2. Update droplet SOPS file:
   ```bash
   ssh deploy@<droplet>
   cd /opt/antiphaze/infrastructure/docker
   sops prod.env.enc
   # update SMTP_PASSWORD
   docker compose up -d
   ```
3. Send a test email through the contact form on antiphazeprod.com.

**Validation:** check the operator inbox; confirm received within 60s.

## 4. Cloudflare API token (deploy / Pages / Workers)

**When:** quarterly.
**How:**
1. Cloudflare dashboard → **My Profile** → **API Tokens**.
2. Create a new token with the same scope as the old one (least privilege: usually `Workers Scripts:Edit`, `Pages:Edit`, `Account: Read`). Copy.
3. Update GitHub Encrypted Secret in each affected repo:
   ```bash
   gh secret set CLOUDFLARE_API_TOKEN --env production --body "<new-token>"
   ```
4. Trigger a CI run on a no-op branch; confirm deploy succeeds.
5. Revoke old token in Cloudflare dashboard.

**Validation:** the post-rotation deploy must succeed. If it fails, restore the old token from the password manager and investigate.

## 5. Wrangler API token

Same procedure as #4 but scoped to Workers and bound to sacred-portal-wellness.

## 6. DigitalOcean API token

**When:** quarterly.
**How:**
1. DigitalOcean dashboard → **API** → **Tokens/Keys** → **Generate New Token** with **App Platform read+write** scope.
2. `gh secret set DO_API_TOKEN --env production --body "<token>"` in `antiphazeprod`.
3. Trigger a CI run; confirm App Platform deploy succeeds.
4. Revoke the old token.

## 7. SSH deploy key (operator → droplet)

**When:** annual or on operator-laptop change.
**How:**
1. On operator laptop:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_antiphaze_new -C "operator@laptop $(date +%Y-%m-%d)"
   ```
2. Copy public key to the droplet:
   ```bash
   ssh deploy@<droplet> 'echo "<new-public-key>" >> ~/.ssh/authorized_keys'
   ```
3. Test the new key:
   ```bash
   ssh -i ~/.ssh/id_ed25519_antiphaze_new deploy@<droplet> 'echo OK'
   ```
4. **Only after success**, remove the old public key from `~/.ssh/authorized_keys` on the droplet, and delete the old private key from the laptop.
5. Update local `~/.ssh/config` to point the host alias at the new key file.

**Validation:** a successful `ssh` session with the new key, the old key removed from `authorized_keys`.

## 8. age key (SOPS encryption)

**When:** annual, or on suspected age-key compromise (treat as P0).
**How:**
1. Generate new key on a clean offline machine:
   ```bash
   age-keygen -o new-age.txt
   ```
2. Add the new public key to `.sops.yaml` recipients (keep the old one too, temporarily).
3. Re-encrypt every SOPS-managed file:
   ```bash
   sops updatekeys infrastructure/docker/prod.env.enc
   ```
4. Commit the re-encrypted file.
5. Copy `new-age.txt` to the droplet:
   ```bash
   scp new-age.txt deploy@<droplet>:/tmp/
   ssh deploy@<droplet> 'sudo mv /tmp/new-age.txt /etc/age/keys.txt && sudo chmod 0400 /etc/age/keys.txt && sudo chown root:root /etc/age/keys.txt'
   ```
6. Confirm decrypt works on droplet:
   ```bash
   ssh deploy@<droplet> 'cd /opt/antiphaze/infrastructure/docker && sops -d prod.env.enc | head -1'
   ```
7. Restart compose stack: `docker compose up -d`.
8. Remove old recipient from `.sops.yaml`, re-run `sops updatekeys`, commit.
9. Securely destroy the old age key file (operator laptop + offline backup).

**Validation:** every container starts with the expected env vars after restart. Old key cannot decrypt any file.

## 9. Web3Forms access key

**When:** the Web3Forms key is intentionally public (client-side). Rotate only on suspected abuse.
**How:** request a new key on the Web3Forms dashboard, swap in `GlobalManagement/src/components/ContactForm.astro`, redeploy.

## 10. Pretix admin WebAuthn registration

**When:** personnel change (rare for single-operator), lost device, or suspected device compromise.
**How:** as the Pretix admin, log in via the still-trusted device → **My Account** → **Security** → remove the lost device's registered credential and register the replacement.

---

## Post-rotation checklist

- [ ] All secrets updated in source-of-truth store
- [ ] Old credentials revoked at the issuing system
- [ ] Latest production deploy is green
- [ ] Smoke test (form submission, sandbox payment, etc.) passes
- [ ] `docs/runbooks/secrets-management.md` rotation log updated with date + person
- [ ] Calendar reminder set for next quarter
