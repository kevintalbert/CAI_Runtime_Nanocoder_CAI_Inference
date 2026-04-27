#!/usr/bin/env bash
# /etc/profile.d/nanocoder-local-llm.sh
#
# Sourced automatically on every interactive terminal in JupyterLab.
# Configures [Nanocoder](https://docs.nanocollective.org/nanocoder/docs/v1.25.2)
# to use llama-server (OpenAI-compatible /v1) on localhost.
#
# Helper commands:
#   nano-start    — download GGUF (if needed) and start llama-server in background
#   nano-status   — is the server up?
#   nano-wait     — block until server ready, then print how to run Nanocoder
#   nano-logs     — tail llama-server output
#   nano-restart  — kill and restart llama-server
#   nano-stop     — kill llama-server

# Only run in interactive shells
[[ $- != *i* ]] && return

# ── Resolve config (env vars always win) ──────────────────────────────────
_LLAMA_PORT="${LLAMA_SERVER_PORT:-8001}"
_MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.5-35B-A3B-GGUF}"
_MODEL_INCLUDE="${MODEL_INCLUDE:-*UD-Q4_K_XL*}"
_MODEL_ALIAS="${MODEL_ALIAS:-unsloth/Qwen3.5-35B-A3B}"
_MODEL_DIR="${MODEL_DIR:-/home/cdsw/models}"
_CTX_SIZE="${CTX_SIZE:-65536}"
_TEMP="${TEMPERATURE:-0.6}"
_TOP_P="${TOP_P:-0.95}"
_TOP_K="${TOP_K:-20}"

_LLAMA_PID_FILE="/tmp/llama-server.pid"
_LLAMA_LOG_FILE="/tmp/llama-server.log"
_DOWNLOAD_LOG_FILE="/tmp/llama-model-download.log"
_NANOCODER_CONFIG_DIR="${NANOCODER_CONFIG_DIR:-$HOME/.config/nanocoder}"

# ── Internal helpers ───────────────────────────────────────────────────────

_nano_write_config() {
    mkdir -p "$_NANOCODER_CONFIG_DIR"
    # Per https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/
    # and providers/llama-cpp — OpenAI-compatible baseUrl must include /v1
    cat > "$_NANOCODER_CONFIG_DIR/agents.config.json" <<EOF
{
  "nanocoder": {
    "providers": [
      {
        "name": "llama.cpp (local)",
        "baseUrl": "http://127.0.0.1:${_LLAMA_PORT}/v1",
        "models": ["${_MODEL_ALIAS}"],
        "requestTimeout": -1,
        "socketTimeout": -1,
        "connectionPool": {
          "idleTimeout": 30000,
          "cumulativeMaxIdleTimeout": 3600000
        }
      }
    ]
  }
}
EOF
}

_gpu_available() {
    command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null
}

_llama_is_running() {
    if [[ -f "$_LLAMA_PID_FILE" ]]; then
        local pid
        pid=$(cat "$_LLAMA_PID_FILE" 2>/dev/null)
        kill -0 "$pid" 2>/dev/null && return 0
    fi
    curl -sf "http://localhost:${_LLAMA_PORT}/health" > /dev/null 2>&1
}

_find_model_file() {
    local repo_name
    repo_name=$(basename "$_MODEL_REPO")
    find "${_MODEL_DIR}/${repo_name}" -name "*.gguf" 2>/dev/null | head -1
}

_start_llama_server() {
    local model_file="$1"
    LLAMA_ARG_CHAT_TEMPLATE_KWARGS='{"enable_thinking": false}' \
    nohup llama-server \
        --model          "$model_file" \
        --alias          "$_MODEL_ALIAS" \
        --temp           "$_TEMP" \
        --top-p          "$_TOP_P" \
        --top-k          "$_TOP_K" \
        --min-p          0.00 \
        --port           "$_LLAMA_PORT" \
        --host           127.0.0.1 \
        --n-gpu-layers   -1 \
        --kv-unified \
        --cache-type-k   q8_0 \
        --cache-type-v   q8_0 \
        --flash-attn     on \
        --fit            on \
        --ctx-size       "$_CTX_SIZE" \
        --chat-template-kwargs '{"enable_thinking": false}' \
        > "$_LLAMA_LOG_FILE" 2>&1 &
    echo $! > "$_LLAMA_PID_FILE"
}

_download_model_then_start() {
    (
        HF_HUB_ENABLE_HF_TRANSFER=1 python3 - <<PYEOF >> "$_DOWNLOAD_LOG_FILE" 2>&1
import os, sys
os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
from huggingface_hub import snapshot_download
import pathlib

repo   = "${_MODEL_REPO}"
target = pathlib.Path("${_MODEL_DIR}") / repo.split("/")[-1]
target.mkdir(parents=True, exist_ok=True)

print(f"Downloading {repo} ...", flush=True)
snapshot_download(
    repo_id       = repo,
    local_dir     = str(target),
    allow_patterns= ["${_MODEL_INCLUDE}"],
    $( [[ -n "${HF_TOKEN}" ]] && echo 'token="${HF_TOKEN}",' )
)
print("Download complete.", flush=True)
PYEOF
        local mf
        mf=$(_find_model_file)
        if [[ -n "$mf" ]]; then
            _start_llama_server "$mf"
            echo "[$(date)] llama-server started: $mf" >> "$_DOWNLOAD_LOG_FILE"
        else
            echo "[$(date)] ERROR: no .gguf found after download" >> "$_DOWNLOAD_LOG_FILE"
        fi
    ) &
}

# ── Banner on terminal open ────────────────────────────────────────────────

_nano_startup() {
    _nano_write_config
    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    export NANOCODER_CONFIG_DIR="$_NANOCODER_CONFIG_DIR"
    export NANOCODER_CONTEXT_LIMIT="${NANOCODER_CONTEXT_LIMIT:-$_CTX_SIZE}"

    echo ""
    echo "┌─ Nanocoder + $(basename $_MODEL_REPO) ───────────────────────────────┐"

    if _llama_is_running; then
        echo "│  ✓ llama-server on port ${_LLAMA_PORT} (OpenAI-compatible /v1)"
        echo "│  ✓ Run: nanocoder   then /model ${_MODEL_ALIAS}"
    elif ! _gpu_available; then
        echo "│  ✗ No GPU — assign a GPU, then run 'nano-start'"
    else
        echo "│  ✓ GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
        echo "│  ○ llama-server not running — run 'nano-start'"
    fi

    echo "│"
    echo "│  Docs: https://docs.nanocollective.org/nanocoder/docs/v1.25.2"
    echo "│  Commands: nano-start  nano-status  nano-wait  nano-logs  nano-restart  nano-stop"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""
}

# ── nano-start ───────────────────────────────────────────────────────────────

nano-start() {
    if ! _gpu_available; then
        echo "✗ No NVIDIA GPU detected — nano-start requires a GPU."
        echo "  Assign a GPU resource to this CML session and restart."
        return 1
    fi
    echo "✓ GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

    _nano_write_config

    if _llama_is_running; then
        echo "✓ llama-server already on port ${_LLAMA_PORT}"
        echo "  Run: nanocoder"
        return 0
    fi

    local model_file
    model_file=$(_find_model_file)

    if [[ -n "$model_file" ]]; then
        echo "✓ Model: $(basename "$model_file")"
        _start_llama_server "$model_file"
        echo "↻ llama-server starting (pid $(cat $_LLAMA_PID_FILE))"
        echo "  Run 'nano-wait' then 'nanocoder'"
    else
        echo "↓ Model not cached — downloading in background ..."
        echo "  Watch: tail -f ${_DOWNLOAD_LOG_FILE}"
        _download_model_then_start
    fi
}

nano-status() {
    if _llama_is_running; then
        echo "✓ llama-server on port ${_LLAMA_PORT}"
        echo "  Config: ${_NANOCODER_CONFIG_DIR}/agents.config.json"
        echo "  Run: nanocoder"
    else
        echo "✗ llama-server is not running"
        [[ -f "$_DOWNLOAD_LOG_FILE" ]] && echo "  Download log: tail -1 → $(tail -1 $_DOWNLOAD_LOG_FILE)"
        echo "  Logs: tail -f ${_DOWNLOAD_LOG_FILE}  |  ${_LLAMA_LOG_FILE}"
    fi
}

nano-wait() {
    echo "Waiting for llama-server ..."
    local i=0
    while (( i < 600 )); do
        if _llama_is_running; then
            echo "✓ Ready. Run: nanocoder"
            echo "  In Nanocoder: /model ${_MODEL_ALIAS}  (provider: llama.cpp local)"
            return 0
        fi
        sleep 2
        (( i += 2 ))
        (( i % 30 == 0 )) && echo "  Still waiting ... (${i}s)"
    done
    echo "✗ llama-server did not become ready within 600s"
    return 1
}

nano-logs() {
    tail -f "${_LLAMA_LOG_FILE}"
}

nano-stop() {
    if [[ -f "$_LLAMA_PID_FILE" ]]; then
        local pid
        pid=$(cat "$_LLAMA_PID_FILE")
        kill "$pid" 2>/dev/null && echo "Stopped llama-server (pid $pid)"
        rm -f "$_LLAMA_PID_FILE"
    else
        echo "No llama-server pid file."
    fi
}

nano-restart() {
    nano-stop
    sleep 1
    local model_file
    model_file=$(_find_model_file)
    if [[ -z "$model_file" ]]; then
        echo "No .gguf in ${_MODEL_DIR}. Run nano-start or check download."
        return 1
    fi
    _start_llama_server "$model_file"
    echo "↻ llama-server restarted (pid $(cat $_LLAMA_PID_FILE))"
}

_nano_startup
