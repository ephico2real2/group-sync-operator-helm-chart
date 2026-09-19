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

helm template regression "$CHART" \
  -f "$CHART/crc-values.yaml" \
  --set installPlanApprover.waitSeconds=1 >"$TMP/rendered.yaml"

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

set +e
MODE=deadline OC_CALLS="$TMP/deadline.calls" PATH="$TMP/bin:$PATH" \
  bash "$TMP/approver.sh" >"$TMP/deadline.log" 2>&1
deadline_rc=$?
set -e

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
