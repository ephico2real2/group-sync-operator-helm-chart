#!/usr/bin/env python3
"""The artifacthub.io/changes annotation must parse as a YAML list of {kind, description}.

Artifact Hub reads the annotation's VALUE as YAML. One unescaped `"` inside a double-quoted description
breaks the whole block, and the failure is silent: helm lint passes, the chart publishes, and Artifact
Hub shows no changelog at all. Found by review on 2026-09-18 — the block had not parsed since the 0.11
entry that quoted `(default "")`, so every entry after it was invisible.
"""
import pathlib
import sys

import yaml

chart = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "charts/group-sync-operator-helm") / "Chart.yaml"
raw = yaml.safe_load(chart.read_text())["annotations"]["artifacthub.io/changes"]
try:
    entries = yaml.safe_load(raw)
except yaml.YAMLError as exc:
    sys.exit(f"::error::{chart}: artifacthub.io/changes is not valid YAML — Artifact Hub drops the whole block:\n{exc}")
if not isinstance(entries, list) or not entries:
    sys.exit(f"::error::{chart}: artifacthub.io/changes must be a non-empty list")
bad = [i for i, e in enumerate(entries, 1) if not (isinstance(e, dict) and set(e) == {"kind", "description"})]
if bad:
    sys.exit(f"::error::{chart}: artifacthub.io/changes entries without exactly kind+description: {bad}")
# The six kinds Artifact Hub documents; anything else (a typo like `fixd`) is rejected by its schema and
# the entry is dropped. Found by the second review pass: the first version of this check let it through.
KINDS = {"added", "changed", "deprecated", "removed", "fixed", "security"}
wrong = [(i, e["kind"]) for i, e in enumerate(entries, 1) if e["kind"] not in KINDS]
if wrong:
    sys.exit(f"::error::{chart}: artifacthub.io/changes kind not in {sorted(KINDS)}: {wrong}")
print(f"ok  artifacthub.io/changes: {len(entries)} entries parse")
