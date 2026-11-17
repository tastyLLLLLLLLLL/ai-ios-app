#!/usr/bin/env bash
# Starts the Pocket AI server. Run it after every pod start:
#
#   bash /workspace/ai-server/start.sh
#
# With the argument "ollama" only the text model service is started (used by setup.sh).
ROOT=/workspace/ai-server
LOGS=$ROOT/logs
export OLLAMA_MODELS=/workspace/ollama
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_KEEP_ALIVE=10m
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_FLASH_ATTENTION=1
mkdir -p "$LOGS"

running() { pgrep -f "$1" >/dev/null 2>&1; }

wait_for() { # url, seconds
  local i
  for i in $(seq 1 "$2"); do
    curl -fs "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

if ! running "ollama serve"; then
  nohup "$ROOT/ollama/bin/ollama" serve > "$LOGS/ollama.log" 2>&1 &
fi
wait_for http://127.0.0.1:11434/api/version 30 || echo "Ollama не запустилась, см. $LOGS/ollama.log"
[ "${1:-}" = "ollama" ] && exit 0

if [ -f /workspace/ComfyUI/main.py ] && ! running "ComfyUI/main.py"; then
  (cd /workspace/ComfyUI && nohup /workspace/venv/bin/python /workspace/ComfyUI/main.py \
    --listen 127.0.0.1 --port 8188 --disable-auto-launch > "$LOGS/comfyui.log" 2>&1 &)
fi

if ! running "ai-server/gateway.py"; then
  nohup /workspace/venv/bin/python "$ROOT/gateway.py" > "$LOGS/gateway.log" 2>&1 &
fi

if wait_for http://127.0.0.1:8080/api/ping 60; then
  printf '\n\033[1;32m✓ Сервер Pocket AI работает\033[0m\n\n'
else
  printf '\n\033[1;31m✗ Сервер не ответил. Пришлите вывод команды: tail -n 40 %s/gateway.log\033[0m\n\n' "$LOGS"
fi

PASSWORD=$(cat "$ROOT/password.txt")
if [ -n "${RUNPOD_POD_ID:-}" ]; then
  ADDRESS="https://${RUNPOD_POD_ID}-8080.proxy.runpod.net"
  LINK=$(/workspace/venv/bin/python -c "import sys, urllib.parse as u; print('pocketai://connect?address=' + u.quote(sys.argv[1], safe='') + '&password=' + u.quote(sys.argv[2], safe=''))" "$ADDRESS" "$PASSWORD" 2>/dev/null)
  echo "Подключение приложения: наведите камеру iPhone на этот QR-код и нажмите «Открыть в Pocket AI»:"
  /workspace/venv/bin/python -c "import qrcode, sys; q = qrcode.QRCode(border=2); q.add_data(sys.argv[1]); q.print_ascii(invert=True)" "$LINK" 2>/dev/null \
    || echo "  (QR-код недоступен — запустите скрипт установки ещё раз)"
  echo
  echo "Или введите вручную (Модели → Онлайн):"
  echo "  Адрес:  $ADDRESS"
else
  echo "Данные для приложения (Модели → Онлайн):"
  echo "  Адрес:  ссылка на порт 8080 из кнопки Connect на RunPod"
fi
echo "  Пароль: $PASSWORD"
echo
echo "Уведомления о готовности картинок, видео и музыки: установите на iPhone приложение ntfy"
echo "и подпишитесь на тему: $(cat "$ROOT/ntfy.txt")"
echo
echo "Пароль никому не пересылайте. Картинки и видео ComfyUI начнёт делать через 1–2 минуты после запуска."
