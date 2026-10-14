#!/usr/bin/env bash
# Writes config/relay.json from the RELAY_CONFIG_JSON secret (format: config/relay.example.json).
set -euo pipefail
if [ -z "${RELAY_CONFIG_JSON:-}" ]; then
  echo "::error::RELAY_CONFIG_JSON secret is required, see config/relay.example.json"
  exit 1
fi
printf '%s' "$RELAY_CONFIG_JSON" > config/relay.json
jq -e '(.licenseServerUrl | startswith("https://"))
  and (.publicKey | test("^[A-Za-z0-9+/]+=*$"))
  and (.transportPublicKey | test("^[A-Za-z0-9+/]+=*$"))' config/relay.json > /dev/null || {
  echo "::error::RELAY_CONFIG_JSON needs an https licenseServerUrl and single-line base64 publicKey / transportPublicKey"
  exit 1
}
