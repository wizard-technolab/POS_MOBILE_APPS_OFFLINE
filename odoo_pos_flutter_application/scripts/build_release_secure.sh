#!/usr/bin/env bash
set -euo pipefail

# Secure release build with Dart obfuscation and split debug symbols.
# Required environment variables:
#   WT_APP_SECRET_KEY      HMAC key for subscription validation
# Optional environment variables:
#   WT_LICENSE_SERVER_URL  Defaults to https://subscription.warlocktechnologies.com
#   BLOCK_COMPROMISED_DEVICES true/false, defaults to false

if [[ -z "${WT_APP_SECRET_KEY:-}" ]]; then
  echo "WT_APP_SECRET_KEY is required. Do not hardcode it in Dart source." >&2
  exit 1
fi

SYMBOL_DIR="build/symbols/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SYMBOL_DIR"

flutter clean
flutter pub get
flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info="$SYMBOL_DIR" \
  --dart-define=WT_APP_SECRET_KEY="$WT_APP_SECRET_KEY" \
  --dart-define=WT_LICENSE_SERVER_URL="${WT_LICENSE_SERVER_URL:-https://synopses-wreckage-babied.ngrok-free.dev}" \
  --dart-define=BLOCK_COMPROMISED_DEVICES="${BLOCK_COMPROMISED_DEVICES:-false}"

echo "Build complete. Store symbol files securely: $SYMBOL_DIR"
