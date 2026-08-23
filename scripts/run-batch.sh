#!/usr/bin/env bash
# Runs scripts/run-task.sh over every task_id in tasks/tasks.json (or a
# filtered subset), stopping the whole batch the moment a task signals a
# rate-limit/quota hit (exit 3) rather than burning through the remaining
# tasks against an exhausted subscription quota. Ordinary task failures
# (exit 1) don't stop the batch — one broken checkout or one bad agent run
# shouldn't cost you the rest of the sample.
#
# Usage: scripts/run-batch.sh [--track java|python] [--repo org/name] [--limit N] [--arm <name>] [--rep <n>] [--agent <claude|agy>]
# Requires: jq
# --arm, --rep, and --agent are forwarded as-is to scripts/run-task.sh — see
# that script's header for the arm list (baseline|graphify|serena|leanctx|
# caveman), the repeat-numbering scheme, and the agent choice. Default to
# baseline / rep 1 / claude there if omitted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/tasks/tasks.json"

TRACK_FILTER=""
REPO_FILTER=""
LIMIT=""
ARM="baseline"
REP=1
AGENT="claude"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --track) TRACK_FILTER="$2"; shift 2 ;;
        --repo) REPO_FILTER="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --arm) ARM="$2"; shift 2 ;;
        --rep) REP="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 2
fi

JQ_FILTER='.tasks[]'
[[ -n "$TRACK_FILTER" ]] && JQ_FILTER="$JQ_FILTER | select(.track == \"$TRACK_FILTER\")"
[[ -n "$REPO_FILTER"  ]] && JQ_FILTER="$JQ_FILTER | select(.repo == \"$REPO_FILTER\")"
JQ_FILTER="$JQ_FILTER | .task_id"

# `while read` loop rather than `mapfile` (bash 4+ only) — this needs to
# work on whatever bash ships on the EC2 AMI in use, and on macOS's stock
# bash 3.2 for local testing; verified `mapfile` isn't available there.
TASK_IDS=()
while IFS= read -r id; do
    TASK_IDS+=("$id")
done < <(jq -r "$JQ_FILTER" "$TASKS_FILE")
if [[ -n "$LIMIT" ]]; then
    TASK_IDS=("${TASK_IDS[@]:0:$LIMIT}")
fi

echo "batch: ${#TASK_IDS[@]} task(s) selected (track=${TRACK_FILTER:-any} repo=${REPO_FILTER:-any} limit=${LIMIT:-none} arm=$ARM rep=$REP agent=$AGENT)"

DONE=0
SKIPPED=0
FAILED=0
declare -a FAILED_IDS=()

for TASK_ID in "${TASK_IDS[@]}"; do
    echo "=== $TASK_ID ==="
    # tee to stderr so output still streams live to the terminal during a
    # real (possibly hours-long) batch, while OUTPUT captures it to tell a
    # resume-skip apart from a fresh completion for the summary counts below.
    set +e
    OUTPUT="$("$SCRIPT_DIR/run-task.sh" "$TASK_ID" --arm "$ARM" --rep "$REP" --agent "$AGENT" 2>&1 | tee /dev/stderr)"
    RC=${PIPESTATUS[0]}
    set -e

    case "$RC" in
        0)
            if grep -q "^skip:" <<<"$OUTPUT"; then
                SKIPPED=$((SKIPPED + 1))
            else
                DONE=$((DONE + 1))
            fi
            ;;
        1)
            FAILED=$((FAILED + 1))
            FAILED_IDS+=("$TASK_ID")
            ;;
        3)
            echo "batch stopped: rate-limit/quota hit on $TASK_ID" >&2
            echo "summary: done=$DONE failed=$FAILED skipped=$SKIPPED stopped_at=$TASK_ID"
            exit 3
            ;;
        *)
            echo "batch stopped: unexpected exit $RC on $TASK_ID" >&2
            exit "$RC"
            ;;
    esac
done

echo "summary: done=$DONE failed=$FAILED skipped=$SKIPPED"
if [[ $FAILED -gt 0 ]]; then
    echo "failed task_ids: ${FAILED_IDS[*]}"
fi
