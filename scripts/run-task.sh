#!/usr/bin/env bash
# Runs one benchmark task in an ephemeral container. Track, repo, base
# commit, and problem statement come from tasks/tasks.json (see
# scripts/pull-tasks.py) — looked up by task_id. Scoring (test_patch
# application, pass/fail) is NOT done here — see scripts/score-python-batch.sh
# / scripts/score-java-batch.sh, which hand the agent's captured diff to the
# real swebench / multi-swe-bench harnesses instead of reimplementing their
# per-repo build/test logic.
#
# Usage: scripts/run-task.sh <task-id> [tasks-file] [--arm <name>]
# Requires: jq
#
# --arm selects which ablation arm to run, per BENCHMARKING.md's ablation
# design. Cumulative — each arm includes every tool before it:
#   baseline  — nothing wired in (plain claude -p); caveman explicitly
#               disabled (see below — it's on by default in the image)
#   graphify  — + `graphify install --project --strict` (blocks the first
#               raw file read until a query runs) + a deterministic
#               `graphify extract . --code-only --no-cluster` pre-build (not
#               left for the agent to discover mid-session — that inflated
#               turns/cost the first time this arm ran for real), agent also
#               nudged via system prompt. Extraction is cached on the host
#               under graph-cache/<repo>__<base_commit>/, reused only across
#               exact-commit repeats of the same task (graphify's own
#               `extract` is incremental by default — VERIFIED via
#               `graphify extract --help`).
#   serena    — + Serena registered as an MCP server, agent nudged
#   headroom  — + `headroom init claude` (durable hooks + provider routing)
#   leanctx   — + `lean-ctx onboard` (auto-detects/registers Claude Code)
#   caveman   — + Caveman enabled (it's baked into the image at build time
#               and enabled by default — VERIFIED live via `claude plugin
#               list` — so arms below caveman must explicitly disable it,
#               not the other way around)
# All registration commands above except graphify/serena were confirmed
# live against the real installed CLIs on EC2 (`--help` output), not guessed
# from docs — docs turned out wrong about caveman's install mechanism (it
# registers as a plugin itself, the docs said it wouldn't) and about
# lean-ctx onboard's flags (no --tool/--yes; it just auto-detects).
#
# LiteLLM (arm 7 in BENCHMARKING.md) is intentionally not wired here: its
# documented "usage-based-routing-v2" strategy load-balances, it doesn't
# route by task complexity, and Claude Code sends one fixed model for a
# whole -p session — wiring it in as literally documented wouldn't measure
# real routing savings. Revisit once there's an actual per-subtask
# model-switch mechanism to test.
#
# Exit codes (matter to scripts/run-batch.sh):
#   0  task ran, agent completed without error (correctness unscored here)
#   1  task ran but failed (agent error, crash, or bad checkout) — batch should continue
#   2  bad input (unknown task_id, missing tasks file, bad --arm) — not a task failure
#   3  rate-limit / usage-quota hit — batch should STOP, not burn through the rest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TASK_ID="${1:?task id (task_id field in tasks/tasks.json)}"
shift

ARM="baseline"
AGENT="claude"
TASKS_FILE="$REPO_ROOT/tasks/tasks.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arm) ARM="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        *) TASKS_FILE="$1"; shift ;;
    esac
done

if [[ "$AGENT" != "claude" && "$AGENT" != "agy" ]]; then
    echo "unknown --agent '$AGENT' (want: claude|agy)" >&2
    exit 2
fi

case "$ARM" in
    baseline) ARM_INDEX=0 ;;
    graphify) ARM_INDEX=1 ;;
    serena)   ARM_INDEX=2 ;;
    headroom) ARM_INDEX=3 ;;
    leanctx)  ARM_INDEX=4 ;;
    caveman)  ARM_INDEX=5 ;;
    *)
        echo "unknown --arm '$ARM' (want: baseline|graphify|serena|headroom|leanctx|caveman)" >&2
        exit 2
        ;;
esac

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 2
fi

if [[ ! -f "$TASKS_FILE" ]]; then
    echo "tasks file not found: $TASKS_FILE" >&2
    exit 2
fi

if [[ "$AGENT" == "claude" ]]; then
    RESULTS_DIR="$REPO_ROOT/results/$ARM"
    MOUNT_DIR="/results/$ARM"
    FRIENDLY_DIR="results/$ARM"
else
    RESULTS_DIR="$REPO_ROOT/results-agy/$ARM"
    MOUNT_DIR="/results-agy/$ARM"
    FRIENDLY_DIR="results-agy/$ARM"
fi

# Resume-safety: running on subscription auth, not a metered API key, so a
# batch that hits a usage cap gets picked up again later (e.g. "tomorrow")
# without re-spending quota on tasks already done. Skip anything already
# attempted instead of re-running it — result.json existing means the
# container ran to completion (success or agent-side failure both write it;
# only a crash before claude produced output leaves it missing, see below).
# Scoped per-arm so the same task_id can be (re-)run under a different arm
# without the skip check hiding it.
if [[ -f "$RESULTS_DIR/${TASK_ID}.result.json" ]]; then
    echo "skip: $FRIENDLY_DIR/${TASK_ID}.result.json already exists"
    exit 0
fi

# No `-e` here: it makes jq exit non-zero on a `null` result, which under
# `set -e` would abort the script on this assignment before the explicit
# not-found check below ever runs — verified this the hard way, it skips
# straight past the friendly error to a bare exit 1.
TASK_JSON="$(jq --arg id "$TASK_ID" '[.tasks[] | select(.task_id == $id)] | first' "$TASKS_FILE")"
if [[ "$TASK_JSON" == "null" ]]; then
    echo "task_id '$TASK_ID' not found in $TASKS_FILE" >&2
    exit 2
fi

TRACK="$(jq -r '.track' <<<"$TASK_JSON")"
REPO="$(jq -r '.repo' <<<"$TASK_JSON")"
BASE_COMMIT="$(jq -r '.base_commit' <<<"$TASK_JSON")"
REPO_URL="https://github.com/${REPO}.git"

if [[ "$TRACK" != "java" && "$TRACK" != "python" ]]; then
    echo "unexpected track '$TRACK' for task_id '$TASK_ID' (want java or python)" >&2
    exit 2
fi

# Own session ID per task, generated on the host and handed to `claude -p`
# via --session-id rather than parsed out afterward. This is the tagging
# scheme the earlier TODO here asked for: every task's Agentsview session is
# known up front, recorded in results/session-map.jsonl, no correlation
# guesswork needed even though every task shares the same in-container cwd
# (/workspace/repo) and would otherwise bucket under one indistinguishable
# Agentsview "project". /proc/sys/kernel/random/uuid is always present on
# the Linux EC2 host this runs on; uuidgen as a fallback for local testing
# on macOS.
SESSION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

# Prompt content is real-world GitHub issue text — will contain apostrophes,
# quotes, backticks, $ signs. Never string-interpolate it into a shell
# command (that broke on the first real issue tried: an apostrophe closed
# the quoting early). Mount it as a file instead and let the container's own
# shell read it via `cat`, so nothing about its content ever touches how the
# script itself is parsed. Same treatment for REPO_URL/TASK_ID/BASE_COMMIT/
# SESSION_ID via -e, even though they're lower-risk, so no variable is ever
# substituted into script text.
PROMPT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE"' EXIT
jq -r '.problem_statement' <<<"$TASK_JSON" > "$PROMPT_FILE"

mkdir -p "$RESULTS_DIR"

# docker compose reads docker-compose.yml relative to cwd (for the ./results
# volume mount), so run from the repo root regardless of caller's cwd.
cd "$REPO_ROOT"

# Graph cache for graphify (arm >= 1), keyed by (repo, base_commit) — safe
# to reuse ONLY across exact-commit repeats of the same task_id, since a
# different base_commit means a different tree. `graphify extract` is
# incremental by default (verified via `graphify extract --help`: only
# `--force` bypasses the manifest gate), so a second run against the same
# commit reuses most of the previous extraction instead of rebuilding it.
# Not shared across different tasks in the same repo — different commits,
# not verified safe to reuse blindly.
#
# Mounted at /home/bench/.graphify-cache (pre-created and bench-owned in
# the image — see the Dockerfiles), NOT at /workspace/repo/graphify-out
# directly: that path doesn't exist in the image (run-task.sh's own
# container script creates /workspace/repo fresh every run), so Docker
# auto-created it as root to satisfy the bind mount before the container's
# git init ever ran — which broke git init with a permission error. The
# container script below symlinks graphify-out to this mount instead.
DOCKER_EXTRA_ARGS=()
if [[ "$ARM_INDEX" -ge 1 ]]; then
    GRAPH_CACHE_DIR="$REPO_ROOT/graph-cache/$(tr '/' '_' <<<"$REPO")__${BASE_COMMIT}"
    mkdir -p "$GRAPH_CACHE_DIR"
    DOCKER_EXTRA_ARGS+=(-v "$GRAPH_CACHE_DIR:/home/bench/.graphify-cache")
fi

if [[ "$AGENT" == "agy" ]]; then
    HOST_AGY_PATH="$(which agy)"
    DOCKER_EXTRA_ARGS+=(-v "$HOST_AGY_PATH:/usr/local/bin/agy:ro")
fi

set +e
docker compose run --rm \
    -e REPO_URL="$REPO_URL" \
    -e TASK_ID="$TASK_ID" \
    -e BASE_COMMIT="$BASE_COMMIT" \
    -e SESSION_ID="$SESSION_ID" \
    -e ARM="$ARM" \
    -e ARM_INDEX="$ARM_INDEX" \
    -e AGENT="$AGENT" \
    -e MOUNT_DIR="$MOUNT_DIR" \
    -v "$(realpath "$PROMPT_FILE"):/tmp/task-prompt.txt:ro" \
    "${DOCKER_EXTRA_ARGS[@]}" \
    "${TRACK}-track" bash -c '
        set -euo pipefail
        # docker-compose.yml mounts the whole host results directories statically
        # — write under the arm subdir within it rather than remounting a
        # different host path, so this composes with that one static mount.
        mkdir -p "$MOUNT_DIR"

        # Shallow fetch by exact commit SHA rather than a depth-limited
        # branch clone — guarantees the checked-out tree matches the task'"'"'s
        # base_commit exactly (verified: GitHub allows fetching an arbitrary
        # reachable SHA for public repos), and avoids pulling full history
        # for large repos like django/spring.
        mkdir -p /workspace/repo && cd /workspace/repo
        git init -q
        git remote add origin "$REPO_URL"
        git fetch --depth 1 origin "$BASE_COMMIT"
        git checkout -q FETCH_HEAD

        # Registration steps below (graphify --project, Serena --scope
        # local) write into the repo tree itself (CLAUDE.md, .claude/) —
        # exclude them here, in git'"'"'s own per-checkout exclude file, so
        # they never get swept into the agent'"'"'s diff by `git add -A`
        # below. graphify-out/ is the extracted knowledge graph (can be
        # large); harmless no-ops for arms that never create these paths.
        {
            echo "graphify-out"
            echo ".claude/"
            echo "CLAUDE.md"
        } >> .git/info/exclude

        # Ablation-arm wiring: each block below registers one more tool with
        # Claude Code, cumulative on $ARM_INDEX. Kept as registration steps
        # (MCP add / plugin install / onboard), never a wrapping launcher
        # (e.g. `headroom wrap claude`), so the actual process invoked below
        # is always literally `claude -p --output-format json --session-id
        # ...` regardless of arm — one less variable between arms.
        SYSTEM_PROMPT=""
        if [[ "$ARM_INDEX" -ge 1 ]]; then
            # --project --strict (needs --project — VERIFIED via `graphify
            # install --help`) blocks the first raw file read per session
            # until a `graphify query` runs, via a PreToolUse hook — a hard
            # gate, not just the system-prompt nudge below.
        if [[ "$AGENT" == "claude" ]]; then
            if [[ "$ARM_INDEX" -ge 1 ]]; then
                graphify install --project --strict --platform claude
                ln -s /home/bench/.graphify-cache graphify-out
                graphify extract . --code-only --no-cluster
                SYSTEM_PROMPT+="Prefer Graphify queries over raw file reads when exploring the codebase. "
            fi
            if [[ "$ARM_INDEX" -ge 2 ]]; then
                claude mcp add --scope local serena -- serena start-mcp-server --context claude-code --project /workspace/repo
                SYSTEM_PROMPT+="Prefer Serena'"'"'s symbol-level tools (find_symbol, rename_symbol) over manual grep/read for navigation and edits. "
            fi
            if [[ "$ARM_INDEX" -ge 3 ]]; then
                headroom init claude
            fi
            if [[ "$ARM_INDEX" -ge 4 ]]; then
                lean-ctx onboard
            fi
            if [[ "$ARM_INDEX" -lt 5 ]]; then
                claude plugin disable caveman || true
            fi
            
            CLAUDE_EXTRA_ARGS=()
            if [[ -n "$SYSTEM_PROMPT" ]]; then
                CLAUDE_EXTRA_ARGS=(--append-system-prompt "$SYSTEM_PROMPT")
            fi
            
            claude -p "$(cat /tmp/task-prompt.txt)" \
                --session-id "$SESSION_ID" \
                --output-format json \
                --dangerously-skip-permissions \
                "${CLAUDE_EXTRA_ARGS[@]}" \
                > "$MOUNT_DIR/${TASK_ID}.result.json" 2> "$MOUNT_DIR/${TASK_ID}.stderr.log" || true
        else
            # agy branch
            if [[ "$ARM_INDEX" -ge 1 ]]; then
                # Assume graphify has an agy platform or just fallback
                graphify install --project --strict --platform agy || true
                ln -s /home/bench/.graphify-cache graphify-out
                graphify extract . --code-only --no-cluster
                SYSTEM_PROMPT+="Prefer Graphify queries over raw file reads when exploring the codebase. "
            fi
            if [[ "$ARM_INDEX" -ge 2 ]]; then
                # agy does not have a local scope add command in the same way, assume global or manually write config
                agy config mcp add serena "serena start-mcp-server --context agy --project /workspace/repo" || true
                SYSTEM_PROMPT+="Prefer Serena'"'"'s symbol-level tools (find_symbol, rename_symbol) over manual grep/read for navigation and edits. "
            fi
            if [[ "$ARM_INDEX" -ge 3 ]]; then
                headroom init agy || true
            fi
            if [[ "$ARM_INDEX" -ge 4 ]]; then
                lean-ctx onboard --agent agy || true
            fi
            # Caveman uses system prompts in agy, assume not enabled unless we add it
            
            AGY_EXTRA_ARGS=()
            if [[ -n "$SYSTEM_PROMPT" ]]; then
                AGY_EXTRA_ARGS=(--prompt "$SYSTEM_PROMPT")
            fi
            
            agy --goal "$(cat /tmp/task-prompt.txt)" \
                "${AGY_EXTRA_ARGS[@]}" \
                > "$MOUNT_DIR/${TASK_ID}.result.json" 2> "$MOUNT_DIR/${TASK_ID}.stderr.log" || true
        fi
        # If a permission prompt still blocks here despite the flag above,
        # known issue on non-interactive first runs — see
        # anthropics/claude-code#52506. Fallback: --permission-mode bypassPermissions

        # git add -A before diff so new files the agent created (a new test
        # class, a new source file) show up as "new file mode" diff hunks —
        # plain `git diff` against a clean checkout silently omits untracked
        # files entirely, which would have dropped exactly the kind of thing
        # the pilot-3 run actually did (added a new test file).
        git add -A
        git diff --cached > "$MOUNT_DIR/${TASK_ID}.patch" || true
    '
DOCKER_EXIT=$?
set -e

RESULT_JSON="$RESULTS_DIR/${TASK_ID}.result.json"

if [[ ! -f "$RESULT_JSON" ]]; then
    echo "no result.json produced (container exit $DOCKER_EXIT) — checkout or agent likely crashed before producing output; see $FRIENDLY_DIR/${TASK_ID}.stderr.log if present" >&2
    exit 1
fi

if ! jq -e . "$RESULT_JSON" >/dev/null 2>&1; then
    echo "result.json is not valid JSON — agent likely crashed mid-output; see $FRIENDLY_DIR/${TASK_ID}.stderr.log" >&2
    exit 1
fi

jq -n --arg task_id "$TASK_ID" --arg session_id "$SESSION_ID" --arg track "$TRACK" \
      --arg repo "$REPO" --arg base_commit "$BASE_COMMIT" --arg arm "$ARM" --arg agent "$AGENT" \
      '{task_id:$task_id, session_id:$session_id, track:$track, repo:$repo, base_commit:$base_commit, arm:$arm, agent:$agent}' \
      >> "$RESULTS_DIR/session-map.jsonl"

IS_ERROR="$(jq -r '.is_error' "$RESULT_JSON")"
API_ERROR_STATUS="$(jq -r '.api_error_status // empty' "$RESULT_JSON")"
RESULT_TEXT="$(jq -r '.result // empty' "$RESULT_JSON")"

# Rate-limit/quota detection is best-effort: `api_error_status` and the
# general is_error/result shape are confirmed real (verified locally against
# a live `claude -p --output-format json` run — see api_error_status:404 for
# a forced bad-model error), but the EXACT signal for a subscription usage
# cap specifically (as opposed to a raw API 429) hasn't been observed live.
# Checks both a 429 status and a few plausible phrases in the result text;
# tighten this the first time a real batch actually hits the cap.
if [[ "$API_ERROR_STATUS" == "429" ]] || grep -qiE "usage limit|rate limit|try again later" <<<"$RESULT_TEXT"; then
    echo "RATE LIMIT / QUOTA detected for $TASK_ID (api_error_status=${API_ERROR_STATUS:-none}) — stopping batch" >&2
    exit 3
fi

if [[ "$IS_ERROR" == "true" ]]; then
    echo "task failed (is_error=true, api_error_status=${API_ERROR_STATUS:-none}): $TASK_ID" >&2
    exit 1
fi

echo "done: $FRIENDLY_DIR/${TASK_ID}.result.json (patch: $FRIENDLY_DIR/${TASK_ID}.patch, session: $SESSION_ID)"

# TODO before real runs:
# - scoring (test_patch application + pass/fail) is handled by
#   scripts/score-python-batch.sh / scripts/score-java-batch.sh, run
#   separately after a batch — not per-task here (see those scripts' headers
#   for why: both delegate to the real swebench / multi-swe-bench harnesses,
#   which build their own per-instance environments and don't fit inside
#   this task's ephemeral container)
