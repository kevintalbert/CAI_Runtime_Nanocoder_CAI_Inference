# CAI Community Runtime — Nanocoder with local Qwen via llama.cpp

Run [Nanocoder](https://docs.nanocollective.org/nanocoder/docs/v1.25.2) against a **local** OpenAI-compatible server inside a **Cloudera AI (CAI)** workspace. An open-weight model (Qwen3.5 by default) is served by [llama.cpp](https://github.com/ggml-org/llama.cpp) on the GPU; Nanocoder is configured with the [llama.cpp provider](https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/providers/llama-cpp) (`baseUrl` …`/v1`, `models` matching `--alias`). No cloud API key is required for that path.

---

## Using the pre-built image

After you publish an image built from this repo, register it in CAI (example tag shown for a 1.0.5 Nanocoder build):

```
<your-registry>/cai-nanocoder-qwen:1.0.5
```

### 1. Register the runtime in CAI

**Admin panel → Runtime Catalog → Add Runtime** and enter your image reference.

### 2. Start a session

Create a new CAI project, select this runtime, and assign a **GPU instance** (24 GB VRAM recommended — see [GPU requirements](#gpu-requirements)).

### 3. Open a terminal

```bash
nano-start    # first run: downloads the GGUF, then starts llama-server on GPU
nano-wait     # blocks until the server is ready
nanocoder     # local-first CLI; use /model with your MODEL_ALIAS if prompted
```

Nanocoder reads `~/.config/nanocoder/agents.config.json`, which the startup script regenerates each session so the **llama.cpp** provider points at `http://127.0.0.1:$LLAMA_SERVER_PORT/v1` and lists your `MODEL_ALIAS`.

---

## Helper commands

| Command | Description |
|--------|-------------|
| `nano-start` | Download model (if needed) and start llama-server in the background |
| `nano-wait` | Block until the server is ready |
| `nano-status` | Check if llama-server is running |
| `nano-logs` | Tail llama-server output |
| `nano-restart` | Kill and restart llama-server |
| `nano-stop` | Stop llama-server |

---

## Configuration

Environment variables can be set on the CAI project or session. The model cache lives under `/home/cdsw/models/` and persists across sessions.

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_REPO` | `unsloth/Qwen3.5-35B-A3B-GGUF` | HuggingFace repo to download |
| `MODEL_INCLUDE` | `*UD-Q4_K_XL*` | Glob to select the quantization file |
| `MODEL_ALIAS` | `unsloth/Qwen3.5-35B-A3B` | Must match llama-server `--alias` and Nanocoder `/model` name |
| `MODEL_DIR` | `/home/cdsw/models` | Local model cache directory |
| `CTX_SIZE` | `65536` | Passed to llama-server `--ctx-size` |
| `NANOCODER_CONTEXT_LIMIT` | *(from `CTX_SIZE` in shell)* | Helps Nanocoder auto-compact and `/usage`; see [configuration](https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/) |
| `NANOCODER_CONFIG_DIR` | `$HOME/.config/nanocoder` | Where `agents.config.json` is written |
| `TEMPERATURE` | `0.6` | Sampling temperature |
| `TOP_P` | `0.95` | Top-p sampling |
| `TOP_K` | `20` | Top-k sampling |
| `LLAMA_SERVER_PORT` | `8001` | llama-server listen port |
| `HF_TOKEN` | *(empty)* | HuggingFace token for gated models |

### Swapping models

Update `MODEL_REPO`, `MODEL_INCLUDE`, and `MODEL_ALIAS` together. Re-run `nano-start` (or `nano-restart` after a download). Any suitable GGUF layout under `MODEL_DIR` works.

### Advanced: provider overrides

Nanocoder supports `NANOCODER_PROVIDERS` / `NANOCODER_PROVIDERS_FILE` with **highest** precedence over `agents.config.json`; see [AI providers](https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/providers/).

---

## GPU requirements

`nano-start` refuses to run if no NVIDIA GPU is detected.

| GPU | VRAM | Notes |
|-----|------|--------|
| A10G, L4, RTX 4090 | 24 GB | Recommended for 35B-A3B at Q4_K_XL |
| A100-40, A100-80, H100 | 40–80 GB | More headroom for larger context |
| T4, V100-16 | 16 GB | Too small for 35B; use a smaller variant |

CUDA kernels in the image target: `sm_70` … `sm_90` (V100 through H100).

---

## Building the image

Docker Desktop needs ample disk (CUDA build is heavy).

```bash
docker build --pull --rm \
  -f Dockerfile \
  -t <your-registry>/cai-nanocoder-qwen:1.0.5 .
```

---

## Repository structure

```
Dockerfile          Multi-stage: CUDA llama.cpp → CAI runtime + Nanocoder (npm)
scripts/startup.sh  profile.d: Nanocoder agents.config.json + nano-* helpers
```

---

## License

MIT © 2026 Kevin Talbert
