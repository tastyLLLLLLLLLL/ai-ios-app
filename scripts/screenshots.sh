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

# Waits until the app saves the finished reply (checks every 2 seconds, up to the given number of tries).
wait_for_reply() {
  local before="$1"
  local tries="${2:-150}"
  for _ in $(seq 1 "$tries"); do
    if [ "$(mtime)" != "$before" ]; then echo "Reply finished"; return 0; fi
    sleep 2
  done
  echo "Timed out waiting for the reply"
}

launch
shot 03-home 5

# Themes: other colour schemes and the forced light mode, then back to the defaults.
launch -demoPalette sunset
shot 03a-theme-sunset 5
launch -demoPalette forest -demoAppearance light
shot 03b-theme-forest-light 5
launch -demoPalette ruby -demoAppearance dark -demoScreen settings
shot 03c-theme-settings 5
launch -demoPalette ocean -demoAppearance system
sleep 3
launch -demoScreen settings
shot 04-settings 5
launch -demoScreen models
shot 05-models-installed 5

# The build server has no GPU, so generation here is far slower than on a phone.
before=$(mtime)
launch -demoPrompt "Объясни простыми словами, что такое чёрная дыра. Ответь в трёх-четырёх предложениях."
shot 06-chat-loading 25
wait_for_reply "$before" 420
shot 07-chat 3
limit 60 xcrun simctl ui "$UDID" appearance light || true
shot 08-chat-light 6
limit 60 xcrun simctl ui "$UDID" appearance dark || true
launch -demoScreen chats
shot 09-chats 6

before=$(mtime)
launch -demoPrompt "Напиши на Python функцию is_palindrome(s). Только код и одно предложение пояснения."
wait_for_reply "$before" 480
shot 10-code 3

launch -demoUncensored YES -demoScreen settings
shot 11-settings-uncensored 6

# Photo question, answered by Gemma 3 4B with its vision module.
if [ -n "${VISION_MODEL:-}" ] && [ -f "$VISION_MODEL" ]; then
  cp "$VISION_MODEL" "$DATA/Documents/Models/gemma-3-4b-it-Q4_K_M.gguf"
  cp "$VISION_MODULE" "$DATA/Documents/Models/mmproj-gemma-3-4b-it.gguf"
  before=$(mtime)
  launch -demoModel gemma-3-4b-it-Q4_K_M.gguf -demoImage "$PWD/scripts/test-photo.jpg" \
    -demoPrompt "Что изображено на этой картинке? Ответь двумя предложениями."
  shot 12-photo-loading 30
  wait_for_reply "$before" 700
  shot 13-photo 3
fi

echo "----- crash reports -----"
ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i pocket || echo "none"
echo "----- app log (errors) -----"
limit 120 xcrun simctl spawn "$UDID" log show --last 15m --style compact --predicate 'process == "PocketAI" AND messageType >= 16' 2>/dev/null | tail -40 || true
echo "----- saved conversations -----"
cat "$CHATS" || echo "no chats saved"
echo
ls -l "$OUT"
