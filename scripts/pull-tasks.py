#!/usr/bin/env python3
"""Pull a fixed, versioned task sample into tasks/tasks.json.

Sources (real, verified against upstream — see BENCHMARKING.md in
token-optimization-stack for the repo list this must match):

- Python: princeton-nlp/SWE-bench_Verified (HF parquet). 500 rows, 12 repos,
  ships an official `difficulty` column with 4 buckets (<15 min fix,
  15 min-1 hour, 1-4 hours, >4 hours) — confirmed by inspecting the parquet
  directly, not from the dataset card text.
- Java: ByteDance-Seed/Multi-SWE-bench (HF jsonl, one file per repo). No
  official difficulty field. Quality-gated per-instance (see
  JAVA_QUALITY_GATE below) since, unlike SWE-bench Verified, this dataset
  is not pre-filtered to "known good" — some instances' fix_patch does not
  actually turn f2p tests green. Difficulty is a patch-size tertile proxy,
  clearly labeled as such (not an official annotation).

Output rows share a common schema across both tracks (see build_python_row /
build_java_row) so scripts/run-task.sh and any future scorer can consume
either without a track-specific code path for basic fields.

Also caches the raw Multi-SWE-bench per-repo jsonl files under
tasks/raw/multi-swe-bench-java/ — scripts/score-java-batch.sh needs the full
original records (build/env metadata, not just the flat fields kept in
tasks.json) as --dataset_files for the real multi-swe-bench harness. Cached
rather than re-fetched at scoring time so scoring runs against exactly what
was sampled from, matching the "fixed, versioned" principle for tasks.json
itself.

Deps: pip install pandas pyarrow requests
Usage: python3 scripts/pull-tasks.py [--seed 42] [--min-per-repo 20] [--out tasks/tasks.json]
"""

import argparse
import io
import json
import os
import random
import sys
from collections import defaultdict

import requests

SWE_BENCH_VERIFIED_PARQUET_URL = (
    "https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified/"
    "resolve/main/data/test-00000-of-00001.parquet"
)

# repo -> Multi-SWE-bench jsonl filename, confirmed present under java/ in
# ByteDance-Seed/Multi-SWE-bench at time of writing.
JAVA_REPOS = {
    "alibaba/fastjson2": "alibaba__fastjson2_dataset.jsonl",
    "elastic/logstash": "elastic__logstash_dataset.jsonl",
    "mockito/mockito": "mockito__mockito_dataset.jsonl",
    "FasterXML/jackson-databind": "fasterxml__jackson-databind_dataset.jsonl",
}
MULTI_SWE_BENCH_JAVA_BASE = (
    "https://huggingface.co/datasets/ByteDance-Seed/Multi-SWE-bench/resolve/main/java/"
)

# Expected Python repos per BENCHMARKING.md — cross-checked against what the
# parquet actually contains (fail loudly on drift rather than silently
# sampling from an unexpected repo list).
EXPECTED_PYTHON_REPOS = {
    "django/django", "sympy/sympy", "scikit-learn/scikit-learn",
    "matplotlib/matplotlib", "sphinx-doc/sphinx", "pytest-dev/pytest",
    "psf/requests", "pallets/flask", "pylint-dev/pylint", "astropy/astropy",
    "mwaskom/seaborn", "pydata/xarray",
}

DIFFICULTY_BUCKETS = ["<15 min fix", "15 min - 1 hour", "1-4 hours", ">4 hours"]


def log(msg):
    print(msg, file=sys.stderr)


def fetch_bytes(url):
    r = requests.get(url, timeout=120)
    r.raise_for_status()
    return r.content


def load_python_rows():
    import pandas as pd

    log(f"fetching {SWE_BENCH_VERIFIED_PARQUET_URL}")
    df = pd.read_parquet(io.BytesIO(fetch_bytes(SWE_BENCH_VERIFIED_PARQUET_URL)))

    seen_repos = set(df["repo"].unique())
    if seen_repos != EXPECTED_PYTHON_REPOS:
        log(f"WARNING: repo set drift vs BENCHMARKING.md.\n"
            f"  missing: {EXPECTED_PYTHON_REPOS - seen_repos}\n"
            f"  unexpected: {seen_repos - EXPECTED_PYTHON_REPOS}")

    rows = []
    for rec in df.to_dict(orient="records"):
        rows.append(build_python_row(rec))
    return rows


def build_python_row(rec):
    return {
        "task_id": rec["instance_id"],
        "track": "python",
        "repo": rec["repo"],
        "base_commit": rec["base_commit"],
        "problem_statement": rec["problem_statement"],
        "patch": rec["patch"],
        "test_patch": rec["test_patch"],
        "FAIL_TO_PASS": list(rec["FAIL_TO_PASS"]),
        "PASS_TO_PASS": list(rec["PASS_TO_PASS"]),
        "difficulty": rec["difficulty"],
        "difficulty_source": "official",
        "source_dataset": "princeton-nlp/SWE-bench_Verified",
    }


def java_quality_gate(rec):
    """Keep only instances where the fix_patch is actually demonstrated to
    turn real failing tests green: at least one f2p test, and none of those
    specific f2p tests are in the fix run's failed set.

    Deliberately NOT `fix_patch_result.failed_count == 0` (tried that first):
    logstash's recorded harness has environment-level noise (a
    'logstash-core:rubyTests'/rspec harness task, or a 'bootstrap' step)
    that fails on every single instance in the file regardless of the fix,
    unrelated to any f2p test — that gate zeroed out all 38 logstash
    instances. Checking only the f2p tests specifically is the actual
    SWE-bench-style correctness criterion and isn't fooled by that noise
    (verified: all 38 logstash instances pass this version)."""
    f2p = set(rec.get("f2p_tests") or {})
    if not f2p:
        return False
    fix_result = rec.get("fix_patch_result") or {}
    failed = set(fix_result.get("failed_tests") or [])
    return f2p.isdisjoint(failed)


def patch_line_delta(patch_text):
    added = sum(1 for l in patch_text.splitlines() if l.startswith("+") and not l.startswith("+++"))
    removed = sum(1 for l in patch_text.splitlines() if l.startswith("-") and not l.startswith("---"))
    return added + removed


def build_java_row(rec, difficulty_label):
    issues = rec.get("resolved_issues") or []
    if issues:
        problem_statement = f"{issues[0]['title']}\n\n{issues[0].get('body', '')}"
    else:
        # No linked issue — fall back to the PR's own title/body, same shape
        # as problem_statement for the python track (title + body text).
        problem_statement = f"{rec['title']}\n\n{rec.get('body', '')}"

    return {
        "task_id": rec["instance_id"],
        "track": "java",
        "repo": f"{rec['org']}/{rec['repo']}",
        # org/number kept separately (not just folded into "repo"/"task_id")
        # because scripts/score-java-batch.sh has to build multi-swe-bench's
        # own Patch record shape ({org, repo, number, fix_patch}) later —
        # that schema is fixed by their harness, confirmed by inspecting
        # multi_swe_bench.harness.run_evaluation.Patch / PullRequestBase.
        "org": rec["org"],
        "number": rec["number"],
        "base_commit": rec["base"]["sha"],
        "problem_statement": problem_statement,
        "patch": rec["fix_patch"],
        "test_patch": rec["test_patch"],
        "FAIL_TO_PASS": list(rec["f2p_tests"].keys()),
        "PASS_TO_PASS": list(rec["p2p_tests"].keys()),
        "difficulty": difficulty_label,
        "difficulty_source": "patch_size_proxy",
        "source_dataset": "ByteDance-Seed/Multi-SWE-bench",
    }


def load_java_rows(raw_dir):
    rows = []
    os.makedirs(raw_dir, exist_ok=True)
    for repo, filename in JAVA_REPOS.items():
        url = MULTI_SWE_BENCH_JAVA_BASE + filename
        log(f"fetching {url}")
        raw_bytes = fetch_bytes(url)
        with open(os.path.join(raw_dir, filename), "wb") as f:
            f.write(raw_bytes)

        text = raw_bytes.decode("utf-8")
        raw = [json.loads(line) for line in text.splitlines() if line.strip()]
        gated = [r for r in raw if java_quality_gate(r)]
        log(f"  {repo}: {len(raw)} instances, {len(gated)} pass quality gate")

        deltas = [patch_line_delta(r["fix_patch"]) for r in gated]
        if deltas:
            sorted_deltas = sorted(deltas)
            t1 = sorted_deltas[len(sorted_deltas) // 3]
            t2 = sorted_deltas[2 * len(sorted_deltas) // 3]
        else:
            t1 = t2 = 0

        for rec, delta in zip(gated, deltas):
            label = "small" if delta <= t1 else ("medium" if delta <= t2 else "large")
            rows.append(build_java_row(rec, label))
    return rows


def stratified_sample(rows, key_fn, n, rng):
    """Proportional-to-bucket-size sample of n rows from one repo's rows,
    stratified by key_fn(row). Falls back to all rows if fewer than n exist."""
    if len(rows) <= n:
        return list(rows)

    buckets = defaultdict(list)
    for r in rows:
        buckets[key_fn(r)].append(r)
    for b in buckets.values():
        rng.shuffle(b)

    # Proportional allocation with largest-remainder rounding so every
    # non-empty bucket gets at least one slot if room allows.
    total = len(rows)
    quotas = {k: (len(v) / total) * n for k, v in buckets.items()}
    alloc = {k: int(q) for k, q in quotas.items()}
    remainder = n - sum(alloc.values())
    for k in sorted(quotas, key=lambda k: quotas[k] - alloc[k], reverse=True)[:remainder]:
        alloc[k] += 1

    sample = []
    for k, bucket in buckets.items():
        sample.extend(bucket[: alloc[k]])
    return sample


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42,
                     help="RNG seed, fixed so the sample is reproducible from this input set")
    ap.add_argument("--min-per-repo", type=int, default=20,
                     help="target sample size per repo (BENCHMARKING.md: minimum 20 in the verified tier)")
    ap.add_argument("--out", default="tasks/tasks.json")
    ap.add_argument("--raw-dir", default="tasks/raw/multi-swe-bench-java",
                     help="where to cache the full raw Multi-SWE-bench per-repo jsonl files")
    ap.add_argument("--python-only", action="store_true")
    ap.add_argument("--java-only", action="store_true")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    all_rows = []

    if not args.java_only:
        all_rows.extend(load_python_rows())
    if not args.python_only:
        all_rows.extend(load_java_rows(args.raw_dir))

    by_repo = defaultdict(list)
    for r in all_rows:
        by_repo[r["repo"]].append(r)

    sampled = []
    for repo, rows in sorted(by_repo.items()):
        track = rows[0]["track"]
        picked = stratified_sample(rows, key_fn=lambda r: r["difficulty"], n=args.min_per_repo, rng=rng)
        if len(picked) < args.min_per_repo:
            log(f"WARNING: {repo} ({track}) has only {len(picked)} eligible instances, "
                f"below the {args.min_per_repo}-per-repo target — taking all of them")
        sampled.extend(picked)
        log(f"{repo}: sampled {len(picked)}/{len(rows)}")

    sampled.sort(key=lambda r: (r["track"], r["repo"], r["task_id"]))

    out = {
        "_comment": (
            "Generated by scripts/pull-tasks.py — do not hand-edit. "
            "Regenerate with the same --seed to reproduce, or bump --seed "
            "and commit the new file to change the sample."
        ),
        "seed": args.seed,
        "min_per_repo": args.min_per_repo,
        "sources": {
            "python": "princeton-nlp/SWE-bench_Verified",
            "java": "ByteDance-Seed/Multi-SWE-bench",
        },
        "tasks": sampled,
    }

    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    log(f"wrote {len(sampled)} tasks to {args.out}")


if __name__ == "__main__":
    main()
