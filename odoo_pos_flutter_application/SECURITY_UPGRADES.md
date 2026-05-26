# Flutter Security Upgrades Applied

## What changed

- Sensitive app configuration moved from SharedPreferences to `flutter_secure_storage`:
  - JWT token
  - API email/password
  - Odoo server URL and DB name
  - device code
  - subscription code, email and expiry
  - API/subscription secret fallback
- Clean secure-storage implementation for sensitive preferences. No legacy SharedPreferences migration is included because this app is not deployed yet.
- Offline login password is no longer stored in SQLite; SQLite stores only a salted PBKDF2-SHA256 password hash.
- Clean encrypted offline-login table. SQLite stores encrypted server/db values and a salted PBKDF2 password hash; no plain-text password is stored.
- MD5 usage in delta sync hashing was replaced with SHA-256.
- Android UI spoofing/tapjacking defenses added:
  - `FLAG_SECURE`
  - Android 12 overlay hiding
  - reject obscured/partially-obscured touches
- Runtime root/jailbreak/tamper checks added through `jailbreak_root_detection`.
- Android app backup disabled for app data.
- Release cleartext traffic disabled. Debug/profile builds keep HTTP enabled for local/dev Odoo testing.
- Release build now enables R8 minify/shrink.
- Secure release script added with Flutter Dart obfuscation and split debug symbols.
- Android signing files are ignored by Git and GPG helper scripts were added.

## Required production build command

```bash
export WT_APP_SECRET_KEY='your-subscription-hmac-secret'
export WT_LICENSE_SERVER_URL='https://subscription.warlocktechnologies.com'
export BLOCK_COMPROMISED_DEVICES='true'
./scripts/build_release_secure.sh
```
To launch Test:
export WT_APP_SECRET_KEY='d4f298c3e8e94172a52b88135c754688439810a9094772186934891275454621'
export WT_LICENSE_SERVER_URL='https://synopses-wreckage-babied.ngrok-free.dev'
export BLOCK_COMPROMISED_DEVICES='false'

flutter run \
  --dart-define=WT_APP_SECRET_KEY="$WT_APP_SECRET_KEY" \
  --dart-define=WT_LICENSE_SERVER_URL="$WT_LICENSE_SERVER_URL" \
  --dart-define=BLOCK_COMPROMISED_DEVICES="$BLOCK_COMPROMISED_DEVICES"

Keep the generated `build/symbols/...` folder private. It is required to decode obfuscated crash logs.

## Android signing secret workflow

Never commit plain signing files:

```bash
android/keystore.properties
android/key.properties
android/app/key.jks
```

Encrypt them before storing/sharing:

```bash
./scripts/encrypt_android_signing.sh your@email.com
```

Decrypt locally before building:

```bash
./scripts/decrypt_android_signing.sh
```

## Notes

- The current package/application ID is preserved to avoid install/update breakage.
- `BLOCK_COMPROMISED_DEVICES` defaults to `false` so genuine users are not blocked by false positives during rollout. Set it to `true` after testing on your real devices.
- Move all production endpoints to HTTPS. The included network security config blocks cleartext traffic by default.
