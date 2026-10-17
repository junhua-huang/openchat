#!/usr/bin/env bash
set -euo pipefail
for required in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_BASE64; do
  if [[ -z "${!required:-}" ]]; then echo "Missing configuration: $required" >&2; exit 1; fi
done
umask 077
python3 - <<'PY'
import base64, os, re
from pathlib import Path
key_id = os.environ['ASC_KEY_ID']
if not re.fullmatch(r'[A-Za-z0-9]+', key_id): raise SystemExit('Invalid API key ID')
root = Path.home() / '.appstoreconnect/private_keys'
root.mkdir(parents=True, exist_ok=True)
(root / ('AuthKey_' + key_id + '.p8')).write_bytes(base64.b64decode(os.environ['ASC_PRIVATE_KEY_BASE64'], validate=True))
PY
xcrun altool --validate-app -f build/export/LiaoChat.ipa -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f build/export/LiaoChat.ipa -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
