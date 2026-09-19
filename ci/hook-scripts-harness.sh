#!/usr/bin/env bash
# The two hook scripts, driven against a fake `oc`, on the paths a live cluster cannot be made to hold
# still for. Written by the PR #65 review (Codex, 2026-09-18) and kept as the regression test:
#
#   approver, reclaim enabled, ResolutionFailed for ever   -> exit 1 with OLM's message AND the orphan
#                                                              remedy, never the generic "no plan names it"
#   reclaim, a CSV of ANOTHER package (…-community.v9.9.9)  -> no delete (the match is anchored on <package>.v)
#   reclaim, a settled orphan of THIS package               -> exactly one delete
#
# Renders the chart with crc-values.yaml, extracts the two Job scripts, and runs them with PATH pointing at
# a fake `oc` that answers from MODE. Needs helm and a python with PyYAML (PYTHON=… to choose one).
set -euo pipefail

CHART="${1:-charts/group-sync-operator-helm}"
PYTHON="${PYTHON:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A FAILED ASSERTION MUST SAY WHICH ONE AND SHOW WHAT IT JUDGED. Under set -e the script used to stop at the
# first false test with no output of its own, and the EXIT trap had already deleted the logs — CI showed a
# bare exit 1 (measured on the pre-fix tree: "rc=1" and nothing else). The ERR trap runs before the EXIT
# trap, while the logs still exist. Not set -E: the trap must not fire inside the $(...) substitutions.
diagnose() {
  echo "::error::hook-scripts-harness: assertion failed at line $1: $2" >&2
  for f in "$TMP"/*.log; do
    [ -f "$f" ] || continue
    echo "--- $(basename "$f") ---" >&2
    sed 's/^/    /' "$f" >&2
  done
}
trap 'diagnose "$LINENO" "$BASH_COMMAND"' ERR

# waitSeconds=5, NOT 1. The deadline case must reach the approver's post-loop report (the C6 fix), and the
# pre-fix script has to fail it EVERY time to be a regression guard. With waitSeconds=1 the pre-fix loop's
# first out_of_time check could already be past a DEADLINE of now+1 whenever the script started in the last
# ~100 ms of a wall-clock second (date +%s granularity) — it then took its in-loop report branch and passed
# the assertions below by accident (measured: 3 of 6 boundary-timed runs). At 5 the check is never past the
# deadline on the first attempt, and both scripts still sleep once, so the run costs the same 5 s.
helm template regression "$CHART" \
  -f "$CHART/crc-values.yaml" \
  --set installPlanApprover.waitSeconds=5 >"$TMP/rendered.yaml"

"$PYTHON" - "$TMP/rendered.yaml" "$TMP" <<'PY'
import pathlib
import sys
import yaml

rendered = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
docs = [d for d in yaml.safe_load_all(rendered.read_text()) if d]

for suffix, filename in (
    ("csv-reclaim", "reclaim.sh"),
    ("installplan-approver", "approver.sh"),
):
    job = next(
        d for d in docs
        if d.get("kind") == "Job" and d["metadata"]["name"].endswith(suffix)
    )
    script = job["spec"]["template"]["spec"]["containers"][0]["command"][2]
    (out / filename).write_text(script)
PY

bash -n "$TMP/reclaim.sh"
bash -n "$TMP/approver.sh"
mkdir "$TMP/bin"

cat >"$TMP/bin/oc" <<'OC'
#!/usr/bin/env bash
set -u

all="$*"
printf '%s\n' "$all" >>"${OC_CALLS:?}"

if [[ "${MODE:?}" == deadline ]]; then
  if [[ "$all" == *ResolutionFailed* ]]; then
    echo 'True|constraints not satisfiable: group-sync-operator.v0.0.36 is not referenced by a subscription'
  elif [[ "$all" == "get clusterserviceversions.operators.coreos.com "* &&
          "$all" == *" -o name" ]]; then
    echo clusterserviceversion.operators.coreos.com/group-sync-operator.v0.0.36
  fi
  exit 0
fi

if [[ "$MODE" == wrong ]]; then
  csv=group-sync-operator-community.v9.9.9
else
  csv=group-sync-operator.v0.0.36
fi
resource="clusterserviceversion.operators.coreos.com/${csv}"

if [[ "$all" == "get clusterserviceversions.operators.coreos.com -n "*" -o name" ]]; then
  echo "$resource"
elif [[ "$all" == *"olm\\.copiedFrom"* ]]; then
  :
elif [[ "$all" == *"metadata.ownerReferences"* ]]; then
  :
elif [[ "$all" == "get subscriptions.operators.coreos.com -n "*" -o name" ]]; then
  :
elif [[ "$all" == *"status.installedCSV"* ]]; then
  :
elif [[ "$all" == *ResolutionFailed* ]]; then
  echo True
elif [[ "$all" == *"status.phase"* ]]; then
  echo Succeeded
elif [[ "$all" == delete\ * ]]; then
  echo deleted
else
  echo "unhandled fake oc call: $all" >&2
  exit 2
fi
OC
chmod +x "$TMP/bin/oc"

# The approver is EXPECTED to exit 1 here; `|| deadline_rc=$?` keeps that from being an errexit or an
# ERR-trap event of its own.
deadline_rc=0
MODE=deadline OC_CALLS="$TMP/deadline.calls" PATH="$TMP/bin:$PATH" \
  bash "$TMP/approver.sh" >"$TMP/deadline.log" 2>&1 || deadline_rc=$?

test "$deadline_rc" -eq 1
grep -q 'OLM cannot resolve subscription' "$TMP/deadline.log"
grep -q 'An orphaned ClusterServiceVersion is blocking it' "$TMP/deadline.log"
if grep -q 'never referenced an InstallPlan' "$TMP/deadline.log"; then
  echo "deadline path emitted the generic error" >&2
  exit 1
fi

MODE=wrong OC_CALLS="$TMP/wrong.calls" PATH="$TMP/bin:$PATH" \
  NAMESPACE=group-sync-operator SUBSCRIPTION=group-sync-operator \
  PACKAGE=group-sync-operator WAIT_SECONDS=1 \
  bash "$TMP/reclaim.sh" >"$TMP/wrong.log" 2>&1

test "$(grep -c '^delete ' "$TMP/wrong.calls" || true)" -eq 0
grep -q 'nothing could be orphaned' "$TMP/wrong.log"

MODE=right OC_CALLS="$TMP/right.calls" PATH="$TMP/bin:$PATH" \
  NAMESPACE=group-sync-operator SUBSCRIPTION=group-sync-operator \
  PACKAGE=group-sync-operator WAIT_SECONDS=1 \
  bash "$TMP/reclaim.sh" >"$TMP/right.log" 2>&1

test "$(grep -c '^delete ' "$TMP/right.calls")" -eq 1
echo "PASS: approver deadline and exact CSV package matching"
