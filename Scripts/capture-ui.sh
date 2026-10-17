#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/ui
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$SIMULATOR_ID" build/DerivedData/Build/Products/Debug-iphonesimulator/LiaoChat.app
for appearance in light dark; do
  xcrun simctl ui "$SIMULATOR_ID" appearance "$appearance"
  xcrun simctl terminate "$SIMULATOR_ID" com.example.LiaoChat || true
  xcrun simctl launch "$SIMULATOR_ID" com.example.LiaoChat --ui-preview
  sleep 2
  xcrun simctl io "$SIMULATOR_ID" screenshot "build/ui/chat-$appearance.png"
done
xcrun simctl ui "$SIMULATOR_ID" appearance light
xcrun simctl terminate "$SIMULATOR_ID" com.example.LiaoChat || true
xcrun simctl launch "$SIMULATOR_ID" com.example.LiaoChat --ui-preview --ui-empty
sleep 2
xcrun simctl io "$SIMULATOR_ID" screenshot build/ui/empty-light.png
