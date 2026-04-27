# ── Stage 1: compile llama.cpp with CUDA ──────────────────────────────────
# nvidia/cuda:devel includes nvcc — no GPU needed at build time.
# CUDA 12.2 requires driver ≥ 535 (covers V100, T4, A100, A10G, L4, H100, etc.).
# "native" lets the compiler include PTX fallback so the binary runs on any
# NVIDIA GPU; if the exact arch isn't precompiled it JIT-compiles on first use.
FROM --platform=linux/amd64 nvidia/cuda:12.2.0-devel-ubuntu22.04 AS llama-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git libcurl4-openssl-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp /opt/llama.cpp && \
    cmake /opt/llama.cpp -B /opt/llama.cpp/build \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86;89;90" && \
    cmake --build /opt/llama.cpp/build --config Release \
        -j$(nproc) --clean-first \
        --target llama-server llama-cli && \
    cp /opt/llama.cpp/build/bin/llama-server \
       /opt/llama.cpp/build/bin/llama-cli \
       /usr/local/bin/

# Use CML base runtime image
FROM --platform=linux/amd64 docker.repository.cloudera.com/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-standard:2025.09.1-b5

# ── CUDA-enabled llama-server binaries ────────────────────────────────────
COPY --from=llama-builder /usr/local/bin/llama-server /usr/local/bin/llama-server
COPY --from=llama-builder /usr/local/bin/llama-cli    /usr/local/bin/llama-cli

# ── CUDA runtime libraries (required by llama-server at runtime) ──────────
# The CML base image has GPU drivers but not the CUDA runtime libs.
# Copy them from the builder so llama-server can find libcudart, libcublas, etc.
RUN --mount=type=bind,from=llama-builder,source=/usr/local/cuda/lib64,target=/cuda-libs \
    cp /cuda-libs/libcudart.so*    /usr/local/lib/ && \
    cp /cuda-libs/libcublas.so*    /usr/local/lib/ && \
    cp /cuda-libs/libcublasLt.so*  /usr/local/lib/ && \
    ldconfig

# ── System dependencies ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        # runtime dep for llama-server (libcurl)
        libcurl4 \
        # editors
        vim nano \
        # terminal multiplexers
        tmux screen \
        # file & text utilities
        curl wget less tree jq unzip zip \
        ripgrep fd-find bat \
        # network utilities
        netcat-openbsd dnsutils iputils-ping \
        # process & system inspection
        pciutils htop procps lsof strace \
        # misc dev conveniences
        ssh-client rsync socat ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    # fd and bat ship under Debian alias names
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── Node.js 22+ (Nanocoder pulls undici@8 which requires node >=22.19; NodeSource)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ── Nanocoder CLI ─────────────────────────────────────────────────────────
RUN npm install -g @nanocollective/nanocoder

# ── Python tooling for model download ─────────────────────────────────────
RUN pip install --no-cache-dir huggingface_hub hf_transfer

# ── ttyd: browser-based terminal (pinned binary; avoids GitHub API + empty TTYD_URL)
ARG TTYD_VERSION=1.7.7
RUN curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
        -o /usr/local/bin/ttyd && \
    chmod +x /usr/local/bin/ttyd

# ── Runtime directories ────────────────────────────────────────────────────
RUN mkdir -p /home/cdsw/models /home/cdsw/.config/nanocoder && \
    chown -R cdsw:cdsw /home/cdsw/models /home/cdsw/.config

# ── Shell startup script (Nanocoder + llama-server helpers) ───────────────
COPY scripts/startup.sh /etc/profile.d/nanocoder-local-llm.sh
RUN chmod +x /etc/profile.d/nanocoder-local-llm.sh && \
    echo '[ -f /etc/profile.d/nanocoder-local-llm.sh ] && source /etc/profile.d/nanocoder-local-llm.sh' \
        >> /etc/bash.bashrc

# ── Default environment (all overridable in CML project settings) ──────────
ENV MODEL_REPO="unsloth/Qwen3.5-35B-A3B-GGUF" \
    MODEL_INCLUDE="*UD-Q4_K_XL*" \
    MODEL_ALIAS="unsloth/Qwen3.5-35B-A3B" \
    MODEL_DIR="/home/cdsw/models" \
    LLAMA_SERVER_PORT="8001" \
    APP_PORT="8080" \
    CTX_SIZE="65536" \
    TEMPERATURE="0.6" \
    TOP_P="0.95" \
    TOP_K="20"
# Optional: NANOCODER_CONFIG_DIR, NANOCODER_CONTEXT_LIMIT — see README.

EXPOSE 8080
# Set working directory
WORKDIR /home/cdsw
# Override CML metadata labels to make this a unique custom runtime
LABEL com.cloudera.ml.runtime.edition="nanocoder-qwen"
LABEL com.cloudera.ml.runtime.full-version="1.0.1-nanocoder-qwen"
LABEL com.cloudera.ml.runtime.short-version="1.0"
LABEL com.cloudera.ml.runtime.maintenance-version="1"
LABEL com.cloudera.ml.runtime.description="Nanocoder with local Qwen/GLM via llama.cpp (OpenAI-compatible /v1)"
