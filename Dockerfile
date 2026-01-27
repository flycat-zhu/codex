    # ---------- Stage 1: build codex from source ----------
        FROM rust:1.80-bookworm AS builder

        # 保留原有环境变量（移除冲突的 sparse 协议配置，后续通过镜像适配）
        ENV CARGO_TERM_COLOR=never \
            # 移除：CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse（与 git 镜像冲突）
            # Rustup 工具链加速（中科大源）
            RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static \
            RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup
        
        RUN mkdir -p /root/.cargo && \
            cat <<EOF > /root/.cargo/config
[source.crates-io]
replace-with = "tuna"

[source.tuna]
registry = "https://mirrors.tuna.tsinghua.edu.cn/git/crates.io-index.git"

[net]
git-fetch-with-cli = true
retry = 5
EOF
    
        # Debian 源配置（保持不变，但确保命令完整）
        RUN echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            apt-get update && apt-get install -y --no-install-recommends \
                ca-certificates git pkg-config build-essential curl libssl-dev zlib1g-dev && \
            rm -rf /var/lib/apt/lists/*
    
        WORKDIR /src
    
        COPY . /src
        # 避免宿主机产物干扰（原有命令保留）
        RUN rm -rf /src/codex-rs/target
    
        # 编译 Rust CLI 二进制（workspace 中的 codex 可执行）
        WORKDIR /src/codex-rs
        # 降低编译内存占用（进一步优化以避免内存不足）
        ENV CARGO_BUILD_JOBS=1 \
            CARGO_INCREMENTAL=0 \
            CARGO_NET_RETRY=5 \
            CARGO_HTTP_TIMEOUT=300
        # 使用 debug 模式以避免内存不足（release 模式需要更多内存）
        RUN cargo build --bin codex
    
        # ---------- Stage 2: runtime ----------
        FROM debian:bookworm-slim
    
        # 修改：替换 Debian 源为清华源（加速 apt-get 安装）
        RUN echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            # 1) 系统依赖 + Python + 文档处理工具（支持中文）
            apt-get update && apt-get install -y --no-install-recommends \
                ca-certificates curl git python3 python3-venv python3-pip libssl3 qpdf \
                pandoc texlive-xetex texlive-fonts-recommended texlive-latex-base && \
            rm -rf /var/lib/apt/lists/*
    
        # 2) 国内 pip 源（系统级）+ ENV（双保险，原有配置保留）
        RUN printf "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ntrusted-host = pypi.tuna.tsinghua.edu.cn\ntimeout = 30\nretries = 3\n" > /etc/pip.conf
        ENV PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple" \
            PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn"
    
        # 3) 创建非 root 用户（原有配置保留）
        RUN useradd -m -u 10001 codex
        
        # 在切换用户前创建工作目录并设置权限
        RUN mkdir -p /work && chown codex:codex /work
        
        USER codex
        WORKDIR /home/codex
    
        # 4) 内置项目专属 venv（原有配置保留）
        ENV VENV=/home/codex/.venv
        RUN python3 -m venv "$VENV" && "$VENV/bin/pip" install -U pip setuptools wheel
        ENV VIRTUAL_ENV="$VENV" \
            PATH="$VENV/bin:/usr/local/bin:/usr/bin:/bin"
    
        # 5) 预装基础依赖（原有配置保留）
        COPY --chown=codex:codex requirements.txt /tmp/requirements.txt
        RUN [ -s /tmp/requirements.txt ] && pip install -r /tmp/requirements.txt || true
    
        # 6) 复制编译产物（如果用了 --release，需改为 target/release/codex）
        COPY --from=builder /src/codex-rs/target/debug/codex /usr/local/bin/codex
    
        # 7) 烘焙 Codex 配置（原有配置保留）
        ENV CODEX_HOME=/home/codex/.codex
        RUN mkdir -p "$CODEX_HOME"
        COPY --chown=codex:codex config.toml $CODEX_HOME/config.toml
    
        # 8) 关闭沙盒（原有配置保留）
        ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1
    
        # 默认工作区（已在切换用户前创建）
        WORKDIR /work
    
        # 设置入口点和默认命令
        # 注意：codex 默认启动交互式 CLI，需要 TTY
        # 使用交互式模式：docker run -it --rm codex-rs:latest
        # 使用非交互式模式：docker run --rm codex-rs:latest exec <command>
        ENTRYPOINT ["codex"]
        CMD []