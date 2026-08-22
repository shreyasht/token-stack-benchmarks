#!/usr/bin/env bash
# Runs one benchmark task in an ephemeral container. Track, repo, base
# commit, and problem statement come from tasks/tasks.json (see
# scripts/pull-tasks.py) — looked up by task_id. Scoring (test_patch
# application, pass/fail) is NOT done here — see scripts/score-python-batch.sh
# / scripts/score-java-batch.sh, which hand the agent's captured diff to the
# real swebench / multi-swe-bench harnesses instead of reimplementing their
# per-repo build/test logic.
#
# Usage: scripts/run-task.sh <task-id> [tasks-file]
# Requires: jq
#
# Exit codes (matter to scripts/run-batch.sh):
#   0  task ran, agent completed without error (correctness unscored here)
#   1  task ran but failed (agent error, crash, or bad checkout) — batch should continue
#   2  bad input (unknown task_id, missing tasks file) — not a task failure
#   3  rate-limit / usage-quota hit — batch should STOP, not burn through the rest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TASK_ID="${1:?task id (task_id field in tasks/tasks.json)}"
TASKS_FILE="${2:-$REPO_ROOT/tasks/tasks.json}"

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 2
fi

if [[ ! -f "$TASKS_FILE" ]]; then
    echo "tasks file not found: $TASKS_FILE" >&2
    exit 2
fi

# Resume-safety: running on subscription auth, not a metered API key, so a
# batch that hits a usage cap gets picked up again later (e.g. "tomorrow")
# without re-spending quota on tasks already done. Skip anything already
# attempted instead of re-running it — result.json existing means the
# container ran to completion (success or agent-side failure both write it;
# only a crash before claude produced output leaves it missing, see below).
if [[ -f "$REPO_ROOT/results/${TASK_ID}.result.json" ]]; then
    echo "skip: results/${TASK_ID}.result.json already exists"
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

mkdir -p "$REPO_ROOT/results"

# docker compose reads docker-compose.yml relative to cwd (for the ./results
# volume mount), so run from the repo root regardless of caller's cwd.
cd "$REPO_ROOT"

set +e
docker compose run --rm \
    -e REPO_URL="$REPO_URL" \
    -e TASK_ID="$TASK_ID" \
    -e BASE_COMMIT="$BASE_COMMIT" \
    -e SESSION_ID="$SESSION_ID" \
    -v "$(realpath "$PROMPT_FILE"):/tmp/task-prompt.txt:ro" \
    "${TRACK}-track" bash -c '
        set -euo pipefail
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

        # claude itself is allowed to fail/error here (set +e-equivalent via
        # ||true) — a bad run still needs its JSON result captured (for the
        # is_error/api_error_status check on the host below) and whatever
        # diff exists still captured, rather than the whole script aborting
        # and losing that signal.
        claude -p "$(cat /tmp/task-prompt.txt)" \
            --session-id "$SESSION_ID" \
            --output-format json \
            --dangerously-skip-permissions \
            > "/results/${TASK_ID}.result.json" 2> "/results/${TASK_ID}.stderr.log" || true
        # If a permission prompt still blocks here despite the flag above,
        # known issue on non-interactive first runs — see
        # anthropics/claude-code#52506. Fallback: --permission-mode bypassPermissions

        # git add -A before diff so new files the agent created (a new test
        # class, a new source file) show up as "new file mode" diff hunks —
        # plain `git diff` against a clean checkout silently omits untracked
        # files entirely, which would have dropped exactly the kind of thing
        # the pilot-3 run actually did (added a new test file).
        git add -A
        git diff --cached > "/results/${TASK_ID}.patch" || true
    '
DOCKER_EXIT=$?
set -e

RESULT_JSON="$REPO_ROOT/results/${TASK_ID}.result.json"

if [[ ! -f "$RESULT_JSON" ]]; then
    echo "no result.json produced (container exit $DOCKER_EXIT) — checkout or claude likely crashed before producing output; see results/${TASK_ID}.stderr.log if present" >&2
    exit 1
fi

if ! jq -e . "$RESULT_JSON" >/dev/null 2>&1; then
    echo "result.json is not valid JSON — claude likely crashed mid-output; see results/${TASK_ID}.stderr.log" >&2
    exit 1
fi

jq -n --arg task_id "$TASK_ID" --arg session_id "$SESSION_ID" --arg track "$TRACK" \
      --arg repo "$REPO" --arg base_commit "$BASE_COMMIT" \
      '{task_id:$task_id, session_id:$session_id, track:$track, repo:$repo, base_commit:$base_commit}' \
      >> "$REPO_ROOT/results/session-map.jsonl"

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

echo "done: results/${TASK_ID}.result.json (patch: results/${TASK_ID}.patch, session: $SESSION_ID)"

# TODO before real runs:
# - scoring (test_patch application + pass/fail) is handled by
#   scripts/score-python-batch.sh / scripts/score-java-batch.sh, run
#   separately after a batch — not per-task here (see those scripts' headers
#   for why: both delegate to the real swebench / multi-swe-bench harnesses,
#   which build their own per-instance environments and don't fit inside
#   this task's ephemeral container)
