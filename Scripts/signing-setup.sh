#!/usr/bin/env bash
set -euo pipefail
for required in APP_BUNDLE_ID APPLE_TEAM_ID BUILD_CERTIFICATE_BASE64 P12_PASSWORD BUILD_PROVISION_PROFILE_BASE64 KEYCHAIN_PASSWORD; do
  if [[ -z "${!required:-}" ]]; then echo "Missing configuration: $required" >&2; exit 1; fi
done
umask 077
SIGNING_DIR="$RUNNER_TEMP/liaochat-signing"
mkdir -p "$SIGNING_DIR"
export SIGNING_DIR
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['SIGNING_DIR'])
(root / 'certificate.p12').write_bytes(base64.b64decode(os.environ['BUILD_CERTIFICATE_BASE64'], validate=True))
(root / 'profile.mobileprovision').write_bytes(base64.b64decode(os.environ['BUILD_PROVISION_PROFILE_BASE64'], validate=True))
PY
SIGNING_KEYCHAIN="$SIGNING_DIR/build.keychain-db"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security import "$SIGNING_DIR/certificate.p12" -P "$P12_PASSWORD" -t cert -f pkcs12 -k "$SIGNING_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$SIGNING_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
security cms -D -i "$SIGNING_DIR/profile.mobileprovision" > "$SIGNING_DIR/profile.plist"
python3 - <<'PY'
import datetime, os, plistlib, re
from pathlib import Path
root = Path(os.environ['SIGNING_DIR'])
profile = plistlib.loads((root / 'profile.plist').read_bytes())
team, bundle = os.environ['APPLE_TEAM_ID'], os.environ['APP_BUNDLE_ID']
if not re.fullmatch(r'[A-Za-z0-9.-]+', bundle) or bundle == 'com.example.LiaoChat': raise SystemExit('Set your real APP_BUNDLE_ID')
if team not in profile['TeamIdentifier']: raise SystemExit('Profile team does not match APPLE_TEAM_ID')
if profile['Entitlements']['application-identifier'] != team + '.' + bundle: raise SystemExit('Profile App ID does not match the bundle ID')
if 'Default' not in profile['Entitlements'].get('com.apple.developer.applesignin', []):
    raise SystemExit('Enable Sign in with Apple for the App ID, regenerate its App Store Connect distribution profile, and update BUILD_PROVISION_PROFILE_BASE64')
if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices') or profile['Entitlements'].get('get-task-allow'): raise SystemExit('Use an App Store Connect distribution profile')
if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None): raise SystemExit('Provisioning profile expired')
uuid = profile['UUID']
if not re.fullmatch(r'[A-Fa-f0-9-]+', uuid): raise SystemExit('Invalid provisioning UUID')
for folder in ['Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles']:
    target = Path.home() / folder
    target.mkdir(parents=True, exist_ok=True)
    (target / (uuid + '.mobileprovision')).write_bytes((root / 'profile.mobileprovision').read_bytes())
options = {'method': 'app-store-connect', 'signingStyle': 'manual', 'teamID': team,
           'provisioningProfiles': {bundle: uuid}, 'signingCertificate': 'Apple Distribution',
           'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True}
Path(os.environ['RUNNER_TEMP'], 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
with open(os.environ['GITHUB_ENV'], 'a') as f:
    f.write('PROFILE_UUID=' + uuid + '\n')
    f.write('SIGNING_KEYCHAIN=' + str(root / 'build.keychain-db') + '\n')
PY
