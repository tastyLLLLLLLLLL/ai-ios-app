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

# Runs a command with a time limit in seconds (macOS has no `timeout`).
limit() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}
step() { echo "[$(date +%H:%M:%S)] $*"; }

UDID=$(xcrun simctl list devices available | grep -E "iPhone 1[67] Pro \(" | head -1 | grep -oE "[0-9A-F-]{36}")
echo "Simulator: $UDID"
step "booting"
limit 120 xcrun simctl boot "$UDID" || true
limit 600 xcrun simctl bootstatus "$UDID" -b || true
step "booted"
limit 60 xcrun simctl ui "$UDID" appearance dark || true
limit 60 xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
limit 300 xcrun simctl install "$UDID" "$APP"
step "installed"

shot() {
  sleep "${2:-4}"
  limit 60 xcrun simctl io "$UDID" screenshot "$OUT/$1.png" || echo "screenshot $1 failed"
  step "shot $1"
}

launch() {
  limit 60 xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  step "launch $*"
  limit 120 xcrun simctl launch "$UDID" "$BUNDLE" "$@" || echo "launch failed or timed out"
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

# Waits until the app saves the finished reply (or gives up after 5 minutes).
wait_for_reply() {
  local before="$1"
  for _ in $(seq 1 150); do
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
limit 60 xcrun simctl ui "$UDID" appearance light || true
shot 06-chat-light 4
limit 60 xcrun simctl ui "$UDID" appearance dark || true

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

echo "----- crash reports -----"
ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i pocket || echo "none"
echo "----- app log (errors) -----"
limit 120 xcrun simctl spawn "$UDID" log show --last 15m --style compact --predicate 'process == "PocketAI" AND messageType >= 16' 2>/dev/null | tail -40 || true
echo "----- saved conversations -----"
cat "$CHATS" || echo "no chats saved"
echo
ls -l "$OUT"
