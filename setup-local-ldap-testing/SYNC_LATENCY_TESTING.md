# Sync latency testing — seed groups and watch them arrive

Copy-pasteable harness for answering *"if I add a group to LDAP, when does it show up in
OpenShift, and does each GroupSync CR honour its own schedule?"*

Everything below is a self-contained block. Set `POD` once and the rest follow.

---

## 0. Setup

```bash
export POD=$(oc get pods -n ldap-testing --no-headers \
  | awk '$3=="Running" && /openldap/ {print $1}' | head -1)
export WORK=/tmp/sync-test && mkdir -p $WORK
echo "pod=$POD  now=$(date -u +%H:%M:%SZ)"
```

## 1. Baseline — schedules and current counts

```bash
oc get groupsync -A -o custom-columns=\
'NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastSyncSuccessTime' --no-headers

echo "app-ocp-rbac-*: $(oc get groups --no-headers | grep -c '^app-ocp-rbac-')"
echo "bda-rbac-*    : $(oc get groups --no-headers | grep -c '^bda-rbac-')"
```

## 2. Seeder — 1 group per family, every 15 minutes, 4 rounds

Names deliberately conform to **both** Kyverno naming policies so the test generates no
policy noise: the mnemonic is 4 letters (`[a-z]{3,4}`) and the BDA service is `spark`
(`spark|flink|trino`).

```bash
cat > $WORK/seed-groups.sh <<'SCRIPT'
#!/bin/bash
POD=$1; LOG=$2
BASE="ou=Groups,dc=ephico2real,dc=com"
MEMBER="uid=bob.wilson,ou=People,dc=ephico2real,dc=com"

for i in 1 2 3 4; do
  case $i in 1) m=tsta; t=synca;; 2) m=tstb; t=syncb;; 3) m=tstc; t=syncc;; 4) m=tstd; t=syncd;; esac
  app="app-ocp-rbac-${m}-ns-audit"
  bda="bda-rbac-spark-${t}-users"
  cat > /tmp/seed-$i.ldif <<EOF
dn: cn=${app},${BASE}
objectClass: groupOfNames
cn: ${app}
description: sync-latency test round ${i}
member: ${MEMBER}

dn: cn=${bda},${BASE}
objectClass: groupOfNames
cn: ${bda}
description: sync-latency test round ${i}
member: ${MEMBER}
EOF
  oc cp /tmp/seed-$i.ldif ldap-testing/$POD:/tmp/ >/dev/null 2>&1
  oc exec -n ldap-testing $POD -- ldapadd -x -H ldap://localhost:389 \
     -D "cn=admin,dc=ephico2real,dc=com" -w admin123 -f /tmp/seed-$i.ldif >/dev/null 2>&1
  echo "$(date -u +%H:%M:%SZ) ROUND $i created: $app , $bda" >> $LOG
  [ $i -lt 4 ] && sleep 900
done
echo "$(date -u +%H:%M:%SZ) ALL 4 ROUNDS CREATED" >> $LOG
SCRIPT
chmod +x $WORK/seed-groups.sh

: > $WORK/seed.log
nohup $WORK/seed-groups.sh "$POD" "$WORK/seed.log" >/dev/null 2>&1 &
echo "seeder started $(date -u +%H:%M:%SZ) — runs 45 min"
```

## 3. Monitor — first-appearance time of each group in OpenShift

```bash
cat > $WORK/watch-appear.sh <<'SCRIPT'
#!/bin/bash
# Uses the log file itself as the "already seen" record. Do NOT use an associative array
# here — macOS ships bash 3.2, which does not support them, and a string subscript is
# evaluated ARITHMETICALLY to index 0. The result is that the first group logs and every
# later one looks already-seen, so the monitor silently reports a single appearance no
# matter how many groups sync. Cost me a false conclusion before I spotted it.
LOG=$1
end=$(( $(date +%s) + 5400 ))          # 90 min ceiling
while [ "$(date +%s)" -lt "$end" ]; do
  for g in $(oc get groups --no-headers 2>/dev/null | awk '{print $1}' \
             | grep -E 'tst[a-d]-ns-audit|spark-sync[a-d]-users'); do
    grep -q " APPEARED ${g}$" "$LOG" 2>/dev/null || \
      echo "$(date -u +%H:%M:%SZ) APPEARED $g" >> "$LOG"
  done
  n=$(oc get groups --no-headers 2>/dev/null | grep -cE 'tst[a-d]-ns-audit|spark-sync[a-d]-users')
  [ "$n" -ge 8 ] && { grep -q "ALL 8 SYNCED" "$LOG" || echo "$(date -u +%H:%M:%SZ) ALL 8 SYNCED" >> "$LOG"; break; }
  sleep 20
done
SCRIPT
chmod +x $WORK/watch-appear.sh

: > $WORK/appear.log
nohup $WORK/watch-appear.sh "$WORK/appear.log" >/dev/null 2>&1 &
echo "monitor started $(date -u +%H:%M:%SZ) — polls every 20s"
```

## 4. Check progress at any time

```bash
echo "now: $(date -u +%H:%M:%SZ)"
echo "--- seeded ---";  cat $WORK/seed.log
echo "--- appeared ---"; cat $WORK/appear.log
oc get groupsync -A -o custom-columns=\
'NAME:.metadata.name,SCHED:.spec.schedule,LAST:.status.lastSyncSuccessTime' --no-headers
```

## 5. Operator log — every sync with real timestamps

The two traps that make this look like it logs nothing:

- the pod's **default container is `kube-rbac-proxy`** (11 lines of TLS startup) — you must
  pass `-c manager`
- timestamps are **epoch floats**, not RFC3339

```bash
oc logs -n group-sync-operator deploy/group-sync-operator-controller-manager -c manager \
  | grep 'Sync Completed Successfully' \
  | python3 -c "
import sys,re,datetime
for l in sys.stdin:
    t=datetime.datetime.fromtimestamp(float(l.split(chr(9))[0]),datetime.UTC)
    cr=re.search(r'group-sync-operator/([a-z0-9-]+)',l).group(1)
    g=re.search(r'\"Groups Created or Updated\": (\d+)',l)
    print(f'{t:%H:%M:%S}  {cr:<22} groups={g.group(1) if g else \"?\"}')
" | tail -20
```

## 6. Confirm a group reached LDAP (before blaming the sync)

```bash
oc exec -n ldap-testing $POD -- ldapsearch -x -H ldap://localhost:389 \
  -D "cn=admin,dc=ephico2real,dc=com" -w admin123 \
  -b "ou=Groups,dc=ephico2real,dc=com" \
  "(|(cn=app-ocp-rbac-tst*)(cn=bda-rbac-spark-sync*))" cn | grep '^cn:'
```

## 7. Stop and clean up

```bash
pkill -f seed-groups.sh; pkill -f watch-appear.sh

for g in tsta tstb tstc tstd; do
  oc exec -n ldap-testing $POD -- ldapdelete -x -H ldap://localhost:389 \
    -D "cn=admin,dc=ephico2real,dc=com" -w admin123 \
    "cn=app-ocp-rbac-${g}-ns-audit,ou=Groups,dc=ephico2real,dc=com" 2>/dev/null
done
for t in synca syncb syncc syncd; do
  oc exec -n ldap-testing $POD -- ldapdelete -x -H ldap://localhost:389 \
    -D "cn=admin,dc=ephico2real,dc=com" -w admin123 \
    "cn=bda-rbac-spark-${t}-users,ou=Groups,dc=ephico2real,dc=com" 2>/dev/null
done

# OpenShift Groups disappear on the next sync (pruning), or remove them now:
oc get groups --no-headers | awk '{print $1}' \
  | grep -E 'tst[a-d]-ns-audit|spark-sync[a-d]-users' | xargs -r -n1 oc delete group
```

---

## Reading the results — the trap

**Do not draw conclusions from a sync at the top of the hour.**

With `ldap-groupsync: */30 * * * *` and `bda-rbac-groupsync: 0 * * * *`, the two schedules
**coincide at `:00`**. A group appearing in both families at `HH:00` is consistent with the
override working *and* with it being ignored (both inheriting `*/30`). It proves nothing
either way.

The discriminating observation is **`:30`**, where `ldap-groupsync` fires and
`bda-rbac-groupsync` must not:

| Time | ldap-groupsync (`*/30`) | bda-rbac-groupsync (`0 * * * *`) |
|---|---|---|
| `HH:00` | fires | fires — **ambiguous, both coincide** |
| `HH:30` | fires | **must not fire** — this is the real test |

So worst-case latency differs by family: up to **30 min** for `app-ocp-rbac-*`, up to
**60 min** for `bda-rbac-*`. A group seeded at `HH:31` waits until `HH+1:00` either way,
which is easy to mistake for the schedules being identical.

Plan the seed times to land *between* `:00` and `:30` if you want the difference visible in
one hour rather than two.
