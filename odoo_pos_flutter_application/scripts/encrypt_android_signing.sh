#!/usr/bin/env bash
set -euo pipefail

# Encrypt Android signing files before committing or sharing.
# Usage: scripts/encrypt_android_signing.sh your@email.com

RECIPIENT="${1:-}"
if [[ -z "$RECIPIENT" ]]; then
  echo "Usage: $0 <gpg-recipient-email-or-key-id>" >&2
  exit 1
fi

for file in android/keystore.properties android/key.properties android/app/key.jks; do
  if [[ -f "$file" ]]; then
    gpg --yes --encrypt --recipient "$RECIPIENT" --output "$file.gpg" "$file"
    echo "Encrypted $file -> $file.gpg"
  fi
done
