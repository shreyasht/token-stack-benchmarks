#!/usr/bin/env bash
# Runs one benchmark task in an ephemeral container. Track, repo, base
# commit, and problem statement come from tasks/tasks.json (see
# scripts/pull-tasks.py) — looked up by task_id, not passed on the command
# line. Still a skeleton, not a finished harness — see TODOs below and the
# open items in token-optimization-stack/BENCHMARKING.md.
#
# Usage: scripts/run-task.sh <task-id> [tasks-file]
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TASK_ID="${1:?task id (task_id field in tasks/tasks.json)}"
TASKS_FILE="${2:-$REPO_ROOT/tasks/tasks.json}"

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 1
fi

if [[ ! -f "$TASKS_FILE" ]]; then
    echo "tasks file not found: $TASKS_FILE" >&2
    exit 1
fi

# Resume-safety: running on subscription auth, not a metered API key, so a
# batch that hits a usage cap gets picked up again later (e.g. "tomorrow")
# without re-spending quota on tasks already done. Skip anything already
# completed instead of re-running it. Checked before the jq lookup below so
# a finished task's row doesn't even need to still be in the tasks file.
if [[ -f "$REPO_ROOT/results/${TASK_ID}.log" ]]; then
    echo "skip: results/${TASK_ID}.log already exists"
    exit 0
fi

# No `-e` here: it makes jq exit non-zero on a `null` result, which under
# `set -e` would abort the script on this assignment before the explicit
# not-found check below ever runs — verified this the hard way, it skips
# straight past the friendly error to a bare exit 1.
TASK_JSON="$(jq --arg id "$TASK_ID" '[.tasks[] | select(.task_id == $id)] | first' "$TASKS_FILE")"
if [[ "$TASK_JSON" == "null" ]]; then
    echo "task_id '$TASK_ID' not found in $TASKS_FILE" >&2
    exit 1
fi

TRACK="$(jq -r '.track' <<<"$TASK_JSON")"
REPO="$(jq -r '.repo' <<<"$TASK_JSON")"
BASE_COMMIT="$(jq -r '.base_commit' <<<"$TASK_JSON")"
REPO_URL="https://github.com/${REPO}.git"

if [[ "$TRACK" != "java" && "$TRACK" != "python" ]]; then
    echo "unexpected track '$TRACK' for task_id '$TASK_ID' (want java or python)" >&2
    exit 1
fi

# Prompt content is real-world GitHub issue text — will contain apostrophes,
# quotes, backticks, $ signs. Never string-interpolate it into a shell
# command (that broke on the first real issue tried: an apostrophe closed
# the quoting early). Mount it as a file instead and let the container's own
# shell read it via `cat`, so nothing about its content ever touches how the
# script itself is parsed. Same treatment for REPO_URL/TASK_ID/BASE_COMMIT
# via -e, even though they're lower-risk, so no variable is ever substituted
# into script text.
PROMPT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE"' EXIT
jq -r '.problem_statement' <<<"$TASK_JSON" > "$PROMPT_FILE"

# docker compose reads docker-compose.yml relative to cwd (for the ./results
# volume mount), so run from the repo root regardless of caller's cwd.
cd "$REPO_ROOT"
docker compose run --rm \
    -e REPO_URL="$REPO_URL" \
    -e TASK_ID="$TASK_ID" \
    -e BASE_COMMIT="$BASE_COMMIT" \
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
        claude -p "$(cat /tmp/task-prompt.txt)" --dangerously-skip-permissions > "/results/${TASK_ID}.log" 2>&1
        # If a permission prompt still blocks here despite the flag above,
        # known issue on non-interactive first runs — see
        # anthropics/claude-code#52506. Fallback: --permission-mode bypassPermissions
    '

echo "done: results/${TASK_ID}.log"

# TODO before real runs:
# - after the agent run, apply the task's test_patch and run the repo's test
#   suite inside the same container to get pass/fail (FAIL_TO_PASS /
#   PASS_TO_PASS are already in each tasks.json row), per BENCHMARKING.md
# - Agentsview has no push API (confirmed — it's a local file-watcher over
#   ~/.claude/projects/, not an endpoint); token/cost/tool-call counts for
#   this run are queryable there automatically now that the projects dir is
#   mounted (see docker-compose.yml), but there's no built-in way to tie a
#   specific Agentsview session back to $TASK_ID — figure out a tagging
#   scheme (session ID captured post-run? cwd-based naming?) before relying
#   on this for per-task numbers in a real batch
# - detect a rate-limit/quota response from `claude -p` (exact error text not
#   yet verified) and exit the whole batch cleanly instead of letting every
#   remaining task in the run fail one-by-one against an exhausted quota
