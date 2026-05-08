#!/usr/bin/env bash
# Refreshes a DO Cloud Firewall rule with the current GitHub Actions runner IP ranges.
# Required env: DO_FIREWALL_ID, HOME_IP. Requires: doctl authenticated, jq, curl.
set -euo pipefail

: "${DO_FIREWALL_ID:?must set DO_FIREWALL_ID}"
: "${HOME_IP:?must set HOME_IP}"

ACTION_IPS_JSON=$(curl -fsSL https://api.github.com/meta | jq -c '.actions')

# Build address list: GitHub runners + HOME_IP
ADDRESSES=$(jq -c --arg home "$HOME_IP" '. + [$home]' <<<"$ACTION_IPS_JSON")

# Compose JSON for `doctl compute firewall update --inbound-rules`
INBOUND_RULES=$(jq -c --argjson addrs "$ADDRESSES" '
  [
    {protocol:"tcp", ports:"22",  sources:{addresses:$addrs}},
    {protocol:"tcp", ports:"80",  sources:{addresses:["0.0.0.0/0","::/0"]}},
    {protocol:"tcp", ports:"443", sources:{addresses:["0.0.0.0/0","::/0"]}}
  ]
' <<<'null')

doctl compute firewall update "$DO_FIREWALL_ID" --inbound-rules "$INBOUND_RULES"
