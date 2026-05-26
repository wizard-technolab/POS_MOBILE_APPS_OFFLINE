#!/usr/bin/env bash
set -euo pipefail

# Decrypt Android signing files locally for release builds.
# Usage: scripts/decrypt_android_signing.sh

for file in android/keystore.properties android/key.properties android/app/key.jks; do
  if [[ -f "$file.gpg" ]]; then
    gpg --yes --decrypt --output "$file" "$file.gpg"
    echo "Decrypted $file.gpg -> $file"
  fi
done
