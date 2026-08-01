# Plan: multi-cluster GroupSync dashboard

**Status:** first slice implemented (§14) and running. Sections below are the design; where
building it proved a section wrong, the correction is marked **Amended** and dated.
Implementation: [`group-sync-dashboard`](https://github.com/ephico2real2/group-sync-dashboard)
— Python/FastAPI, deployed on CRC 2026-08-01.
**Goal:** a containerized web app that shows, across several OpenShift clusters, what
GroupSync is doing: which CRs exist, when each last synced, which groups they produced, and
whether anything is silently broken.

Read-only. It observes; it does not create or edit GroupSync CRs.

---

## 1. Why this is worth building

Everything this dashboard would surface has, in the course of one session on a single
cluster, been the thing that went wrong:

| Failure | How it presents today |
|---|---|
| Group referenced by a RoleBinding but absent | nothing — binding looks healthy, grants nobody |
| Group synced but empty | nothing — `oc get groups` shows a blank USERS column |
| Group in LDAP but filtered out by the CR | nothing — no object is ever created |
| CR not honouring its schedule | nothing until you diff timestamps by hand |

None of these raise an event or a failed reconcile. They are all *absences*, and absences are
exactly what a human scanning `oc get` output does not notice. That is the case for a
dashboard rather than a runbook.

## 2. The constraint that shapes the design

**The API carries current state only — one timestamp per CR, one per Group. There is no sync
history anywhere in it.**

So a timeline cannot be read from the cluster on demand; it has to be *accumulated*. Three
sources, and the tradeoff drives the storage decision:

| Source | Gives | Costs |
|---|---|---|
| `.status.lastSyncSuccessTime` | last success only | trivial to poll; history must be built by storing successive observations |
| `.status.conditions[]` | last success *and* last failure, each with `lastTransitionTime` + `observedGeneration`, failure with a message | free — same GET; but the two conditions coexist, see below |
| operator log, `manager` container | every sync, with `Groups Created or Updated` counts | lost on pod restart, needs `pods/log` RBAC, timestamps are **epoch floats** not RFC3339, and the pod's *default* container is `kube-rbac-proxy` which logs nothing useful |

**Decision needed:** poll-and-store (simple, durable, loses detail between polls) versus
log-scrape (richer, fragile, more RBAC). Recommend poll-and-store as the primary, with log
scrape as an optional per-cluster enrichment.

### 2.1 `ReconcileError` is sticky — verified 2026-08-01, CRC

A healthy CR mid-normal-operation carries **both** conditions at `status: True`
simultaneously:

```json
{ "type": "ReconcileSuccess", "status": "True", "reason": "LastReconcileCycleSucceded",
  "lastTransitionTime": "2026-08-01T07:00:10Z", "observedGeneration": 2 },
{ "type": "ReconcileError",   "status": "True", "reason": "LastReconcileCycleFailed",
  "lastTransitionTime": "2026-07-30T15:16:17Z", "observedGeneration": 1,
  "message": "failed calling webhook \"validate.kyverno.svc-fail\": ... connection refused" }
```

That `ReconcileError` is from a Kyverno webhook outage two days earlier, at
`generation=1`. It was never cleared by any of the ~100 successful syncs since.

**So `ReconcileError.status == "True"` does not mean "currently failing".** Reading it that
way paints every CR that has ever had one bad reconcile permanently red — a false alarm that
would train operators to ignore the dashboard, which is worse than not showing the field.

The error is current only if it is *newer* than the success:

```text
error_is_current =
    ReconcileError.lastTransitionTime  >  ReconcileSuccess.lastTransitionTime
```

Prefer that comparison over `observedGeneration`: generation only advances on a **spec**
change, so two failures at the same generation are indistinguishable by it, and a CR whose
spec never changes stays at one generation forever.

When the error is *not* current it is still worth keeping — as history, not as an alarm. It
is the only failure record the API retains, and it survives the pod restarts that lose the
operator log.

## 3. What to read from each cluster

```text
GroupSync         .spec.schedule, .spec.providers[].ldap.rfc2307.groupsQuery.filter
                  .status.lastSyncSuccessTime, .metadata.generation
                  .status.conditions[]            -- last success AND last failure (§2.1)
Group             .metadata.name, .users[], .metadata.labels, .metadata.annotations
```

API group is `redhatcop.redhat.io/v1alpha1` — note it is **not** `redhat-cop.io`, which is
the prefix used by the labels and annotations below. The two differ by a hyphen and are easy
to transpose.

**The join key is a label.** Groups synced by the operator carry:

```text
group-sync-operator.redhat-cop.io/sync-provider: <groupsync-name>_<provider>
```

e.g. `bda-rbac-groupsync_ldap`. That is what attributes a Group to the CR that created it —
without it there is no way to answer "which groups did this CR produce?" and the dashboard
would be reduced to two unrelated lists.

**Each Group also carries its own sync timestamp and source DN** (verified 2026-08-01):

```yaml
annotations:
  group-sync-operator.redhat-cop.io/sync-time: "2026-08-01T07:00:07Z"   # RFC3339, per group
  openshift.io/ldap.uid:  cn=app-ocp-rbac-abcd-ns-superuser,ou=Groups,dc=ephico2real,dc=com
  openshift.io/ldap.url:  openldap-service.ldap-testing.svc.cluster.local:389
labels:
  openshift.io/ldap.host: openldap-service.ldap-testing.svc.cluster.local
```

Two things follow.

`sync-time` is **per group**, so a group that stopped being refreshed is detectable even
while its CR keeps reporting success — see the stale-group alert in §8. This is the one
absence-shaped failure that `lastSyncSuccessTime` alone cannot expose, because a CR that
syncs 39 of its 40 groups reports exactly the same status as one that syncs all 40.

`ldap.uid` is the **source DN**, which answers "where did this group come from?" without any
LDAP credential. For the §1 case *"group in LDAP but filtered out by the CR"* it gives the
half of the answer that is visible from the cluster: the DNs that did make it through. It
cannot show what was excluded — nothing on-cluster can, since no object is created — so
diagnosing an over-tight filter still means comparing this list against LDAP by hand.

Optional, for the RoleBinding view (§7): `RoleBinding` / `ClusterRoleBinding` subjects of
`kind: Group`.

### 3.1 A sync writes its groups over several seconds

`sync-time` is not one value per sync. For `ldap-groupsync` at 07:00 the 40 groups carried 15
distinct timestamps spanning `07:00:00`–`07:00:10`, and the CR's `lastSyncSuccessTime` was
`07:00:10` — equal to the *last* group written, i.e. the CR timestamp is stamped after the
group writes finish.

So **the CR timestamp and its groups' timestamps are legitimately unequal, by up to the write
window.** Any staleness check must be a threshold, never an equality — and the threshold has
to exceed the write window, which scales with group count and will be wider on a real
directory than the 10s seen here on 40 groups.

## 4. RBAC — one read-only ServiceAccount per cluster

```yaml
kind: ClusterRole
rules:
  - apiGroups: ["redhatcop.redhat.io"]
    resources: ["groupsyncs"]
    verbs: ["get", "list"]
  - apiGroups: ["user.openshift.io"]
    resources: ["groups"]
    verbs: ["get", "list"]
  # only if the RoleBinding view is enabled
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings", "clusterrolebindings"]
    verbs: ["get", "list"]
  # only if log-scrape enrichment is enabled
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
```

No `watch` — see §6. No write verbs anywhere.

> Worth checking per cluster before assuming: on this cluster the Kyverno **admission**
> controller could not read `groups.user.openshift.io` while the **background** controller
> could. Do not assume a ServiceAccount can read Groups just because it can read core
> resources.

## 5. Multi-cluster connection model

One record per cluster, each independently credentialed:

```yaml
clusters:
  - name: crc-local
    apiUrl: https://api.crc.testing:6443
    tokenSecretRef: gsd-token-crc-local     # Secret in the dashboard's namespace
    caBundleRef: gsd-ca-crc-local           # optional; else system trust
    insecureSkipVerify: false               # dev only
    enrichment:
      operatorLogs: false
```

Tokens live in Secrets mounted into the backend, never in the config object and never
returned by the API. A cluster with a bad or expired token must render as a **degraded card,
not a page-level error** — one unreachable cluster should not blank the dashboard.

Bootstrapping a cluster is then:

```bash
oc create sa group-sync-dashboard -n group-sync-operator
oc adm policy add-cluster-role-to-user group-sync-reader -z group-sync-dashboard -n group-sync-operator
oc create token group-sync-dashboard -n group-sync-operator --duration=8760h
```

**Token lifetime is the main operational question.** Bound tokens expire; the dashboard needs
either long-lived tokens (simpler, worse security posture) or a refresh story. Flag rather
than decide here.

## 6. Polling, not watching

Sync events are at most hourly. A `watch` per cluster means N persistent connections,
reconnect handling, and relist storms on restart — for data that changes on a cron.

**Poll every 60s** per cluster. That is 60× finer than the fastest schedule seen in practice
and cheap: two list calls per cluster per minute.

Store an observation row each time `lastSyncSuccessTime` **changes** — not every poll — so
the timeline is sync events rather than a poll log.

## 7. Views

**Cluster overview** — one card per cluster: reachable?, CR count, group count, oldest
`lastSyncSuccessTime`, count of groups that are empty or unattributed.

**GroupSync detail** — per CR: schedule, filter, last sync, *next expected* sync (computed
from the cron expression — this is what makes "overdue" detectable), sync timeline, and the
groups it owns.

**Group explorer** — every group with member count and owning CR. Filterable to the two
states that are otherwise invisible:

- `EMPTY` — synced, zero members
- `UNATTRIBUTED` — no `sync-provider` label, so not operator-managed

> **Amended 2026-08-01 (found by building it).** The two states must be **mutually
> exclusive**, and the implementation initially made them overlap. A group created by hand
> (`oc adm groups new`) has zero members *and* no `sync-provider` label, so a naive
> `member_count == 0` test reported it twice — once as unattributed, and once as "synced with
> zero members", which it never was. `EMPTY` therefore requires `sync_provider IS NOT NULL`.
>
> The distinction is not pedantic: the two point at different faults. `EMPTY` means the
> operator synced a group and found nobody, which sends you to LDAP. `UNATTRIBUTED` means
> nothing is managing the object at all, which sends you to whoever created it. Reporting
> the second as the first sends the reader hunting an LDAP fault that does not exist.

**Binding health** (optional, needs the RBAC above) — RoleBindings and ClusterRoleBindings
whose `kind: Group` subject does not resolve to an existing Group. This is the highest-value
view and the one nothing in OpenShift provides today.

## 8. Alert conditions worth computing

- **Overdue:** `now - lastSyncSuccessTime > 2 × schedule interval` → the schedule stopped firing
- **Empty group:** synced with zero members → LDAP-side problem, e.g. a `member:` DN that
  does not resolve
- **Dangling binding:** a binding references a Group that does not exist
- **Group count cliff:** a sync where the group count drops sharply → filter or LDAP change
- **Newly unattributed:** a Group lost its `sync-provider` label
- **Stale group:** `CR.lastSyncSuccessTime - group.sync-time > 1 interval` → the CR is
  syncing, but this group is not being refreshed with the rest. Invisible at CR level (§3)
- **Reconcile error current:** `ReconcileError.lastTransitionTime >
  ReconcileSuccess.lastTransitionTime` → the last cycle failed, with the operator's own
  message. Never alert on `ReconcileError.status` alone (§2.1)

The first three each correspond to a real failure observed on this cluster.

Two of these need care before they are switched on:

**Stale group** must use a threshold wide enough for the intra-sync write window (§3.1) and
should be suppressed during an in-flight sync, when some groups legitimately still carry the
previous cycle's timestamp. Comparing against the *CR* timestamp rather than `now` mostly
handles this, since the CR is stamped last.

**Group count cliff** needs a floor as well as a ratio, and must tolerate motion in both
directions. A single observed cycle on this cluster (07:00, §A) added four groups — `+1` to a
CR holding 40 and `+3` to one holding 18, a 17% jump for the latter in one sync. On a CR
owning three groups, losing one is a 33% drop and routine. Percentage alone will either miss
real cliffs on large CRs or fire constantly on small ones.

## 9. Shape

```text
frontend (SPA)  ──►  backend API  ──►  cluster A  (token A)
                          │        ──►  cluster B  (token B)
                          ▼
                     store (observations)
```

- **Backend:** one service, fans out per cluster, owns polling and the store. Language open;
  Go gives real client-go typing, Python/FastAPI gives faster iteration.
- **Frontend:** SPA against the backend only. Never holds a cluster token.
- **Store:** SQLite is sufficient for observation rows at this volume; Postgres if the
  dashboard itself needs HA.

## 10. Storage schema

Three tables. `clusters` is config; the other two are the accumulated observations that the
API cannot give us (§2).

```sql
-- configured clusters (token lives in a Secret, never here)
cluster(
  id, name, api_url, token_secret_ref, ca_bundle_ref,
  insecure_skip_verify, enrichment_operator_logs, enabled
)

-- one row per OBSERVED sync, written only when lastSyncSuccessTime CHANGES
sync_event(
  id, cluster_id, groupsync_name, groupsync_namespace,
  synced_at,            -- .status.lastSyncSuccessTime, the operator's own timestamp
  observed_at,          -- when our poll saw it; observed_at - synced_at = our lag, not the operator's
  schedule,             -- snapshot: schedules change, and old rows must stay interpretable
  group_count,          -- groups carrying this CR's sync-provider label at observation time
  UNIQUE(cluster_id, groupsync_name, synced_at)
)

-- current group state, replaced each poll; history not kept
group_state(
  cluster_id, name, member_count, sync_provider, observed_at,
  group_synced_at,      -- the group's OWN sync-time annotation, not the CR's (§3)
  ldap_uid,             -- source DN from openshift.io/ldap.uid
  PRIMARY KEY(cluster_id, name)
)

-- last reconcile FAILURE per CR, from .status.conditions (§2.1)
-- separate from sync_event because failures and successes advance independently:
-- a CR can hold a months-old error alongside a 60-second-old success
reconcile_error(
  cluster_id, groupsync_name,
  failed_at,            -- ReconcileError.lastTransitionTime
  observed_generation,
  message,
  PRIMARY KEY(cluster_id, groupsync_name)
)
```

Two deliberate choices:

**`synced_at` and `observed_at` are separate.** The first is the operator's; the second is
ours. Conflating them would attribute our polling lag to the operator. With a 60s poll,
`observed_at - synced_at` should stay under a minute — if it grows, the *dashboard* is
behind, which is a different problem from a sync being late.

**`schedule` is snapshotted per event.** Schedules change — this session moved one from
`*/2` to `*/30` mid-flight. Without the snapshot, historical rows get re-interpreted against
today's cron and every pre-change event looks overdue.

The `UNIQUE` constraint makes the poll loop idempotent: re-observing the same
`lastSyncSuccessTime` is a no-op, so polling faster than the schedule costs nothing.

> **Amended 2026-08-01 (found by building it).** Two more tables are required; the schema
> above cannot answer §11 without them.
>
> ```sql
> -- current CR state, replaced each poll
> groupsync_state(
>   cluster_id, name, namespace, schedule, ldap_filter,
>   last_sync_at, generation, provider_key, observed_at,
>   PRIMARY KEY(cluster_id, name, namespace)
> )
>
> -- §12 step 7's outcome, which §11's /api/clusters returns
> poll_outcome(cluster_id, observed_at, status, message)
> ```
>
> `group_state` covers groups but nothing covers **CRs**, and `sync_event` cannot stand in
> for it: a CR that has never synced has no event at all, yet still has a schedule and a
> filter to display — and `.spec` fields such as the LDAP filter are not on the event by
> design, since the event snapshots only what is needed to interpret it later.
>
> `poll_outcome` is where `reachable` / `last_poll` / `error` live. §12 computes the outcome
> and §11 returns it, but §10 gave it nowhere to sit.
>
> `provider_key` is stored rather than reconstructed. The label the operator writes is
> `<groupsync-name>_<provider>`, and the provider's name is not on the CR's status — so the
> poller records the label value it actually observed on that CR's groups. Matching is
> anchored on the `<name>_` prefix, or `ldap-groupsync` would claim
> `ldap-groupsync-staging`'s groups.

## 11. API surface

All read-only. No endpoint returns a token or accepts one from the browser.

```text
GET  /api/clusters                        id, name, reachable, last_poll, error
GET  /api/clusters/{id}/groupsyncs        schedule, filter, last_sync, next_expected, state
GET  /api/clusters/{id}/groupsyncs/{n}/events?since=   the accumulated timeline
GET  /api/clusters/{id}/groups?state=empty|unattributed|all
GET  /api/clusters/{id}/bindings/dangling  optional, needs the extra RBAC in §4
GET  /api/alerts                          computed, across all clusters
GET  /healthz  /readyz
```

`state` on a groupsync is computed, not stored:

```text
ok        now - last_sync  <=  1 interval  + grace
late      now - last_sync   >  1 interval  + grace
overdue   now - last_sync   >  2 intervals + grace      -> alert
unknown   cluster unreachable, no sync observed yet, or an unparseable schedule
```

> **Amended 2026-08-01 (found by building it).** `grace` is not in the original thresholds,
> and they do not work without it — **they flap once per cycle on a perfectly healthy CR.**
>
> The window is after the next sync fires but before our poll observes it. The operator
> fires 3–14s after its cron minute (measured on CRC), and the poll that sees it lands up to
> `pollIntervalSeconds` later. For those ~70s the *observed* age exceeds one full interval
> with nothing actually wrong, so `ok: age <= interval` reports `late` on every single cycle.
> A status that blinks amber every cycle is one operators learn to ignore, which costs more
> than the field is worth.
>
> `grace` (default 120s — poll interval plus scheduler slack) shifts the boundary; it does
> not widen the classes, and a genuinely overdue CR still crosses `2 × interval + grace`.
> Both behaviours are pinned by tests.
>
> `unknown` also absorbs an unparseable schedule: missing information is not evidence of
> failure, and calling it `overdue` would invent an outage.

**`next_expected` needs a real cron parser**, not arithmetic on the interval. `0 * * * *`
and `*/30 * * * *` both "fire hourly" if you only measure gaps from the last event — the
difference only shows at `:30`, which is exactly the ambiguity that made the first pass of
the schedule test inconclusive. Use a library (`croniter`, `robfig/cron`); do not hand-roll.

## 12. Poll loop

Per cluster, every 60s, independently — one slow or unreachable cluster must not stall the
others:

```text
1. list GroupSync            -> spec.schedule, spec.providers[].ldap...filter,
                                status.lastSyncSuccessTime, status.conditions[]
2. list Group                -> name, users[], sync-provider label,
                                sync-time + ldap.uid annotations
3. attribute groups to CRs via the label   (verified: 62/62 attributed, 0 orphans)
4. for each CR: if lastSyncSuccessTime differs from the newest stored sync_event,
   insert one row (schedule + group_count snapshotted)
5. upsert reconcile_error from the ReconcileError condition, if present
6. replace group_state for this cluster
7. record poll outcome: ok | auth_failed | unreachable | forbidden
```

Step 7 matters more than it looks. **`forbidden` must be distinguishable from `unreachable`**
— a ServiceAccount that can list GroupSync but not Group produces a half-populated view that
otherwise looks like a cluster with no groups. Surface it as a degraded card naming the
missing permission, not as an empty result.

Verified on CRC: a bad token returns **401**, a permission failure **403**, and a connect or
TLS failure raises before any status code — three distinct signals, so the distinction is
readable rather than inferred.

> **Amended 2026-08-01 (found by building it).** Steps 1 and 2 must **page**. The API server
> returned a `continue` token for as few as two Groups once `limit` was set, and a list call
> that ignores it is silently truncated. Truncation here is the worst possible failure mode:
> a short group list looks exactly like a cluster that has fewer groups than it does, which
> is precisely the invisible-absence class this dashboard exists to catch. The client
> follows `metadata.continue` until it is empty.

## 13. Open questions

1. **Token lifetime and rotation** — long-lived tokens, or a refresh mechanism?
2. **Retention** — how long to keep observations? Sync events are small; a year is probably
   fine.
3. **Where does it run** — on one of the observed clusters, or standalone? Standalone avoids
   a cluster being unable to report its own outage.
4. **Auth on the dashboard itself** — it aggregates group membership across clusters, which
   is sensitive. OIDC in front, or is it internal-only?
5. **Log-scrape enrichment** — worth the extra RBAC and fragility for per-sync group counts,
   or is poll-and-store enough?

## 14. First slice — built 2026-08-01

Cluster overview + GroupSync detail against **one** cluster, poll-and-store, no log scrape,
no binding view. That proves the connection model and the timeline-accumulation design — the
two things most likely to be wrong — before any multi-cluster or enrichment work.

**Built and running.** Python/FastAPI + SQLite + a vanilla-JS SPA, in
[`group-sync-dashboard`](https://github.com/ephico2real2/group-sync-dashboard). Deployed to
CRC from the internal registry, observing its own cluster via the pod's projected
ServiceAccount token; 82 tests (62 unit, 20 Playwright) plus 4 opt-in live-cluster smoke
tests, skipped by default so the suite stays hermetic.

What the slice actually settled:

| Question | Answer |
|---|---|
| Connection model | Works. Per-cluster token + CA, TLS verified (no `insecureSkipVerify` needed even on CRC) |
| Timeline accumulation | Works. The `UNIQUE` constraint makes a 60s poll against a 30m schedule free |
| Poll vs watch | Poll is ample — 2 list calls/minute, ~15ms each against 63 groups |
| Cost of the design | Four wrong assumptions, all in §7/§10/§11/§12 above and all amended |

**Deliberately still out:** binding health, log-scrape enrichment, and the group-count cliff
alert — the last needs a floor as well as a ratio (§8).

**The next thing worth doing is a second cluster**, not another view. Everything so far has
one cluster's worth of evidence, and §5's degraded-card behaviour has only been tested
against a synthetic failure, never a real second endpoint.

### 14.1 What the first slice proved about the *plan*

Four of the amendments above were found by building, not by reading — worth recording,
because they share a shape. Each is a case where the design was right about *what* to show
and wrong about *when the data means it*:

- a status field that is true but not current (`ReconcileError`, §2.1),
- a threshold that is correct on paper and flaps in practice (§11),
- two categories that read as disjoint and overlap on real objects (§7),
- a list call that is complete until the collection grows (§12).

None would have surfaced from more design review. All four surfaced within minutes of
pointing the thing at a real cluster and seeding the states it was supposed to catch — which
is the argument for §14 existing at all.

**The first slice has no test data for its most important views.** On CRC right now there are
zero empty groups and zero unattributed groups (§A) — the two states §7 calls out as
otherwise invisible. Both filters would return an empty list, which looks identical to a
working filter and to a broken one. Before building them, seed the states deliberately:

```bash
# UNATTRIBUTED — a group the operator does not own
oc adm groups new gsd-test-unattributed

# EMPTY — strip the members from a synced group; the next sync restores it,
# so observe within one interval, and expect it to self-heal
oc patch group app-ocp-rbac-abcd-ns-superuser --type=json -p='[{"op":"remove","path":"/users"}]'
```

The empty case self-healing on the next sync is itself the better test: it exercises the
transition, not just the state.

---

## Appendix A. Verification log

Everything in §2.1, §3, §3.1 and the drift figure in §8 was read off CRC on **2026-08-01**,
against the two CRs in `values.yaml` (`ldap-groupsync` at `*/30 * * * *`, `bda-rbac-groupsync`
at `0 * * * *`). Commands, so the claims can be re-checked rather than trusted:

```bash
# CR schedules + last success  ->  bda 0 * * * * / ldap */30 * * * *, both gen=2
oc get groupsync -A -o custom-columns=\
'NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastSyncSuccessTime,GEN:.metadata.generation'

# full status  ->  the coexisting ReconcileSuccess + ReconcileError of §2.1
oc get groupsync ldap-groupsync -n group-sync-operator -o jsonpath='{.status}' | python3 -m json.tool

# attribution + empty/unattributed census  ->  62 groups, 41 + 21, 0 empty, 0 unattributed
oc get groups -o json | python3 -c "
import sys, json
from collections import Counter
items = json.load(sys.stdin)['items']
c = Counter(g['metadata'].get('labels', {}).get(
    'group-sync-operator.redhat-cop.io/sync-provider') for g in items)
print('total', len(items), dict(c))
print('empty', sum(1 for g in items if not (g.get('users') or [])))
"

# per-group sync-time spread  ->  the 10s write window of §3.1
oc get groups -o json | python3 -c "
import sys, json
from collections import Counter
items = json.load(sys.stdin)['items']
c = Counter((g['metadata'].get('labels', {}).get(
                 'group-sync-operator.redhat-cop.io/sync-provider'),
             g['metadata'].get('annotations', {}).get(
                 'group-sync-operator.redhat-cop.io/sync-time')) for g in items)
for (provider, synced), n in sorted(c.items(), key=lambda kv: str(kv[0])):
    print(f'{provider:28} {synced}  x{n}')
"
```

Observed at 07:00: `ldap-groupsync`'s groups carried 15 distinct `sync-time` values from
`07:00:00` to `07:00:10`, and the CR's `lastSyncSuccessTime` was `07:00:10`.

**A sync landed mid-verification, which is why the census is quoted twice.** The census run
before 07:00 returned 58 groups (40 + 18); the run after returned 62 (41 + 21). The
difference is not drift — it is one cycle's work, and `creationTimestamp` accounts for all
four:

```text
07:00:10  app-ocp-rbac-tstd-ns-audit      ldap-groupsync   +1
07:00:14  bda-rbac-spark-syncb-users      bda-rbac-groupsync
07:00:14  bda-rbac-spark-syncc-users      bda-rbac-groupsync  +3
07:00:14  bda-rbac-spark-syncd-users      bda-rbac-groupsync
```

Earlier cycles show the same pattern (`tsta` at 06:00:07, `tstb`/`tstc` at 06:30:07), so the
LDAP fixture under `setup-local-ldap-testing/` is actively seeding groups and this cluster
gains one or more per cycle. Two consequences for the dashboard: the first slice has a live
source of *new*-group events to build the timeline against, and any count comparison taken
across a sync boundary — as the two censuses above were — is measuring the operator, not the
directory. The `sync_event` table of §10 exists precisely so this distinction is recorded
rather than reconstructed.

**What this does not establish.** One cluster, one LDAP directory, ~60 groups, two CRs, and a
single `v1alpha1` operator build. The write window of §3.1 is a *lower* bound — it will widen
with group count, and the staleness threshold of §8 must be derived from a real directory
rather than inherited from this number. The stickiness of `ReconcileError` in §2.1 is one
observation of one error surviving ~100 successes; it has not been tested against an operator
upgrade or a CR whose spec changes while the error is outstanding.
