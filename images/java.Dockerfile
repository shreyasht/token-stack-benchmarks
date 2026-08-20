# Ephemeral task runner for Java-track benchmark repos (jackson-databind, mockito, logstash).
# Build once, run with --rm per task. Do not persist state in this image.

FROM eclipse-temurin:21-jdk

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip python3 python3-pip python3-venv nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# uv, for tools that recommend it over pip (Serena)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Claude Code CLI (verified real package)
RUN npm install -g @anthropic-ai/claude-code

# Stack tools — pinned versions matching token-optimization-stack's docs.
# Re-check these against token-optimization-stack/scripts/check-pinned-versions.sh
# before rebuilding; bump here manually if that check reports drift.
RUN pip install --break-system-packages graphifyy \
    && pip install --break-system-packages "headroom-ai[all]" \
    && uv tool install serena-agent

RUN curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/v2.1.0/install.sh | bash
RUN curl -fsSL https://raw.githubusercontent.com/yvgude/lean-ctx/v3.9.19/install.sh | sh

WORKDIR /workspace
