#!/bin/bash
# Verifies the LDAP endpoint the operator is configured against, and that the operator actually
# synced through it.
#
# Every check that fails makes this script exit non-zero, so `helm test` reports a failure. The
# previous version routed failures through a report function that only counted them and ended in an
# unconditional `exit 0` — it passed while the directory was in CrashLoopBackOff.
#
# A bind test needs ldapsearch, which is not in this image. The operator's own sync status stands in
# for it and is strictly stronger: a completed sync proves DNS, TCP, TLS, bind and query all worked.
#
# Needs oc and curl. NOT openssl: it is absent from current ose-cli builds and present only in some
# older ones, so depending on it passed on one cluster and failed on another. curl is in every
# variant, and verifies the chain and the hostname during the handshake.

set -uo pipefail

FAILED=0
pass() { echo "   ✅ $*"; }
fail() { echo "   ❌ $*"; FAILED=$((FAILED + 1)); }
info() { echo "   ℹ️  $*"; }
section() { echo; echo "📍 $*"; echo "------------------------------------------------------------"; }

echo "🔍 LDAP connectivity and trust verification"
echo "============================================================"

# ---- Prerequisites ---------------------------------------------------------------------------
# Missing tools are a failure, not something to skip. Skipping is how the previous version passed
# without testing anything.
section "Tooling"
for t in oc curl; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t available"
  else fail "$t missing — this image cannot verify the endpoint"; fi
done
if [ "$FAILED" -gt 0 ]; then
  echo
  echo "❌ Cannot run: set test.ldapClientImage to an image with oc and curl."
  exit 1
fi

section "Credentials from the mounted secret"
if   [ -s /credentials/username ]; then BIND_DN=$(cat /credentials/username)
elif [ -s /credentials/bindDN   ]; then BIND_DN=$(cat /credentials/bindDN)
else echo "   ❌ no bind DN at /credentials/username or /credentials/bindDN"; exit 1; fi

if   [ -s /credentials/password     ]; then BIND_PW=$(cat /credentials/password)
elif [ -s /credentials/bindPassword ]; then BIND_PW=$(cat /credentials/bindPassword)
else echo "   ❌ no bind password at /credentials/password or /credentials/bindPassword"; exit 1; fi

pass "bind DN: ${BIND_DN}"
pass "bind password: ${#BIND_PW} characters"

section "Configuration under test"
echo "   URL:            ${GROUPSYNC_URL}"
echo "   insecure:       ${GROUPSYNC_INSECURE}"
echo "   groups base DN: ${GROUPS_BASE_DN}"
echo "   groups filter:  ${GROUPS_FILTER}"
echo "   CA:             ${CA_NAMESPACE:-<unset>}/${CA_NAME:-<unset>} key ${CA_KEY:-<unset>}"

# ---- Parse the URL ---------------------------------------------------------------------------
case "$GROUPSYNC_URL" in
  ldaps://*) SCHEME=ldaps; DEFAULT_PORT=636; REST="${GROUPSYNC_URL#ldaps://}" ;;
  ldap://*)  SCHEME=ldap;  DEFAULT_PORT=389; REST="${GROUPSYNC_URL#ldap://}"  ;;
  *) echo "   ❌ not an LDAP URL: ${GROUPSYNC_URL}"; exit 1 ;;
esac
# Strip any path/query, which the OAuth-style URL form carries.
REST="${REST%%/*}"
case "$REST" in
  *:*) HOST="${REST%:*}"; PORT="${REST##*:}" ;;
  *)   HOST="$REST";      PORT="$DEFAULT_PORT" ;;
esac

section "Test 1 — DNS resolution of ${HOST}"
if getent hosts "$HOST" >/dev/null 2>&1 || nslookup "$HOST" >/dev/null 2>&1; then
  pass "resolves"
else
  fail "does not resolve. The Service name or namespace in groupSync.url is wrong, or the
       directory is outside the cluster and needs an egress path."
fi

section "Test 2 — TCP connect to ${HOST}:${PORT}"
if timeout 10 bash -c "</dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
  pass "accepting connections"
else
  fail "connection refused or timed out. The directory is down, the port is wrong, or a
       NetworkPolicy blocks it. ${SCHEME} defaults to ${DEFAULT_PORT}."
fi

# ---- Test 3: TLS ------------------------------------------------------------------------------
# The check that was missing entirely. An ldaps:// handshake completes before any LDAP traffic, so
# the client must already trust the CA — insecure cannot rescue it, and a SAN mismatch fails even
# with the right CA.
if [ "$SCHEME" = "ldaps" ]; then
  section "Test 3 — TLS chain and hostname for ${HOST}:${PORT}"

  CA_RES=configmaps
  [ "${CA_KIND:-ConfigMap}" = "Secret" ] && CA_RES=secrets

  rm -rf /tmp/ca && mkdir -p /tmp/ca
  # oc extract, not jsonpath: the key contains a dot and jsonpath treats it as a path separator,
  # so {.data.ca.crt} and {.data['ca.crt']} both return empty on a resource that has the key.
  oc extract "${CA_RES}/${CA_NAME}" -n "$CA_NAMESPACE" \
     --keys="${CA_KEY}" --to=/tmp/ca --confirm >/dev/null 2>&1
  # Checked on the file, not the exit code: a missing key exits 0 and writes nothing.
  if [ ! -s "/tmp/ca/${CA_KEY}" ]; then
    fail "cannot read ${CA_KIND:-ConfigMap} ${CA_NAMESPACE}/${CA_NAME} key ${CA_KEY}.
       Either it does not exist, the key name is wrong, or this ServiceAccount is denied it.
       An ldaps:// url needs the CA regardless of insecure."
  else
    pass "CA read: $(grep -c 'BEGIN CERTIFICATE' "/tmp/ca/${CA_KEY}") certificate(s)"

    # curl verifies the chain AND the hostname in one handshake. LDAPS is not HTTP, so a SUCCESSFUL
    # handshake still fails afterwards on the protocol — exit 52, empty reply — and exit 60 is the
    # only verification failure. curl's own message says whether the chain or the hostname was wrong.
    TLS=$(curl -sS -v --cacert "/tmp/ca/${CA_KEY}" --max-time 20 "https://${HOST}:${PORT}" 2>&1)
    RC=$?

    printf '%s\n' "$TLS" | grep -E 'subject:|issuer:|subjectAltName:' | sed 's/^\*[[:space:]]*/      /'

    if [ "$RC" -eq 60 ]; then
      fail "the certificate does NOT verify: $(printf '%s' "$TLS" | grep -m1 -oE 'SSL certificate problem.*|SSL:.*' || echo 'verification failed')
       Either ${CA_NAMESPACE}/${CA_NAME} did not sign the certificate this endpoint serves, or it has
       no SAN for ${HOST}. Reissue for the name in groupSync.url, or point groupSync.ca at the CA
       that signed it."
    else
      pass "chain verifies against ${CA_NAMESPACE}/${CA_NAME}, hostname matches ${HOST}"
    fi
  fi
  rm -rf /tmp/ca
else
  section "Test 3 — TLS"
  info "plain ldap:// — nothing to verify. Credentials cross the network in the clear."
  TLS_VERIFIED=no
fi

# ---- Test 4: the operator actually synced -----------------------------------------------------
# Stands in for a bind test. A completed sync proves bind and query worked, which connectivity
# checks alone cannot show.
section "Test 4 — the operator synced through this configuration"
CRS=$(oc get groupsync -n "$GROUPSYNC_NAMESPACE" -o name 2>/dev/null)
if [ -z "$CRS" ]; then
  fail "no GroupSync resources in ${GROUPSYNC_NAMESPACE}"
else
  DEADLINE=$(( $(date +%s) + ${SYNC_WAIT_SECONDS:-180} ))
  for cr in $CRS; do
    NAME="${cr#*/}"
    OK=""
    while :; do
      OK=$(oc get "$cr" -n "$GROUPSYNC_NAMESPACE" \
           -o jsonpath='{.status.lastSyncSuccessTime}' 2>/dev/null)
      [ -n "$OK" ] && break
      [ "$(date +%s)" -ge "$DEADLINE" ] && break
      sleep 5
    done

    if [ -z "$OK" ]; then
      fail "${NAME} has never completed a sync within ${SYNC_WAIT_SECONDS:-180}s.
       oc describe groupsync ${NAME} -n ${GROUPSYNC_NAMESPACE}"
      continue
    fi

    # A ReconcileError condition persists after a later success, so it is only reported when its
    # transition is NEWER than the last successful sync. Otherwise every run reports a stale error.
    ERR_AT=$(oc get "$cr" -n "$GROUPSYNC_NAMESPACE" \
             -o jsonpath='{range .status.conditions[?(@.type=="ReconcileError")]}{.lastTransitionTime}{end}' 2>/dev/null)
    if [ -n "$ERR_AT" ] && [ "$ERR_AT" \> "$OK" ]; then
      MSG=$(oc get "$cr" -n "$GROUPSYNC_NAMESPACE" \
            -o jsonpath='{range .status.conditions[?(@.type=="ReconcileError")]}{.message}{end}' 2>/dev/null)
      fail "${NAME} last synced ${OK} but reported an error at ${ERR_AT}:
       ${MSG}"
    else
      pass "${NAME} last synced ${OK}${ERR_AT:+ (an older error at ${ERR_AT} is stale)}"
    fi
  done
fi

section "Groups on the cluster"
COUNT=$(oc get groups --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "${COUNT} group(s) present"
[ "$COUNT" = "0" ] && info "zero is expected only if the directory has no matching groups"

# ---- Summary ---------------------------------------------------------------------------------
echo
echo "============================================================"
if [ "$FAILED" -eq 0 ]; then
  if [ "${TLS_VERIFIED:-yes}" = "no" ]; then
    echo "🎉 All checks passed — the endpoint is reachable and the operator synced."
    echo "   NOT verified: transport security. This is plain ldap://, so nothing was encrypted."
  else
    echo "🎉 All checks passed — the endpoint is reachable, trusted, and the operator synced."
  fi
  exit 0
fi
echo "❌ ${FAILED} check(s) failed. Details above."
echo
echo "   operator logs:  oc logs -n ${GROUPSYNC_NAMESPACE} -l control-plane=group-sync-operator"
echo "   CR status:      oc describe groupsync -n ${GROUPSYNC_NAMESPACE}"
exit 1
