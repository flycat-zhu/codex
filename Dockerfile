# ---------- Stage 0: chef base（安装 cargo-chef，供后续 stage 复用）----------
FROM rust:1.93-bookworm AS chef

# ⚠️ 在最前面设置 Rustup 国内镜像（必须在任何 rustup 命令之前）
ENV RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static \
    RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup \
    RUSTUP_IO_THREADS=4 \
    CARGO_TERM_COLOR=never \
    CARGO_NET_RETRY=5 \
    CARGO_HTTP_TIMEOUT=300 \
    CARGO_BUILD_JOBS=4 \
    CARGO_INCREMENTAL=0

# 配置 Cargo 使用国内 Sparse 稀疏协议（避免克隆 100 万次提交的全量 git 历史，速度提升 10x+）
RUN mkdir -p /root/.cargo && \
    cat <<EOF > /root/.cargo/config.toml
[source.crates-io]
replace-with = "tuna-sparse"

[source.tuna-sparse]
registry = "sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/"

[net]
retry = 5
timeout = 60

[build]
jobs = 4
incremental = false
EOF

# 配置 Debian 源（使用清华镜像）并安装系统依赖
RUN echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
    echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git pkg-config build-essential curl libssl-dev zlib1g-dev libcap-dev && \
    rm -rf /var/lib/apt/lists/*

# 预装 rust-toolchain.toml 要求的工具链（minimal profile 跳过 rust-docs，避免构建时按需下载）
RUN rustup set auto-self-update disable && \
    rustup toolchain install 1.93.0 \
        --profile minimal \
        --component clippy,rustfmt,rust-src \
        --no-self-update && \
    rustup default 1.93.0

# 安装 cargo-chef（用于分层缓存依赖，只要 Cargo.toml/Cargo.lock 不变就能复用依赖编译层）
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    cargo install cargo-chef --locked

WORKDIR /src/codex-rs

# ---------- Stage 1: planner（生成依赖配方文件）----------
FROM chef AS planner
# 复制源码，生成 recipe.json（描述所有依赖信息）
COPY codex-rs/ ./
RUN cargo chef prepare --recipe-path /tmp/recipe.json

# ---------- Stage 2: builder（先编译依赖，再编译项目代码）----------
FROM chef AS builder

# ── 第一步：仅编译依赖 ──
# 此层独立缓存：只要 Cargo.toml/Cargo.lock 不变，即使业务代码任意改动也能 100% 复用
COPY --from=planner /tmp/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/cargo-target \
    CARGO_TARGET_DIR=/cargo-target cargo chef cook --recipe-path recipe.json -p codex-cli

# ── 第二步：复制真正的源码并编译业务代码 ──
# 依赖已在上层缓存，这里只需重编译业务代码，速度极快
COPY codex-rs/ ./
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/cargo-target \
    mkdir -p /artifacts && \
    CARGO_TARGET_DIR=/cargo-target cargo build -p codex-cli --bin codex && \
    cp /cargo-target/debug/codex /artifacts/codex

# ---------- Stage 3: runtime ----------
FROM debian:bookworm-slim

# 配置清华 Debian 源并安装运行时依赖
# ⚠️ 移除了 texlive-xetex / texlive-fonts-recommended / texlive-latex-base（约 400-600MB，节省数分钟安装时间）
RUN echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
    echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        python3 python3-venv python3-pip \
        libssl3 qpdf pandoc && \
    rm -rf /var/lib/apt/lists/*

# 国内 pip 源（系统级）
RUN printf "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ntrusted-host = pypi.tuna.tsinghua.edu.cn\ntimeout = 30\nretries = 3\n" > /etc/pip.conf
ENV PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple" \
    PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn"

# 创建非 root 用户，初始化工作目录（合并 RUN 减少镜像层数）
RUN useradd -m -u 10001 codex && \
    mkdir -p /work && chown codex:codex /work

# 设置入口点脚本（必须在 USER codex 之前以 root 身份写入 /usr/local/bin）
# 使用交互式模式：docker run -it --rm <image>
# 使用非交互式模式：docker run --rm <image> exec <command>
#
# ⚠️ AGENTS.md 挂载说明（解决 Docker volume 遮蔽问题）：
# 当 -v <file>:/work/AGENTS.md:ro 出现在 -v <dir>:/work:rw 之前时，
# 目录挂载会遮蔽文件挂载，导致 /work/AGENTS.md 不可见。
# 解决方案（二选一）：
#   方案一（推荐）：调换挂载顺序，将 /work 目录挂载放在 AGENTS.md 文件挂载之前。
#   方案二：将 AGENTS.md 挂载至 /run/codex/AGENTS.md（不在 /work 内），
#           启动脚本会自动将其复制到 /work/AGENTS.md。
#           示例：-v /path/to/AGENTS.md:/run/codex/AGENTS.md:ro
RUN printf '#!/bin/sh\nset -eu\n\n# 初始化 /work 项目根标记\nif [ -d /work ] && [ -w /work ]; then\n  touch /work/.codex-root 2>/dev/null || true\nfi\n\n# AGENTS.md 恢复机制（方案二支持）\n# 当 /work/AGENTS.md 因目录挂载遮蔽而不可见时，从备用路径 /run/codex/AGENTS.md 复制\nif [ -w /work ] && [ ! -f /work/AGENTS.md ] && [ -r /run/codex/AGENTS.md ]; then\n  cp /run/codex/AGENTS.md /work/AGENTS.md 2>/dev/null || true\nfi\n\nexec codex "$@"\n' > /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

USER codex
WORKDIR /home/codex

# 内置项目专属 venv
ENV VENV=/home/codex/.venv
RUN python3 -m venv "$VENV" && "$VENV/bin/pip" install -U pip setuptools wheel
ENV VIRTUAL_ENV="$VENV" \
    PATH="$VENV/bin:/usr/local/bin:/usr/bin:/bin"

# 预装基础 Python 依赖（cache mount uid 与 codex 用户 10001 一致）
COPY --chown=codex:codex requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/home/codex/.cache/pip,uid=10001 \
    [ -s /tmp/requirements.txt ] && pip install -r /tmp/requirements.txt || true

# 复制编译产物
COPY --from=builder /artifacts/codex /usr/local/bin/codex

# 烘焙 Codex 配置
ENV CODEX_HOME=/home/codex/.codex
RUN mkdir -p "$CODEX_HOME/skills"
COPY --chown=codex:codex config.toml $CODEX_HOME/config.toml

# 内置自定义 skills（将本地 skills/ 目录中的内容烘焙进镜像）
# 使用方式：在项目根目录的 skills/ 目录下按标准结构创建 skill，重新构建镜像即可内置
# skill 标准结构：skills/<skill-name>/SKILL.md（必需）+ agents/openai.yaml（推荐）
COPY --chown=codex:codex skills/ $CODEX_HOME/skills/

# 关闭沙盒
ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD []
