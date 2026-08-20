#!/usr/bin/env bash
# Minimal skeleton for running one benchmark task in an ephemeral container.
# This is a starting point, not a finished harness — it does not yet parse
# Multi-SWE-bench / SWE-bench-Verified task JSON, apply the task's test patch,
# or score pass/fail. See TODOs below and the open items in
# token-optimization-stack/BENCHMARKING.md.
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

PROMPT="$(cat "$PROMPT_FILE")"

docker compose run --rm "${TRACK}-track" bash -c "
    set -euo pipefail
    git clone --depth 50 '$REPO_URL' /workspace/repo
    cd /workspace/repo
    claude -p '$PROMPT' > /results/${TASK_ID}.log 2>&1
"

echo "done: results/${TASK_ID}.log"

# TODO before real runs:
# - pull task prompt + gold patch + test patch from the actual Multi-SWE-bench /
#   SWE-bench-Verified dataset files instead of a manually supplied prompt file
# - after the agent run, apply the task's test patch and run the repo's test
#   suite inside the same container to get pass/fail, per BENCHMARKING.md
# - capture token/cost/tool-call counts from Agentsview for this session,
#   tagged with $TASK_ID, instead of just the raw claude log
# - detect a rate-limit/quota response from `claude -p` (exact error text not
#   yet verified) and exit the whole batch cleanly instead of letting every
#   remaining task in the run fail one-by-one against an exhausted quota
