#!/usr/bin/env python3
"""rbac_config_source against hand-built renders — the cases a chart render cannot produce.

The matrix only ever renders this chart, which always emits RBAC, so it can show that a labelled object
passes and an unlabelled one fails, but never that a render with no RBAC is a failure rather than a vacuous
PASS, or that a missing Chart.yaml cannot pass. These cases pin that, in memory: no helm, no cluster.
Exits 1 if any case does not hold.
"""
import importlib.util, sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "render_checks", Path(__file__).resolve().parent / "render-checks.py"
)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)


def rbac(kind="ClusterRoleBinding", value="group-sync-operator-helm"):
    labels = {} if value is None else {rc.CONFIG_SOURCE: value}
    return {"kind": kind, "metadata": {"name": "fixture", "labels": labels}}


def expect(name, docs, problems, contains=None):
    bad = rc.rbac_config_source(docs)
    ok = bool(bad) == problems and (contains is None or any(contains in b for b in bad))
    print(f"  {'ok  ' if ok else 'FAIL'} {name}{'' if ok else f': {bad!r}'}")
    return ok


def main():
    ok = True
    for kind in sorted(rc.RBAC_KINDS):
        ok &= expect(f"a labelled {kind} passes", [rbac(kind)], problems=False)
        for value in (None, "", "wrong-chart"):
            ok &= expect(f"a {kind} labelled {value!r} fails", [rbac(kind, value)], problems=True,
                         contains=f"want 'group-sync-operator-helm'")
    ok &= expect("an empty render is not a vacuous pass", [], problems=True, contains="checked nothing")
    ok &= expect("a render with no RBAC is not a vacuous pass",
                 [{"kind": "ConfigMap", "metadata": {"name": "x"}}], problems=True, contains="checked nothing")
    saved, rc.CHART_YAML = rc.CHART_YAML, Path(__file__).resolve().parent / "no-such-Chart.yaml"
    try:
        rc.rbac_config_source([rbac()])
        print("  FAIL a missing Chart.yaml cannot pass: it returned")
        ok = False
    except FileNotFoundError:
        print("  ok   a missing Chart.yaml cannot pass")
    finally:
        rc.CHART_YAML = saved
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
