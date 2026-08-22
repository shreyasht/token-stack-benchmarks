# Ephemeral task runner for Java-track benchmark repos (jackson-databind, mockito, logstash).
# Build once, run with --rm per task. Do not persist state in this image.

FROM eclipse-temurin:21-jdk

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip python3 python3-pip python3-venv nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (verified real package) — system-wide as root, fine, always on PATH.
RUN npm install -g @anthropic-ai/claude-code

# graphifyy/headroom-ai — system-wide as root, same reasoning.
# headroom-ai: base package only, no extras. `[all]` transitively pulls in
# torch/transformers/sentence-transformers/onnxruntime plus voice/image/
# spreadsheet/memory-stack deps irrelevant to this benchmark and multi-GB by
# itself. Base already includes tree-sitter/ast-grep-cli/tiktoken — the
# AST-aware code compression the doc's savings claim rests on.
# mcp: headroom's own `headroom mcp serve` (registered by `headroom init claude`
# as a stdio MCP server) hard-requires the `mcp` SDK and isn't pulled in by the
# base package — without it the registered command crashes on spawn
# (ImportError: MCP SDK not installed) and wedges claude -p startup, which
# then surfaces ~3 minutes later as a misleading "Connection refused" API error.
RUN pip install --break-system-packages graphifyy headroom-ai mcp

# Non-root user, UID matching the host (ec2-user, confirmed 1000) — required
# because `claude --dangerously-skip-permissions` refuses to run as root, and
# the mounted OAuth credential file (~/.claude/.credentials.json, host mode
# 600) needs a matching numeric UID to stay readable without loosening its
# permissions. Some base images (this one included — Ubuntu-based, reserves
# UID 1000 for its own default user) already have UID 1000 taken; reuse
# whatever's there instead of assuming it's free. .graphify-cache is a
# pre-owned bind-mount target for the host-side graph cache — mounting
# straight into /workspace/repo (created fresh per-task by run-task.sh, not
# baked into the image) made Docker auto-create that path as root before
# the container's own git init ran, breaking it with a permission error;
# mounting over an already-bench-owned path avoids that.
RUN if getent passwd 1000 >/dev/null; then \
        existing="$(getent passwd 1000 | cut -d: -f1)"; \
        usermod -l bench -d /home/bench -m -s /bin/bash "$existing"; \
        groupmod -n bench "$existing" 2>/dev/null || true; \
    else \
        useradd -m -u 1000 -s /bin/bash bench; \
    fi \
    && mkdir -p /workspace /home/bench/.graphify-cache \
    && chown -R bench:bench /workspace /home/bench

USER bench
WORKDIR /workspace
ENV HOME="/home/bench"
ENV PATH="/home/bench/.local/bin:${PATH}"

# uv + Serena, and the curl-installers for Caveman/LeanCTX, all install into
# $HOME — must run as the non-root user so they land in /home/bench, not
# /root (which becomes inaccessible once USER switches off root above).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv tool install serena-agent

RUN curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/v2.1.0/install.sh | bash
RUN curl -fsSL https://raw.githubusercontent.com/yvgude/lean-ctx/v3.9.19/install.sh | sh
