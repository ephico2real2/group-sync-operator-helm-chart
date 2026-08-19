#!/usr/bin/env python3
"""Assert every `oc` call in this chart names its resource IN FULL.

WHY — a defect measured on a live cluster in the sibling openshift-rbac-automation chart, whose scripts have
the same call shapes as these:

    Error from server (Forbidden): subscriptions.messaging.knative.dev "…" is forbidden:
    … cannot get resource "subscriptions" in API group "messaging.knative.dev"

`oc get subscription` had bound to the WRONG API GROUP. A resource plural is not reserved: Knative Eventing
serves `subscriptions`, OLM serves `subscriptions`, and which one a short name resolves to is decided by API
discovery — so it changes as CRDs are installed and removed. These scripts run in containers with HOME=/tmp
and therefore a COLD discovery cache on every run, so the binding is not stable even between two runs of the
same Job.

THE FAILURE MODE IS WHY THIS IS A CI GATE AND NOT A STYLE PREFERENCE. A misrouted request returns Forbidden,
which reads as missing RBAC on the resource you MEANT. Worse, a misrouted LIST returns NOTHING rather than
failing — and this chart has two decisions driven by a list:

    relabel-provenance.sh   `oc get groupsyncs…` decides which CRs are LIVE, and `oc get groups…` decides
                            which Groups carry a stale provenance value. An empty list from a misrouted read
                            means "no live CR" and "no groups to fix" — a silent no-op that reports success.
    operator-wait / approver  read the Subscription and its InstallPlans to decide whether to wait or approve.

`groups` is the one worth naming explicitly here: it is an OpenShift kind (user.openshift.io) whose plural is
attractive to other operators, and this chart WRITES to it.

WHAT IS CHECKED, and deliberately not:

  checked      the resource ARGUMENT of an `oc` verb, in the rendered chart (so a script that only exists as
              a ConfigMap value is covered exactly like a file), in every files/*.sh source script, and in
              NOTES.txt plus the values files — because an operator copy-pastes those.
  not checked  `oc get "$var"` forms, which hold `-o name` output that is already fully qualified; comment
              lines, so prose can still discuss `oc get csv`; and kubectl, which this chart does not use.

There is deliberately NO allowlist for "clusters where the short name is fine". A cluster can add a colliding
CRD tomorrow, so the rule is unconditional.
"""

import glob
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHART = os.path.join(REPO, "charts", "group-sync-operator-helm")

# Every spelling `oc` accepts for the kinds this chart touches, including the documented short aliases,
# because all of them route through the same discovery.
MUST_QUALIFY = {
    "subscription": "subscriptions.operators.coreos.com",
    "subscriptions": "subscriptions.operators.coreos.com",
    "sub": "subscriptions.operators.coreos.com",
    "subs": "subscriptions.operators.coreos.com",
    "installplan": "installplans.operators.coreos.com",
    "installplans": "installplans.operators.coreos.com",
    "ip": "installplans.operators.coreos.com",
    "csv": "clusterserviceversions.operators.coreos.com",
    "csvs": "clusterserviceversions.operators.coreos.com",
    "clusterserviceversion": "clusterserviceversions.operators.coreos.com",
    "clusterserviceversions": "clusterserviceversions.operators.coreos.com",
    "operatorgroup": "operatorgroups.operators.coreos.com",
    "operatorgroups": "operatorgroups.operators.coreos.com",
    "og": "operatorgroups.operators.coreos.com",
    "group": "groups.user.openshift.io",
    "groups": "groups.user.openshift.io",
    "groupsync": "groupsyncs.redhatcop.redhat.io",
    "groupsyncs": "groupsyncs.redhatcop.redhat.io",
}

OC_CALL = re.compile(r"\boc\s+(?:get|patch|delete|wait|describe|label|annotate)\s+"
                     r"(?:-{1,2}[\w-]+(?:[= ]\S+)?\s+)*"
                     r"([A-Za-z][\w.,-]*)")


def offenders(text, where):
    found = []
    for line_no, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in OC_CALL.finditer(line):
            arg = m.group(1)
            if arg.startswith("$"):
                continue
            for part in arg.split(","):
                if part in MUST_QUALIFY:
                    found.append((where, line_no, part, MUST_QUALIFY[part], line.strip()[:100]))
    return found


def render():
    """Render with the minimum needed to succeed. groupSync.url is derived from the cluster via `lookup`,
    which returns nothing offline, so the chart fails by design without it — see the CI render checks."""
    proc = subprocess.run(
        ["helm", "template", "qualified-probe", CHART, "--set", "groupSync.url=ldaps://probe:636"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("::error::helm template failed\n%s" % proc.stderr)
    return proc.stdout


def main():
    errors, scripts_seen, files_seen = [], 0, 0

    # 1. rendered ConfigMap scripts — the form that actually runs in a Job
    for doc in yaml.safe_load_all(render()):
        if not doc or doc.get("kind") != "ConfigMap":
            continue
        for key, body in (doc.get("data") or {}).items():
            if key.endswith(".sh"):
                scripts_seen += 1
                errors += offenders(body, "%s/%s" % (doc["metadata"]["name"], key))

    # 2. the source scripts under files/, which are also run by hand from a runbook
    for path in sorted(glob.glob(os.path.join(CHART, "files", "*.sh"))):
        files_seen += 1
        errors += offenders(open(path).read(), os.path.relpath(path, REPO))

    # 3. NOTES.txt and the values files — an operator copy-pastes these, so an ambiguous command is a trap
    for path in [os.path.join(CHART, "templates", "NOTES.txt")] + \
                sorted(glob.glob(os.path.join(CHART, "*values*.y*ml"))) + \
                sorted(glob.glob(os.path.join(CHART, "environments", "*values*.y*ml"))):
        if os.path.exists(path):
            errors += offenders(open(path).read(), os.path.relpath(path, REPO))

    # EVERY SELECTOR MUST MATCH SOMETHING. A check that silently inspects nothing passes forever.
    if not scripts_seen:
        errors.append(("(render)", 0, "-", "-", "no ConfigMap key ending in .sh rendered — either the "
                                                "scripts left ConfigMaps or the key naming changed"))
    if not files_seen:
        errors.append(("(files)", 0, "-", "-", "no files/*.sh found — this check stopped covering the "
                                               "source scripts"))

    if errors:
        for where, line_no, short, full, ctx in errors:
            print("::error::%s:%s uses the ambiguous resource name '%s' — write '%s'. A plural is not "
                  "reserved, so `%s` can bind to another API group; measured on a live cluster, "
                  "`oc get subscription` resolved to subscriptions.messaging.knative.dev and returned "
                  "Forbidden. A misrouted LIST returns nothing rather than failing. Context: %s"
                  % (where, line_no, short, full, short, ctx))
        print("\nFAILED: %d ambiguous resource name(s)" % len(errors))
        return 1
    print("OK: %d rendered script(s) and %d source script(s) name every resource in full."
          % (scripts_seen, files_seen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
