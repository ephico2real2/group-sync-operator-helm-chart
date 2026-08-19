#!/usr/bin/env bash
# Force a GroupSync CR to sync now, instead of waiting for its cron schedule.
#
# Why a spec change and not an annotation: the operator reconciles on GENERATION change,
# and generation only advances when .spec changes. Verified on CRC 2026-08-01 —
# `oc annotate` left generation at 2 and lastSyncSuccessTime untouched, while a spec patch
# took generation to 3 and produced a sync within seconds.
#
# pageSize is the lever because it is functionally inert at this scale: it toggles between
# 0 (unpaged) and 1000, both of which return the same groups from this directory. Nothing
# else in the spec can be changed without altering what gets synced.
#
#   ./60-force-groupsync.sh app-ocp-rbac-group-groupsync [namespace]

set -euo pipefail

CR="${1:?usage: 60-force-groupsync.sh <groupsync-name> [namespace]}"
NS="${2:-group-sync-operator}"
PATH_PAGESIZE="/spec/providers/0/ldap/rfc2307/groupsQuery/pageSize"

oc get groupsync "$CR" -n "$NS" >/dev/null 2>&1 || { echo "no GroupSync '$CR' in namespace '$NS'" >&2; exit 1; }
before=$(oc get groupsync "$CR" -n "$NS" -o jsonpath='{.status.lastSyncSuccessTime}')
current=$(oc get groupsync "$CR" -n "$NS" -o jsonpath="{.spec.providers[0].ldap.rfc2307.groupsQuery.pageSize}")

# Refuse anything but the two values this toggle knows how to put back. The test below is one-way — only
# "0" maps to 1000, everything else maps to 0 — so a directory tuned to e.g. pageSize 500 would have that
# value silently destroyed on the first run and replaced with 1000 on the second.
case "$current" in
  ''|0|1000) ;;
  *) echo "refusing to touch pageSize=$current on $CR: this toggle only round-trips 0 and 1000," >&2
     echo "and would overwrite your tuned value. Bump .spec some other way." >&2; exit 1 ;;
esac
toggled=$([ "$current" = "0" ] && echo 1000 || echo 0)

echo "forcing sync of $CR (pageSize $current -> $toggled); last sync was ${before:-never}"
oc patch groupsync "$CR" -n "$NS" --type=json \
  -p="[{\"op\":\"add\",\"path\":\"$PATH_PAGESIZE\",\"value\":$toggled}]" >/dev/null

for _ in $(seq 1 30); do
  now=$(oc get groupsync "$CR" -n "$NS" -o jsonpath='{.status.lastSyncSuccessTime}')
  if [ -n "$now" ] && [ "$now" != "$before" ]; then
    echo "synced at $now"
    exit 0
  fi
  sleep 2
done

echo "timed out after 60s waiting for lastSyncSuccessTime to advance" >&2
exit 1
