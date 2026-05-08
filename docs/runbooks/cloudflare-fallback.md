# Runbook: Cloudflare Fallback During a Global Outage

Cloudflare provides DNS, CDN, WAF, Turnstile, Workers, Pages, and Access for all three sites. We accept the dependency in exchange for free-tier coverage. **When Cloudflare has a global outage, parts of all three sites degrade.** This runbook documents what to do.

Recent precedent: **Nov 2025**, **Jun 2025**, **Mar 2025**. Expect roughly one notable global incident per quarter; most are < 60 minutes; some have been multi-hour.

## Step 1 — Confirm the outage is Cloudflare's, not yours

1. Check <https://www.cloudflarestatus.com>. If components show "Major Outage" or "Partial Outage" for the regions/products you use (Workers, Pages, Access, DNS), proceed.
2. Verify it isn't only your account: try a third-party site you know uses Cloudflare (e.g. <https://www.discord.com>, <https://www.openai.com>). Both broken == global event.
3. Check <https://status.sigstore.dev> too if a release is in flight (cosign signing depends on Sigstore which is independent but worth knowing).

If the issue is **not** clearly Cloudflare's, treat it as a normal incident and follow `incident-response-template.md` instead — the procedures below assume Cloudflare's infrastructure is degraded and yours is fine.

## Step 2 — Know what's affected per site

| Site | Cloudflare components on the critical path | Failure mode |
|---|---|---|
| **GlobalManagement** | DNS proxy, Pages hosting, Turnstile | Cached pages may still serve from CF edge briefly; new visits fail; contact form (Turnstile + Web3Forms) likely fails |
| **sacred-portal-wellness** | DNS proxy, Workers (the entire app runs there), Turnstile | Site is down. Square checkout cannot start. Existing in-flight Square sessions on Square-hosted pages continue |
| **antiphazeprod** (marketing) | DNS proxy, App Platform behind CF | Marketing site fails at the proxy; origin is reachable directly via DO IP if CF DNS is also down |
| **antiphazeprod** (tickets) | DNS proxy, CF Access on `/control` | Public ticket pages fail at the proxy; **admin `/control` is unreachable** because CF Access is the auth |

## Step 3 — Mitigations by site

### GlobalManagement (CF Pages)

**Option A — wait it out.** Cached HTML continues to serve from edge until cache expires. Most static pages are cacheable; users hitting cached URLs may not notice a short outage. **Recommended for outages < 30 minutes.**

**Option B — operator status page.** If outage is multi-hour, post a banner on social channels pointing customers to email contact (`info@...`).

There is no fast direct-to-origin path because the Pages origin is itself Cloudflare infrastructure.

### sacred-portal-wellness (CF Workers)

**No fallback is possible** — the entire application runs on Workers. Steps:
1. Post status update on the `wellness.echoeslabmusic.com` socials and email outbound queue.
2. Existing Square-hosted checkouts continue independently of Workers; orders that completed during the outage will deliver webhook callbacks once Workers recovers (Square retries webhooks). **Idempotency on the webhook handler is what makes this safe.**
3. Do **not** attempt manual order processing. Wait for recovery.

### antiphazeprod marketing (DO App Platform behind CF)

**Option A — direct origin URL.** App Platform exposes a stable `*.ondigitalocean.app` URL. Until Cloudflare recovers, share the direct URL on social media for those who need to view content. SEO impact is minor for a multi-hour outage.

**Option B — toggle orange-cloud off (DNS only).** *Only useful if Cloudflare DNS resolution still works but CF proxy is broken.* In the Cloudflare DNS dashboard, click the orange cloud next to the A record to grey-cloud (DNS-only). DNS will resolve directly to the origin. Lose: WAF, DDoS protection, CDN. Gain: site reachable directly.
- TTL during normal operation should be set to 5 minutes for this record so that toggling propagates quickly. Document this as an operational note.

### antiphazeprod tickets (Pretix on droplet behind CF + Caddy)

**Public ticket pages:** orange-cloud toggle (as above) restores public access. The droplet IP serves Caddy directly; Caddy has a real LE certificate so TLS works.

**Admin `/control`:** CF Access is the auth gate. With CF Access down, `/control` is unreachable.

**Emergency-only manual fallback:**
1. SSH to the droplet directly (this works as long as DigitalOcean's SSH and the droplet are healthy).
2. Use the local Pretix CLI for **emergency-only** changes — never as a regular operating mode:
   ```bash
   ssh deploy@<droplet>
   docker compose exec pretix python -m pretix shell
   ```
3. Do **not** reconfigure Caddy to expose `/control` to the public internet during the outage. Once CF Access is back, you would have to remember to re-protect it; this is a foot-gun. The droplet-local CLI is the safer fallback.

## Step 4 — Restoration

Once <https://www.cloudflarestatus.com> shows "Operational" for the affected components:

1. **Reverse any orange-cloud bypasses.** Click the grey cloud back to orange. Re-enables WAF + DDoS + caching.
2. **Re-test each site.** Hit a known URL on each, plus the contact form, plus a sandbox checkout (sacred-portal).
3. **Process the webhook backlog.** For sacred-portal: monitor `/api/webhooks/square` logs for the spike of retried events; verify HMAC continues to pass; verify idempotency is preventing double-charges. For antiphaze: confirm Pretix admin `/control` is reachable through CF Access.
4. **Document.** Append an entry to `docs/runbooks/incident-response-template.md`'s incident log: timestamp, duration, customer impact, mitigations attempted, lessons learned.

## Step 5 — Pre-conditions to make this runbook work

Set these up *before* the next outage so they're ready:

- [ ] DNS TTLs set to 5 minutes on records that may need orange-cloud toggling.
- [ ] Operator has the App Platform direct URL bookmarked.
- [ ] Operator has the droplet IP and SSH key ready (works regardless of Cloudflare status).
- [ ] Status-page channel exists (social account, status page, email list) and operator can post to it from a non-Cloudflare-dependent device.
- [ ] Sandbox Square account credentials available for post-recovery smoke test.
- [ ] Webhook idempotency confirmed working in dev (key: `square_order_id`).

## Acceptance of residual risk

For sacred-portal specifically, **payment processing is unavailable during a CF Workers outage and we accept that.** The alternative (a multi-region origin not on Cloudflare) costs an order of magnitude more and is not justified at current order volume. This decision is documented in the cross-cutting threat model and revisited yearly.
