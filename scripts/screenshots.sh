#!/usr/bin/env bash
# Runs the app in the iOS Simulator with a real model and saves screenshots to ./shots.
# Usage: scripts/screenshots.sh <path to PocketAI.app> <path to model .gguf> <model file name>
set -euo pipefail

APP="$1"
MODEL="$2"
MODEL_NAME="$3"
BUNDLE=com.personal.pocketai
OUT=shots
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available | grep -E "iPhone 1[67] Pro \(" | head -1 | grep -oE "[0-9A-F-]{36}")
echo "Simulator: $UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl install "$UDID" "$APP"

shot() {
  sleep "${2:-4}"
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png"
}

launch() {
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE" "$@"
}

launch
shot 01-first-launch 8
launch -demoScreen models
shot 02-models-empty 5

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
CHATS="$DATA/Documents/chats.json"
mkdir -p "$DATA/Documents/Models"
cp "$MODEL" "$DATA/Documents/Models/$MODEL_NAME"

mtime() { stat -f %m "$CHATS" 2>/dev/null || echo 0; }

# Waits until the app saves the finished reply (or gives up after 8 minutes).
wait_for_reply() {
  local before="$1"
  for _ in $(seq 1 240); do
    if [ "$(mtime)" != "$before" ]; then echo "Reply finished"; return 0; fi
    sleep 2
  done
  echo "Timed out waiting for the reply"
}

launch
shot 03-home 5

before=$(mtime)
launch -demoPrompt "Объясни простыми словами, что такое чёрная дыра. Ответь в трёх-четырёх предложениях."
shot 04-chat-streaming 25
wait_for_reply "$before"
shot 05-chat 2
xcrun simctl ui "$UDID" appearance light
shot 06-chat-light 4
xcrun simctl ui "$UDID" appearance dark

before=$(mtime)
launch -demoPrompt "Напиши на Python функцию, которая проверяет, является ли строка палиндромом. Коротко объясни, как она работает."
wait_for_reply "$before"
shot 07-code 2

launch -demoScreen chats
shot 08-chats 5
launch -demoScreen settings
shot 09-settings 5
launch -demoScreen models
shot 10-models 5

echo "----- saved conversations -----"
cat "$CHATS" || echo "no chats saved"
echo
ls -l "$OUT"
