# Cloudflare Bootstrap Runbook

End-to-end click-by-click guide for placing all three Echoes Lab properties
(`globalmanagement.com`, `sacredportalwellness.com`, `antiphazeprod.com`)
behind Cloudflare's free tier. No paid features are required for the steady
state described here.

> Audience: the operator with admin access to the Cloudflare account and the
> three domain registrars. Time budget: ~90 minutes of click-work + 1-4 hours
> of DNS propagation per zone.

---

## 1. Overview

What this runbook achieves, end state — all on the **Free** plan ($0/mo):

- Cloudflare proxy in front of each apex + `www` (orange-cloud) → DDoS,
  geo-anycast caching, hide origin IPs.
- Universal SSL edge certificates (auto-renewing).
- Web Application Firewall (WAF) Managed Rules + OWASP Core Ruleset (free
  tier provides 5 firewall rules + the managed rulesets).
- Bot Fight Mode (free, basic bot scoring).
- Cloudflare Pages hosting `GlobalManagement` (Astro static).
- Cloudflare Access ("Zero Trust" Free, up to 50 users) protecting Pretix
  `/control` admin on `antiphazeprod.com`.
- Cloudflare Turnstile widgets on every site form (free).
- Cloudflare Origin CA cert pinned on the Anti Phaze droplet so origin TLS
  is validated by edge (Full strict mode).

What this runbook intentionally does **not** do (out of scope, deferred or
free-tier limitation):

- No Logpush (Enterprise-only). Platform-native logs are accepted.
- No Argo Smart Routing or APO ($5/mo each). Not needed.
- No Advanced Certificate Manager. Not needed at apex+www depth.

---

## 2. Prerequisites

Before clicking anything:

1. **Cloudflare account credentials** — fresh email address dedicated to
   ops (`ops@…`) is recommended; not a personal email.
2. **TOTP authenticator app ready** (1Password, Authy, etc.) — 2FA is
   enabled in Step 1 and recovery codes saved in the password manager.
3. **Registrar dashboard access** for all three domains. Confirm you can
   reach the NS-records page on each. Common registrars: Namecheap,
   Cloudflare Registrar (if already there, skip the NS update), GoDaddy,
   Porkbun, Squarespace Domains, Google Domains (now Squarespace).
4. **Existing DNS export per domain** — before cutover, take screenshots
   *and* `dig`/`drill` exports of all current records (A, AAAA, CNAME, MX,
   TXT, SRV, CAA). Cloudflare's auto-import is good but not perfect; weird
   one-off TXT records (verification proofs) sometimes get missed. Save
   each export as `~/Documents/dns-backup/<domain>.txt`.
5. **Maintenance window** — schedule DNS cutover in low-traffic hours.
   Worst-case window for partial unavailability is ~5 min while old NS
   records flush from upstream resolvers; full propagation can take 1-4 h
   on first cutover.
6. **Password manager** open and ready to capture the Cloudflare API
   token, Origin CA private key, Turnstile site/secret keys, and Access
   one-time-PIN policy emails as you generate them.

---

## 3. Step 1 — Create Cloudflare account

1. Browse to <https://dash.cloudflare.com/sign-up>.
2. Enter the ops email + a 24+ char generated password from the password
   manager. Confirm via the verification email.
3. After first login, you'll land on the *empty* dashboard. Skip any
   "Add a website" prompt for now — we want 2FA on first.
4. Top-right user menu → **My Profile** → **Authentication** tab.
5. Under **Two-Factor Authentication**, click **Set up** next to
   "Authenticator app". Scan the QR code into the TOTP app. Enter the
   6-digit code to confirm.
6. **Immediately** click **Generate** under Recovery Codes; copy all 10
   codes into the password manager as a separate secure note. These are
   single-use; treat them like root keys.
7. Optional but recommended: enable a hardware key (WebAuthn) under the
   same screen if a YubiKey is available.

Decision point: if SSO is required for compliance, this is also the
moment to enable Cloudflare's SSO option (paid, Teams plan); for the
$0/mo target stick with TOTP + WebAuthn.

---

## 4. Step 2 — Add zones

Repeat this section three times — once per apex domain.

1. Top nav → **Websites** → **+ Add a site**.
2. Type the **apex** domain (e.g. `antiphazeprod.com`, no `www`, no
   protocol). Click **Continue**.
3. Plan picker — scroll **all the way down**, click **Free** ("$0/month
   when paid annually"), **Continue**.
4. Cloudflare scans the zone at the current authoritative NS and presents
   a table of imported records. Sit with this screen:
   - Verify every existing A, AAAA, CNAME, MX, TXT is present.
   - Cross-check against the `dns-backup/<domain>.txt` export from
     Prerequisites step 4.
   - Add any missing records by hand (`+ Add record` button).
5. For each apex (`@`) A record and the `www` CNAME, ensure the **Proxy
   status** column shows the orange cloud (Proxied). Leave `MX`,
   verification `TXT`, mail-related `_dmarc`, `_domainkey`, etc. as
   **DNS only** (grey cloud). We do not proxy email.
6. Click **Continue**. Cloudflare assigns the zone two nameservers on
   the next screen — copy both into the password manager keyed by domain
   (e.g. `cf-ns:antiphazeprod.com → arwen.ns.cloudflare.com,
   bert.ns.cloudflare.com`).

> Rollback note: until you change registrar NS records, the zone is
> "pending" at Cloudflare and the live DNS is unchanged. Bailing out here
> costs nothing.

---

## 5. Step 3 — Update registrar nameservers

Once per domain, in **the registrar's** control panel (not Cloudflare):

1. Find the **Nameservers** / **NS records** screen for the domain.
2. Switch from "default / registrar-provided" to "custom nameservers".
3. Paste the two Cloudflare-assigned nameservers from Step 2.6.
4. **Save**. Some registrars lock this behind a 60-second confirmation
   email; complete that flow.
5. Back in Cloudflare's **Websites** → click the (still-pending) zone →
   **Check nameservers**. Status flips from "Pending Nameserver Update"
   to "Active" once propagation completes — usually 5-30 minutes for
   modern registrars but can take up to 4 hours.

Verification from a terminal:

```bash
dig +short NS antiphazeprod.com
# expect: arwen.ns.cloudflare.com.
#         bert.ns.cloudflare.com.
```

If after 4 hours the zone is still pending: re-check the registrar
saved successfully (some registrars require a separate "publish" or
"apply" button beyond Save).

---

## 6. Step 4 — Per-zone settings

Repeat for each of the three zones once status is **Active**. Settings
appear in the left rail of the zone overview page.

### 6.1 DNS

1. Left rail → **DNS** → **Records**.
2. Confirm apex A and `www` CNAME are orange-cloud (Proxied).
3. Add CAA records to lock issuance to Cloudflare + Cloudflare Origin
   CA + Let's Encrypt (defense-in-depth; prevents rogue CAs):
   ```
   @  CAA  0 issue "letsencrypt.org"
   @  CAA  0 issue "pki.goog"
   @  CAA  0 issue "comodoca.com"
   @  CAA  0 issue "digicert.com"
   @  CAA  0 issuewild ";"
   @  CAA  0 iodef "mailto:ops@<domain>"
   ```
   (Cloudflare Universal SSL uses multiple CAs, hence the four `issue`
   lines.)

### 6.2 SSL/TLS

1. Left rail → **SSL/TLS** → **Overview**.
2. Encryption mode: **Full (strict)**.
   - **Do NOT** pick *Flexible* — it terminates TLS at the edge and talks
     plaintext HTTP to the origin, which defeats the purpose.
   - **Do NOT** pick *Full* (without strict) — it accepts self-signed
     origin certs, allowing on-path swap.
   - For `antiphazeprod.com` we install an Origin CA cert in Step 5 so
     that *strict* validation succeeds.
   - For `globalmanagement.com` and `sacredportalwellness.com`, the
     origins are Cloudflare Pages and Workers respectively — both
     auto-trusted by Cloudflare's edge, no Origin CA needed.

### 6.3 SSL/TLS → Edge Certificates

1. Left rail → **SSL/TLS** → **Edge Certificates**.
2. **Always Use HTTPS**: ON.
3. **Minimum TLS Version**: 1.2.
4. **Opportunistic Encryption**: ON.
5. **TLS 1.3**: ON (default).
6. **Automatic HTTPS Rewrites**: ON.
7. **Certificate Transparency Monitoring**: ON.
8. **HSTS**: **OFF** at the Cloudflare edge.
   - Rationale: HSTS is delivered by application-layer headers from the
     site code (`_headers` for Pages, `next.config.ts` for sacred-portal,
     Caddyfile for antiphaze). Single source of truth — if we toggle here
     too, divergent values risk locking browsers onto stale settings.

### 6.4 Security → Bots

1. Left rail → **Security** → **Bots**.
2. **Bot Fight Mode**: ON.
3. Leave Super Bot Fight Mode OFF (Pro plan).

### 6.5 Security → WAF

1. Left rail → **Security** → **WAF** → **Managed rules** tab.
2. **Cloudflare Managed Ruleset**: enable. Action default = "Managed
   challenge". Sensitivity = Medium.
3. **Cloudflare OWASP Core Ruleset**: enable. Sensitivity = **Medium**
   for the first 14 days (collect false-positive baseline). After two
   weeks of clean logs, raise to **High**.
4. Leave Custom Rules empty for now (free tier allows 5; we'll add them
   in Phase 5+ if WAF logs show specific abuse).
5. **Rate limiting rules**: free tier provides 1 rule. Skip for now —
   we'll add a `/login` and `/control` rate limit in a later phase once
   we have actual traffic shapes.

### 6.6 Network

1. Left rail → **Network**.
2. **HTTP/2**: ON.
3. **HTTP/3 (with QUIC)**: ON.
4. **0-RTT Connection Resumption**: **OFF** (replay-attack risk on
   non-idempotent endpoints — Square checkout, Pretix admin, contact
   form posts).
5. **IPv6 Compatibility**: ON.
6. **WebSockets**: ON (sacred-portal & Pretix benefit).
7. **Pseudo IPv4**: Off.
8. **gRPC**: Off (not needed).

### 6.7 Speed → Optimization

1. Left rail → **Speed** → **Optimization**.
2. Leave defaults — Auto Minify is being deprecated; build pipelines
   already minify. Brotli is on by default at the edge.

---

## 7. Step 5 — Origin CA certificate for the antiphaze droplet

Only `antiphazeprod.com` needs this — Pages and Workers handle their
own origin certs.

1. Zone `antiphazeprod.com` → **SSL/TLS** → **Origin Server** →
   **Create Certificate**.
2. Generation method: **Let Cloudflare generate a private key and CSR**.
3. Key type: **ECDSA**, curve **P-256** (smaller, faster handshakes than
   RSA-2048; both fully compatible).
4. Hostnames: `antiphazeprod.com, *.antiphazeprod.com`.
5. Validity: **15 years** (Cloudflare's max for Origin CA certs; they
   are only trusted by Cloudflare's edge so long-lived is acceptable).
6. **Create**. The next screen shows the certificate PEM and the private
   key PEM **once** — copy both into the password manager as separate
   secure notes immediately. Closing the screen without copying the key
   means you have to revoke + reissue.

Install on the droplet:

```bash
# From the operator's workstation — replace droplet IP/user as needed
scp origin.crt root@droplet:/etc/caddy/origin.crt
scp origin.key root@droplet:/etc/caddy/origin.key

ssh root@droplet
chown root:root /etc/caddy/origin.{crt,key}
chmod 0644 /etc/caddy/origin.crt
chmod 0600 /etc/caddy/origin.key
ls -l /etc/caddy/origin.*   # verify perms
```

The Caddyfile updates that consume these files are committed in
Phase 3 Task D (xcaddy + Caddyfile updates). Once the new Caddy image
is rebuilt and `docker compose up -d caddy` is run, edge-to-origin TLS
will validate against the Origin CA root.

> Rotation note: bookmark the certificate ID shown in the Origin Server
> table; in 14 years 11 months you'll be glad you did.

---

## 8. Step 6 — Cloudflare Pages for GlobalManagement

1. Top nav (account-level, not zone-level) → **Workers & Pages** →
   **Create** → **Pages** tab → **Connect to Git**.
2. Authorize the Cloudflare GitHub app against the `habibots`
   organization (or whichever org owns the repo). Limit the app's repo
   access to the three site repos only.
3. Pick `habibots/GlobalManagement`. Click **Begin setup**.
4. Configuration screen:
   - **Project name**: `globalmanagement`.
   - **Production branch**: `main`.
   - **Framework preset**: **Astro**.
   - **Build command**: `npm run build`.
   - **Build output directory**: `dist`.
   - **Root directory (advanced)**: leave blank (repo root).
   - **Environment variables (Production)** — **Add variable**:
     - `PUBLIC_WEB3FORMS_ACCESS_KEY` = (rotated value from password
       manager; the original was committed in early history and is
       being rotated as part of Phase 0).
     - `PUBLIC_TURNSTILE_SITE_KEY` = (the GlobalManagement Turnstile
       site key from Step 7 below — circular, so come back here after
       Step 7 if you're doing this in order).
     - `NODE_VERSION` = `22` (forces the Pages build container onto
       the same Node major as local dev).
5. **Save and Deploy**. First deploy takes 2-4 minutes. If it fails on
   missing env vars, re-check that they're set under **Production**
   (Preview is separate).

After first successful deploy:

6. Project page → **Custom domains** tab → **Set up a custom domain**:
   - Add `globalmanagement.com`. Cloudflare auto-creates the CNAME at
     the apex via CNAME flattening (because the zone is in the same
     account).
   - Add `www.globalmanagement.com`. Same flow.
   - Both should show **Active** within a couple of minutes.
7. Project page → **Settings** → **Builds & deployments** →
   **Preview deployments** → set **Branch deployments** to **All
   non-production branches**. This makes `devops` (and any other
   feature branches) produce preview URLs of the form
   `<commit-sha>.globalmanagement.pages.dev`.
8. Project page → **Settings** → **Functions** — leave empty (we have
   no Pages Functions; the site is fully static).

> Rollback note: Pages keeps every deploy. If a bad deploy reaches prod,
> open the deploy in the project history and click **Rollback** — DNS
> swaps back in seconds.

---

## 9. Step 7 — Turnstile widget keys

One widget per site = three widgets total.

1. Top nav (account-level) → **Turnstile** → **Add Site**.
2. Site name: e.g. `globalmanagement-prod`.
3. Hostnames: list every hostname the widget is allowed to render on,
   one per line. For each site:
   - GlobalManagement: `globalmanagement.com`, `www.globalmanagement.com`,
     plus the Pages preview hostname pattern
     `*.globalmanagement.pages.dev` to make widgets work on previews.
   - Sacred Portal: `sacredportalwellness.com`,
     `www.sacredportalwellness.com`, `*.workers.dev` for preview.
   - Anti Phaze: `antiphazeprod.com`, `www.antiphazeprod.com`,
     `tickets.antiphazeprod.com` (Pretix uses Turnstile for the Pretix
     contact form if enabled — harmless to allowlist).
4. Widget Mode: **Managed** (Cloudflare auto-decides between invisible
   pass, checkbox, or interactive challenge based on risk score).
5. Pre-clearance: **Off** for now. Re-evaluate after 30 days of clean
   challenge logs.
6. **Save**. The next screen shows the **Site Key** (public, prefix
   `0x4`) and **Secret Key** (server-side only).
7. File these immediately:
   - Site Key → goes into the per-site env-var stores as
     `PUBLIC_TURNSTILE_SITE_KEY` (Pages env vars, Worker bindings,
     droplet `.env`).
   - Secret Key → goes into the per-site secret stores:
     - GlobalManagement: **not used** — Web3Forms verifies Turnstile on
       its side using its own backend integration; site only needs the
       site key in the form payload.
     - Sacred Portal: `wrangler secret put TURNSTILE_SECRET_KEY` against
       the Worker.
     - Anti Phaze: `/etc/antiphaze/.env` on the droplet, key
       `TURNSTILE_SECRET_KEY`.

> Repeat steps 1-7 three times (one site per Turnstile widget).

---

## 10. Step 8 — Cloudflare Access (Zero Trust) for Pretix `/control`

Goal: any request to `tickets.antiphazeprod.com/control*` requires email
verification + WebAuthn before reaching Pretix. Free Zero Trust plan
allows up to 50 users.

1. Browse to <https://one.dash.cloudflare.com>. First visit prompts you
   to pick a **team domain** (subdomain of `cloudflareaccess.com`, e.g.
   `echoeslab.cloudflareaccess.com`). This is permanent-ish — pick
   something durable. **Confirm**.
2. Plan: **Free** (up to 50 users). **Subscribe**.
3. Left rail → **Access** → **Applications** → **Add an application** →
   **Self-hosted**.
4. Application configuration:
   - **Application name**: `Pretix Admin`.
   - **Session Duration**: 8 hours.
   - **Application domain**:
     - Subdomain: `tickets`
     - Domain: `antiphazeprod.com`
     - Path: `control` (matches `/control` and below; Cloudflare's
       Access path matcher is prefix-based with implicit wildcard).
   - **Identity providers**: enable **One-time PIN** (the default,
     emails the user a 6-digit code; no IdP setup needed for the free
     tier). Leave Google/GitHub off unless someone wants SSO later.
   - **Application Appearance**: optional logo + name shown on the
     login page.
   - **Cookie settings**: HTTP Only ON, Same Site = Lax, Secure ON.
5. Click **Next**.
6. Policies — **Add a policy**:
   - **Policy name**: `antiphaze-admins`.
   - **Action**: **Allow**.
   - **Session duration**: Same as application (8 h).
   - **Configure rules** → Include → Selector = **Emails** → list each
     authorized admin email address explicitly (do not use "Emails
     ending in @<domain>" unless the org has its own email domain — for
     Anti Phaze, list each personal email used by an authorized
     operator).
   - **Require** rules → add Selector = **Authentication method** =
     **WebAuthn** ⇒ this forces the user to register and use a hardware
     key or platform authenticator on top of the email PIN. (For users
     without WebAuthn devices yet, defer enabling this until they
     enroll; otherwise they get locked out.)
7. **Next** → **Add application**.
8. Verify in an incognito window: <https://tickets.antiphazeprod.com/control/>
   should now show the Cloudflare Access login screen, not Pretix's. Enter
   an authorized email → check inbox → enter PIN → WebAuthn prompt →
   land on Pretix's own login.

> Rollback note: a misconfigured Access app can lock out the operator.
> Keep a second browser session open on the Cloudflare dashboard while
> you set this up so you can disable the application if you misconfigure
> the policy. The app's **Disable** toggle is at the top of the app's
> overview screen.

---

## 11. Step 9 — Verification commands

Run for each domain after cutover.

```bash
# Authoritative NS — should be the two Cloudflare nameservers from Step 2.
dig +short NS globalmanagement.com
dig +short NS sacredportalwellness.com
dig +short NS antiphazeprod.com

# Edge proxy — expect HTTP/2 or HTTP/3, CF-RAY header, server: cloudflare.
curl -sI https://globalmanagement.com    | grep -iE 'cf-ray|server|http/'
curl -sI https://sacredportalwellness.com | grep -iE 'cf-ray|server|http/'
curl -sI https://antiphazeprod.com       | grep -iE 'cf-ray|server|http/'

# HTTP→HTTPS redirect — expect 301 with location: https://...
curl -sI http://antiphazeprod.com | head -n 5

# CF metadata — expect fl=, h=, ip=, ts=, visit_scheme=https, ...
curl -s  https://antiphazeprod.com/cdn-cgi/trace

# Edge cert chain — expect issuer = Cloudflare Inc / Google Trust / ...
echo | openssl s_client -servername antiphazeprod.com -connect antiphazeprod.com:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates

# Access — should return Cloudflare Access redirect, NOT Pretix HTML.
curl -sIL https://tickets.antiphazeprod.com/control/ | head -n 20
```

If any of those don't match expectations, see Step 10.

---

## 12. Step 10 — Rollback plan

The cutover is reversible at every stage. Failure modes and their
remedies:

1. **Site unreachable after NS swap** (most likely cause: missing or
   mistyped record during auto-import).
   - Fix forward: in the Cloudflare zone DNS table, add/correct the
     missing record. Propagation is ~1 minute (Cloudflare's edge cache
     is fast).
   - Hard rollback: in the registrar, paste the **original** NS values
     recorded in Prerequisites step 4. Wait 1-4 hours for upstream
     resolvers to flush.

2. **TLS errors after enabling Full (strict)** for `antiphazeprod.com`
   only.
   - Cause: Caddy on the droplet is still serving its public Let's
     Encrypt cert (works) or a self-signed cert (fails strict).
   - Fix forward: complete Step 5 (Origin CA cert install) and rebuild
     the Caddy container. While that's in flight, temporarily downgrade
     SSL/TLS mode to **Full** (without strict). Revert to **Full
     (strict)** as soon as the Origin CA cert is live.

3. **Cloudflare Access locks the operator out**.
   - In a second browser already logged into the Cloudflare dashboard
     (kept open per Step 8 rollback note): Zero Trust → Access →
     Applications → Pretix Admin → top-right **⋯** menu → **Delete**.
     Pretix `/control` is immediately reachable directly again.

4. **Pages deploy serves wrong content / breaks layout**.
   - Project history → click previous green deploy → **Rollback to this
     deployment**. DNS swaps in <30 s.

5. **WAF false-positives blocking real users**.
   - Security → Events to identify the rule ID firing. Then Security →
     WAF → Managed rules → expand the offending ruleset → toggle the
     specific rule to **Disable** (preserve everything else).

Always communicate cutovers in #ops before flipping NS records and again
when rollback is required.

---

## 13. Cost summary

Everything in this runbook is on the Free plan:

| Feature                                | Tier         | Cost   |
|----------------------------------------|--------------|--------|
| Zone (per domain × 3)                  | Free         | $0/mo  |
| Universal SSL (edge cert)              | Free         | $0/mo  |
| Origin CA cert (15 yr)                 | Free         | $0/mo  |
| Pages project + custom domain          | Free         | $0/mo  |
| Pages builds (500/mo limit)            | Free         | $0/mo  |
| WAF Managed Rules + OWASP Core         | Free         | $0/mo  |
| Bot Fight Mode (basic)                 | Free         | $0/mo  |
| Rate Limiting (1 rule, 10k req/mo)     | Free         | $0/mo  |
| Turnstile (3 widgets, 1M req/mo)       | Free         | $0/mo  |
| Zero Trust / Access (≤ 50 users)       | Free         | $0/mo  |
| **Total recurring**                    |              | **$0** |

Where paid tiers would kick in (we are not using these):

| Want                                   | Tier         | Cost   |
|----------------------------------------|--------------|--------|
| Logpush to S3/GCS                      | Enterprise   | $$$$$  |
| Super Bot Fight Mode                   | Pro          | $20/mo |
| Argo Smart Routing                     | Pro+ add-on  | $5/mo  |
| Advanced Cert Manager (deeper subdom.) | Add-on       | $10/mo |
| WAF Custom rules (>5)                  | Pro          | $20/mo |
| Rate limiting (>1 rule)                | Pro          | $20/mo |

---

## 14. Open follow-ups (intentionally deferred)

- **Logpush** is Enterprise-only. We accept platform-native log
  retention: Cloudflare's free dashboard stores 24 h of HTTP request
  logs (under Analytics → Logs preview) and Security Events for 7 days.
  When this ceases to be acceptable, evaluate an alternative log shipper
  (e.g., Vector reading from the origin) before paying for Enterprise.

- **Advanced Certificate Manager** ($10/mo) is only required when we
  introduce subdomains deeper than two labels (`*.app.antiphazeprod.com`,
  for example). Not currently planned.

- **WAF custom rules beyond 5** — defer until WAF Events show a specific
  abuse pattern that the managed rulesets miss.

- **Cloudflare Registrar** transfer — for any domain still at a paid
  registrar, a transfer to Cloudflare Registrar is at-cost (no markup)
  and removes one external account from the security perimeter. Worth
  doing at next renewal, not urgent.

- **Cloudflare Tunnel** — currently Pretix is exposed via a public
  droplet IP behind Caddy + Origin CA. If we ever want to remove the
  public ingress entirely, replace Caddy with a `cloudflared` tunnel
  and bind Pretix to localhost only. Free tier, but adds one more piece
  to operate.

---

*Last updated:* 2026-05-07 — Phase 2 of the website-hardening project.
