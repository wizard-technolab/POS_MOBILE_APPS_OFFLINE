#!/usr/bin/env bash
set -euo pipefail

# Secure release build with Dart obfuscation and split debug symbols.
# Required environment variables:
#   WT_APP_SECRET_KEY      HMAC key for subscription validation
# Optional environment variables:
#   WT_LICENSE_SERVER_URL  Defaults to http://warlock-subscription.odoo.com
#   BLOCK_COMPROMISED_DEVICES true/false, defaults to false

if [[ -z "${WT_APP_SECRET_KEY:-}" ]]; then
  echo "WT_APP_SECRET_KEY is required. Do not hardcode it in Dart source." >&2
  exit 1
fi

# Safety check: Ensure signing files are decrypted before building
# if [[ ! -f "android/keystore.properties" || ! -f "android/app/key.jks" ]]; then
#   echo "Error: Android signing files are missing or still encrypted." >&2
#   echo "Please run: ./scripts/decrypt_android_signing.sh" >&2
#   exit 1
# fi

SYMBOL_DIR="build/symbols/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SYMBOL_DIR"

flutter clean
flutter pub get
flutter build appbundle \
  --release \
  --obfuscate \
  --no-tree-shake-icons \
  --split-debug-info="$SYMBOL_DIR" \
  --dart-define=WT_APP_SECRET_KEY="$WT_APP_SECRET_KEY" \
  --dart-define=WT_LICENSE_SERVER_URL="${WT_LICENSE_SERVER_URL:-http://warlock-subscription.odoo.com}" \
  --dart-define=BLOCK_COMPROMISED_DEVICES="${BLOCK_COMPROMISED_DEVICES:-true}"

echo "Build complete. Store symbol files securely: $SYMBOL_DIR"
