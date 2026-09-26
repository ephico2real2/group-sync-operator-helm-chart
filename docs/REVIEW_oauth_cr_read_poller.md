# Review — oauth-cr-read and the dashboard poller's oauths grant (#73)

**Implementer: OB1-lite (Opus 5.5). Reviewers: Grok 4.6 High Fast (Cursor, with a shell), Codex gpt-5.6-sol
xhigh, Codex Astra gpt-6-astra high. Arbiter: Claude.** Each reviewer worked on its own `git archive` export;
every verdict below cites a command it ran or a file:line it read.

## The use case, so a finding can be judged against it

`ci/render-checks.py`'s `oauth_cr_read` keeps an unused cluster-scoped `oauths` grant out of the chart. It
assumed every such grant served one of the chart's hook Jobs. #68 added the dashboard's cluster poller
(`templates/03.1-dashboard-cluster-poller-rbac.yaml`), which grants `get oauths/cluster` to a ServiceAccount
the dashboard uses from outside the chart — a used grant with no Job behind it. From `55c17bc` (2026-09-21)
the three renders with no reaching Job failed, and `main` stayed red.

**The constraint:** the poller's permissions are never reduced, and nothing wider than `get oauths/cluster`
may ride on the exemption.

## Rounds

| Pass | Commit | Seats | Outcome |
|---|---|---|---|
| Spec | — (on `89a92f6`) | Grok | C1–C4 confirmed; C5, C6 findings accepted: identify the poller by its binding, enforce exactness on every render, fail a reduction, fix the docstring |
| Code | `19e6efe` | Grok, Codex, Codex Astra | identification, reachability, tests and CI confirmed by all three; wildcard gap, wording and stale anchors accepted |
| Second pass | `9f638f6` | Grok, Codex | every claim confirmed; no new findings |

## Code review of `19e6efe`

| Claim | Grok | Codex | Astra | Decision |
|---|---|---|---|---|
| C1 fidelity to the spec | CONFIRMED | REFUTED (wildcard) | REFUTED (wildcard) | identification and Job reachability confirmed by all; the refutations are C6 |
| C2 test fails before, passes after | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C3 CI render step 20/20 on head, 3 failed on base | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C4 step placement, workflow parses | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C5 identification edge cases | CONFIRMED | CONFIRMED | CONFIRMED | — |
| C6 `resources: ['*']` invisible (beside the pin; leftover role in a no-reach render) | PLAUSIBLE, fix | P1, fix + test | same gap measured | **Accepted** |
| C7 a narrower rule called "wider" | not worth it | fix now | optional | **Accepted** — "wider" points the reader the wrong way |
| C8 stale `ci.yaml` line anchors in `ci/act-local.sh` | — | non-blocking | stale reference | **Accepted** — cite step names |

Two departures from Codex's P1 code, both confirmed safe on the second pass: a literal `oauths` resource still
counts in any API group (only stricter — it can add a failure, never hide one; no real render is affected),
and the per-field detail strings were kept, except that `verbs: ['*']` no longer also reports `verbs missing
['get']`.

## Evidence on `9f638f6`

- `python3 ci/test_oauth_cr_read.py`: 14/14 on head; on `19e6efe`'s check it fails B G I J M N; on
  `89a92f6`'s it fails A B F G I J K L M N.
- The "Render every combination and assert coherence" step: `all combinations coherent`, 20 rows `ok`
  (base: `3 assertion(s) failed`).
- 17 successful renders: no `resources: ['*']` rule; the poller passes in all of them.
- `charts/` unchanged against `89a92f6`; version-bump: no chart content changed, no bump needed.
