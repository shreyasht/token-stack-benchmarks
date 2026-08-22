#!/usr/bin/env bash
# Prints token/cost counts for one task_id across every ablation arm that has
# been run for it, side by side — the actual answer to "how do we check the
# token savings" for a set of scripts/run-task.sh --arm runs. Reads straight
# out of each arm's own results/<arm>/<task_id>.result.json (the raw `claude
# -p --output-format json` output captured by run-task.sh) rather than
# re-deriving anything.
#
# Usage: scripts/compare-arms.sh <task_id>
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AGENT="claude"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent) AGENT="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

TASK_ID="${1:?task id (task_id field in tasks/tasks.json)}"

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 1
fi

# Same arm list/order as scripts/run-task.sh's --arm values, cumulative.
ARMS=(baseline graphify serena headroom leanctx caveman)

if [[ "$AGENT" == "claude" ]]; then
    RESULTS_BASE="$REPO_ROOT/results"
else
    RESULTS_BASE="$REPO_ROOT/results-agy"
fi

FOUND=0
ROWS=()
for ARM in "${ARMS[@]}"; do
    RESULT_JSON="$RESULTS_BASE/$ARM/${TASK_ID}.result.json"
    [[ -f "$RESULT_JSON" ]] || continue
    FOUND=1
    ROWS+=("$(jq -c --arg arm "$ARM" \
        '{arm: $arm, input_tokens: (.usage.input_tokens // null), output_tokens: (.usage.output_tokens // null), cache_creation_input_tokens: (.usage.cache_creation_input_tokens // null), cache_read_input_tokens: (.usage.cache_read_input_tokens // null), total_cost_usd: .total_cost_usd, num_turns: .num_turns, is_error: .is_error}' \
        "$RESULT_JSON")")
done

if [[ "$FOUND" -eq 0 ]]; then
    echo "no results found for $TASK_ID under any of: ${ARMS[*]} (looked under $(basename "$RESULTS_BASE")/<arm>/${TASK_ID}.result.json)" >&2
    exit 1
fi

printf '%s\n' "${ROWS[@]}" | jq -s '.' | jq -r '
    (["arm","input_tokens","output_tokens","cache_creation","cache_read","cost_usd","turns","is_error"]),
    (.[] | [.arm, .input_tokens, .output_tokens, .cache_creation_input_tokens, .cache_read_input_tokens, .total_cost_usd, .num_turns, .is_error])
    | @tsv
' | column -t -s $'\t'
