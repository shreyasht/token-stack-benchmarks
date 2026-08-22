# token-stack-benchmarks

Local, isolated benchmarking setup for the claims in
[token-optimization-stack](../token-optimization-stack/TOKEN_OPTIMIZATION_STACK.md).
Methodology lives there, in `BENCHMARKING.md` — this repo is just the execution
environment: containers, not methodology.

## Architecture

```
EC2 instance (disposable — the isolation boundary; destroy/rebuild between batches)
 └── docker compose
      ├── java-track image    — ephemeral, --rm per task
      └── python-track image  — ephemeral, --rm per task

Same instance, outside Docker
 └── agentsview serve         — persistent, collects results across all runs
```

Runs on a throwaway EC2 instance, not the local machine — matches the earlier
call to isolate the actual benchmark execution (untrusted third-party build/test
code across a dozen external repos) rather than the local dev environment.
No persistent IAM credentials on the instance; close the security group except
what you need; destroy/relaunch between benchmark batches rather than reusing
one long-running box, same reasoning as the original EC2-vs-laptop discussion.

Agentsview runs on the instance directly, not in a container. It doesn't
execute untrusted repo/build code — the task containers do that — so there's
no isolation reason to containerize it, and containerizing it would add an
unverified networking step for no security benefit.

## Why containers only for the task runners

Each benchmark task means cloning a real external repo (django, jackson-databind,
etc.) and running its build/test suite inside the same environment the agent has
shell access to. That's arbitrary third-party code execution by design — see the
isolation discussion in the parent conversation. `--rm` + resource caps + no
docker.sock mount keeps the blast radius to one throwaway container per task.

## Setup

**0. Get this repo onto the instance** — `git clone`/`scp`/`rsync`, your call.

**1. Launch/size the EC2 instance.** Gradle/maven builds on the Java-track
repos (jackson-databind, logstash, mockito) are the resource-heavy part —
size for that, not for idle. A 4 vCPU / 16GB instance (e.g. `m6i.xlarge` or
`c6i.xlarge`) is a reasonable starting point; bump if builds OOM or queue up
when running tasks in parallel. Install Docker + the Compose plugin per your
AMI's normal method (not scripted here — depends on which AMI you're using).

**2. Install and run Agentsview on the instance.** Real CLI (verified against
upstream README, differs from what token-optimization-stack's docs claimed —
see the note in that repo about fixing the Agentsview section):
```bash
pip install agentsview   # or: brew install --cask agentsview
agentsview serve
```
Default web UI: `http://127.0.0.1:8080`.

Agentsview has no push/ingest API (confirmed against upstream README) — it's
a local file-watcher over `~/.claude/projects/`, so there's no endpoint or
bind-host concern here at all. `docker-compose.yml` mounts that directory
into each task container (writable) so containers write session transcripts
where the host's Agentsview file-watcher actually sees them. Every task
container shares the same in-container cwd (`/workspace/repo`), which would
otherwise make every session indistinguishable in Agentsview's UI (same
directory-hashed "project" for all of them) — `scripts/run-task.sh` handles
this by generating a session ID itself and passing it to `claude -p
--session-id`, then recording `{task_id, session_id, ...}` in
`results/session-map.jsonl`, so any session can be traced back to the task
that produced it.

**3. Authenticate Claude Code with your subscription, not an API key.**
Deliberate choice to avoid per-token spend — accepted tradeoff is hitting
usage caps mid-batch and resuming later (`scripts/run-task.sh` skips tasks
that already have a results file, so resuming doesn't re-spend quota on
finished work).

```bash
sudo dnf install -y nodejs npm   # if not already installed
sudo npm install -g @anthropic-ai/claude-code@2.1.12   # 2.1.17+ has a login regression, see anthropics/claude-code#20325
claude login
```

Confirmed on this instance: credentials land at `~/.claude/.credentials.json`.
`docker-compose.yml` mounts that file (read-only) into each task container at
`/home/bench/.claude/.credentials.json` (containers run as non-root user
`bench`, UID 1000 — see the Dockerfiles) so ephemeral containers reuse the
host's login instead of each one needing its own interactive device-flow —
that only works once this file exists, so run `claude login` before `docker
compose build`/`run`.

**4. Build the images:**
```bash
docker-compose build   # or `docker compose build` if your AMI has the plugin instead
```
Compose file syntax is validated (`docker-compose config` parses it cleanly on
Docker Compose v2.40.3) — whichever binary your AMI ships, the file itself is
fine.

## Task sample

`tasks/tasks.json` is generated, not hand-written — regenerate with:
```bash
pip install pandas pyarrow requests
python3 scripts/pull-tasks.py   # --seed 42 --min-per-repo 20 by default
```
Pulls from `princeton-nlp/SWE-bench_Verified` (Python, official `difficulty`
field) and `ByteDance-Seed/Multi-SWE-bench` (Java, patch-size-tertile proxy
difficulty — no official field there, see script header). Java instances are
quality-gated (f2p tests must actually pass after the fix — Multi-SWE-bench,
unlike SWE-bench Verified, isn't pre-filtered to that standard) before
sampling. Current committed file: 231 tasks (180 python / 51 java), seed 42.
Several repos have fewer than 20 eligible instances after gating (e.g.
`pallets/flask`: 1, `mwaskom/seaborn`: 2) — the script takes all of them and
logs a warning rather than padding the sample.

Regenerating with a different `--seed` changes the sample — only do that
deliberately and commit the new file, since `BENCHMARKING.md` requires a
fixed, reproducible task list.

`scripts/pull-tasks.py` also caches the full raw Multi-SWE-bench per-repo
files under `tasks/raw/multi-swe-bench-java/` (committed, same
fixed-sample reasoning) — `scripts/score-java-batch.sh` needs the original
records (build/env metadata), not just the flat fields kept in `tasks.json`.

## Running a task

Requires `jq` on the host (`sudo dnf install -y jq` / `apt-get install -y jq`).

```bash
scripts/run-task.sh <task-id> [--arm baseline|graphify|serena|headroom|leanctx|caveman]
```

`<task-id>` is a `task_id` from `tasks/tasks.json` (e.g.
`fasterxml__jackson-databind-1234`) — the script looks up that row's track,
repo, base commit, and problem statement itself; no other arguments needed.
It shallow-fetches the repo at the task's exact `base_commit` (by SHA, not a
branch) so the checked-out tree matches what the task's patches assume, then
runs the agent via `claude -p --output-format json --session-id <generated>`
and captures, under `results/<arm>/` (default arm: `baseline`):
- `results/<arm>/<task-id>.result.json` — the run's own JSON summary (cost,
  token usage, `is_error`, `api_error_status`, the session ID)
- `results/<arm>/<task-id>.patch` — the agent's actual code changes (`git diff`
  after `git add -A`, so new files it created are included, not just edits
  to existing ones)
- an appended line in `results/<arm>/session-map.jsonl` tying `task_id` (and
  `arm`) to the Agentsview session ID for that run

### Ablation arms

`--arm` selects which stack tools are wired into that run, cumulative, per
`BENCHMARKING.md`'s ablation design: `baseline` (nothing) → `graphify` →
`serena` → `headroom` → `leanctx` → `caveman` (everything through Caveman).
Each arm registers one more tool with Claude Code inside the container before
invoking it (`claude mcp add` for Serena, `claude plugin install` for
Caveman, etc. — see `scripts/run-task.sh`'s header for the exact mechanism
per tool); Graphify and Serena additionally get a system-prompt nudge to
actually use them, matching `TOKEN_OPTIMIZATION_STACK.md`'s own "Agent
Instructions" section. Running the same task_id under a different arm does
not skip — the resume check is scoped per arm.

**LiteLLM (arm 7 in BENCHMARKING.md) is intentionally not wired in.** Its
documented `usage-based-routing-v2` config is a load-balancing strategy, not
complexity-based routing, and Claude Code sends one fixed model for a whole
`-p` session — wiring the proxy in as literally documented wouldn't measure
real per-task routing savings. Revisit once there's an actual per-subtask
model-switch mechanism to test.

**Headroom / LeanCTX / Caveman registration commands are NOT VERIFIED** —
written from each tool's public docs, not confirmed against the real
installed CLI. Before trusting those arms, run `headroom --help`, `lean-ctx
onboard --help`, and `claude plugin install --help` on the actual EC2 install
and fix `scripts/run-task.sh`'s TODOs if the real subcommands differ.

Compare token/cost counts across arms for one task_id:
```bash
scripts/compare-arms.sh <task-id>
```

Exit codes matter if you're scripting around this directly: `0` ran fine,
`1` the task failed (bad checkout, agent error, crash) but that's not fatal
to a batch, `2` bad input (unknown task_id), `3` a rate-limit/quota hit was
detected — a batch should stop on `3`, not keep burning through remaining
tasks against an exhausted subscription quota. That detection is
best-effort: it checks for a `429` `api_error_status` and a few plausible
phrases in the result text (confirmed real fields, via a live
`--output-format json` test that forced a different API error — but the
exact shape of a *subscription usage-cap* hit specifically hasn't been
observed live yet). Tighten it the first time a real batch actually hits
the cap.

This script does **not** apply `test_patch` or score pass/fail — see
Scoring below.

## Running a batch

```bash
scripts/run-batch.sh [--track java|python] [--repo org/name] [--limit N] [--arm <name>]
```

Runs `scripts/run-task.sh` over every matching `task_id` in
`tasks/tasks.json`, skipping ones with an existing
`results/<arm>/<task_id>.result.json` (resume-safe, same reasoning as
run-task.sh's own skip check). `--arm` is forwarded as-is (default
`baseline`) — see "Ablation arms" above. Stops the
whole batch immediately on a rate-limit/quota hit (exit `3`); an ordinary
task failure (exit `1`) doesn't stop the batch, it's just counted. Prints a
`done=/failed=/skipped=` summary and the list of failed task_ids at the end.

## Scoring

Neither script above touches `test_patch` or determines pass/fail — that's
delegated entirely to the real upstream evaluation harnesses (`swebench` for
Python, `multi-swe-bench` for Java) rather than hand-rolling per-repo/
version test commands here, which risks silently wrong pass/fail. Both
harnesses build their own per-instance Docker image (a different mechanism
from this repo's lightweight `java-track`/`python-track` images), apply the
patch, run the real test suite, and report resolved/unresolved against
`FAIL_TO_PASS`/`PASS_TO_PASS`.

```bash
pip install swebench
scripts/score-python-batch.sh [--arm <name>]         # every attempted python task, or pass specific task_ids

git clone git@github.com:multi-swe-bench/multi-swe-bench.git /tmp/multi-swe-bench && (cd /tmp/multi-swe-bench && make install)  # not on PyPI, source-only
scripts/score-java-batch.sh [--arm <name>]           # every attempted java task, or pass specific task_ids
```

Both default to scoring `results/baseline/` — pass `--arm <name>` to score a
different arm's results (see "Ablation arms" above).

Both read each attempted task's `results/<arm>/<task_id>.patch` and hand it to the
harness in its own expected format — CLI flags and predictions/patch-file
schemas were confirmed by reading each package's installed source directly
(see the scripts' headers), not guessed from docs. **Both verified end to
end** on a real Docker host, one task_id each: java
(`alibaba__fastjson2-1245`, via `multi_swe_bench.harness.run_evaluation` →
unresolved) and python (`astropy__astropy-12907`, via
`swebench.harness.run_evaluation` → resolved). Note: the python harness now
requires the `SWE-bench/SWE-bench_Verified` dataset (the `princeton-nlp`
mirror lacks the `image` field it needs) — already fixed in the script.
Neither track has run a full batch yet.

## Status

Infrastructure scaffold, task sampling, task running, and scoring wiring are
all in place and confirmed working end to end for both tracks (one task_id
each, real Docker host, real verdicts). Ablation-arm wiring (`--arm`) is
written but not yet run live — Headroom/LeanCTX/Caveman's exact registration
subcommands need confirming against the real EC2 install first (see
"Ablation arms" above). No full batch run yet (the pilot in `results/README.md`
predates the scoring harness and was checked informally against a reference
PR instead). Once a real batch runs — agent + scoring both — results get
written up in `token-optimization-stack/BENCHMARKING.md`, not here.

If you have pre-existing results from before `--arm` support (a flat
`results/<task_id>.result.json` instead of `results/<arm>/<task_id>.result.json`),
they were run with nothing wired in — move them into the `baseline` arm
before running anything new:
```bash
mkdir -p results/baseline
mv results/*.result.json results/*.patch results/session-map.jsonl results/baseline/ 2>/dev/null
```
