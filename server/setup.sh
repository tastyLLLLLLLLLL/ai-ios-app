#!/usr/bin/env bash
# Pocket AI server: first-time installation on a RunPod GPU pod.
#
#   curl -fsSL https://raw.githubusercontent.com/tastyLLLLLLLLLL/ai-ios-app/main/server/setup.sh | bash
#
# Everything is installed into /workspace, the disk that survives a pod restart.
# The script can be run again at any time: finished downloads are skipped.
set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/tastyLLLLLLLLLL/ai-ios-app/main/server"
ROOT=/workspace/ai-server
COMFY=/workspace/ComfyUI
VENV=/workspace/venv
MODELS=$COMFY/models
export OLLAMA_MODELS=/workspace/ollama

FAILED=()
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! Не получилось: %s\033[0m\n' "$*"; FAILED+=("$*"); }

# Downloads a file unless it is already there. Resumes interrupted downloads.
get() {
  local url=$1 dest=$2
  if [ -s "$dest" ]; then ok "$(basename "$dest") уже скачан"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  echo "Скачиваю $(basename "$dest")…"
  if curl -fL -# --retry 3 --retry-delay 5 -C - -o "$dest.part" "$url"; then
    mv "$dest.part" "$dest"
    ok "$(basename "$dest")"
  else
    rm -f "$dest.part"
    return 1
  fi
}

# Pulls the first text model tag that exists (newer versions first, older as a fallback).
pull() {
  local tag
  for tag in "$@"; do
    echo "Скачиваю модель $tag…"
    if "$ROOT/ollama/bin/ollama" pull "$tag"; then ok "$tag"; return 0; fi
  done
  warn "текстовая модель $1"
}

mkdir -p "$ROOT/logs" "$OLLAMA_MODELS"

say "1/6 Системные пакеты"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq git curl zstd python3-venv >/dev/null 2>&1 || warn "системные пакеты"

say "2/6 Файлы сервера Pocket AI"
for file in gateway.py start.sh autostart.sh; do
  curl -fsSL "$REPO_RAW/$file" -o "$ROOT/$file" || { echo "Не удалось скачать $file — проверьте интернет и запустите скрипт ещё раз."; exit 1; }
done
chmod +x "$ROOT/start.sh" "$ROOT/autostart.sh"
[ -s "$ROOT/password.txt" ] || python3 -c "import secrets; print(secrets.token_urlsafe(18))" > "$ROOT/password.txt"
[ -s "$ROOT/ntfy.txt" ] || python3 -c "import secrets; print('pocketai-' + secrets.token_hex(8))" > "$ROOT/ntfy.txt"
ok "Пароль и тема уведомлений созданы"

say "3/6 Ollama (текст и код)"
if [ ! -x "$ROOT/ollama/bin/ollama" ]; then
  if ! command -v ollama >/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
  fi
  # Copied to /workspace so it survives a pod restart without reinstalling.
  mkdir -p "$ROOT/ollama/bin" "$ROOT/ollama/lib"
  if cp "$(command -v ollama)" "$ROOT/ollama/bin/ollama" && cp -r /usr/local/lib/ollama "$ROOT/ollama/lib/"; then
    ok "Ollama установлена"
  else
    warn "установка Ollama"
  fi
fi
bash "$ROOT/start.sh" ollama

pull qwen3:4b
pull gpt-oss:20b
pull qwen3.6:27b qwen3:32b
pull qwen3-coder:30b
pull gemma4:31b gemma3:27b
pull deepseek-r1:32b
pull hf.co/mlabonne/gemma-3-27b-it-abliterated-GGUF:Q4_K_M

say "4/6 ComfyUI (картинки, видео, музыка)"
if [ ! -d "$COMFY/.git" ]; then
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI "$COMFY" || warn "ComfyUI"
else
  git -C "$COMFY" pull --ff-only -q || true
fi
[ -x "$VENV/bin/python" ] || python3 -m venv --system-site-packages "$VENV"
"$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$VENV/bin/pip" install -q -r "$COMFY/requirements.txt" aiohttp qrcode || warn "библиотеки ComfyUI"
if ! "$VENV/bin/python" -c "import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  "$VENV/bin/pip" install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 || warn "PyTorch"
fi
ok "ComfyUI готов"

say "5/6 Модели для картинок, видео и музыки"
HF=https://huggingface.co
get "$HF/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors" "$MODELS/checkpoints/flux1-dev-fp8.safetensors" \
  || get "$HF/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors" "$MODELS/checkpoints/flux1-schnell-fp8.safetensors" \
  || warn "FLUX"
get "$HF/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" "$MODELS/checkpoints/sd_xl_base_1.0.safetensors" \
  || warn "SDXL"
get "$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors" "$MODELS/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors" \
  && get "$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$MODELS/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
  && get "$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors" "$MODELS/vae/wan2.2_vae.safetensors" \
  || warn "Wan 2.2 (видео)"
get "$HF/Comfy-Org/ACE-Step_ComfyUI_repackaged/resolve/main/all_in_one/ace_step_v1_3.5b.safetensors" "$MODELS/checkpoints/ace_step_v1_3.5b.safetensors" \
  || warn "ACE-Step (музыка)"

say "6/6 Запуск"
# Restart the gateway so an updated version takes effect.
pkill -f "ai-server/gateway.py" 2>/dev/null; sleep 1
bash "$ROOT/start.sh"

if [ ${#FAILED[@]} -gt 0 ]; then
  printf '\n\033[1;33mНе всё установилось:\033[0m\n'
  printf '  • %s\n' "${FAILED[@]}"
  echo "Запустите эту же команду ещё раз — уже скачанное повторно качаться не будет."
fi
