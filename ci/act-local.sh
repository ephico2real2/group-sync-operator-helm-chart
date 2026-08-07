#!/usr/bin/env bash
#
# Run .github/workflows/ci.yaml locally, with act (https://github.com/nektos/act).
#
# Why this exists: `helm lint` and `helm template` — the commands CONTRIBUTING.md suggests — are a
# fraction of what CI actually asserts. The render matrix alone covers 19 value combinations, and the
# docs and test-scripts jobs catch a whole class of bug (a .helmignore pattern once shipped both test
# scripts as 0 bytes while every suite still passed). This runs the real workflow, unmodified, so a PR
# can be verified before it is pushed — or when GitHub Actions is having an outage and every job dies
# in "Set up job" for reasons that have nothing to do with the change.
#
#   ./ci/act-local.sh                    # every job
#   ./ci/act-local.sh docs chart         # only those jobs
#   ./ci/act-local.sh --list             # what jobs exist
#   ./ci/act-local.sh --rebuild-image    # rebuild the runner image, e.g. after the base image moves
#
# ONLY ci.yaml is ever run. helm.yaml is deliberately out of reach: it packages and publishes the
# chart, and pointing a local runner at it — with whatever credentials happen to be in the
# environment — has no upside.
#
# The event is pull_request, not push, and that is load-bearing. version-bump is gated on
# `if: github.event_name == 'pull_request'` (ci.yaml:151), so under `act push` act skips it without
# creating a container and exits 0 — which reads as a pass while nothing was checked. The job also
# diffs against `github.event.pull_request.base.sha`, which act leaves empty, so the payload written
# below names the merge-base with the default branch.
#
# WHAT IS STILL WEAKER THAN THE REAL RUN: version-bump compares COMMITS, so a chart edit you have not
# committed yet is invisible to it, and on the default branch the merge-base is HEAD, the diff is empty
# and the job passes having compared nothing. Both cases are called out in the summary rather than left
# to look like a pass.

set -euo pipefail

# Anchored so the script works from any working directory. SCRIPT_PATH is resolved BEFORE the chdir
# because ${BASH_SOURCE[0]} holds the path exactly as invoked: after `cd`, a relative one no longer
# resolves, and `--help` — which reads this file to print its own header — could not open it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
cd -- "$REPO_ROOT"

WORKFLOW=".github/workflows/ci.yaml"
RUNNER_IMAGE="group-sync-operator-helm-ci:act"
BASE_IMAGE="catthehacker/ubuntu:act-latest"

REBUILD=false
LIST_ONLY=false
JOBS=()

for arg in "$@"; do
  case "$arg" in
    --rebuild-image) REBUILD=true ;;
    --list|-l)       LIST_ONLY=true ;;
    # The header block IS the help text. Printed by walking comment lines from line 3 to the first
    # line that is not one, so editing the header can never desync it from a hardcoded line range.
    -h|--help)       awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$SCRIPT_PATH"; exit 0 ;;
    -*)              echo "unknown option: $arg — see --help" >&2; exit 2 ;;
    *)               JOBS+=("$arg") ;;
  esac
done

die() { echo "❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------------------------------

command -v act >/dev/null 2>&1 || die "act is not installed.
   macOS:  brew install act
   Linux:  https://nektosact.com/installation/"

# Prints the HOST-side path podman serves the Docker API on, or nothing. Needed twice — to point act at
# podman, and to work out which CLI owns a DOCKER_HOST the caller supplied — so it lives in one place.
#
# Do NOT reach for `podman info` on macOS: its .Host.RemoteSocket.Path is the path INSIDE the VM
# (/run/user/<uid>/podman/podman.sock) and .Exists is evaluated in there too, so it reports a socket
# that is true and unusable from the host. On native Linux there is no machine and podman info IS
# correct, which is what makes the machine list a clean discriminator between the two.
#
# The machine is named explicitly: `podman machine inspect` with no argument does NOT inspect the
# active machine. Per podman-machine-inspect(1), "if a machine name is not specified as an argument,
# then podman-machine-default will be inspected" — so a machine created with --name would be missed
# and silently fall through to the podman info path. `--format '{{.Name}}'` also appends `*` to the
# default machine, hence the strip.
podman_socket() {
  command -v podman >/dev/null 2>&1 || return 0
  pod_machine="$(podman machine list --format '{{.Name}}|{{.Running}}' 2>/dev/null | awk -F'|' '$2=="true"{print $1; exit}')"
  if [ -n "$pod_machine" ]; then
    podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' "${pod_machine%\*}" 2>/dev/null | head -1
  else
    podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null | sed 's|^unix://||'
  fi
}

# act speaks the Docker API, so podman serves it just as well — but the image MUST be built into the
# same daemon act then looks in. Building into daemon A while act reads daemon B fails in "Set up job"
# with the tag missing and nothing pointing at why, so every branch below settles DOCKER_HOST and
# BUILDER together.
if [ -n "${DOCKER_HOST:-}" ]; then
  # An explicit DOCKER_HOST is the caller's decision and is left alone — but the builder is NOT assumed
  # to be docker. Measured: with DOCKER_HOST pointed at podman's socket, defaulting to docker built the
  # image into Docker Desktop's build cache and act, reading podman, failed in Set up job. So the
  # socket's owner decides.
  BUILDER="${CONTAINER_BUILDER:-}"
  if [ -z "$BUILDER" ]; then
    pod_sock="$(podman_socket)"
    if [ -n "$pod_sock" ] && [ "${DOCKER_HOST#unix://}" = "$pod_sock" ]; then
      BUILDER=podman
    else
      BUILDER=docker
    fi
  fi
  command -v "$BUILDER" >/dev/null 2>&1 \
    || die "DOCKER_HOST is set but '$BUILDER' is not installed. Name the right one:
   CONTAINER_BUILDER=<docker|podman> $0"
  echo "🔌 DOCKER_HOST from the environment, built with $BUILDER: $DOCKER_HOST"

elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  BUILDER=docker
  # DOCKER_HOST is exported from the CLI's ACTIVE CONTEXT rather than left unset, because act does not
  # read docker contexts at all — with no DOCKER_HOST it falls back to unix:///var/run/docker.sock.
  # Those are routinely different daemons. Measured on the author's Mac: the active context is
  # `desktop-linux` at unix:///Users/<user>/.docker/run/docker.sock, while /var/run/docker.sock is a
  # symlink to PODMAN's socket. Leaving it unset would build into Docker Desktop and run act against
  # podman.
  ctx_host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  if [ -n "$ctx_host" ]; then
    export DOCKER_HOST="$ctx_host"
    echo "🔌 docker, active context: $DOCKER_HOST"
  else
    echo "🔌 docker daemon is reachable (no context endpoint reported; using act's default socket)"
  fi

elif command -v podman >/dev/null 2>&1; then
  BUILDER=podman
  sock="$(podman_socket)"
  if [ -z "$sock" ]; then
    stopped="$(podman machine list --format '{{.Name}}' 2>/dev/null | head -1 || true)"
    [ -z "$stopped" ] && die "podman is installed but no socket could be discovered. On Linux:
   systemctl --user start podman.socket"
    die "no podman machine is running. Start it: podman machine start ${stopped%\*}"
  fi
  [ -S "$sock" ] || die "podman reports socket $sock but it is not a socket."
  export DOCKER_HOST="unix://$sock"
  # No machine name in the label: podman_socket() runs in a command substitution, so anything it
  # assigns is lost with that subshell. The path names the machine on macOS anyway.
  echo "🔌 podman: $DOCKER_HOST"

else
  die "no container runtime found. act needs docker or podman.
   macOS:  brew install podman && podman machine init && podman machine start"
fi

# The base runner image is multi-arch, so the host's architecture is used rather than a hardcoded
# linux/amd64 — which on an Apple Silicon machine would silently run the whole suite under emulation.
# Only the amd64 path has actually been exercised.
case "$(uname -m)" in
  x86_64|amd64) PLATFORM=linux/amd64 ;;
  arm64|aarch64) PLATFORM=linux/arm64 ;;
  *)            PLATFORM="linux/$(uname -m)" ;;
esac

# Scratch space for the build context and the event payload. Removed on exit — which is why the job
# LOGS live in their own directory further down: those have to outlive the run to be readable.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------------------------------

# Discovered rather than hardcoded, so a job added to ci.yaml is covered here without an edit.
#
# Read in a loop rather than with `mapfile`: mapfile is a bash 4 builtin, and macOS still ships bash
# 3.2 as /bin/bash. A Homebrew bash makes this work on the author's machine and nowhere else.
#
# act's stderr is kept rather than discarded: a YAML error in ci.yaml is the most likely reason this
# comes back empty, and act explains it there. The exit status is NOT observable — the command runs in
# a process substitution — so that message is the only diagnosis available.
#
# Sorted because act's own ordering is not stable: three consecutive `act --list` runs on an unchanged
# ci.yaml returned two different orders. Runs should be reproducible enough that two logs can be diffed.
ALL_JOBS=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] && ALL_JOBS+=("$line")
done < <(act --list -W "$WORKFLOW" 2>"$WORK_DIR/list.err" | awk 'NR>1 && NF {print $2}' | sort)

if [ "${#ALL_JOBS[@]}" -eq 0 ]; then
  echo "❌ act listed no jobs in $WORKFLOW. It reported:" >&2
  sed 's/^/   /' "$WORK_DIR/list.err" >&2
  exit 1
fi

if [ "$LIST_ONLY" = true ]; then
  printf '%s\n' "${ALL_JOBS[@]}"
  exit 0
fi

if [ "${#JOBS[@]}" -eq 0 ]; then
  JOBS=("${ALL_JOBS[@]}")
else
  # act exits 1 with "Could not find any stages to run" on an unknown id, so this is only about giving
  # a better message than that one — and listing what the valid ids are.
  for j in "${JOBS[@]}"; do
    found=false
    for a in "${ALL_JOBS[@]}"; do [ "$j" = "$a" ] && found=true && break; done
    [ "$found" = true ] || die "no such job: $j
   valid jobs: ${ALL_JOBS[*]}"
  done
fi

# ---------------------------------------------------------------------------------------------------
# Event payload
# ---------------------------------------------------------------------------------------------------

# version-bump diffs the chart against github.event.pull_request.base.sha. act synthesises an empty
# payload, and an empty base makes the job's `git diff` fail into its `|| true`, report "no chart
# content changed" and pass — so the base is named here. ACT_BASE_REF overrides it.
BASE_REF="${ACT_BASE_REF:-$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo main)}"
BASE_SHA="$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
VACUOUS_REASON=""
DANGLING_HEAD=""

if [ -z "$BASE_SHA" ]; then
  VACUOUS_REASON="no merge-base with '$BASE_REF' — version-bump had nothing to diff against.
    Pass one: ACT_BASE_REF=<branch-or-sha> ./ci/act-local.sh"
elif [ "$BASE_SHA" = "$HEAD_SHA" ]; then
  VACUOUS_REASON="HEAD is the merge-base with '$BASE_REF', so version-bump saw an empty diff and
    passed without comparing anything. That is expected on the default branch."
fi

# A branch whose ref path .gitignore matches breaks git INSIDE the container, and version-bump then
# passes having compared nothing. act copies the repo with --use-gitignore true by default, so the
# ignore rules are applied to .git as well: on `tmp/demo`, .git/refs/heads/tmp/ is excluded, .git/HEAD
# is copied still pointing at it, and `git diff` dies with "fatal: bad revision 'HEAD'" — straight into
# the job's own `|| true`, which reports "no chart content changed" and succeeds.
#
# Measured on this repo, whose .gitignore carries tmp/, temp/ and *.log: one commit, one unbumped chart
# change, branch renamed from tmp/demo-branch-behaviour to demo/branch-behaviour and nothing else — the
# run went from ✅ pass to the correct ❌ with the ::error:: annotation.
#
# Only loose refs are affected. A packed ref lives in .git/packed-refs, which no rule here matches.
HEAD_REF="$(git symbolic-ref --quiet HEAD 2>/dev/null || true)"
if [ -n "$HEAD_REF" ] && [ -f ".git/$HEAD_REF" ] \
   && git check-ignore -q ".git/$HEAD_REF" 2>/dev/null \
   && ! grep -q " $HEAD_REF\$" .git/packed-refs 2>/dev/null; then
  ignore_rule="$(git check-ignore -v ".git/$HEAD_REF" 2>/dev/null | awk '{print $1}')"
  DANGLING_HEAD="the current branch's ref (.git/$HEAD_REF) is excluded by ${ignore_rule:-.gitignore}, so
    act copies a .git whose HEAD points at a ref that is not there. Every git command in a job fails
    with \"fatal: bad revision 'HEAD'\", and version-bump passes having compared NOTHING.
    Rename the branch off that path — git branch -m <new-name> — or pass --use-gitignore=false to act."
fi
printf '{"pull_request":{"base":{"sha":"%s"}}}\n' "$BASE_SHA" > "$WORK_DIR/event.json"
echo "🌿 diffing against $BASE_REF (${BASE_SHA:-none}) for version-bump"

# Refused rather than warned when version-bump is in scope: its whole value is telling you the chart
# needs a version bump, and under a dangling HEAD it says the opposite with a green tick. The other jobs
# touch no git history, so they are allowed through with a warning.
if [ -n "$DANGLING_HEAD" ]; then
  case " ${JOBS[*]} " in
    *" version-bump "*) die "$DANGLING_HEAD" ;;
    *)                  echo "⚠️  $DANGLING_HEAD" ;;
  esac
fi

# ---------------------------------------------------------------------------------------------------
# Runner image
# ---------------------------------------------------------------------------------------------------

# catthehacker/ubuntu:act-latest is act's own recommended image, but it is slimmer than GitHub's
# ubuntu-latest in two ways this workflow depends on. Both are patched here rather than in ci.yaml,
# because the point is to run the workflow AS GITHUB RUNS IT:
#
#   1. PyYAML. The docs and test-scripts jobs `import yaml` without installing it (ci.yaml:262, 289,
#      320) and rely on the runner image having it. render-matrix installs it explicitly at line 33.
#      Without this the two jobs die on ModuleNotFoundError.
#   2. PEP 668. Ubuntu 24.04's pip refuses system-wide installs with
#      "error: externally-managed-environment", so render-matrix's own `pip install --quiet pyyaml`
#      fails here while succeeding on GitHub, whose runner pip is not externally managed.
#
# If either of these ever becomes load-bearing — a local run green only because of this file while
# GitHub is red — the implicit dependency in ci.yaml is the bug, not this image.
if [ "$REBUILD" = true ] || ! "$BUILDER" image inspect "$RUNNER_IMAGE" >/dev/null 2>&1; then
  echo "🐳 building $RUNNER_IMAGE from $BASE_IMAGE ($PLATFORM; once, --rebuild-image to redo)"
  cat > "$WORK_DIR/Dockerfile" <<DOCKERFILE
FROM $BASE_IMAGE
ENV PIP_BREAK_SYSTEM_PACKAGES=1
RUN pip3 install --quiet pyyaml
DOCKERFILE
  # --load matters: `docker build` may be driving a buildx "docker-container" builder, which leaves the
  # result in the build CACHE and loads it into no daemon at all — it prints "No output specified with
  # docker-container driver" and EXITS 0. Measured; act then failed in Set up job with the tag missing.
  build_cmd=(build)
  if [ "$BUILDER" = docker ] && docker buildx version >/dev/null 2>&1; then
    build_cmd=(buildx build --load)
  fi
  "$BUILDER" "${build_cmd[@]}" --platform "$PLATFORM" -t "$RUNNER_IMAGE" "$WORK_DIR" >/dev/null \
    || die "could not build $RUNNER_IMAGE"
  echo "   built"
fi

# Checked unconditionally and AFTER the build, because a build can exit 0 having produced no image (see
# above). This is a valid proxy for what act will see: every branch above settles BUILDER and
# DOCKER_HOST on the same daemon.
"$BUILDER" image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 \
  || die "$RUNNER_IMAGE is missing from the daemon $BUILDER talks to, even after a successful build.
   If your builder and DOCKER_HOST disagree, name the right builder:
   CONTAINER_BUILDER=<docker|podman> $0"

# ---------------------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------------------

# Deliberately NOT inside WORK_DIR: the trap removes that on exit, and these have to survive for the
# paths printed below to be worth anything.
LOG_DIR="$(mktemp -d)"
echo "📁 logs: $LOG_DIR"
echo

FAILED=()
for job in "${JOBS[@]}"; do
  printf '▶  %-14s ' "$job"
  #   pull_request                the event the workflow gates version-bump on — see the header
  #   --eventpath                 supplies the base sha that job diffs against
  #   -P ubuntu-latest=…          every job in ci.yaml runs-on ubuntu-latest
  #   --pull=false                the runner image is local-only, so act must not try to pull the tag
  #   --container-daemon-socket - stops act bind-mounting the daemon socket into the job container.
  #                               Under podman on macOS that mount fails outright ("making volume
  #                               mountpoint … operation not supported") because the socket lives on
  #                               the host filesystem the VM cannot mkdir into. No job here runs a
  #                               container, so nothing needs the socket.
  if act pull_request -W "$WORKFLOW" -j "$job" \
       --eventpath "$WORK_DIR/event.json" \
       -P "ubuntu-latest=$RUNNER_IMAGE" \
       --pull=false \
       --container-architecture "$PLATFORM" \
       --container-daemon-socket - \
       > "$LOG_DIR/$job.log" 2>&1; then
    # A pass is not accepted at face value if git died inside the job. Every git failure in these
    # workflows lands in a `|| true` or a `2>/dev/null` — that is deliberate on GitHub, where the git
    # context is always sound — so a broken context turns a real comparison into a vacuous success with
    # a green tick. The preflight above catches the cause known to occur here (a gitignored branch ref);
    # this catches the symptom whatever the cause.
    if grep -q '^\[.*\]   | fatal: ' "$LOG_DIR/$job.log"; then
      echo "❌ FAIL   $LOG_DIR/$job.log   (act exited 0, but git failed inside the job)"
      FAILED+=("$job")
    else
      echo "✅ pass"
    fi
  else
    echo "❌ FAIL   $LOG_DIR/$job.log"
    FAILED+=("$job")
  fi
done

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "❌ ${#FAILED[@]} of ${#JOBS[@]} job(s) failed: ${FAILED[*]}"
  for job in "${FAILED[@]}"; do
    echo
    echo "── $job ──────────────────────────────────────────────"
    # ❗ is how act renders a ::error:: annotation, and those carry the actual diagnosis — the
    # workflow's own "README says X, values.yaml has Y". Matching only ❌ and the `| ` stdout lines
    # drops exactly the line worth reading. The full log is on disk for anything this misses.
    #
    # `|| true` because grep exits 1 when it matches nothing, and under `set -o pipefail` that becomes
    # the pipeline's status even though tail succeeded — which `set -e` would turn into an abort HERE,
    # in the middle of the report, silently dropping every later job's excerpt. A log with no match is
    # rare (act truncated before its first step output) but it is the one that most needs reporting.
    grep -E '❗|❌|  \| ' "$LOG_DIR/$job.log" | tail -25 || true
  done
  exit 1
fi

echo "✅ all ${#JOBS[@]} job(s) passed"
if [ -n "$VACUOUS_REASON" ]; then
  case " ${JOBS[*]} " in
    *" version-bump "*) echo; echo "⚠️  $VACUOUS_REASON" ;;
  esac
fi
