# Ephemeral task runner for Python-track benchmark repos (django, flask, sympy, etc. — SWE-bench Verified).
# Build once, run with --rm per task. Do not persist state in this image.

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip nodejs npm ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Claude Code CLI (verified real package)
RUN npm install -g @anthropic-ai/claude-code

# Stack tools — pinned versions matching token-optimization-stack's docs.
# Re-check these against token-optimization-stack/scripts/check-pinned-versions.sh
# before rebuilding; bump here manually if that check reports drift.
#
# headroom-ai: base package only, no extras. `[all]` transitively pulls in
# torch/transformers/sentence-transformers/onnxruntime plus voice/image/
# spreadsheet/memory-stack deps irrelevant to this benchmark and multi-GB by
# itself. Base already includes tree-sitter/ast-grep-cli/tiktoken — the
# AST-aware code compression the doc's savings claim rests on.
RUN pip install graphifyy headroom-ai \
    && uv tool install serena-agent

RUN curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/v2.1.0/install.sh | bash
RUN curl -fsSL https://raw.githubusercontent.com/yvgude/lean-ctx/v3.9.19/install.sh | sh

WORKDIR /workspace
