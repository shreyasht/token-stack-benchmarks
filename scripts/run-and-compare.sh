#!/usr/bin/env bash
# Runs a batch of tasks under a small set of ablation arms (default:
# baseline vs caveman — the full stack) and prints per-task + aggregate
# token/cost savings of the last arm vs the first. Wraps scripts/run-task.sh
# for the actual runs; does NOT score correctness — run
# scripts/score-python-batch.sh / scripts/score-java-batch.sh separately
# per arm if you need resolved/unresolved too.
#
# Usage: scripts/run-and-compare.sh [--track java|python] [--repo org/name]
#          [--limit N] [--arms arm1,arm2,...] [--agent <claude|agy>]
#          [--model <model>] [--effort <level>] [task_id ...]
# --arms: comma-separated ablation arms to run, in order. First arm is the
#   savings baseline, last arm is what it's compared against (default:
#   baseline,caveman). See scripts/run-task.sh's header for valid arm names.
# --limit N selects the first N matching task_ids from tasks/tasks.json
#   (same selection as scripts/run-batch.sh) when no task_id is given
#   positionally. Give explicit task_id(s) instead to run exactly those.
# --model/--effort forwarded to scripts/run-task.sh as-is (see its header).
# Reruns are cheap: scripts/run-task.sh skips any arm+task already run.
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/tasks/tasks.json"

TRACK_FILTER=""
REPO_FILTER=""
LIMIT=""
ARMS_CSV="baseline,caveman"
AGENT="claude"
MODEL=""
EFFORT=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --track) TRACK_FILTER="$2"; shift 2 ;;
        --repo) REPO_FILTER="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --arms) ARMS_CSV="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --effort) EFFORT="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 1
fi

IFS=',' read -ra ARMS <<<"$ARMS_CSV"
if [[ "${#ARMS[@]}" -lt 2 ]]; then
    echo "--arms needs at least 2 arms (comma-separated) to compare savings" >&2
    exit 2
fi
BASELINE_ARM="${ARMS[0]}"
FINAL_ARM="${ARMS[-1]}"

TASK_IDS=()
if [[ $# -gt 0 ]]; then
    TASK_IDS=("$@")
else
    JQ_FILTER='.tasks[]'
    [[ -n "$TRACK_FILTER" ]] && JQ_FILTER="$JQ_FILTER | select(.track == \"$TRACK_FILTER\")"
    [[ -n "$REPO_FILTER"  ]] && JQ_FILTER="$JQ_FILTER | select(.repo == \"$REPO_FILTER\")"
    JQ_FILTER="$JQ_FILTER | .task_id"
    while IFS= read -r id; do
        TASK_IDS+=("$id")
    done < <(jq -r "$JQ_FILTER" "$TASKS_FILE")
    if [[ -n "$LIMIT" ]]; then
        TASK_IDS=("${TASK_IDS[@]:0:$LIMIT}")
    fi
fi

if [[ "${#TASK_IDS[@]}" -eq 0 ]]; then
    echo "no tasks selected (track=${TRACK_FILTER:-any} repo=${REPO_FILTER:-any} limit=${LIMIT:-none})" >&2
    exit 2
fi

echo "run-and-compare: ${#TASK_IDS[@]} task(s), arms=${ARMS_CSV} agent=$AGENT model=${MODEL:-default} effort=${EFFORT:-default}"

for TASK_ID in "${TASK_IDS[@]}"; do
    for ARM in "${ARMS[@]}"; do
        echo "=== $TASK_ID / $ARM ==="
        set +e
        "$SCRIPT_DIR/run-task.sh" "$TASK_ID" --arm "$ARM" --agent "$AGENT" --model "$MODEL" --effort "$EFFORT"
        RC=$?
        set -e
        if [[ "$RC" -eq 3 ]]; then
            echo "stopped: rate-limit/quota hit on $TASK_ID / $ARM" >&2
            exit 3
        fi
        # exit 1 (task failure) is not fatal to the batch — keep going, it'll
        # just be missing from the comparison table below.
    done
done

# Same path-segment logic as scripts/compare-arms.sh: results/ or
# results-agy/, plus a model-<model>[-effort-<level>]/ subdir when set.
if [[ "$AGENT" == "claude" ]]; then
    RESULTS_BASE="$REPO_ROOT/results"
else
    RESULTS_BASE="$REPO_ROOT/results-agy"
fi
MODEL_SEGMENT_SUFFIX=""
if [[ -n "$MODEL" || -n "$EFFORT" ]]; then
    MODEL_SEGMENT=""
    if [[ -n "$MODEL" ]]; then
        MODEL_SLUG="$(tr '/:' '--' <<<"$MODEL")"
        MODEL_SEGMENT="model-$MODEL_SLUG"
    fi
    if [[ -n "$EFFORT" ]]; then
        MODEL_SEGMENT="${MODEL_SEGMENT:+$MODEL_SEGMENT-}effort-$EFFORT"
    fi
    MODEL_SEGMENT_SUFFIX="/$MODEL_SEGMENT"
fi

echo
echo "--- savings: $BASELINE_ARM -> $FINAL_ARM ---"
ROWS=()
for TASK_ID in "${TASK_IDS[@]}"; do
    BASE_JSON="$RESULTS_BASE/$BASELINE_ARM$MODEL_SEGMENT_SUFFIX/${TASK_ID}.result.json"
    FINAL_JSON="$RESULTS_BASE/$FINAL_ARM$MODEL_SEGMENT_SUFFIX/${TASK_ID}.result.json"
    [[ -f "$BASE_JSON" && -f "$FINAL_JSON" ]] || continue
    ROWS+=("$(jq -sc --arg id "$TASK_ID" '
        {
            task_id: $id,
            base_input: .[0].usage.input_tokens,
            final_input: .[1].usage.input_tokens,
            base_cost: .[0].total_cost_usd,
            final_cost: .[1].total_cost_usd
        }
        | . + {
            input_saved_pct: (if .base_input > 0 then (100 * (.base_input - .final_input) / .base_input) else null end),
            cost_saved_pct: (if .base_cost > 0 then (100 * (.base_cost - .final_cost) / .base_cost) else null end)
        }
    ' "$BASE_JSON" "$FINAL_JSON")")
done

if [[ "${#ROWS[@]}" -eq 0 ]]; then
    echo "no task has both $BASELINE_ARM and $FINAL_ARM results yet" >&2
    exit 1
fi

printf '%s\n' "${ROWS[@]}" | jq -s '.' | jq -r '
    (["task_id","base_input","final_input","input_saved_%","base_cost_usd","final_cost_usd","cost_saved_%"]),
    (.[] | [.task_id, .base_input, .final_input, (.input_saved_pct | round), .base_cost, .final_cost, (.cost_saved_pct * 100 | round / 100)])
    | @tsv
' | column -t -s $'\t'

printf '%s\n' "${ROWS[@]}" | jq -s '
    {
        avg_input_saved_pct: (map(.input_saved_pct) | add / length),
        avg_cost_saved_pct: (map(.cost_saved_pct) | add / length),
        tasks_compared: length
    }
'
