#!/usr/bin/env python3
"""oauth_cr_read against hand-built renders — the cases the chart's own values cannot produce.

The render matrix only ever renders the poller ClusterRole exactly as the template writes it, so it can
show that the exact grant passes but never that a widened, reduced or unbound one fails. These are the
eight cases that pin that, in memory: no helm, no cluster. Exits 1 if any case does not hold.
"""
import copy, importlib.util, sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "render_checks", Path(__file__).resolve().parent / "render-checks.py"
)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

EXACT = {
    "apiGroups": ["config.openshift.io"],
    "resources": ["oauths"],
    "resourceNames": ["cluster"],
    "verbs": ["get"],
}
LABELS = {"app.kubernetes.io/component": "dashboard-cluster-poller"}


def poller(name="group-sync-dashboard-cluster-poller", rule=None, bind=True, sa=True, oauths=True):
    docs = []
    if sa:
        docs.append({
            "kind": "ServiceAccount",
            "metadata": {"name": name, "namespace": "group-sync-operator", "labels": dict(LABELS)},
        })
    rules = []
    if oauths:
        rules.append(copy.deepcopy(rule or EXACT))
    rules.append({"apiGroups": ["user.openshift.io"], "resources": ["groups"], "verbs": ["get", "list"]})
    docs.append({"kind": "ClusterRole", "metadata": {"name": name, "labels": dict(LABELS)}, "rules": rules})
    if bind:
        docs.append({
            "kind": "ClusterRoleBinding",
            "metadata": {"name": name, "labels": dict(LABELS)},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": name},
            "subjects": [{"kind": "ServiceAccount", "name": name, "namespace": "group-sync-operator"}],
        })
    return docs


def extraction():
    return [
        {
            "kind": "ClusterRole",
            "metadata": {"name": "group-sync-operator-oauth-secret-extraction"},
            "rules": [copy.deepcopy(EXACT)],
        },
        {
            "kind": "ClusterRoleBinding",
            "metadata": {"name": "oauth-extract"},
            "roleRef": {
                "kind": "ClusterRole",
                "name": "group-sync-operator-oauth-secret-extraction",
                "apiGroup": "rbac.authorization.k8s.io",
            },
            "subjects": [{
                "kind": "ServiceAccount",
                "name": "oauth-secret-extractor",
                "namespace": "group-sync-operator",
            }],
        },
    ]


def job(body, name="group-sync-operator-oauth-secret-extraction"):
    return {
        "kind": "Job",
        "metadata": {"name": name, "namespace": "group-sync-operator"},
        "spec": {"template": {"spec": {
            "serviceAccountName": "oauth-secret-extractor",
            "containers": [{"name": "run", "command": ["bash", "-c", body]}],
        }}},
    }


REACH = "BIND_DN=''\nSRC_SECRET=''\noc get oauth cluster -o json\n"


def expect(name, docs, problems, contains=None):
    got = rc.oauth_cr_read(copy.deepcopy(docs))
    ok = (bool(got) == bool(problems))
    if contains and not any(contains in g for g in got):
        ok = False
    print(f"[{'OK' if ok else 'FAIL'}] {name}  got={got}")
    return ok


def main():
    ok = True
    # A — the three CI failures: exact bound poller, no Job reach. Must PASS after the fix.
    ok &= expect("A poller exact+bound, no reach", poller(), problems=False)
    # B — wider verbs still fail, and the message names what is wider.
    ok &= expect(
        "B poller verbs also list",
        poller(rule={**EXACT, "verbs": ["get", "list"]}),
        problems=True,
        contains="verbs also ['list']",
    )
    # C — any other oauths grant with no reaching Job still fails (unchanged).
    ok &= expect(
        "C leftover ClusterRole",
        [{"kind": "ClusterRole", "metadata": {"name": "leftover-reader"}, "rules": [copy.deepcopy(EXACT)]}],
        problems=True,
        contains="leftover-reader grants oauths",
    )
    # D — reach branch: Job granted, poller also present. Still PASS.
    ok &= expect("D Job reaches + poller", poller() + extraction() + [job(REACH)], problems=False)
    # E — label without a binding is still an unused grant.
    ok &= expect("E labelled, unbound", poller(bind=False), problems=True, contains="grants oauths")
    # F — poller permissions must not be reduced.
    ok &= expect("F oauths pin removed", poller(oauths=False), problems=True, contains="was reduced")
    # G — wider poller is a failure even when a Job also reaches the API.
    ok &= expect(
        "G wider poller + reach",
        poller(rule={**EXACT, "verbs": ["get", "list"]}) + extraction() + [job(REACH)],
        problems=True,
        contains="verbs also ['list']",
    )
    # H — Job-reachability half unchanged.
    ok &= expect(
        "H Job reaches, no extraction grant",
        poller() + [job(REACH)],
        problems=True,
        contains="nothing grants get oauths/cluster",
    )
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
