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
done
xcrun simctl ui "$capture_device_id" appearance light
xcrun simctl terminate "$capture_device_id" com.example.LiaoChat || true
xcrun simctl launch "$capture_device_id" com.example.LiaoChat --ui-preview --ui-empty
sleep 4
xcrun simctl io "$capture_device_id" screenshot build/ui/empty-light.png
