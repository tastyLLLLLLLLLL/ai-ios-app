"""Pocket AI server gateway.

One password-protected entry point for the iPhone app:
  * text and code models run in Ollama (streamed chat);
  * images, video and music are jobs for ComfyUI, tracked here with progress;
  * finished jobs can be announced through ntfy.

Runs on port 8080, which RunPod publishes as https://<pod id>-8080.proxy.runpod.net.
"""

import asyncio
import json
import os
import random
import subprocess
import time
import uuid
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

ROOT = Path(os.environ.get("POCKETAI_ROOT", "/workspace/ai-server"))
COMFY_DIR = Path(os.environ.get("POCKETAI_COMFY", "/workspace/ComfyUI"))
OLLAMA = "http://127.0.0.1:11434"
COMFY = "http://127.0.0.1:8188"
CLIENT_ID = "pocket-ai-gateway"
JOBS_FILE = ROOT / "jobs.json"
IDLE_FILE = ROOT / "idle_minutes.txt"

PASSWORD = (ROOT / "password.txt").read_text().strip()
NTFY_TOPIC = (ROOT / "ntfy.txt").read_text().strip() if (ROOT / "ntfy.txt").exists() else ""

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------

# Text and code models. Matched by name prefix against what Ollama has installed.
TEXT_MODELS = [
    {"match": "qwen3.6", "name": "Qwen3.6 27B", "category": "text",
     "summary": "Самая сильная универсальная модель, хорошо знает русский."},
    {"match": "qwen3:32b", "name": "Qwen3 32B", "category": "text",
     "summary": "Сильная универсальная модель, хорошо знает русский, умеет рассуждать."},
    {"match": "gemma4", "name": "Gemma 4 31B", "category": "text",
     "summary": "Модель Google: живой язык, хорошо держит длинные разговоры."},
    {"match": "gemma3:27b", "name": "Gemma 3 27B", "category": "text",
     "summary": "Модель Google: живой язык, хорошо держит длинные разговоры."},
    {"match": "gpt-oss", "name": "gpt-oss 20B", "category": "text",
     "summary": "Модель OpenAI с открытыми весами: быстрая, сильна в рассуждениях."},
    {"match": "deepseek-r1", "name": "DeepSeek R1 32B", "category": "text",
     "summary": "Подробно рассуждает перед ответом, сильна в логике и математике."},
    {"match": "hf.co/mlabonne/gemma-3-27b-it-abliterated", "name": "Gemma 3 27B без цензуры", "category": "text",
     "summary": "Та же Gemma 3 со снятыми ограничениями: не отказывается отвечать.", "uncensored": True},
    {"match": "qwen3:4b", "name": "Qwen3 4B (быстрая)", "category": "text",
     "summary": "Маленькая и очень быстрая модель для простых вопросов. Ещё сервер переводит ей описания для картинок."},
    {"match": "qwen3-coder", "name": "Qwen3-Coder 30B", "category": "code",
     "summary": "Специально для программирования, быстрая."},
]

# Media models: which files must exist for each one.
MEDIA_MODELS = [
    {"id": "flux-dev", "name": "FLUX.1 dev", "kind": "image",
     "summary": "Лучшее качество и фотореализм.",
     "files": ["checkpoints/flux1-dev-fp8.safetensors"]},
    {"id": "flux-schnell", "name": "FLUX.1 schnell", "kind": "image",
     "summary": "Быстрая версия FLUX: картинка за несколько секунд.",
     "files": ["checkpoints/flux1-schnell-fp8.safetensors"]},
    {"id": "sdxl", "name": "SDXL", "kind": "image",
     "summary": "Лёгкая и быстрая, понимает описания стилей.",
     "files": ["checkpoints/sd_xl_base_1.0.safetensors"]},
    {"id": "wan22", "name": "Wan 2.2", "kind": "video",
     "summary": "Видео по описанию, сильный фотореализм. Ролик считается несколько минут.",
     "files": ["diffusion_models/wan2.2_ti2v_5B_fp16.safetensors",
               "text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
               "vae/wan2.2_vae.safetensors"]},
    {"id": "ace-step", "name": "ACE-Step", "kind": "music",
     "summary": "Песни с вокалом по описанию стиля и тексту.",
     "files": ["checkpoints/ace_step_v1_3.5b.safetensors"]},
]


def media_available(model):
    return all((COMFY_DIR / "models" / f).exists() for f in model["files"])


def describe_text_model(tag):
    for entry in TEXT_MODELS:
        if tag.startswith(entry["match"]):
            return {
                "id": tag,
                "name": entry["name"],
                "category": entry["category"],
                "summary": entry["summary"],
                "uncensored": entry.get("uncensored", False),
            }
    return {"id": tag, "name": tag, "category": "text", "summary": "Модель с сервера.", "uncensored": False}


# ---------------------------------------------------------------------------
# ComfyUI workflows
# ---------------------------------------------------------------------------

def image_workflow(model_id, prompt, negative, width, height, seed):
    ckpt = {
        "flux-dev": "flux1-dev-fp8.safetensors",
        "flux-schnell": "flux1-schnell-fp8.safetensors",
        "sdxl": "sd_xl_base_1.0.safetensors",
    }[model_id]
    flux = model_id.startswith("flux")
    steps = {"flux-dev": 20, "flux-schnell": 4, "sdxl": 30}[model_id]
    wf = {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["1", 1]}},
        "4": {"class_type": "EmptySD3LatentImage" if flux else "EmptyLatentImage",
              "inputs": {"width": width, "height": height, "batch_size": 1}},
        "5": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": steps, "cfg": 1.0 if flux else 7.0,
            "sampler_name": "euler" if flux else "dpmpp_2m",
            "scheduler": "simple" if flux else "karras",
            "denoise": 1.0, "model": ["1", 0],
            "positive": ["8", 0] if model_id == "flux-dev" else ["2", 0],
            "negative": ["3", 0], "latent_image": ["4", 0]}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"filename_prefix": "pocketai/image", "images": ["6", 0]}},
    }
    if model_id == "flux-dev":
        wf["8"] = {"class_type": "FluxGuidance", "inputs": {"guidance": 3.5, "conditioning": ["2", 0]}}
    return wf


def video_workflow(prompt, negative, width, height, seconds, seed):
    frames = {2: 49, 3: 73, 5: 121}.get(seconds, 73)
    return {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": "wan2.2_ti2v_5B_fp16.safetensors", "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": "umt5_xxl_fp8_e4m3fn_scaled.safetensors", "type": "wan", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": "wan2.2_vae.safetensors"}},
        "4": {"class_type": "ModelSamplingSD3", "inputs": {"shift": 8.0, "model": ["1", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["2", 0]}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
        "7": {"class_type": "Wan22ImageToVideoLatent", "inputs": {
            "vae": ["3", 0], "width": width, "height": height, "length": frames, "batch_size": 1}},
        "8": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": 30, "cfg": 5.0, "sampler_name": "uni_pc", "scheduler": "simple",
            "denoise": 1.0, "model": ["4", 0], "positive": ["5", 0], "negative": ["6", 0],
            "latent_image": ["7", 0]}},
        "9": {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["3", 0]}},
        "10": {"class_type": "CreateVideo", "inputs": {"images": ["9", 0], "fps": 24}},
        "11": {"class_type": "SaveVideo", "inputs": {
            "video": ["10", 0], "filename_prefix": "pocketai/video", "format": "auto", "codec": "auto"}},
    }


def music_workflow(tags, lyrics, seconds, seed):
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "ace_step_v1_3.5b.safetensors"}},
        "2": {"class_type": "TextEncodeAceStepAudio", "inputs": {
            "clip": ["1", 1], "tags": tags, "lyrics": lyrics, "lyrics_strength": 0.99}},
        "3": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["2", 0]}},
        "4": {"class_type": "EmptyAceStepLatentAudio", "inputs": {"seconds": seconds, "batch_size": 1}},
        "5": {"class_type": "ModelSamplingSD3", "inputs": {"shift": 5.0, "model": ["1", 0]}},
        "6": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": 50, "cfg": 5.0, "sampler_name": "euler", "scheduler": "simple",
            "denoise": 1.0, "model": ["5", 0], "positive": ["2", 0], "negative": ["3", 0],
            "latent_image": ["4", 0]}},
        "7": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["6", 0], "vae": ["1", 2]}},
        "8": {"class_type": "SaveAudio", "inputs": {"audio": ["7", 0], "filename_prefix": "pocketai/music"}},
    }


DEFAULT_NEGATIVE = "low quality, blurry, distorted, watermark, text artifacts, deformed"

# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

jobs = {}          # job id -> job dict
prompt_to_job = {}  # ComfyUI prompt id -> job id


def save_jobs():
    try:
        JOBS_FILE.write_text(json.dumps(list(jobs.values()), ensure_ascii=False))
    except OSError:
        pass


def load_jobs():
    if not JOBS_FILE.exists():
        return
    try:
        for job in json.loads(JOBS_FILE.read_text()):
            # Anything unfinished was lost when the server restarted.
            if job["status"] in ("queued", "running"):
                job["status"] = "failed"
                job["error"] = "Сервер перезапускался, задача прервана."
            jobs[job["id"]] = job
    except (OSError, ValueError, KeyError):
        pass


def public_job(job):
    return {k: v for k, v in job.items() if k != "prompt_id"}


async def notify(title, message):
    """Push notification through ntfy (JSON form keeps Cyrillic intact). Never includes the prompt."""
    if not NTFY_TOPIC:
        return
    try:
        async with ClientSession(timeout=ClientTimeout(total=10)) as session:
            await session.post("https://ntfy.sh/", json={
                "topic": NTFY_TOPIC, "title": title, "message": message, "tags": ["sparkles"],
            })
    except Exception:
        pass


KIND_DONE = {"image": "Картинка готова", "video": "Видео готово", "music": "Музыка готова"}


async def finish_job(job, outputs=None, error=None):
    job["finished"] = time.time()
    if error:
        job["status"] = "failed"
        job["error"] = error
        await notify("Pocket AI", "Не получилось создать: " + error[:200])
    else:
        job["status"] = "done"
        job["progress"] = 1.0
        job["outputs"] = outputs or []
        await notify("Pocket AI", KIND_DONE.get(job["kind"], "Готово") + ". Откройте приложение.")
    save_jobs()


def collect_outputs(history_entry):
    files = []
    for node_output in history_entry.get("outputs", {}).values():
        for value in node_output.values():
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, dict) and "filename" in item and item.get("type", "output") == "output":
                        files.append({"filename": item["filename"], "subfolder": item.get("subfolder", "")})
    return files


async def watch_comfy(app):
    """Follows ComfyUI progress over its websocket and finishes jobs when their prompt completes."""
    while True:
        try:
            async with ClientSession() as session:
                async with session.ws_connect(f"{COMFY}/ws?clientId={CLIENT_ID}", heartbeat=30) as ws:
                    async for msg in ws:
                        if msg.type != WSMsgType.TEXT:
                            continue
                        event = json.loads(msg.data)
                        data = event.get("data", {})
                        job = jobs.get(prompt_to_job.get(data.get("prompt_id", "")))
                        if not job:
                            continue
                        kind = event.get("type")
                        if kind == "execution_start":
                            job["status"] = "running"
                        elif kind == "progress" and data.get("max"):
                            job["status"] = "running"
                            job["progress"] = round(min(0.99, data["value"] / data["max"]), 3)
                        elif kind == "execution_error":
                            await finish_job(job, error=str(data.get("exception_message", "ошибка ComfyUI"))[:500])
                        elif kind == "execution_success" or (kind == "executing" and data.get("node") is None):
                            await complete_from_history(session, job)
        except Exception:
            await asyncio.sleep(3)


async def complete_from_history(session, job):
    if job["status"] in ("done", "failed"):
        return
    async with session.get(f"{COMFY}/history/{job['prompt_id']}") as response:
        history = await response.json()
    entry = history.get(job["prompt_id"])
    if not entry:
        return
    outputs = collect_outputs(entry)
    if outputs:
        await finish_job(job, outputs=outputs)
    else:
        await finish_job(job, error="ComfyUI не вернул файл.")


async def poll_unfinished(app):
    """Safety net in case a websocket event was missed."""
    while True:
        await asyncio.sleep(15)
        pending = [j for j in jobs.values() if j["status"] in ("queued", "running") and j.get("prompt_id")]
        if not pending:
            continue
        try:
            async with ClientSession(timeout=ClientTimeout(total=20)) as session:
                for job in pending:
                    await complete_from_history(session, job)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# GPU memory: text models and media models share one graphics card
# ---------------------------------------------------------------------------

async def unload_text_models():
    try:
        async with ClientSession(timeout=ClientTimeout(total=30)) as session:
            async with session.get(f"{OLLAMA}/api/ps") as response:
                running = (await response.json()).get("models", [])
            for model in running:
                await session.post(f"{OLLAMA}/api/generate", json={"model": model["name"], "keep_alive": 0})
    except Exception:
        pass


async def free_media_memory():
    if any(j["status"] in ("queued", "running") for j in jobs.values()):
        return
    try:
        async with ClientSession(timeout=ClientTimeout(total=15)) as session:
            await session.post(f"{COMFY}/free", json={"unload_models": True, "free_memory": True})
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Saving money: the pod switches itself off after a period without use
# ---------------------------------------------------------------------------

last_activity = time.time()
active_chats = 0
DEFAULT_IDLE_MINUTES = 10


def idle_minutes():
    """Minutes without use before the pod stops itself; 0 means never."""
    try:
        return max(0, int(IDLE_FILE.read_text().strip()))
    except (OSError, ValueError):
        return DEFAULT_IDLE_MINUTES


def touch():
    global last_activity
    last_activity = time.time()


async def stop_pod(reason):
    """Stops this RunPod pod. Pods come with runpodctl and a pod-scoped key, so no account key is needed."""
    pod = os.environ.get("RUNPOD_POD_ID", "")
    if not pod:
        return False
    await notify("Pocket AI", reason)
    for command in (["runpodctl", "pod", "stop", pod], ["runpodctl", "stop", "pod", pod]):
        try:
            process = await asyncio.create_subprocess_exec(
                *command, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            if await process.wait() == 0:
                return True
        except FileNotFoundError:
            return False
    return False


async def watch_idle(app):
    while True:
        await asyncio.sleep(60)
        limit = idle_minutes()
        busy = active_chats > 0 or any(j["status"] in ("queued", "running") for j in jobs.values())
        if busy:
            touch()
            continue
        if limit and time.time() - last_activity > limit * 60:
            if await stop_pod(f"Сервер выключен: им не пользовались {limit} мин. Деньги за работу больше не списываются."):
                return
            touch()  # Stop failed; try again after another idle period.


# ---------------------------------------------------------------------------
# Prompt translation: image, video and music models understand English best
# ---------------------------------------------------------------------------

# The small model loads in seconds; the big ones are only a fallback.
TRANSLATORS = ["qwen3:4b", "gemma4", "gemma3:27b", "qwen3.6", "qwen3:32b", "gpt-oss"]


def has_cyrillic(text):
    return any("а" <= ch.lower() <= "я" or ch.lower() == "ё" for ch in text)


async def translate(text, purpose):
    """Translates a Russian description into English with an installed text model; returns the original on failure."""
    if not text or not has_cyrillic(text):
        return text
    try:
        async with ClientSession(timeout=ClientTimeout(total=120)) as session:
            async with session.get(f"{OLLAMA}/api/tags") as response:
                installed = [m["name"] for m in (await response.json()).get("models", [])]
            model = next((name for prefix in TRANSLATORS for name in installed if name.startswith(prefix)), None)
            if not model:
                return text
            payload = {
                "model": model,
                "stream": False,
                "think": False,
                "keep_alive": 0,
                "messages": [
                    {"role": "system", "content":
                        f"Translate the user's text into English as a {purpose}. "
                        "Keep every detail. Reply with the translation only, without quotes or comments."},
                    {"role": "user", "content": text},
                ],
            }
            async with session.post(f"{OLLAMA}/api/chat", json=payload) as response:
                if response.status != 200:
                    payload.pop("think")
                    async with session.post(f"{OLLAMA}/api/chat", json=payload) as retry:
                        result = await retry.json()
                else:
                    result = await response.json()
        answer = result.get("message", {}).get("content", "").strip()
        if "</think>" in answer:
            answer = answer.split("</think>", 1)[1].strip()
        return answer.strip('"').strip() or text
    except Exception:
        return text


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------

@web.middleware
async def auth(request, handler):
    if request.path == "/api/ping":
        return await handler(request)
    header = request.headers.get("Authorization", "")
    key = header[7:] if header.startswith("Bearer ") else request.query.get("key", "")
    if key != PASSWORD:
        return web.json_response({"error": "Неверный пароль"}, status=401)
    touch()
    return await handler(request)


async def ping(request):
    return web.json_response({"ok": True})


def gpu_name():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return out.splitlines()[0] if out else ""
    except Exception:
        return ""


async def health(request):
    return web.json_response({"ok": True, "gpu": gpu_name(), "ntfyTopic": NTFY_TOPIC})


async def models(request):
    text = []
    try:
        async with ClientSession(timeout=ClientTimeout(total=10)) as session:
            async with session.get(f"{OLLAMA}/api/tags") as response:
                for model in (await response.json()).get("models", []):
                    text.append(describe_text_model(model["name"]))
    except Exception:
        pass
    order = {e["match"]: i for i, e in enumerate(TEXT_MODELS)}
    text.sort(key=lambda m: next((v for k, v in order.items() if m["id"].startswith(k)), 99))
    media = [
        {"id": m["id"], "name": m["name"], "kind": m["kind"], "summary": m["summary"]}
        for m in MEDIA_MODELS if media_available(m)
    ]
    return web.json_response({"text": text, "media": media})


async def chat(request):
    """Streams an Ollama chat answer back to the app as newline-separated JSON."""
    global active_chats
    active_chats += 1
    try:
        return await stream_chat(request)
    finally:
        active_chats -= 1
        touch()


async def stream_chat(request):
    body = await request.json()
    await free_media_memory()
    payload = {
        "model": body["model"],
        "messages": body["messages"],
        "stream": True,
        "options": body.get("options", {}),
    }
    if "think" in body:
        payload["think"] = body["think"]

    response = web.StreamResponse(headers={"Content-Type": "application/x-ndjson", "Cache-Control": "no-cache"})
    await response.prepare(request)

    lock = asyncio.Lock()
    last_write = time.time()

    async def write(data):
        nonlocal last_write
        async with lock:
            await response.write(data)
            last_write = time.time()

    async def heartbeat():
        # RunPod's proxy drops a connection that stays silent for long; a model can take
        # a minute or two to load, so an empty line is sent every few seconds meanwhile.
        while True:
            await asyncio.sleep(5)
            if time.time() - last_write >= 5:
                await write(b"\n")

    if not await model_loaded(payload["model"]):
        await write((json.dumps({"status": "loading"}) + "\n").encode())
    beat = asyncio.create_task(heartbeat())
    try:
        async with ClientSession(timeout=ClientTimeout(total=None, sock_read=900)) as session:
            async with session.post(f"{OLLAMA}/api/chat", json=payload) as upstream:
                if upstream.status != 200:
                    text = await upstream.text()
                    # Models without thinking reject the "think" option; retry without it.
                    if "think" in payload and "think" in text.lower():
                        payload.pop("think")
                        async with session.post(f"{OLLAMA}/api/chat", json=payload) as retry:
                            async for line in retry.content:
                                await write(line)
                    else:
                        await write((json.dumps({"error": text[:500]}) + "\n").encode())
                else:
                    async for line in upstream.content:
                        await write(line)
    except (ConnectionResetError, asyncio.CancelledError):
        raise
    except Exception as error:
        await write((json.dumps({"error": str(error)[:300]}) + "\n").encode())
    finally:
        beat.cancel()
    await response.write_eof()
    return response


async def model_loaded(name):
    try:
        async with ClientSession(timeout=ClientTimeout(total=5)) as session:
            async with session.get(f"{OLLAMA}/api/ps") as response:
                return any(m.get("name") == name for m in (await response.json()).get("models", []))
    except Exception:
        return False


async def create_job(request):
    """Registers the job and answers at once; translation and ComfyUI submission run in the background."""
    body = await request.json()
    kind = body.get("kind")
    model_id = body.get("model")
    model = next((m for m in MEDIA_MODELS if m["id"] == model_id and m["kind"] == kind), None)
    if not model or not media_available(model):
        return web.json_response({"error": "Эта модель не установлена на сервере."}, status=400)
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        return web.json_response({"error": "Опишите, что нужно создать."}, status=400)

    job = {
        "id": uuid.uuid4().hex[:12],
        "kind": kind,
        "model": model_id,
        "modelName": model["name"],
        "prompt": prompt,
        "status": "queued",
        "progress": 0.0,
        "created": time.time(),
        "finished": None,
        "outputs": [],
        "error": None,
        "prompt_id": None,
    }
    jobs[job["id"]] = job
    save_jobs()
    asyncio.create_task(submit_job(job, body))
    return web.json_response(public_job(job))


async def submit_job(job, body):
    kind, model_id, prompt = job["kind"], job["model"], job["prompt"]
    try:
        seed = int(body.get("seed") or random.randint(1, 2**31 - 1))
        if kind == "image":
            english = await translate(prompt, "detailed prompt for an image generation model")
            width, height = int(body.get("width", 1024)), int(body.get("height", 1024))
            workflow = image_workflow(model_id, english, body.get("negative") or DEFAULT_NEGATIVE, width, height, seed)
        elif kind == "video":
            english = await translate(prompt, "detailed prompt for a video generation model")
            width, height = int(body.get("width", 1280)), int(body.get("height", 704))
            workflow = video_workflow(english, body.get("negative") or DEFAULT_NEGATIVE, width, height,
                                      int(body.get("seconds", 3)), seed)
        else:
            english = await translate(prompt, "comma-separated list of music style tags (genre, mood, instruments, vocals)")
            workflow = music_workflow(english, body.get("lyrics") or "[instrumental]", int(body.get("seconds", 60)), seed)

        await unload_text_models()
        result, status = None, 0
        for attempt in range(12):  # ComfyUI may still be starting right after the pod boots
            try:
                async with ClientSession(timeout=ClientTimeout(total=60)) as session:
                    async with session.post(f"{COMFY}/prompt", json={"prompt": workflow, "client_id": CLIENT_ID}) as response:
                        result = await response.json(content_type=None)
                        status = response.status
                break
            except Exception:
                await asyncio.sleep(10)
        if result is None:
            await finish_job(job, error="ComfyUI не запустился. Выполните на сервере: bash /workspace/ai-server/start.sh")
            return
        if status != 200 or "prompt_id" not in result:
            detail = result.get("error", {}).get("message") if isinstance(result.get("error"), dict) else None
            errors = result.get("node_errors")
            message = detail or "ComfyUI отклонил задачу"
            if errors:
                message += ": " + json.dumps(errors, ensure_ascii=False)[:400]
            await finish_job(job, error=message)
            return
        job["prompt_id"] = result["prompt_id"]
        prompt_to_job[result["prompt_id"]] = job["id"]
        save_jobs()
    except Exception as error:
        await finish_job(job, error=f"Ошибка на сервере: {error}"[:500])


async def list_jobs(request):
    ordered = sorted(jobs.values(), key=lambda j: j["created"], reverse=True)[:100]
    return web.json_response([public_job(j) for j in ordered])


async def delete_job(request):
    job = jobs.pop(request.match_info["job_id"], None)
    if job and job["status"] in ("queued", "running"):
        try:
            async with ClientSession(timeout=ClientTimeout(total=10)) as session:
                await session.post(f"{COMFY}/queue", json={"delete": [job.get("prompt_id")]})
                await session.post(f"{COMFY}/interrupt")
        except Exception:
            pass
    save_jobs()
    return web.json_response({"ok": True})


async def job_file(request):
    job = jobs.get(request.match_info["job_id"])
    index = int(request.match_info["index"])
    if not job or index >= len(job.get("outputs", [])):
        return web.json_response({"error": "Файл не найден"}, status=404)
    item = job["outputs"][index]
    base = (COMFY_DIR / "output").resolve()
    path = (base / item["subfolder"] / item["filename"]).resolve()
    if base not in path.parents or not path.exists():
        return web.json_response({"error": "Файл не найден"}, status=404)
    return web.FileResponse(path)


async def get_settings(request):
    return web.json_response({"idleMinutes": idle_minutes()})


async def set_settings(request):
    body = await request.json()
    if "idleMinutes" in body:
        IDLE_FILE.write_text(str(max(0, int(body["idleMinutes"]))))
    return web.json_response({"idleMinutes": idle_minutes()})


async def shutdown(request):
    """Switches the pod off at the user's request (the "Выключить" button in the app)."""
    if not os.environ.get("RUNPOD_POD_ID"):
        return web.json_response({"error": "Выключение работает только на RunPod."}, status=400)

    async def later():
        await asyncio.sleep(2)  # let the answer reach the phone first
        await stop_pod("Сервер выключен из приложения.")

    asyncio.create_task(later())
    return web.json_response({"ok": True})


async def on_startup(app):
    load_jobs()
    app["watchers"] = [
        asyncio.create_task(watch_comfy(app)),
        asyncio.create_task(poll_unfinished(app)),
        asyncio.create_task(watch_idle(app)),
    ]


def main():
    app = web.Application(middlewares=[auth], client_max_size=64 * 1024 * 1024)
    app.router.add_get("/api/ping", ping)
    app.router.add_get("/api/health", health)
    app.router.add_get("/api/models", models)
    app.router.add_post("/api/chat", chat)
    app.router.add_get("/api/jobs", list_jobs)
    app.router.add_post("/api/jobs", create_job)
    app.router.add_delete("/api/jobs/{job_id}", delete_job)
    app.router.add_get("/api/jobs/{job_id}/files/{index}", job_file)
    app.router.add_get("/api/settings", get_settings)
    app.router.add_post("/api/settings", set_settings)
    app.router.add_post("/api/shutdown", shutdown)
    app.on_startup.append(on_startup)
    web.run_app(app, host="0.0.0.0", port=8080, print=None)


if __name__ == "__main__":
    main()
