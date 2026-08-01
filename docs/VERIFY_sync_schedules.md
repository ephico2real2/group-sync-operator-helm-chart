# Verifying the sync schedules actually fire

Evidence that `groupSync.schedule` and the per-item `customGroupSyncs` override reach the
cluster and drive real syncs on their own cadences. Run on CRC, 2026-07-31.

```yaml
# values.yaml
groupSync:
  schedule: "*/30 * * * *"          # every 30 minutes

customGroupSyncs:
  items:
    - name: bda-rbac-groupsync
      schedule: "0 * * * *"         # hourly — per-item override
```

## Where the evidence is

There are **no per-sync Jobs or Pods**. The operator does the work in-process, so
`oc get jobs` shows nothing sync-related — the only Job in the namespace is the
`post-install,post-upgrade` OAuth secret-extraction hook, which is unrelated.

Two sources instead:

| Source | Shows |
|---|---|
| `.status.lastSyncSuccessTime` on each GroupSync CR | when it last succeeded |
| operator log, **`manager` container** | every sync, with group counts |

> The pod's default container is `kube-rbac-proxy`, which logs 11 lines of TLS startup and
> nothing else. `-c manager` is required or it looks like the operator logs nothing:
>
> ```bash
> oc logs -n group-sync-operator deploy/group-sync-operator-controller-manager -c manager \
>   | grep 'Sync Completed Successfully'
> ```
>
> Timestamps are epoch floats, not RFC3339, so they need converting before they mean anything.

## What was observed

```
TIME (UTC)   CR                       GROUPS  MIN  ON-SCHEDULE?
16:30:25     bda-rbac-groupsync           17   30  no — reconcile
16:32:05     ldap-groupsync               37   32  no — reconcile
16:32:09     bda-rbac-groupsync           17   32  no — reconcile
17:00:03     bda-rbac-groupsync           17    0  YES
17:00:11     ldap-groupsync               37    0  YES
17:30:07     ldap-groupsync               37   30  YES
18:00:03     bda-rbac-groupsync           17    0  YES
18:00:12     ldap-groupsync               37    0  YES
18:30:07     ldap-groupsync               37   30  YES
19:00:04     bda-rbac-groupsync           17    0  YES
19:00:14     ldap-groupsync               37    0  YES
19:30:07     ldap-groupsync               37   30  YES
```

## Interpretation

**The 16:30–16:32 syncs are not evidence of anything.** `helm upgrade` ran at 16:30:13 and
changed both CRs to `generation=2`; the operator re-synced because the spec changed. 16:32
matches neither cron expression. Stopping here and declaring success would have been reading
the right outcome from the wrong cause — the schedules had not fired yet at that point.

**17:00 proves the schedules are live but not that they differ.** Both CRs fired within
seconds of the top of the hour. `*/30` and `0 * * * *` both include `:00`, so this is
consistent with either expression, including the possibility that the override was silently
ignored and both inherited `*/30`.

**17:30 is the discriminating observation.** `ldap-groupsync` fired; `bda-rbac-groupsync` did
not. That is only possible if the two CRs hold different schedules, so it is the first
moment the per-item override is demonstrated rather than assumed.

**18:00 / 18:30 / 19:00 / 19:30 confirm it repeats.** The alternating pattern — both at
`:00`, only `ldap-groupsync` at `:30` — holds across four more cycles, ruling out coincidence
on a single hour boundary.

Group counts are stable throughout (37 for `app-ocp-rbac-*`, 17 for `bda-rbac-*`), so the
syncs are real work against LDAP, not no-ops.

Firing 3–14 seconds after the minute is normal scheduler latency.

## Reproducing

```bash
# 1. live schedules
oc get groupsync -A -o custom-columns=\
'NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastSyncSuccessTime'

# 2. every sync with its timestamp converted
oc logs -n group-sync-operator deploy/group-sync-operator-controller-manager -c manager \
  | grep 'Sync Completed Successfully' \
  | python3 -c "
import sys,re,datetime
for l in sys.stdin:
    t=datetime.datetime.fromtimestamp(float(l.split(chr(9))[0]),datetime.UTC)
    cr=re.search(r'group-sync-operator/([a-z0-9-]+)',l).group(1)
    print(f'{t:%H:%M:%S}  {cr}')
"
```

To confirm an override rather than inheritance, **compare a time the two schedules disagree
on** — `:30` here. Checking only `:00` cannot distinguish them.

## Caveat

A sync at a scheduled time proves the cron expression is being honoured. It does not prove
the operator would have picked up a *change* — group counts were static across this window,
so nothing new appeared. To test that end to end, add a group to LDAP and confirm it appears
after the next tick.
