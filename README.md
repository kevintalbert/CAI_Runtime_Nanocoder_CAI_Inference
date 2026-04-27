# CAI Community Runtime — Nanocoder with local Qwen via llama.cpp

Run [Nanocoder](https://docs.nanocollective.org/nanocoder/docs/v1.25.2) inside a **Cloudera AI (CAI)** workspace in either mode:

1. **Hosted CAI Inference** — OpenAI-compatible `baseUrl` (no GPU in the session). Set **`CAI_INFERENCE_BASE_URL`** and **`CAI_INFERENCE_API_KEY`** in CML/CAI project (or session) environment variables; see [Where to set the CAI Inference URL and token](#where-to-set-the-cai-inference-url-and-token). The image can ship a default URL in the Dockerfile; override there when your route differs.
2. **Local GPU** — [llama.cpp](https://github.com/ggml-org/llama.cpp) serves an open-weight GGUF on the GPU; Nanocoder uses the [llama.cpp provider](https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/providers/llama-cpp) (`baseUrl` …`/v1`, `models` matching `--alias`).

When both are configured, use **`/provider`** in Nanocoder to switch between **CAI Inference** and **llama.cpp (local)**.

---

## Using the pre-built image

After you publish an image built from this repo, register it in CAI (example tag shown for a 1.0.5 Nanocoder build):

```
<your-registry>/cai-nanocoder-qwen:1.0.1
```

For example, here is one already built:

```
kevintalbert/nanocoder:1.0.1
```

### 1. Register the runtime in CAI

**Admin panel → Runtime Catalog → Add Runtime** and enter your image reference.

### 2. Start a session

- **GPU + local model:** assign a **GPU** (24 GB VRAM recommended — see [GPU requirements](#gpu-requirements)).
- **CPU / no GPU:** leave GPU unassigned; ensure `CAI_INFERENCE_BASE_URL` is set (built-in default in the Dockerfile points at your CAI Inference OpenAI route unless you override it in CML).

### 3. Open a terminal

**Hosted inference only (no GPU):**

```bash
nano-wait     # succeeds immediately when CAI_INFERENCE_BASE_URL is set
nanocoder     # /provider → CAI Inference → /model with your CAI_INFERENCE_MODEL
```

**Local llama on GPU:**

```bash
nano-start    # first run: downloads the GGUF, then starts llama-server on GPU
nano-wait     # blocks until the local server is ready (or exits early if only hosted is configured)
nanocoder     # /provider → llama.cpp (local) → /model with your MODEL_ALIAS
```

Nanocoder reads `~/.config/nanocoder/agents.config.json`, regenerated each login. It includes **CAI Inference** when `CAI_INFERENCE_BASE_URL` is non-empty, and **llama.cpp (local)** when you use local inference.

---

## Helper commands

| Command | Description |
|--------|-------------|
| `nano-refresh-config` | Re-source optional `session.env`, re-read all env vars, rewrite `agents.config.json` (use after changing env in the same shell) |
| `nano-start` | Download model (if needed) and start llama-server in the background |
| `nano-wait` | Block until the server is ready |
| `nano-status` | Check if llama-server is running |
| `nano-logs` | Tail llama-server output |
| `nano-restart` | Kill and restart llama-server |
| `nano-stop` | Stop llama-server |

---

## Configuration

Environment variables can be set on the CAI project or session. The model cache lives under `/home/cdsw/models/` and persists across sessions.

### Where to set the CAI Inference URL and token

Use **Cloudera AI (CAI) / Cloudera Machine Learning (CML) environment variables** so every workbench session exports them before a terminal starts (and before `nanocoder` reads config).

1. **Project-level (recommended)**  
   Open your **project** → **Settings** (or **Project settings**) → **Environment variables** (the label may be **Environment**, **Variables**, or **Advanced** depending on your Cloudera version).  
   Add or edit:

   | Name | Purpose |
   |------|--------|
   | `CAI_INFERENCE_BASE_URL` | Full OpenAI-compatible base URL for your serving route, including the path through **`/v1`** (example shape: `https://…/namespaces/…/endpoints/…/openai/v1`). |
   | `CAI_INFERENCE_API_KEY` | API key, bearer token, or workload token required by that endpoint. Omit if the route allows unauthenticated calls from your network. |
   | `CAI_INFERENCE_MODEL` | *(Optional.)* Model id sent in chat requests; must match what the inference service expects (default in the image is `qwen-code`). |

   Save, then **start a new session** (or restart the workbench) so variables are picked up.

2. **Session or workspace overrides**  
   If your deployment supports **per-session** or **per-model** environment overrides, set the same variable names there; they typically override project defaults for that session only.

3. **Image defaults (URL only)**  
   This repo’s **`Dockerfile`** sets a default **`CAI_INFERENCE_BASE_URL`** (and **`CAI_INFERENCE_MODEL`**) via `ENV` so CPU-only sessions work out of the box when that URL is correct for your cluster. **Override in the project** when the hostname, namespace, endpoint name, or path changes. **Do not put secrets in the Dockerfile**; use **`CAI_INFERENCE_API_KEY`** only in CML/CAI project or session environment variables (or your org’s secret store if you later wire that into env at session start).

4. **How Nanocoder receives the token**  
   The **CAI Inference** provider’s `apiKey` in `agents.config.json` uses Nanocoder’s [environment substitution](https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/) so the literal **`${CAI_INFERENCE_API_KEY:-}`** is resolved when Nanocoder runs. You do **not** need to edit `agents.config.json` by hand for normal use.

5. **Regenerating `agents.config.json` from the session environment**  
   On **every new interactive terminal**, `scripts/startup.sh` (installed as `/etc/profile.d/nanocoder-local-llm.sh`) runs in this order:
   - **Optional file:** If **`NANOCODER_SESSION_ENV_FILE`** points to an existing file, it is **`source`d** with **`set -a`** so variables are **exported**. Otherwise, if **`~/.config/nanocoder/session.env`** exists, that file is sourced the same way. Use standard shell lines such as `export CAI_INFERENCE_API_KEY=…`.
   - **Process environment:** Variables already injected by CAI/CML (project or session **Environment variables**) are read as usual; the script then copies the current values of `CAI_*`, `MODEL_*`, etc. into **`~/.config/nanocoder/agents.config.json`** (or **`$NANOCODER_CONFIG_DIR/agents.config.json`**).
   - **`nano-refresh-config`:** Run this in an **already-open** terminal after you change project/session env or edit `session.env`, so the JSON is rewritten without opening a new shell.

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
| `CAI_INFERENCE_BASE_URL` | *(see Dockerfile `ENV`)* | OpenAI-compatible base URL (must include path through `/v1`, no trailing slash beyond what your route expects) |
| `CAI_INFERENCE_MODEL` | `qwen-code` | Model id sent in API requests (must match what your inference service expects) |
| `CAI_INFERENCE_API_KEY` | *(empty)* | Bearer/API key if your endpoint requires auth; referenced from `agents.config.json` via Nanocoder env substitution |
| `NANOCODER_SESSION_ENV_FILE` | *(unset)* | Absolute path to a shell file (`export VAR=value`) sourced at terminal start before writing `agents.config.json`; overrides default path below if set |
| *(default file)* | — | If `NANOCODER_SESSION_ENV_FILE` is unset, **`~/.config/nanocoder/session.env`** is sourced when it exists |
| `NANOCODER_DISABLE_TOOLS` | *(unset / false)* | If **`1`**, **`true`**, **`yes`**, or **`on`** (case-insensitive), each provider in `agents.config.json` gets **`"disableTools": true`** (disables tool calling for that provider in Nanocoder) |

### Swapping models

Update `MODEL_REPO`, `MODEL_INCLUDE`, and `MODEL_ALIAS` together. Re-run `nano-start` (or `nano-restart` after a download). Any suitable GGUF layout under `MODEL_DIR` works.

### Advanced: provider overrides

Nanocoder supports `NANOCODER_PROVIDERS` / `NANOCODER_PROVIDERS_FILE` with **highest** precedence over `agents.config.json`; see [AI providers](https://docs.nanocollective.org/nanocoder/docs/v1.25.2/configuration/providers/).

---

## GPU requirements

`nano-start` starts local **llama-server** only when an NVIDIA GPU is present. Without a GPU, use the **CAI Inference** provider (`CAI_INFERENCE_BASE_URL`) or set that variable and run **`nanocoder`** directly.

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
  -t <your-registry>/nanocoder:1.0.1 .
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
