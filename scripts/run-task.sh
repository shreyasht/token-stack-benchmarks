#!/usr/bin/env bash
# Minimal skeleton for running one benchmark task in an ephemeral container.
# This is a starting point, not a finished harness — it does not yet load a
# task's row from tasks/tasks.json (see scripts/pull-tasks.py), apply the
# task's test patch, or score pass/fail. See TODOs below and the open items
# in token-optimization-stack/BENCHMARKING.md.
#
# Usage: scripts/run-task.sh <java|python> <repo-url> <task-id> <prompt-file>

set -euo pipefail

TRACK="${1:?track: java or python}"
REPO_URL="${2:?repo git URL}"
TASK_ID="${3:?task id, used for the results filename}"
PROMPT_FILE="${4:?path to a file containing the task prompt/issue text}"

if [[ "$TRACK" != "java" && "$TRACK" != "python" ]]; then
    echo "track must be 'java' or 'python'" >&2
    exit 1
fi

# Resume-safety: running on subscription auth, not a metered API key, so a
# batch that hits a usage cap gets picked up again later (e.g. "tomorrow")
# without re-spending quota on tasks already done. Skip anything already
# completed instead of re-running it.
if [[ -f "results/${TASK_ID}.log" ]]; then
    echo "skip: results/${TASK_ID}.log already exists"
    exit 0
fi

# Prompt content is real-world GitHub issue text — will contain apostrophes,
# quotes, backticks, $ signs. Never string-interpolate it into a shell
# command (that broke on the first real issue tried: an apostrophe closed
# the quoting early). Mount it as a file instead and let the container's own
# shell read it via `cat`, so nothing about its content ever touches how the
# script itself is parsed. Same treatment for REPO_URL/TASK_ID via -e, even
# though they're lower-risk, so no variable is ever substituted into script
# text.
docker compose run --rm \
    -e REPO_URL="$REPO_URL" \
    -e TASK_ID="$TASK_ID" \
    -v "$(realpath "$PROMPT_FILE"):/tmp/task-prompt.txt:ro" \
    "${TRACK}-track" bash -c '
        set -euo pipefail
        git clone --depth 50 "$REPO_URL" /workspace/repo
        cd /workspace/repo
        claude -p "$(cat /tmp/task-prompt.txt)" --dangerously-skip-permissions > "/results/${TASK_ID}.log" 2>&1
        # If a permission prompt still blocks here despite the flag above,
        # known issue on non-interactive first runs — see
        # anthropics/claude-code#52506. Fallback: --permission-mode bypassPermissions
    '

echo "done: results/${TASK_ID}.log"

# TODO before real runs:
# - tasks/tasks.json is now populated (scripts/pull-tasks.py) with real
#   problem_statement/patch/test_patch/FAIL_TO_PASS/PASS_TO_PASS per task —
#   this script still takes a hand-supplied prompt file instead of loading
#   task_id's row from tasks.json. Wire that up.
# - after the agent run, apply the task's test patch and run the repo's test
#   suite inside the same container to get pass/fail, per BENCHMARKING.md
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
