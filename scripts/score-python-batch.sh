#!/usr/bin/env bash
# Scores completed python-track task runs against real ground truth, using
# the official swebench evaluation harness rather than hand-rolling
# per-repo/version test commands ourselves. SWE-bench Verified instances
# each need a specific conda env + install spec per repo/version
# (django != sympy != matplotlib) — that matrix is exactly what `swebench`
# already encodes and validates; reimplementing it here risks silently
# wrong pass/fail, which is worse than not scoring at all.
#
# What this does: builds a predictions.json (the harness's own input format:
# {instance_id, model_patch, model_name_or_path} per task) from each
# attempted task's results/<task_id>.patch (captured by scripts/run-task.sh
# via `git diff` inside the agent's container), then hands it to
# `swebench.harness.run_evaluation`, which builds its own per-instance
# Docker image, applies the patch, runs the real test suite, and reports
# resolved/unresolved per FAIL_TO_PASS/PASS_TO_PASS.
#
# VERIFIED: CLI flags and predictions.json schema below were confirmed by
# reading the installed swebench package source directly (harness/
# run_evaluation.py's argparse block, harness/utils.py's
# get_predictions_from_file) — not guessed from docs. Also verified end to
# end on a real Docker host: astropy__astropy-12907 ran clean through
# run_evaluation and reported resolved.
#
# Usage: scripts/score-python-batch.sh [--arm <name>] [--rep <n>] [--agent <claude|agy>] [task_id ...]   # default: baseline arm, rep 1, claude, every attempted python task
# --arm selects which ablation arm's results dir to score — see
# scripts/run-task.sh's header for the arm list. Defaults to baseline.
# --rep selects which repeat to score (default 1); see run-task.sh's --rep.
# --agent selects which agent's results tree (results/ vs results-agy/) to
# score (default claude); see run-task.sh's --agent.
# Requires: pip install swebench, jq, Docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/tasks/tasks.json"
DATASET_NAME="SWE-bench/SWE-bench_Verified"   # NOT princeton-nlp — that mirror lacks the "image" field the harness now requires

ARM="baseline"
REP=1
AGENT="claude"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arm) ARM="$2"; shift 2 ;;
        --rep) REP="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

# rep 1 stays at <results-dir>/<arm>/ (matches scripts/run-task.sh's
# default, no migration needed); rep N>1 reads <results-dir>/<arm>/repN/
# instead. <results-dir> is results/ for claude, results-agy/ for agy.
ARM_REL="$ARM"
if [[ "$REP" -gt 1 ]]; then
    ARM_REL="$ARM/rep$REP"
fi
if [[ "$AGENT" == "claude" ]]; then
    RESULTS_DIR="$REPO_ROOT/results/$ARM_REL"
else
    RESULTS_DIR="$REPO_ROOT/results-agy/$ARM_REL"
fi

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 1
fi
if ! python3 -c "import swebench" 2>/dev/null; then
    echo "swebench not installed — run: pip install swebench" >&2
    exit 1
fi

TASK_IDS=()
if [[ $# -gt 0 ]]; then
    TASK_IDS=("$@")
else
    while IFS= read -r id; do
        TASK_IDS+=("$id")
    done < <(jq -r '.tasks[] | select(.track=="python") | .task_id' "$TASKS_FILE")
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
EMPTY_PATCH="$WORK_DIR/empty.patch"
: > "$EMPTY_PATCH"
PREDICTIONS_JSONL="$WORK_DIR/predictions.jsonl"
: > "$PREDICTIONS_JSONL"

SCORED_IDS=()
for TASK_ID in "${TASK_IDS[@]}"; do
    RESULT_JSON="$RESULTS_DIR/${TASK_ID}.result.json"
    [[ -f "$RESULT_JSON" ]] || continue   # not attempted yet — skip silently, not an error

    PATCH_FILE="$RESULTS_DIR/${TASK_ID}.patch"
    if [[ ! -f "$PATCH_FILE" ]]; then
        echo "WARNING: no .patch for $TASK_ID (agent likely crashed before diff capture) — scoring as empty patch (guaranteed unresolved)" >&2
        PATCH_FILE="$EMPTY_PATCH"
    fi

    # --rawfile reads the diff straight from the file into the jq program's
    # variable rather than round-tripping arbitrary multi-line diff text
    # through a shell variable first — same reasoning as run-task.sh's
    # prompt-file mount, just for output instead of input.
    jq -n --arg instance_id "$TASK_ID" --rawfile model_patch "$PATCH_FILE" \
        '{instance_id: $instance_id, model_patch: $model_patch, model_name_or_path: "token-stack-benchmarks"}' \
        >> "$PREDICTIONS_JSONL"
    SCORED_IDS+=("$TASK_ID")
done

if [[ ${#SCORED_IDS[@]} -eq 0 ]]; then
    echo "no attempted python-track tasks found under $RESULTS_DIR/ — run scripts/run-batch.sh --track python --arm $ARM first" >&2
    exit 1
fi

jq -s '.' "$PREDICTIONS_JSONL" > "$WORK_DIR/predictions.json"

RUN_ID="score-$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$RESULTS_DIR/python-scores"
mkdir -p "$REPORT_DIR"

echo "scoring ${#SCORED_IDS[@]} task(s) (arm=$ARM rep=$REP agent=$AGENT) against $DATASET_NAME, run_id=$RUN_ID"

python3 -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET_NAME" \
    --predictions_path "$WORK_DIR/predictions.json" \
    --instance_ids "${SCORED_IDS[@]}" \
    --run_id "$RUN_ID" \
    --report_dir "$REPORT_DIR"

echo "done — report under $REPORT_DIR (run_id=$RUN_ID; exact report filename comes from the harness itself)"
