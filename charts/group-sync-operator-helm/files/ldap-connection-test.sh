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
# username and password ONLY. The operator reads exactly these two keys — secretUsernameKey and
# secretPasswordKey in its source — and a missing one is not an error to it: getLdapCredentialValue
# substitutes an empty string, so the wrong key names give an anonymous bind rather than a failure.
#
# This used to fall back to bindDN/bindPassword. Those are the OAuth identity provider's names, on a
# DIFFERENT Secret in openshift-config that this chart does not own, and the operator never reads them.
# Accepting them here reported a Secret as usable that the operator cannot authenticate with.
if [ -s /credentials/username ]; then BIND_DN=$(cat /credentials/username)
else
  echo "   ❌ no bind DN at /credentials/username"
  echo "      The operator reads the keys username and password, and nothing else. bindDN belongs to the"
  echo "      OAuth identity provider's Secret in openshift-config, not to this one."
  exit 1
fi

if [ -s /credentials/password ]; then BIND_PW=$(cat /credentials/password)
else
  echo "   ❌ no bind password at /credentials/password"
  echo "      The operator reads the keys username and password, and nothing else. bindPassword belongs to"
  echo "      the OAuth identity provider's Secret in openshift-config, not to this one."
  exit 1
fi

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

    # curl verifies the chain AND the hostname in one handshake, so a completed handshake is proof of
    # both. LDAPS is not HTTP, so even a SUCCESSFUL handshake then fails on the protocol — exit 52,
    # empty reply — which is why success cannot be read off the exit code.
    #
    # Success is therefore asserted POSITIVELY, from curl's own machine-readable counters, and never by
    # negating one failure code. The previous check was `[ "$RC" -eq 60 ]`, which catches only ONE of
    # the six ways this can fail. Measured against this endpoint on the pinned ose-cli:v4.14 image
    # (curl 7.61.1 + OpenSSL 1.1.1k, which predates the 7.62 merge of exit 51 into 60):
    #
    #   case                             exit  verify_result  appconnect   -eq 60 said
    #   correct CA (SUCCESS)              52         0         0.080235      pass  ok
    #   valid CA that did not sign it     60        19         0.000000      fail  ok
    #   hostname mismatch, no SAN         51         1         0.000000      PASS  wrong
    #   unreadable / garbage CA file      77         1         0.000000      PASS  wrong
    #   closed port                       28         0         0.000000      PASS  wrong
    #   DNS failure                        6         0         0.000000      PASS  wrong
    #   TLS against the plaintext 389     35         1         0.000000      PASS  wrong
    #
    # So the old check did catch a stale CA — the case it was written for — and reported
    # "chain verifies ... hostname matches" for the five others, including a certificate with no SAN for
    # the host and an endpoint that was not listening at all.
    #
    # Both counters are required. ssl_verify_result alone is 0 when no handshake happened at all (closed
    # port, DNS failure), and time_appconnect alone does not say the peer verified. Together they are
    # true only for the success row. Both are documented -w variables rather than English log text, so
    # the check survives a wording change in a future image and fails CLOSED if the variables vanish.
    TLS=$(curl -sS -v -o /dev/null --max-time 20 --cacert "/tmp/ca/${CA_KEY}" \
          -w '\nGSD_TLS verify=%{ssl_verify_result} appconnect=%{time_appconnect}\n' \
          "https://${HOST}:${PORT}" 2>&1)
    RC=$?

    printf '%s\n' "$TLS" | grep -E 'subject:|issuer:|subjectAltName:' | sed 's/^\*[[:space:]]*/      /'

    VERIFY=$(printf '%s' "$TLS" | sed -n 's/.*GSD_TLS verify=\([0-9]*\).*/\1/p' | tail -1)
    APPCONNECT=$(printf '%s' "$TLS" | sed -n 's/.*appconnect=\([0-9.]*\).*/\1/p' | tail -1)

    # Non-zero test without floating point: strip zeros and the separator, and any remaining character
    # is a significant digit. 0.000000 -> empty; 0.080235 -> "8235"; missing -> empty, so fail closed.
    if [ -n "$(printf '%s' "$APPCONNECT" | tr -d '0.')" ] && [ "$VERIFY" = "0" ]; then
      pass "chain verifies against ${CA_NAMESPACE}/${CA_NAME}, hostname matches ${HOST}"
    else
      fail "the TLS handshake did not complete with a verified certificate.
       curl exit ${RC}, ssl_verify_result=${VERIFY:-<none>}, time_appconnect=${APPCONNECT:-<none>}
       $(printf '%s' "$TLS" | grep -m1 -oE 'SSL certificate problem.*|SSL:.*|Could not resolve.*|Failed to connect.*|Connection refused.*|Operation timed out.*|error:.*' || echo 'curl emitted no diagnostic line')
       Either ${CA_NAMESPACE}/${CA_NAME} did not sign the certificate this endpoint serves, it has no
       SAN for ${HOST}, or nothing is serving TLS on ${HOST}:${PORT}. Reissue for the name in
       groupSync.url, or point groupSync.ca at the CA that signed it."
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
CRS=$(oc get groupsyncs.redhatcop.redhat.io -n "$GROUPSYNC_NAMESPACE" -o name 2>/dev/null)
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
       oc describe groupsyncs.redhatcop.redhat.io ${NAME} -n ${GROUPSYNC_NAMESPACE}"
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
COUNT=$(oc get groups.user.openshift.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
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
echo "   CR status:      oc describe groupsyncs.redhatcop.redhat.io -n ${GROUPSYNC_NAMESPACE}"
exit 1
