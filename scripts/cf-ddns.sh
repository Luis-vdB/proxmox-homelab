#!/bin/bash
# ---------------------------------------------------------------------------
# Cloudflare DDNS Updater
# Keeps vpn.<your-domain> pointed at the host's current dynamic public IP.
# Runs inside LXC 120 via a systemd timer, every 5 minutes.
#
# Secrets are NOT stored in this script. They are sourced at runtime from
# /etc/cf-ddns/config (chmod 600, root-only). See config/cf-ddns.config.example.
# ---------------------------------------------------------------------------

# Fail fast: exit on error (-e), error on unset variables (-u),
# and fail a pipeline if any stage fails (-o pipefail).
set -euo pipefail

# Load CF_API_TOKEN, CF_ZONE, CF_RECORD, CF_RECORD_TYPE, CF_TTL, CF_PROXIED
source /etc/cf-ddns/config

# Timestamped logging to the systemd journal
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Step 1: Get the host's current public IP
CURRENT_IP=$(curl -sf https://api.ipify.org) || {
    log "ERROR: Failed to get public IP from ipify.org"
    exit 1
}
log "Current public IP: $CURRENT_IP"

# Step 2: Resolve the Cloudflare Zone ID for the domain
ZONE_ID=$(curl -sf \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE" \
    | jq -r '.result[0].id') || {
    log "ERROR: Failed to get Zone ID from Cloudflare"
    exit 1
}
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
    log "ERROR: Zone ID is empty or null. Check CF_ZONE and API token."
    exit 1
fi
log "Zone ID: $ZONE_ID"

# Step 3: Fetch the current A record (its ID and the IP it currently holds)
RECORD_DATA=$(curl -sf \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$CF_RECORD_TYPE&name=$CF_RECORD") || {
    log "ERROR: Failed to get DNS record from Cloudflare"
    exit 1
}
RECORD_ID=$(echo "$RECORD_DATA" | jq -r '.result[0].id')
RECORD_IP=$(echo "$RECORD_DATA" | jq -r '.result[0].content')
if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" = "null" ]; then
    log "ERROR: DNS record not found. Has vpn.<your-domain> been created in Cloudflare?"
    exit 1
fi
log "DNS record ID: $RECORD_ID"
log "DNS record current IP: $RECORD_IP"

# Step 4: Compare. If the public IP already matches the record, do nothing.
if [ "$CURRENT_IP" = "$RECORD_IP" ]; then
    log "IP unchanged ($CURRENT_IP). No update needed."
    exit 0
fi

# IP changed -> push the new value to Cloudflare via the API
log "IP changed: $RECORD_IP -> $CURRENT_IP. Updating Cloudflare..."
UPDATE_RESULT=$(curl -sf \
    -X PUT \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"$CF_RECORD_TYPE\",\"name\":\"$CF_RECORD\",\"content\":\"$CURRENT_IP\",\"ttl\":$CF_TTL,\"proxied\":$CF_PROXIED}" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID") || {
    log "ERROR: Failed to update DNS record"
    exit 1
}

# Confirm the API reported success
SUCCESS=$(echo "$UPDATE_RESULT" | jq -r '.success')
if [ "$SUCCESS" = "true" ]; then
    log "SUCCESS: DNS record updated to $CURRENT_IP"
else
    ERROR=$(echo "$UPDATE_RESULT" | jq -r '.errors[0].message')
    log "ERROR: Cloudflare API returned failure: $ERROR"
    exit 1
fi
