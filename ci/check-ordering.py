#!/usr/bin/env python3
"""Assert this chart's install/uninstall ordering is DECLARED, not accidental.

Ported from the sibling openshift-rbac-automation chart's check-ordering.py, which already asserted
the rule this chart was breaking. Three ordering mechanisms are in play and they are NOT
interchangeable:

  helm.sh/hook-weight            orders the Jobs among themselves under plain `helm install`.
  argocd.argoproj.io/sync-wave   orders every resource under ArgoCD — and ArgoCD DELETES in REVERSE
                                 wave order, which is the direction that bites.
  argocd.argoproj.io/hook        decides WHICH PHASE a Job runs in under ArgoCD. Without it ArgoCD
                                 falls back to that object's own helm.sh/hook, mapping post-install to
                                 PostSync — after the entire sync, not at the object's wave. The wave
                                 then orders it against nothing but other PostSync hooks.

Every rule below is here because it was violated, measured, and fixed in 0.13.0 — not because it
seemed prudent:

  * The InstallPlan approver sat one wave AFTER the Subscription. ArgoCD advances only when a wave is
    healthy, and a Manual-approval Subscription is Progressing until its InstallPlan is approved
    (its health check forgives RequiresApproval only when .status.installedCSV is already set, which
    on a first install it is not). The approver was waiting on the wave that was waiting on it.
  * The OAuth extraction and LDAP CA Jobs carried a wave but no argocd hook, so they ran in PostSync
    — after the GroupSync CRs at wave 3 that consume the Secret and ConfigMap they create.
  * The GroupSync CRs lacked SkipDryRunOnMissingResource. Since 0.13.0 the CRD is not in the manifest
    (OLM installs it when the Subscription resolves), and ArgoCD dry-runs every resource before
    applying it — a dry-run against a kind the cluster does not serve yet fails THE WHOLE SYNC.

HOW THIS STAYS TRUE WHEN TEMPLATES ARE ADDED, which is the whole design — a validator needing an edit
every time the thing it validates changes is a validator that silently rots:

  1. DERIVE, NEVER LIST. The operator's CRs are selected by API GROUP (redhatcop.redhat.io), so a new
     redhat-cop kind is covered the day it is added. Jobs are selected by kind. Values overlays are
     DISCOVERED by glob, so a new cluster overlay is checked without touching this file or CI.
  2. REQUIRE THE ANNOTATION, NEVER ASSUME A DEFAULT. ArgoCD treats a missing sync-wave as wave 0 —
     the Subscription's own wave — so an omission is not a cosmetic gap, it is an ordering bug that
     reads as fine. Checked in the template SOURCE as well as in the render, because a render only
     sees the templates the current values switch on: 00-namespace.yaml and the vendored CRD are both
     gated off by default and no combination here reaches them.
  3. EVERY SELECTOR MUST MATCH SOMETHING. A selector that quietly matches nothing passes forever while
     testing nothing, which is worse than no check at all. Each lookup asserts it found what it was
     looking for, so renaming a component fails loudly rather than silently disabling its rule.

Usage:
    ci/check-ordering.py                              # default values plus every discovered overlay
    ci/check-ordering.py --chart charts/group-sync-operator-helm
"""

import argparse
import glob
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

WAVE = "argocd.argoproj.io/sync-wave"
HOOK = "argocd.argoproj.io/hook"
OPTS = "argocd.argoproj.io/sync-options"
HELM_HOOK = "helm.sh/hook"
HELM_WEIGHT = "helm.sh/hook-weight"

# The operator's own API group. Selecting on the group rather than on "GroupSync" means a second kind
# from the same bundle is covered without editing this file.
CR_GROUP = "redhatcop.redhat.io"

# A url must be set for anything to render offline: the chart's lookup-based discovery resolves to
# nothing under `helm template`, and every GroupSync CR then hits a `fail`.
BASE = ["--set", "groupSync.url=ldaps://example:636"]


def annotations(doc):
    return (doc.get("metadata") or {}).get("annotations") or {}


def group_of(doc):
    return (doc.get("apiVersion") or "").split("/")[0]


def is_test(doc):
    """The helm-test fixtures: the two test Pods (helm.sh/hook: test) plus the SA/RBAC/ConfigMap they
    use, which live under templates/tests/ and carry the shared test ServiceAccount's name. These are
    exempt from the wave rule DELIBERATELY, not by omission: `helm test` runs them after the release
    is deployed, they consume nothing another wave produces, and a wave on them would declare an
    ordering intent that does not exist. The exemption is by naming convention ({release}-test-* and
    the -default-test cluster pair), and check_render asserts the convention still matches something,
    so a rename fails loudly rather than silently widening the rule."""
    if "test" in annotations(doc).get(HELM_HOOK, ""):
        return True
    name = (doc.get("metadata") or {}).get("name") or ""
    return "-test-" in name or name.endswith("-test") or "-default-test-" in name


def wave_of(doc):
    """The wave ArgoCD will actually use. sync-wave wins; hook-weight is only the fallback."""
    a = annotations(doc)
    for key in (WAVE, HELM_WEIGHT):
        if key in a:
            try:
                return int(a[key])
            except ValueError:
                return None
    return None


def render(chart, values):
    cmd = ["helm", "template", "ordering-check", chart] + BASE
    for v in values:
        cmd += ["-f", v]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        return None, (out.stderr.strip().splitlines() or ["render failed"])[-1]
    return [d for d in yaml.safe_load_all(out.stdout) if d], None


def check_template_sources(chart, errors):
    """RULE 2, on the SOURCE. A render only sees templates the current values switch on; reading the
    files needs no values, so a gated template cannot hide and a new one cannot be forgotten."""
    seen = 0
    for path in sorted(glob.glob(os.path.join(chart, "templates", "**", "*.yaml"), recursive=True)):
        rel = os.path.relpath(path, REPO)
        text = open(path, encoding="utf-8").read()
        if "kind: Job" not in text:
            continue
        seen += 1
        # Substring, not YAML: these files are Go templates and do not parse before rendering.
        if HOOK not in text:
            errors.append(f"{rel}: a Job with no {HOOK}. Without it ArgoCD falls back to this "
                          f"object's helm.sh/hook and post-install becomes PostSync, which runs "
                          f"after the whole sync instead of at its wave.")
    if not seen:
        errors.append("RULE 3: no Job templates found at all — did templates/ move?")


def check_render(label, docs, errors, stats=None):
    def problem(msg):
        errors.append(f"[{label}] {msg}")

    # RULE 2. Every non-test document declares its wave explicitly.
    for d in docs:
        if is_test(d):
            # Counted so main() can assert the exemption still matches something — RULE 3 applied to
            # the exemption itself. A renamed test fixture would otherwise fall INTO the wave rule
            # (failing loudly, acceptable), but a convention that matched nothing at all would mean
            # the fixtures are gone or renamed wholesale and this script no longer knows the chart.
            if stats is not None:
                stats["test_fixtures"] = stats.get("test_fixtures", 0) + 1
            continue
        if WAVE not in annotations(d):
            problem(f"{d['kind']}/{d['metadata']['name']} has no {WAVE}. ArgoCD would place it at "
                    f"wave 0 — the Subscription's own wave — which reads as fine and is not.")

    subs = [d for d in docs if d["kind"] == "Subscription"]
    crs = [d for d in docs if group_of(d) == CR_GROUP]
    jobs = [d for d in docs if d["kind"] == "Job" and not is_test(d)]

    # RULE 3: every selector must match something.
    if not subs:
        return problem("RULE 3: no Subscription in the render — the selector matched nothing.")
    if not jobs:
        return problem("RULE 3: no Jobs in the render — the selector matched nothing.")
    sub_wave = wave_of(subs[0])
    if sub_wave is None:
        return problem("the Subscription has no readable wave, so nothing can be ordered against it.")

    # RULE 2 again, for the phase. Every Job states which ArgoCD phase it runs in.
    for j in jobs:
        if HOOK not in annotations(j):
            problem(f"Job/{j['metadata']['name']} has no {HOOK}; ArgoCD would derive its phase from "
                    f"helm.sh/hook and post-install maps to PostSync.")

    # THE DEADLOCK RULE. The approver must share the Subscription's wave and must run in the Sync
    # phase. ArgoCD advances a wave only when it is healthy, and a Manual-approval Subscription stays
    # Progressing until its InstallPlan is approved — so an approver in ANY later wave, or in
    # PostSync (which runs only after the whole sync succeeds), waits on the wave waiting on it.
    approvers = [j for j in jobs if "installplan-approver" in j["metadata"]["name"]]
    if approvers:
        for j in approvers:
            w, phase = wave_of(j), annotations(j).get(HOOK)
            if w != sub_wave:
                problem(f"Job/{j['metadata']['name']} is at wave {w}; the Subscription is at wave "
                        f"{sub_wave}. It must SHARE that wave or a first sync deadlocks.")
            if phase != "Sync":
                problem(f"Job/{j['metadata']['name']} is {HOOK}={phase}; it must be Sync. PostSync "
                        f"runs only after the whole sync succeeds, which cannot happen while the "
                        f"Subscription waits for this Job.")
    elif any("installplan-approver" in d["metadata"]["name"] for d in docs):
        problem("RULE 3: approver RBAC is present but its Job is not — selector drift.")

    # TEARDOWN. Higher wave = deleted earlier. The CRs must go before the Subscription so the
    # operator is still running to execute their finalizers.
    for c in crs:
        w = wave_of(c)
        if w is None or w <= sub_wave:
            problem(f"{c['kind']}/{c['metadata']['name']} is at wave {w}, not above the "
                    f"Subscription's {sub_wave}. ArgoCD deletes in reverse wave order, so on teardown "
                    f"the operator would be removed before the finalizer that needs it.")
        # FIRST SYNC. The CRD is not in this manifest — OLM installs it when the Subscription
        # resolves — and ArgoCD dry-runs every resource before applying it. A dry-run against a kind
        # the cluster does not serve yet fails the WHOLE sync.
        if "SkipDryRunOnMissingResource=true" not in annotations(c).get(OPTS, ""):
            problem(f"{c['kind']}/{c['metadata']['name']} lacks SkipDryRunOnMissingResource=true in "
                    f"{OPTS}. Its CRD arrives from OLM mid-sync, so the first sync fails at dry-run.")

    # The readiness wait sits between the Subscription and the CRs: after it, because there is
    # nothing to wait for until the Subscription exists; before them, because a CR applied against an
    # operator that is not serving yet is the failure it exists to prevent.
    waits = [j for j in jobs if "operator-wait" in j["metadata"]["name"]]
    if waits and crs:
        for j in waits:
            w = wave_of(j)
            if not (sub_wave < w < min(wave_of(c) for c in crs)):
                problem(f"Job/{j['metadata']['name']} is at wave {w}; it must sit strictly between "
                        f"the Subscription ({sub_wave}) and the CRs "
                        f"({min(wave_of(c) for c in crs)}).")

    # Under plain Helm the waves are inert and hook-weight is the only ordering. Two hooks sharing an
    # event and a weight run in an order Helm does not define, so a dependency between them is luck.
    by_weight = {}
    for j in jobs:
        a = annotations(j)
        if HELM_HOOK not in a or HELM_WEIGHT not in a:
            continue
        for event in (e.strip() for e in a[HELM_HOOK].split(",")):
            by_weight.setdefault((event, a[HELM_WEIGHT]), []).append(j["metadata"]["name"])
    for (event, weight), names in sorted(by_weight.items()):
        if len(names) > 1:
            problem(f"{len(names)} {event} hooks share helm.sh/hook-weight {weight} "
                    f"({', '.join(sorted(names))}); their relative order under plain Helm is undefined.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chart", default="charts/group-sync-operator-helm")
    args = ap.parse_args()
    chart = os.path.join(REPO, args.chart) if not os.path.isabs(args.chart) else args.chart

    errors = []
    check_template_sources(chart, errors)

    # RULE 1. Overlays are DISCOVERED, so a new one is covered without editing this file. Files
    # marked requires-cluster cannot render offline by design and are skipped, not failed.
    overlays = []
    for path in sorted(glob.glob(os.path.join(chart, "*-values.yaml"))
                       + glob.glob(os.path.join(chart, "environments", "*.yaml"))):
        if "requires-cluster: true" in open(path, encoding="utf-8").read():
            continue
        overlays.append(path)

    cases = [("defaults", [])] + [(os.path.basename(p), [p]) for p in overlays]
    checked = 0
    stats = {}
    for label, values in cases:
        docs, err = render(chart, values)
        if err:
            errors.append(f"[{label}] render failed: {err}")
            continue
        check_render(label, docs, errors, stats)
        checked += 1

    # crd.install is the one gate that ADDS an object rather than removing one, so the vendored CRD's
    # own wave is only reachable — and only covered by RULE 2 — with it on.
    cmd = ["helm", "template", "ordering-check", chart] + BASE + ["--set", "crd.install=true"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        errors.append("[crd.install=true] render failed: "
                      + (out.stderr.strip().splitlines() or ["render failed"])[-1])
    else:
        check_render("crd.install=true", [d for d in yaml.safe_load_all(out.stdout) if d],
                     errors, stats)
        checked += 1

    if not checked:
        errors.append("RULE 3: nothing rendered — every case failed, so nothing was actually checked.")

    # RULE 3 applied to the is_test exemption itself: if no render produced a single test fixture,
    # the naming convention the exemption keys on no longer matches this chart, and the exemption is
    # exempting nothing while claiming to. (Individual renders may legitimately have zero — a values
    # file can switch the test resources off — so this is asserted across ALL renders, not per case.)
    if checked and not stats.get("test_fixtures"):
        errors.append("RULE 3: the test-fixture exemption matched nothing in any render — the "
                      "{release}-test-* naming convention has drifted; update is_test() in this "
                      "script to follow it.")

    if errors:
        for e in errors:
            print(f"::error::{e}")
        print(f"\nFAILED: {len(errors)} ordering problem(s)")
        return 1
    print(f"OK: ordering declared and consistent across {checked} render(s) plus the template sources.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
