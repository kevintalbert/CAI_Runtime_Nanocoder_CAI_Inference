#!/usr/bin/env bash
# /etc/profile.d/nanocoder-local-llm.sh
#
# Sourced automatically on every interactive terminal in JupyterLab.
# Configures [Nanocoder](https://docs.nanocollective.org/nanocoder/docs/v1.25.2):
#   • Optional CAI Inference (OpenAI-compatible) when CAI_INFERENCE_BASE_URL is set
#   • Local llama-server on localhost when you run nano-start on a GPU session
#
# Helper commands:
#   nano-refresh-config — re-source session.env, re-read env, rewrite agents.config.json
#   nano-start    — download GGUF (if needed) and start llama-server in background
#   nano-status   — is the server up?
#   nano-wait     — block until server ready, then print how to run Nanocoder
#   nano-logs     — tail llama-server output
#   nano-restart  — kill and restart llama-server
#   nano-stop     — kill llama-server
#
# Session env (optional): set NANOCODER_SESSION_ENV_FILE to a path, or create
#   ~/.config/nanocoder/session.env with export KEY=value lines. Sourced on each
#   interactive shell (set -a) before agents.config.json is written.

# Only run in interactive shells
[[ $- != *i* ]] && return

# ── Internal helpers ───────────────────────────────────────────────────────

_nano_source_session_env() {
    local f="${NANOCODER_SESSION_ENV_FILE:-}"
    if [[ -n "$f" && -f "$f" ]]; then
        # shellcheck disable=SC1090
        set -a && source "$f" && set +a && return
    fi
    local def="${HOME}/.config/nanocoder/session.env"
    if [[ -f "$def" ]]; then
        # shellcheck disable=SC1090
        set -a && source "$def" && set +a
    fi
}

_nano_reload_runtime_env() {
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
}

_nano_set_disable_tools_line() {
    case "${NANOCODER_DISABLE_TOOLS:-}" in
        1|true|TRUE|yes|YES|on|ON)
            _NANO_DT_LINE=$',\n        "disableTools": true'
            ;;
        *)
            _NANO_DT_LINE=''
            ;;
    esac
}

_nano_source_session_env
_nano_reload_runtime_env

_nano_refresh_cai_env() {
    _CAI_BASE="${CAI_INFERENCE_BASE_URL:-}"
    _CAI_MODEL="${CAI_INFERENCE_MODEL:-qwen-code}"
}

_hosted_inference_configured() {
    [[ -n "${CAI_INFERENCE_BASE_URL:-}" ]]
}

_nano_write_config() {
    _nano_reload_runtime_env
    _nano_refresh_cai_env
    _nano_set_disable_tools_line
    mkdir -p "$_NANOCODER_CONFIG_DIR"
    # Nanocoder substitutes ${VAR} in config at load time (see project .env.example).
    # Local baseUrl: https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/providers/llama-cpp
    if _hosted_inference_configured; then
        cat > "$_NANOCODER_CONFIG_DIR/agents.config.json" <<EOF
{
  "nanocoder": {
    "providers": [
      {
        "name": "CAI Inference",
        "baseUrl": "${_CAI_BASE}",
        "apiKey": "\${CAI_INFERENCE_API_KEY:-}",
        "models": ["${_CAI_MODEL}"],
        "requestTimeout": -1,
        "socketTimeout": -1,
        "connectionPool": {
          "idleTimeout": 30000,
          "cumulativeMaxIdleTimeout": 3600000
        }${_NANO_DT_LINE}
      },
      {
        "name": "llama.cpp (local)",
        "baseUrl": "http://127.0.0.1:${_LLAMA_PORT}/v1",
        "models": ["${_MODEL_ALIAS}"],
        "requestTimeout": -1,
        "socketTimeout": -1,
        "connectionPool": {
          "idleTimeout": 30000,
          "cumulativeMaxIdleTimeout": 3600000
        }${_NANO_DT_LINE}
      }
    ]
  }
}
EOF
    else
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
        }${_NANO_DT_LINE}
      }
    ]
  }
}
EOF
    fi
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
        echo "│  ✓ Run: nanocoder   then /model ${_MODEL_ALIAS} (local)"
        if _hosted_inference_configured; then
            echo "│  ✓ CAI Inference also configured — /provider to switch"
        fi
    elif _hosted_inference_configured; then
        echo "│  ✓ CAI Inference (hosted) — model id: ${CAI_INFERENCE_MODEL:-qwen-code}"
        echo "│  ✓ Run: nanocoder  →  /provider  →  CAI Inference  →  /model ${CAI_INFERENCE_MODEL:-qwen-code}"
        echo "│    No GPU required for the hosted path."
        if _gpu_available; then
            echo "│  ○ Optional local GPU: run 'nano-start' for llama.cpp on this machine"
        fi
    elif ! _gpu_available; then
        echo "│  ✗ No GPU and CAI_INFERENCE_BASE_URL is not set."
        echo "│    Set CAI_INFERENCE_BASE_URL to your OpenAI-compatible endpoint, or assign a GPU."
    else
        echo "│  ✓ GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
        echo "│  ○ llama-server not running — run 'nano-start'"
    fi

    echo "│"
    echo "│  Docs: https://docs.nanocollective.org/nanocoder/docs/v1.25.2"
    echo "│  Commands: nano-refresh-config  nano-start  nano-status  nano-wait  nano-logs  nano-restart  nano-stop"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""
}

# ── nano-refresh-config ──────────────────────────────────────────────────────

nano-refresh-config() {
    _nano_source_session_env
    _nano_write_config
    echo "Updated ${_NANOCODER_CONFIG_DIR}/agents.config.json (from env + optional session.env)."
}

# ── nano-start ───────────────────────────────────────────────────────────────

nano-start() {
    _nano_refresh_cai_env
    if ! _gpu_available; then
        echo "✗ No NVIDIA GPU — local llama-server cannot use GPU offload here."
        if _hosted_inference_configured; then
            _nano_write_config
            echo "✓ CAI_INFERENCE_BASE_URL is set — use hosted inference (no local server)."
            echo "  Run: nanocoder  →  /provider  →  CAI Inference  →  /model ${CAI_INFERENCE_MODEL:-qwen-code}"
            return 0
        fi
        echo "  Set CAI_INFERENCE_BASE_URL for a hosted OpenAI-compatible endpoint, or assign a GPU."
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
    _nano_refresh_cai_env
    if _hosted_inference_configured; then
        echo "✓ CAI Inference baseUrl: ${CAI_INFERENCE_BASE_URL}"
        echo "  Model id (Nanocoder): ${CAI_INFERENCE_MODEL:-qwen-code}"
    fi
    if _llama_is_running; then
        echo "✓ llama-server on port ${_LLAMA_PORT}"
        echo "  Config: ${_NANOCODER_CONFIG_DIR}/agents.config.json"
        echo "  Run: nanocoder"
    else
        echo "✗ llama-server is not running"
        [[ -f "$_DOWNLOAD_LOG_FILE" ]] && echo "  Download log: tail -1 → $(tail -1 $_DOWNLOAD_LOG_FILE)"
        echo "  Logs: tail -f ${_DOWNLOAD_LOG_FILE}  |  ${_LLAMA_LOG_FILE}"
        _hosted_inference_configured || echo "  (No CAI_INFERENCE_BASE_URL — set it to use hosted inference without local llama.)"
    fi
}

nano-wait() {
    _nano_refresh_cai_env
    if _llama_is_running; then
        echo "✓ llama-server is ready. Run: nanocoder"
        echo "  Local model: /model ${_MODEL_ALIAS}"
        return 0
    fi
    if _hosted_inference_configured; then
        echo "✓ Hosted CAI Inference is configured (local llama not required)."
        echo "  Run: nanocoder  →  /provider  →  CAI Inference  →  /model ${CAI_INFERENCE_MODEL:-qwen-code}"
        return 0
    fi
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
    echo "  Tip: set CAI_INFERENCE_BASE_URL to use a hosted model without local llama."
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
    if ! _gpu_available; then
        echo "✗ nano-restart needs a GPU for local llama-server."
        _hosted_inference_configured && echo "  Hosted path: run nanocoder (CAI Inference provider)."
        return 1
    fi
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
