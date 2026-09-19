# Review — PR #65, chart 0.13.2: reinstall is one shot, and Argo CD no longer prunes the credentials Secret and the CA copy

Adversarial second-opinion pass, 2026-09-18 → 19, on the ten-claim brief for #65. Codex (gpt-5.6-sol,
xhigh) had a shell and measured with a fake-`oc` harness; Cursor (Grok 4.6 high fast, ask mode, shell
blocked) traced from source and marked what it could not measure PLAUSIBLE; OB3 (Opus 5, the project
reviewer, self-scaling depth) built a stateful harness with a call log and cited the Argo CD 3.4.7 and
gitops-engine sources. Every verdict was re-checked here before a decision.

## Verdicts

| Claim | Codex | Cursor | OB3 | Decision |
|---|---|---|---|---|
| C1 the stamp drops `app.kubernetes.io/instance`; nothing selects by it | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C2 Argo label-tracking semantics; the new key collides with nothing | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C3 reclaim: any-phase candidate, settled-only delete, `continue 2` | CONFIRMED | CONFIRMED | CONFIRMED | — (N2 refines the final line) |
| C4 clean install / installed CSV: exit 0 at once | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C5 weights under Helm; same wave and concurrent under Argo; retry automatic | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C6 approver reports the original message at the deadline | **REFUTED** | **REFUTED** | **REFUTED** | **Accepted** — OB3's F1 applied |
| C7 values keys, image, version, three parseable entries | REFUTED (whole block) | CONFIRMED | CONFIRMED (+N3) | **Accepted on the fact** — the block had not parsed since 0.11; OB3's F5 + a CI check |
| C8 RBAC namespaced and additive | CONFIRMED | CONFIRMED / PLAUSIBLE | CONFIRMED | — |
| C9 ci scripts and the render matrix pass | CONFIRMED | PLAUSIBLE (not run) | CONFIRMED | — |
| C10 the upgrade needs a manual sync | **REFUTED** | CONFIRMED | **REFUTED** | **Accepted** — the statement was wrong for the release upgrade; OB3's F3 applied, Codex's annotation snippet rejected |

## C6 — the deadline path reported the wrong failure

**Finding (all three).** The loop is `for i in $(seq 1 "$ATTEMPTS")`, and my patient branch only
`continue`d inside it. `ATTEMPTS = waitSeconds/5` and `DEADLINE = now + waitSeconds` are two clocks over the
same budget, so with a fast API the attempts ran out before `out_of_time` ever fired, control fell through to
the plan scan, and the Job died with "never referenced an InstallPlan … a missing catalog source" — pointing
the operator at a catalog problem. OB3 measured it both ways: an instant fake `oc` gave the generic message,
a 0.5 s-latency one gave the remedy — "a timing accident".

**Re-check.** Codex's harness on HEAD failed exactly at `grep -q 'OLM cannot resolve subscription'` on the
deadline log; passed on the fixed tree.

**Decision.** Accepted. OB3's F1: `report_resolution_failure()` as one function, called at once when the
reclaim is disabled and after the loop when the last verdict read was `ResolutionFailed`. Codex's
alternative (a `while` loop driven by the deadline) fixes the same thing with a larger diff; not taken.

## N1 (OB3) — a settled orphan made the approver exit 0 without approving

**Finding.** `csv_phase` is read before `resolution_failure`, and "Succeeded and no InstallPlan pending →
nothing to approve, exit 0" is exactly what a settled orphan looks like. Under Argo both hooks share wave 0, so
the approver reads the orphan, exits 0 and is deleted (HookSucceeded); the reclaim deletes the orphan seconds
later; OLM stages a Manual plan; nobody approves it; the Subscription stays Progressing and wave 0 never goes
healthy — the 0.13.0 deadlock. The PR's Argo runs passed only because they landed inside the twelve-second
`Installing` churn after an uninstall. Harness: exit 0 in 0.10 s, zero patches.

**Re-check.** Reproduced with OB3's harness on HEAD (`c6e-stale-succeeded-orphan`: exit 0, 0 PATCHED). Traced
the fix: with the reclaim enabled a Succeeded CSV is "nothing to approve" only when `installedCSV` names it;
otherwise the Job logs and keeps waiting for the plan that follows the reclaim. Reclaim disabled: unchanged.

**Decision.** Accepted — OB3's F2, the single most important finding of the pass. On the fixed tree `c6e`
approves the plan (1 PATCHED). Live: the uninstall → wait until the orphan has been Succeeded for minutes →
install sequence (recorded on the PR) exercises this path on the cluster.

## Codex's top finding — the package match was a substring

**Finding.** `*"${PACKAGE#openshift-}"*|"${PACKAGE}"*` (ported from cert-manager-venafi, whose package and
CSV prefixes differ) matched `group-sync-operator-community.v9.9.9` and deleted it as an orphan of this
package. Harness: `exit=0 deletes=1`.

**Re-check.** Ran the harness on HEAD: the wrong-package case deleted. The approver in this chart already
anchors on `"${SUBSCRIPTION}.v"` and its comment gives the same reason.

**Decision.** Accepted: both scans anchored on `"${PACKAGE}.v"*`. Routed to the cert-manager-venafi and
openshift-gitops charts (same ported block; venafi genuinely needs the stripped prefix, the gitops chart does
not).

## C7 / N3 — `artifacthub.io/changes` had not parsed since 0.11

**Finding (Codex, OB3).** The 0.11 "added" entry quotes `(default "")` inside a double-quoted description, so
the whole annotation value fails to parse; Artifact Hub then shows no changelog at all, including this
release's three entries. Pre-existing — measured on `main` too.

**Decision.** Accepted on the fact. OB3's F5 (the entry rewritten as a folded scalar) and a CI step,
`ci/check-artifacthub-changes.py`, so it cannot recur silently. 60 entries parse.

## C10 — "run one manual sync after the upgrade" was the wrong mechanism

**Finding (Codex, OB3).** Every rendered resource carries `helm.sh/chart: <name>-<version>`, so the release
upgrade 0.13.1 → 0.13.2 changes 36 of 36 common objects and adds three; the Application is OutOfSync,
automated sync runs, and a sync always carries its Sync hooks even under `ApplyOutOfSyncOnly`
(gitops-engine `sync_context.go`, `filterOutOfSyncTasks … if t.isHook() { return true }`). The hooks rerun
and rewrite both objects. What the PR measured — no operation when moving between two commits whose non-hook
manifest is identical — is true of that pair, not of the release.

**Decision.** Accepted: OB3's F3 corrects the changelog sentence. Codex's proposed "one-release annotation on
the Subscription" is rejected — the chart label already does this on every version bump. OB3's note that no
annotation, wave or sync-option makes Argo run hooks on a Synced application (only a manifest change or a
manual sync does) is recorded as the boundary.

## Not asked, and what happened to it

- OB3 N2: the reclaim's final line said "no CSV here is orphaned" when a candidate existed but never settled
  — F4 applied, three lines; the message now names the unsettled candidate and where to look.
- OB3 N4: the PR body said "19-combination render matrix"; the step runs 20. PR body corrected.
- Codex's `ci/pr65-hook-regressions.sh` adopted as `ci/hook-scripts-harness.sh` and wired into CI beside the
  ordering check; it is the failing-before / passing-after test for C6 and the package anchor.
- Cursor: no Unasked findings beyond C6; its C9 was PLAUSIBLE because it has no shell — Codex and OB3 ran the
  checks.

## Outcome

Three claims refuted by measurement (C6, C7's whole-block parse, C10's mechanism) and two volunteered defects
that outrank them (OB3's settled-orphan early exit, Codex's substring package match). Five fixes applied, one
snippet rejected with the reason. Re-validated: `helm lint`; url-guard, check-ordering, qualified-resources;
the 20-combination render matrix; the two new CI checks; OB3's 16-case harness on the fixed scripts (every
case as specified, `c6e` now approves); the live cluster uninstall → settled orphan → install. Second pass on
the fixed head: pending.
