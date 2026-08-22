#!/usr/bin/env bash
# Scores completed java-track task runs against real ground truth, using the
# official multi-swe-bench evaluation harness rather than hand-rolling
# Maven/Gradle invocations ourselves. Same reasoning as
# scripts/score-python-batch.sh for the Python track: this is the same
# harness (and, for the Multi-SWE-bench-sourced repos, literally the same
# infra) that produced the f2p_tests/p2p_tests ground truth in
# tasks/raw/multi-swe-bench-java/*.jsonl in the first place.
#
# What this does: builds a patch_files jsonl in multi-swe-bench's own Patch
# record shape ({org, repo, number, fix_patch}) from each attempted task's
# results/<task_id>.patch, then hands it plus the cached raw dataset files
# to `multi_swe_bench.harness.run_evaluation --mode evaluation`, which
# builds its own per-instance Docker image, applies the patch, and reports
# resolved/unresolved. Scoping is by PR number: the harness only builds/runs
# instances whose PR number appears in patch_files (confirmed by reading
# run_evaluation.py's Instances property — `instance.pr.number in
# self.patch_numbers`), so passing the full raw dataset_files as-is is fine.
#
# VERIFIED: CLI flags, Patch schema, and PR-number scoping below were
# confirmed by reading the installed multi-swe-bench package source
# directly, not guessed from docs. Also verified end-to-end on a real
# Docker host: alibaba__fastjson2-1245 ran clean through
# run_evaluation --mode evaluation and produced a final_report.json
# (unresolved — correct outcome for that patch, not a script bug).
#
# Usage: scripts/score-java-batch.sh [task_id ...]   # default: every attempted java task
# Requires: multi-swe-bench (not on PyPI — git clone + `make install` from
# https://github.com/multi-swe-bench/multi-swe-bench), jq, Docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/tasks/tasks.json"
RESULTS_DIR="$REPO_ROOT/results"
RAW_DATASET_DIR="$REPO_ROOT/tasks/raw/multi-swe-bench-java"

if ! command -v jq >/dev/null; then
    echo "jq required (dnf install -y jq / apt-get install -y jq)" >&2
    exit 1
fi
if ! python3 -c "import multi_swe_bench" 2>/dev/null; then
    echo "multi-swe-bench not installed — not on PyPI, run: git clone git@github.com:multi-swe-bench/multi-swe-bench.git && cd multi-swe-bench && make install" >&2
    exit 1
fi
if [[ ! -d "$RAW_DATASET_DIR" ]] || [[ -z "$(ls -A "$RAW_DATASET_DIR" 2>/dev/null)" ]]; then
    echo "no cached raw dataset files under $RAW_DATASET_DIR — run scripts/pull-tasks.py first" >&2
    exit 1
fi

TASK_IDS=()
if [[ $# -gt 0 ]]; then
    TASK_IDS=("$@")
else
    while IFS= read -r id; do
        TASK_IDS+=("$id")
    done < <(jq -r '.tasks[] | select(.track=="java") | .task_id' "$TASKS_FILE")
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
EMPTY_PATCH="$WORK_DIR/empty.patch"
: > "$EMPTY_PATCH"
PATCH_JSONL="$WORK_DIR/patches.jsonl"
: > "$PATCH_JSONL"

SCORED_IDS=()
for TASK_ID in "${TASK_IDS[@]}"; do
    RESULT_JSON="$RESULTS_DIR/${TASK_ID}.result.json"
    [[ -f "$RESULT_JSON" ]] || continue   # not attempted yet — skip silently, not an error

    TASK_ROW="$(jq --arg id "$TASK_ID" '[.tasks[] | select(.task_id == $id)] | first' "$TASKS_FILE")"
    if [[ "$TASK_ROW" == "null" ]]; then
        echo "WARNING: $TASK_ID has a result.json but no row in $TASKS_FILE — skipping" >&2
        continue
    fi
    ORG="$(jq -r '.org' <<<"$TASK_ROW")"
    NUMBER="$(jq -r '.number' <<<"$TASK_ROW")"
    REPO_SHORT="$(jq -r '.repo | split("/")[1]' <<<"$TASK_ROW")"

    PATCH_FILE="$RESULTS_DIR/${TASK_ID}.patch"
    if [[ ! -f "$PATCH_FILE" ]]; then
        echo "WARNING: no .patch for $TASK_ID (agent likely crashed before diff capture) — scoring as empty patch (guaranteed unresolved)" >&2
        PATCH_FILE="$EMPTY_PATCH"
    fi

    jq -nc --arg org "$ORG" --arg repo "$REPO_SHORT" --argjson number "$NUMBER" \
          --rawfile fix_patch "$PATCH_FILE" \
          '{org: $org, repo: $repo, number: $number, fix_patch: $fix_patch}' \
          >> "$PATCH_JSONL"
    SCORED_IDS+=("$TASK_ID")
done

if [[ ${#SCORED_IDS[@]} -eq 0 ]]; then
    echo "no attempted java-track tasks found under results/ — run scripts/run-batch.sh --track java first" >&2
    exit 1
fi

REPO_DIR="$WORK_DIR/repos"
OUTPUT_DIR="$RESULTS_DIR/java-scores"
LOG_DIR="$RESULTS_DIR/java-scores-logs"
mkdir -p "$REPO_DIR" "$OUTPUT_DIR" "$LOG_DIR"

echo "scoring ${#SCORED_IDS[@]} task(s) against tasks/raw/multi-swe-bench-java/*.jsonl"

python3 -m multi_swe_bench.harness.run_evaluation \
    --mode evaluation \
    --workdir "$WORK_DIR" \
    --patch_files "$PATCH_JSONL" \
    --dataset_files "$RAW_DATASET_DIR"/*.jsonl \
    --repo_dir "$REPO_DIR" \
    --output_dir "$OUTPUT_DIR" \
    --log_dir "$LOG_DIR"

echo "done — report under $OUTPUT_DIR"
