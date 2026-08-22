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

**⚠️ Unverified — check before relying on it:** the default bind is
`127.0.0.1`, which is loopback-only and will **not** be reachable from inside
a container via `host.docker.internal` (that resolves to the host's real
gateway IP, not its loopback interface). Run `agentsview serve --help` and
check `~/.agentsview/config.toml` for a bind-host option before your first
real run — if there isn't one, drop the `AGENTSVIEW_ENDPOINT` wiring in
`docker-compose.yml` and instead point each task container's results at the
`./results` volume mount, importing into Agentsview from the host after each
batch.

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

## Running a task

```bash
scripts/run-task.sh java https://github.com/FasterXML/jackson-databind <task-id> path/to/prompt.txt
```

This is a skeleton, not a finished harness — see the TODOs at the bottom of
`scripts/run-task.sh`. It does not yet load a task's prompt/patch from
`tasks/tasks.json` (still takes a hand-supplied prompt file), apply test
patches, or score pass/fail.

## Status

Infrastructure scaffold only. No benchmark runs have happened yet. Once the
task-loading and scoring TODOs are filled in and a pilot batch runs, results
get written up in `token-optimization-stack/BENCHMARKING.md`, not here.
