#!/bin/bash
# Repairs the sync-provider label on Groups whose GroupSync CR was RENAMED.
#
# WHY THIS EXISTS. The operator stamps every Group it syncs with
# group-sync-operator.redhat-cop.io/sync-provider=<groupsync-cr-name>_<provider-name>, and it only
# rewrites a Group when that Group's LDAP MEMBERSHIP changes. Rename a customGroupSyncs item and Helm
# deletes the old CR and creates the new one, but the Groups keep the old owner in that label forever:
# measured on this chart's own renames, 22 of 66 Groups, and a forced sync via
# setup-local-ldap-testing/60-force-groupsync.sh did not move them either.
#
# WHAT A STALE VALUE COSTS. RBAC is unaffected — the GroupConfig policies that grant access match this
# label with `operator: Exists` and narrow by the GROUP NAME, never by the value. What breaks is
# attribution AND alerting: the dashboard rebuilds `<cr>_<provider>` and compares, so a mismatched value
# means the Group is credited to no CR and its stale-group alert cannot fire.
#
# THE MAPPING IS DECLARED, NEVER GUESSED. Spotting the problem is easy — strip _<provider> off the value
# and see whether that CR still exists. Knowing the REPLACEMENT is not: nothing on the cluster records
# that one CR succeeded another, and guessing by matching a Group against each CR's LDAP filter would be
# acting on an ambiguous signal, which is how a sibling chart's sweeper once deleted healthy
# RoleBindings. So renames arrive from values as `old=new`, and nothing else is ever touched.
#
# NO HEREDOCS IN THIS FILE. It ships inside a ConfigMap via `.Files.Get ... | indent 4`, which indents
# EVERY line — including a heredoc terminator, which then terminates nothing. Multi-line output is
# echoed line by line instead.
#
# Env: RENAMES  comma-separated old=new pairs; empty means there is nothing to do
#      DRY_RUN  "true" reports and changes nothing
#      LIMIT    refuse a run that would relabel more than this many Groups; 0 disables the cap
set -uo pipefail

LABEL_KEY="${LABEL_KEY:-group-sync-operator.redhat-cop.io/sync-provider}"
RENAMES="${RENAMES:-}"
DRY_RUN="${DRY_RUN:-false}"
LIMIT="${LIMIT:-25}"

log()  { echo "[provenance-relabel] $*"; }
fail() { echo "[provenance-relabel] FAILED: $*" >&2; exit 1; }

# A typo'd cap is worse than no cap, because the guard silently stops firing while the run still reports
# success. Refuse to start instead.
case "$LIMIT" in
  ''|*[!0-9]*) fail "LIMIT must be a whole number (0 disables the cap), got '${LIMIT}'" ;;
esac

if [ -z "$RENAMES" ]; then
  log "no renames declared (no customGroupSyncs item lists previousNames); nothing to do"
  exit 0
fi

[ "$DRY_RUN" = "true" ] && log "DRY RUN: no Group will be modified"
log "label key: ${LABEL_KEY}, cap: ${LIMIT} Group(s) per run"

# ── Step 1: which CRs exist right now ───────────────────────────────────────────────────────────────
# A rename is only credible when the OLD name is GONE. If it still exists it owns its Groups
# legitimately, and rewriting them would hand one CR's Groups to another.
# EVERY NAMESPACE, DELIBERATELY — even though the deployment contract is one namespace.
#
# The contract, verified on this cluster: GroupSync CRs live only in the operator's namespace, that is the
# only namespace watched (WATCH_NAMESPACE=group-sync-operator,openshift-config), and this Job runs in the
# same namespace the chart places the CRs in (both use .Values.groupSync.namespace). Under that contract a
# cluster-wide read and a namespaced one return exactly the same set, so `-A` costs nothing.
#
# It is `-A` anyway because Groups are CLUSTER-SCOPED. The question being answered is "does the CR named in
# this Group's label still exist", which is a fact about the cluster; making it depend on where the Job
# happens to run would be an assumption doing work that a flag can do instead. And if the contract is ever
# broken, this fails in the safe direction: seeing MORE CRs can only make the test below refuse to adopt,
# which it logs, whereas seeing FEWER could make it adopt a Group that a live CR still owns.
#
# One call fetches the names AND their provider names, as "name provider [provider...]" per line, so the
# provider suffix never needs a second per-CR lookup — which would have had to name a namespace and would
# have reintroduced exactly the assumption this avoids.
CR_LINES="$(oc get groupsync -A -o jsonpath='{range .items[*]}{.metadata.name}{range .spec.providers[*]}{" "}{.name}{end}{"\n"}{end}')" \
  || fail "cannot list GroupSync CRs, so no rename can be validated — the API's error is above"
log "live GroupSync CRs: $(echo "$CR_LINES" | awk '{print $1}' | tr '\n' ' ')"

is_live_cr() {
  echo "$CR_LINES" | awk '{print $1}' | grep -qxF "$1"
}

# The provider names of one CR: everything after the name on its line.
providers_of() {
  echo "$CR_LINES" | awk -v want="$1" '$1 == want { $1 = ""; print }'
}

# ── Step 2: collect what would change, before changing anything ─────────────────────────────────────
# Three parallel arrays, one entry per Group to relabel. Collecting first means the cap below is checked
# against the WHOLE run rather than one mapping at a time.
GROUP_NAMES=()
OLD_VALUES=()
NEW_VALUES=()
SKIPPED=0
SEEN_OLD_NAMES=""

# Splitting on spaces is safe here: every name involved is a Kubernetes object name, so it cannot
# contain a space. Commas become spaces and the loop stays a plain `for`.
for pair in ${RENAMES//,/ }; do
  case "$pair" in
    # `cut -d= -f2` of "a=b=c" is "b": a stray '=' inside a previousNames entry would silently rewrite
    # the declared mapping instead of failing, so refuse it here.
    *=*=*) fail "malformed rename '${pair}' — a name cannot contain '=', write previousNames entries as bare old names" ;;
    *=*) : ;;
    *) fail "malformed rename '${pair}' — expected old=new" ;;
  esac

  old_cr="$(echo "$pair" | cut -d= -f1)"
  new_cr="$(echo "$pair" | cut -d= -f2)"

  if [ -z "$old_cr" ] || [ -z "$new_cr" ]; then
    fail "malformed rename '${pair}' — both sides must be named"
  fi

  # The same previous name declared twice is two claims on the same Groups: whichever pair ran last
  # would win silently, the cap would count the same Group once per claim, and the log would show it
  # "relabelled" twice. Refuse the ambiguity before anything is relabelled.
  for seen in $SEEN_OLD_NAMES; do
    if [ "$seen" = "$old_cr" ]; then
      fail "the previous name '${old_cr}' appears in more than one rename, so its Groups would have two claimed owners — declare each old name exactly once"
    fi
  done
  SEEN_OLD_NAMES="$SEEN_OLD_NAMES $old_cr"

  if [ "$old_cr" = "$new_cr" ]; then
    log "skip ${old_cr}: the previous name is the current name"
    continue
  fi

  if is_live_cr "$old_cr"; then
    log "skip ${old_cr} -> ${new_cr}: '${old_cr}' is still a live CR, so its Groups are owned, not orphaned"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if ! is_live_cr "$new_cr"; then
    fail "rename ${old_cr} -> ${new_cr}: '${new_cr}' is not a live GroupSync CR, so the new value would name nothing"
  fi

  # The suffix is the PROVIDER's name, taken from the live CR rather than assumed to be "ldap", because a
  # CR may carry several providers and each one stamps its own value. Already fetched in Step 1.
  PROVIDERS="$(providers_of "$new_cr")"
  if [ -z "$(echo $PROVIDERS)" ]; then
    fail "GroupSync/${new_cr} declares no named providers, so no label value can be derived"
  fi

  pair_found=0
  for provider in $PROVIDERS; do
    old_value="${old_cr}_${provider}"
    new_value="${new_cr}_${provider}"

    MATCHED="$(oc get groups -l "${LABEL_KEY}=${old_value}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
      || fail "cannot list Groups labelled ${LABEL_KEY}=${old_value} — the API's error is above"

    found=0
    for group in $MATCHED; do
      GROUP_NAMES+=("$group")
      OLD_VALUES+=("$old_value")
      NEW_VALUES+=("$new_value")
      found=$((found + 1))
    done
    log "${old_value} -> ${new_value}: ${found} Group(s)"
    pair_found=$((pair_found + found))
  done

  if [ "$pair_found" -eq 0 ]; then
    # Zero matches is what "already repaired" looks like — but it is ALSO what a renamed provider looks
    # like: the stale value's suffix is the OLD CR's provider name, and only the NEW CR's providers can
    # be read, so a rename that changed the provider name too leaves its stale values unfindable here.
    log "NOTE: ${old_cr} -> ${new_cr}: no Group carries ${old_cr}_<provider> for any provider of ${new_cr} — already repaired, or the provider name changed with the rename (a value stamped by the old provider name cannot be derived and stays stale)"
  fi
done

TOTAL=${#GROUP_NAMES[@]}

if [ "$TOTAL" -eq 0 ]; then
  log "nothing to relabel (${SKIPPED} rename(s) skipped as still-live); no Group carries a declared old value"
  exit 0
fi

# ── Step 3: the cap ─────────────────────────────────────────────────────────────────────────────────
if [ "$LIMIT" -gt 0 ] && [ "$TOTAL" -gt "$LIMIT" ]; then
  log "would relabel ${TOTAL} Group(s):"
  for i in $(seq 0 $((TOTAL - 1))); do
    log "    ${GROUP_NAMES[$i]}  ${OLD_VALUES[$i]} -> ${NEW_VALUES[$i]}"
  done
  fail "refusing to relabel ${TOTAL} Groups, which exceeds LIMIT=${LIMIT}. That many at once usually means RENAMES is wrong for this cluster rather than that many Groups genuinely changing owner. Check 'oc get groupsync' and the declared previousNames, then re-run or raise provenanceRelabel.limit."
fi

# ── Step 4: apply ───────────────────────────────────────────────────────────────────────────────────
# ONLY --overwrite, and only this one key. REMOVING the key would revoke access: its presence is the only
# thing narrowing the GroupConfig policies to synced groups, so the next reconcile would delete the
# ClusterRoleBindings they created. Nothing here deletes a Group or a label.
FAILURES=0
CHANGED=0

for i in $(seq 0 $((TOTAL - 1))); do
  group="${GROUP_NAMES[$i]}"
  old_value="${OLD_VALUES[$i]}"
  new_value="${NEW_VALUES[$i]}"

  if [ "$DRY_RUN" = "true" ]; then
    log "would relabel ${group}: ${old_value} -> ${new_value}"
    CHANGED=$((CHANGED + 1))
    continue
  fi

  if oc label group "$group" "${LABEL_KEY}=${new_value}" --overwrite >/dev/null; then
    log "relabelled ${group}: ${old_value} -> ${new_value}"
    CHANGED=$((CHANGED + 1))
  else
    log "ERROR relabelling ${group}; it keeps ${old_value}"
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "$DRY_RUN" = "true" ]; then
  log "DRY RUN: ${CHANGED} Group(s) would be relabelled, none were"
  exit 0
fi

log "relabelled ${CHANGED} of ${TOTAL} Group(s)"
if [ "$SKIPPED" -gt 0 ]; then
  # Without this line, a reader of the final log plus exit 0 believes every declared rename was applied.
  log "NOTE: ${SKIPPED} declared rename(s) skipped because the old CR is still live — those Groups were not touched; check whether previousNames is ahead of the actual rename"
fi
if [ "$FAILURES" -gt 0 ]; then
  fail "${FAILURES} Group(s) could not be relabelled and keep their old value; each is logged above"
fi
exit 0
