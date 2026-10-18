#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/ui
capture_device_id="$(xcrun simctl list devices booted -j | python3 -c 'import json,os,sys; d=json.load(sys.stdin); ids=[x["udid"] for group in d["devices"].values() for x in group if x["state"]=="Booted" and "iPhone" in x["name"]]; preferred=os.environ["SIMULATOR_ID"]; print(preferred if preferred in ids else ids[0] if ids else preferred)')"
xcrun simctl bootstatus "$capture_device_id" -b
xcrun simctl status_bar "$capture_device_id" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$capture_device_id" build/DerivedData/Build/Products/Debug-iphonesimulator/LiaoChat.app
for appearance in light dark; do
  xcrun simctl ui "$capture_device_id" appearance "$appearance"
  xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
  xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview
  sleep 4
  xcrun simctl io "$capture_device_id" screenshot "build/ui/chat-$appearance.png"
  xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
  xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview --ui-math
  sleep 4
  xcrun simctl io "$capture_device_id" screenshot "build/ui/math-$appearance.png"
  if [[ "$appearance" == dark ]]; then
    xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
    xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview --ui-tools
    sleep 4
    xcrun simctl io "$capture_device_id" screenshot build/ui/tools-dark.png
  fi
done
xcrun simctl ui "$capture_device_id" appearance light
xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview --ui-empty
sleep 4
xcrun simctl io "$capture_device_id" screenshot build/ui/empty-light.png
xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview --ui-models
sleep 4
xcrun simctl io "$capture_device_id" screenshot build/ui/model-effort-light.png
for surface in files tools approval timeline mcp github; do
  xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
  xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview "--ui-$surface"
  sleep 4
  xcrun simctl io "$capture_device_id" screenshot "build/ui/$surface-light.png"
  if [[ "$surface" == files ]]; then
    xcrun simctl get_app_container "$capture_device_id" com.example.LiaoChat data > build/ui-container.txt
    python3 - <<'PY'
from pathlib import Path
import shutil
container = Path('build/ui-container.txt').read_text().strip()
target = Path('build/generated'); target.mkdir(exist_ok=True)
expected = {'.pdf', '.docx', '.xlsx', '.zip'}
for source in Path(container).rglob('*'):
    if source.is_file() and source.suffix in expected:
        shutil.copyfile(source, target / ('native-sample' + source.suffix))
found = {p.suffix for p in target.iterdir()}
print('Native document formats collected:', sorted(found))
assert found == expected, 'Native sample generation incomplete: ' + repr(sorted(expected - found))
PY
  fi
done
