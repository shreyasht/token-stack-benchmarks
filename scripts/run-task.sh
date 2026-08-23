#!/usr/bin/env bash
# Runs one benchmark task in an ephemeral container. Track, repo, base
# commit, and problem statement come from tasks/tasks.json (see
# scripts/pull-tasks.py) — looked up by task_id. Scoring (test_patch
# application, pass/fail) is NOT done here — see scripts/score-python-batch.sh
# / scripts/score-java-batch.sh, which hand the agent's captured diff to the
# real swebench / multi-swe-bench harnesses instead of reimplementing their
# per-repo build/test logic.
#
# Usage: scripts/run-task.sh <task-id> [tasks-file] [--arm <name>] [--rep <n>] [--agent <claude|agy>]
# Requires: jq
#
# --rep selects which repeat of this arm to run (default 1), for
# BENCHMARKING.md's >=3-repeats-per-arm requirement. rep 1 writes to
# <results-dir>/<arm>/ (unchanged, no migration needed for already-run rep-1
# data); rep N>1 writes to <results-dir>/<arm>/repN/ instead, so reps never
# collide with each other or with rep 1.
#
# --agent selects which CLI runs the task: `claude` (default, Claude Code)
# or `agy` (Antigravity CLI). Results land in separate top-level trees
# (results/ vs results-agy/) so the two agents' data never collide — an
# agent is a different variable from an arm, not another arm value, since
# every arm 0-4 can in principle be run under either.
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
# Headroom and LiteLLM are dropped from the stack entirely (not deferred —
# removed from TOKEN_OPTIMIZATION_STACK.md too). Headroom's only usable
# registration path (`headroom init claude`, chosen to avoid stacking a
# separate `wrap`/`proxy` launcher around this invocation) turned out to
# register an on-demand MCP tool the agent may never call, not the
# transparent compression the doc claimed (confirmed via `headroom doctor`:
# nothing is actually routed without a running `headroom proxy` +
# ANTHROPIC_BASE_URL). Its `mcp serve` subcommand also crashed outright
# against a plain `pip install headroom-ai` (needs the `[mcp]` extra, pinned
# `mcp<2` — headroom's own code still uses the v1 SDK's `@server.list_tools()`
# decorator, which mcp 2.0.0 removed). LiteLLM's documented
# "usage-based-routing-v2" strategy load-balances, it doesn't route by task
# complexity, and Claude Code sends one fixed model for a whole -p session —
# wiring it in as literally documented wouldn't measure real routing savings.
# Both added complexity disproportionate to what they measurably deliver.
# The --agent agy path below was merged from a branch cut before this
# removal, so its arm wiring is renumbered here to match the 5-arm scheme —
# it must NOT reintroduce headroom.
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
REP=1
AGENT="claude"
TASKS_FILE="$REPO_ROOT/tasks/tasks.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arm) ARM="$2"; shift 2 ;;
        --rep) REP="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        *) TASKS_FILE="$1"; shift ;;
    esac
done

if ! [[ "$REP" =~ ^[0-9]+$ ]] || [[ "$REP" -lt 1 ]]; then
    echo "bad --rep '$REP' (want a positive integer)" >&2
    exit 2
fi

if [[ "$AGENT" != "claude" && "$AGENT" != "agy" ]]; then
    echo "unknown --agent '$AGENT' (want: claude|agy)" >&2
    exit 2
fi

case "$ARM" in
    baseline) ARM_INDEX=0 ;;
    graphify) ARM_INDEX=1 ;;
    serena)   ARM_INDEX=2 ;;
    leanctx)  ARM_INDEX=3 ;;
    caveman)  ARM_INDEX=4 ;;
    *)
        echo "unknown --arm '$ARM' (want: baseline|graphify|serena|leanctx|caveman)" >&2
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

# rep 1 stays at <results-dir>/<arm>/ (backward compat, no migration for
# existing data); rep N>1 gets its own <results-dir>/<arm>/repN/ subdir.
# <results-dir> is results/ for claude, results-agy/ for agy — a separate
# top-level tree per agent (see docker-compose.yml's two static mounts)
# rather than another arm value, so claude and agy data never collide.
ARM_REL="$ARM"
if [[ "$REP" -gt 1 ]]; then
    ARM_REL="$ARM/rep$REP"
fi
if [[ "$AGENT" == "claude" ]]; then
    RESULTS_BASE_NAME="results"
else
    RESULTS_BASE_NAME="results-agy"
fi
RESULTS_DIR="$REPO_ROOT/$RESULTS_BASE_NAME/$ARM_REL"
MOUNT_DIR="/$RESULTS_BASE_NAME/$ARM_REL"
FRIENDLY_DIR="$RESULTS_BASE_NAME/$ARM_REL"

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
        # docker-compose.yml mounts the whole host results/ and results-agy/
        # dirs statically — write under the arm (+rep) subdir within
        # whichever one $MOUNT_DIR points at, rather than remounting a
        # different host path, so this composes with those static mounts.
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
        # the agent CLI, cumulative on $ARM_INDEX. Kept as registration
        # steps (MCP add / plugin install / onboard), never a wrapping
        # launcher (e.g. `lean-ctx wrap claude`), so the actual process
        # invoked below is always the plain `-p ... --output-format json`
        # call regardless of arm — one less variable between arms.
        SYSTEM_PROMPT=""

        if [[ "$AGENT" == "claude" ]]; then
            if [[ "$ARM_INDEX" -ge 1 ]]; then
                # --project --strict (needs --project — VERIFIED via
                # `graphify install --help`) blocks the first raw file read
                # per session until a `graphify query` runs, via a
                # PreToolUse hook — a hard gate, not just the system-prompt
                # nudge below.
                graphify install --project --strict --platform claude
                # graphify-out symlinked to the host-mounted cache
                # (/home/bench/.graphify-cache) so `graphify extract`'"'"'s
                # default output location transparently persists across
                # exact-commit repeats of this task.
                ln -s /home/bench/.graphify-cache graphify-out
                # Deterministic pre-build, not left for the agent to
                # discover mid-session (that inflated turns/cost the first
                # time this arm ran for real — the graph didn'"'"'t exist
                # yet). --code-only --no-cluster: local tree-sitter AST
                # only, no LLM calls, so this step has no hidden
                # token/quota cost of its own.
                graphify extract . --code-only --no-cluster
                SYSTEM_PROMPT+="Prefer Graphify queries over raw file reads when exploring the codebase. "
            fi
            if [[ "$ARM_INDEX" -ge 2 ]]; then
                claude mcp add --scope local serena -- serena start-mcp-server --context claude-code --project /workspace/repo
                SYSTEM_PROMPT+="Prefer Serena'"'"'s symbol-level tools (find_symbol, rename_symbol) over manual grep/read for navigation and edits. "
            fi
            if [[ "$ARM_INDEX" -ge 3 ]]; then
                # VERIFIED on real EC2 install (`lean-ctx onboard --help`):
                # no --tool/--yes flags exist, it auto-detects installed
                # agents.
                lean-ctx onboard
            fi

            # Caveman is baked into the image at build time (its install.sh
            # registers the plugin itself, contrary to its docs) and is
            # enabled by default in every fresh container regardless of
            # arm — VERIFIED live: `claude plugin list` showed
            # caveman@caveman already "enabled" before this block ever ran.
            # So every arm below caveman must explicitly disable it, or
            # lower arms are silently contaminated with its
            # output-compression hook. Already enabled for the caveman arm
            # itself by default — nothing to do there.
            if [[ "$ARM_INDEX" -lt 4 ]]; then
                claude plugin disable caveman || true
            fi

            # Array, not a bare ${SYSTEM_PROMPT:+...} expansion — the
            # latter word-splits on the spaces inside $SYSTEM_PROMPT and
            # leaks literal quote characters into argv once past parameter
            # expansion.
            CLAUDE_EXTRA_ARGS=()
            if [[ -n "$SYSTEM_PROMPT" ]]; then
                CLAUDE_EXTRA_ARGS=(--append-system-prompt "$SYSTEM_PROMPT")
            fi

            # claude itself is allowed to fail/error here (set +e-equivalent
            # via ||true) — a bad run still needs its JSON result captured
            # (for the is_error/api_error_status check on the host below)
            # and whatever diff exists still captured, rather than the
            # whole script aborting and losing that signal.
            claude -p "$(cat /tmp/task-prompt.txt)" \
                --session-id "$SESSION_ID" \
                --output-format json \
                --dangerously-skip-permissions \
                "${CLAUDE_EXTRA_ARGS[@]}" \
                > "$MOUNT_DIR/${TASK_ID}.result.json" 2> "$MOUNT_DIR/${TASK_ID}.stderr.log" || true
        else
            # agy (Antigravity CLI) branch. Renumbered to match the 5-arm
            # scheme above (graphify=1, serena=2, leanctx=3, caveman=4) —
            # this was merged from a branch cut before headroom was removed
            # and the arms renumbered, so it must NOT call headroom.
            #
            # Isolated writable HOME for agy so it never touches the
            # container'"'"'s real $HOME (shared with claude'"'"'s own
            # config) and never needs to write into the read-only host
            # mount directly.
            export HOME=/tmp/agy_home
            mkdir -p /tmp/agy_home/.gemini
            cp -r /tmp/host_agy_data /tmp/agy_home/.gemini/antigravity-cli
            chmod -R u+w /tmp/agy_home

            if [[ "$ARM_INDEX" -ge 1 ]]; then
                # TODO: confirm `graphify install --platform agy` is a real
                # flag value against `graphify install --help` on the real
                # EC2 agy install — unverified, kept from the source branch.
                graphify install --project --strict --platform agy || true
                ln -s /home/bench/.graphify-cache graphify-out
                graphify extract . --code-only --no-cluster
                SYSTEM_PROMPT+="Prefer Graphify queries over raw file reads when exploring the codebase. "
            fi
            if [[ "$ARM_INDEX" -ge 2 ]]; then
                # TODO: confirm this is agy'"'"'s real MCP-registration
                # subcommand against `agy --help` — unverified, kept from
                # the source branch (agy may not have a --scope local
                # equivalent).
                agy mcp add serena "serena start-mcp-server --context agy --project /workspace/repo" || true
                SYSTEM_PROMPT+="Prefer Serena'"'"'s symbol-level tools (find_symbol, rename_symbol) over manual grep/read for navigation and edits. "
            fi
            if [[ "$ARM_INDEX" -ge 3 ]]; then
                # TODO: confirm lean-ctx'"'"'s agy integration flag against
                # `lean-ctx onboard --help` — unverified, kept from the
                # source branch.
                lean-ctx onboard --agent agy || true
            fi
            # No caveman equivalent wired for agy yet (index >= 4) — it'"'"'s
            # a Claude Code plugin specifically, not a portable CLI tool.
            # caveman arm under --agent agy currently just runs the leanctx
            # arm'"'"'s wiring with nothing extra on top; that'"'"'s a real
            # gap, not a silent bug — flagged here rather than faked.

            AGY_EXTRA_ARGS=()

            FULL_PROMPT="$(cat /tmp/task-prompt.txt)"
            if [[ -n "$SYSTEM_PROMPT" ]]; then
                FULL_PROMPT="$FULL_PROMPT

System Instructions:
$SYSTEM_PROMPT"
            fi

            agy -p "$FULL_PROMPT" \
                --output-format json \
                --dangerously-skip-permissions \
                "${AGY_EXTRA_ARGS[@]}" \
                > "$MOUNT_DIR/${TASK_ID}.result.json" 2> "$MOUNT_DIR/${TASK_ID}.stderr.log" || true

            # Sync the generated transcripts back to the host so Agentsview
            # can see them: to $MOUNT_DIR/transcripts for archiving
            # alongside this arm+rep'"'"'s other results, and to the host'"'"'s
            # native brain directory so Agentsview'"'"'s file-watcher picks
            # them up immediately.
            mkdir -p "$MOUNT_DIR/transcripts"
            cp -r /tmp/agy_home/.gemini/antigravity-cli/brain/* "$MOUNT_DIR/transcripts/" 2>/dev/null || true
            cp -r /tmp/agy_home/.gemini/antigravity-cli/brain/* "/tmp/host_agy_brain/" 2>/dev/null || true
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
      --arg repo "$REPO" --arg base_commit "$BASE_COMMIT" --arg arm "$ARM" --argjson rep "$REP" --arg agent "$AGENT" \
      '{task_id:$task_id, session_id:$session_id, track:$track, repo:$repo, base_commit:$base_commit, arm:$arm, rep:$rep, agent:$agent}' \
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
