#!/bin/bash

set -e

# Configuration variables
TMP_DIR="/tmp"

# 🔍 STEP 3: Verify All Resources and Configuration
# 
# Comprehensive verification script that checks the status of all
# resources created for GroupSync operator testing, including secrets,
# ConfigMaps, and the GroupSync CR status.
#
# Purpose: Validates complete test environment setup and troubleshoots issues

echo "🔍 GroupSync Operator Resource Verification"
echo "==========================================="
echo

echo "📋 ConfigMap Status:"
echo "------------------"
if oc get configmap ca-config-map-test -n openshift-config &> /dev/null; then
    echo "✅ ConfigMap 'ca-config-map-test' exists in openshift-config"
    oc get configmap ca-config-map-test -n openshift-config
else
    echo "❌ ConfigMap 'ca-config-map-test' NOT found in openshift-config"
fi
echo

echo "🔐 Secret Status (group-sync-operator):"
echo "------------------------------------"
if oc get secret ldap-group-sync -n group-sync-operator &> /dev/null; then
    echo "✅ Secret 'ldap-group-sync' exists in group-sync-operator"
    oc get secret ldap-group-sync -n group-sync-operator
else
    echo "❌ Secret 'ldap-group-sync' NOT found in group-sync-operator"
fi
echo

echo "🔑 Secret Status (openshift-config) - NEW:"
echo "------------------------------------------"
if oc get secret ldap-secret -n openshift-config &> /dev/null; then
    echo "✅ Secret 'ldap-secret' exists in openshift-config"
    oc get secret ldap-secret -n openshift-config
else
    echo "❌ Secret 'ldap-secret' NOT found in openshift-config"
fi
echo

echo "🚀 GroupSync Operator Status:"
echo "---------------------------"
# Every CR in the namespace, not one hardcoded name. This used to look for "ldap-group-sync", which is
# the SECRET's name — the CR is "app-ocp-rbac-group-groupsync" — so it printed "NOT found" on a perfectly healthy lab.
# Listing also covers the customGroupSyncs tenants, which a single name never could.
CRS=$(oc get groupsync -n group-sync-operator -o name 2>/dev/null | sed 's|.*/||')
if [ -n "$CRS" ]; then
    for cr in $CRS; do
        SYNCED=$(oc get groupsync "$cr" -n group-sync-operator -o jsonpath='{.status.lastSyncSuccessTime}' 2>/dev/null)
        echo "✅ GroupSync CR '$cr' exists — last successful sync: ${SYNCED:-never}"
    done
else
    echo "❌ no GroupSync CRs found in group-sync-operator"
    VERIFY_FAILED=1
fi
echo

# Enhanced LDAP Content Validation
echo "🔍 LDAP Server Content Validation:"
echo "----------------------------------"

# Check if LDAP server is running
# grep -q, not the exit status: `kubectl get` with zero matches still exits 0, so this guard always
# passed and the jsonpath on the next line then aborted the script under set -e.
if kubectl get pods -n ldap-testing -l app=openldap-server --field-selector=status.phase=Running -o name 2>/dev/null | grep -q openldap; then
    LDAP_POD=$(kubectl get pods -n ldap-testing -l app=openldap-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
    echo "✅ LDAP Server Pod: $LDAP_POD"
    
    # Test service account access
    if kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
        -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
        -w "bindpassword123" \
        -b "ou=Groups,dc=ephico2real,dc=com" \
        -s base "(objectClass=*)" dn >/dev/null 2>&1; then
        echo "✅ Service account access: Working"
        
        # Validate bindDN configuration from GroupSync secret
        echo "🔐 GroupSync bindDN Configuration:"
        echo "----------------------------------"
        if oc get secret ldap-group-sync -n group-sync-operator >/dev/null 2>&1; then
            BIND_DN=$(oc get secret ldap-group-sync -n group-sync-operator -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo "Unable to decode")
            BIND_PASS=$(oc get secret ldap-group-sync -n group-sync-operator -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "Unable to decode")
            
            echo "   🆔 Configured bindDN: $BIND_DN"
            echo "   🔑 Password length: ${#BIND_PASS} characters"
            
            # Test if bindDN exists in LDAP
            if kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=admin,dc=ephico2real,dc=com" -w "admin123" -b "$BIND_DN" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
                echo "   ✅ bindDN exists in LDAP: YES"
                
                # Test authentication with bindDN
                if kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "$BIND_DN" -w "$BIND_PASS" -b "ou=Groups,dc=ephico2real,dc=com" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
                    echo "   ✅ bindDN authentication: WORKING"
                    echo "   ✅ Groups OU access: PERMITTED"
                else
                    echo "   ❌ bindDN authentication: FAILED"
                    echo "   🔧 Fix: Check password or run ACL configuration"
                fi
            else
                echo "   ❌ bindDN exists in LDAP: NO"
                echo "   🔧 Fix: Ensure LDAP bootstrap completed successfully"
            fi
        else
            echo "   ❌ GroupSync secret not found"
        fi
        echo
        
        # Count LDAP objects
        TOTAL_USERS=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=admin,dc=ephico2real,dc=com" -w "admin123" -b "ou=People,dc=ephico2real,dc=com" "(objectClass=inetOrgPerson)" cn 2>/dev/null | grep -c "^cn:" || true)
        RBAC_GROUPS=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn 2>/dev/null | grep -c "^cn:" || true)
        OTHER_GROUPS=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(&(objectClass=groupOfNames)(!(cn=app-ocp-rbac-*)))" cn 2>/dev/null | grep -c "^cn:" || true)
        
        echo "✅ Test Users: $TOTAL_USERS"
        echo "✅ RBAC Groups (will sync): $RBAC_GROUPS"
        echo "✅ Non-RBAC Groups (won't sync): $OTHER_GROUPS"
        
        # Team breakdown
        PLATFORM_GROUPS=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(cn=app-ocp-rbac-platform-*)" cn 2>/dev/null | grep -c "^cn:" || true)
        ALPHA_GROUPS=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(cn=app-ocp-rbac-alpha-*)" cn 2>/dev/null | grep -c "^cn:" || true)
        DEMO_GROUPS=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(cn=app-ocp-rbac-demo-*)" cn 2>/dev/null | grep -c "^cn:" || true)
        # ${VAR:-0} because each count comes from a command substitution that can legitimately be empty, and
        # bare arithmetic on an empty string is a fatal syntax error under set -e.
        OTHER_TEAMS=$(( ${RBAC_GROUPS:-0} - ${PLATFORM_GROUPS:-0} - ${ALPHA_GROUPS:-0} - ${DEMO_GROUPS:-0} ))
        
        echo "   🏢 Platform: $PLATFORM_GROUPS groups"
        echo "   🅰️ Alpha: $ALPHA_GROUPS groups"
        echo "   🎮 Demo: $DEMO_GROUPS groups"
        echo "   🔄 Other: $OTHER_TEAMS groups"
        
        # Detailed user listing
        echo "👥 Users in LDAP:"
        echo "----------------"
        kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=admin,dc=ephico2real,dc=com" -w "admin123" -b "ou=People,dc=ephico2real,dc=com" "(objectClass=inetOrgPerson)" uid cn mail 2>/dev/null | awk '
        /^dn:/ { dn=$0; uid=""; cn=""; mail="" }
        /^uid:/ { uid=$2 }
        /^cn:/ { cn=substr($0,5) }
        /^mail:/ { mail=$2 }
        /^$/ && uid { printf "   👤 %s (%s) - %s\n", uid, cn, mail; uid="" }
        ' || echo "   ❌ Unable to retrieve user list"
        echo
        
        # Detailed RBAC group listing with members
        echo "🏢 RBAC Groups (will sync to OpenShift):"
        echo "---------------------------------------"
        kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn member 2>/dev/null | awk '
        /^dn:/ { dn=$0; cn=""; members="" }
        /^cn:/ { cn=$2 }
        /^member:/ { 
            member=$0
            gsub(/^member: uid=/, "", member)
            gsub(/,ou=People,dc=ephico2real,dc=com/, "", member)
            if (members == "") members = member
            else members = members ", " member
        }
        /^$/ && cn { 
            printf "   🔗 %s\n      👥 Members: %s\n", cn, (members ? members : "none")
            cn=""; members=""
        }
        ' || echo "   ❌ Unable to retrieve RBAC group list"
        echo
        
        # Non-RBAC groups
        echo "🔄 Non-RBAC Groups (won't sync):"
        echo "-------------------------------"
        kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(&(objectClass=groupOfNames)(!(cn=app-ocp-rbac-*)))" cn member 2>/dev/null | awk '
        /^dn:/ { dn=$0; cn=""; members="" }
        /^cn:/ { cn=$2 }
        /^member:/ { 
            member=$0
            gsub(/^member: uid=/, "", member)
            gsub(/,ou=People,dc=ephico2real,dc=com/, "", member)
            if (members == "") members = member
            else members = members ", " member
        }
        /^$/ && cn { 
            printf "   🔗 %s\n      👥 Members: %s\n", cn, (members ? members : "none")
            cn=""; members=""
        }
        ' || echo "   ❌ Unable to retrieve non-RBAC group list"
        echo
        
        # Web GUI status
        if kubectl get route phpldapadmin-route -n ldap-testing >/dev/null 2>&1; then
            GUI_URL=$(kubectl get route phpldapadmin-route -n ldap-testing -o jsonpath='{.spec.host}' 2>/dev/null || echo "Not available")
            echo "✅ Web GUI: http://$GUI_URL"
        else
            echo "❌ Web GUI: Not deployed"
        fi
    else
        echo "❌ Service account access: Failed"
        echo "   Run: kubectl cp configure-acls.ldif ldap-testing/$LDAP_POD:$TMP_DIR/"
        echo "   Then: kubectl exec -n ldap-testing $LDAP_POD -- ldapmodify -x -H ldap://localhost:389 -D 'cn=admin,cn=config' -w 'config123' -f $TMP_DIR/configure-acls.ldif"
        VERIFY_FAILED=1
    fi
else
    echo "❌ LDAP Server: Not running"
    echo "   Deploy with: ./30-manage-ldap-server.sh deploy-all"
    VERIFY_FAILED=1
fi
echo

# Public LDAPS (group-sync-operator-helm-chart#71): what a client OUTSIDE the cluster — Keycloak — relies on.
# Route ldaps must pass TLS through to slapd; slapd's certificate must verify against the enterprise CA by
# the Route's host name; slapd must be serving the certificate cert-manager holds now, not one it loaded
# before a renewal; and the Keycloak bind account must be able to read People and Groups.
#
# Path A (plain LDAP, no cert-manager) has none of this, so the block is SKIPPED, with a note, when
# cert-manager or Route ldaps is absent. Absent, not unreadable: --ignore-not-found turns a missing object
# into an empty success, so an API error is still a failure.
echo "🌐 Public LDAPS endpoint:"
echo "------------------------"
LDAPS_OK=1
LDAPS_SKIPPED=""
ldaps_fail() { echo "❌ $*"; LDAPS_OK=0; VERIFY_FAILED=1; }
# Membership of one SAN in "DNS:a, DNS:b" — exact, so the .svc name does not match inside .svc.cluster.local.
has_san() { tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -qxF "DNS:$1"; }
# Is $1 strictly later than $2, as instants? RFC 3339 with any fractional precision and Z or an offset. A
# string compare misorders '…:50.001Z' against '…:50Z', and an equal second proves nothing about order.
rfc3339_after() {
    python3 - "$1" "$2" <<'PY'
import calendar, datetime, decimal, re, sys

def instant(s):
    m = re.fullmatch(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)', s)
    if not m:
        raise ValueError('not an RFC 3339 timestamp: %r' % s)
    d = datetime.datetime.fromisoformat(m[1] + ('+00:00' if m[3] == 'Z' else m[3]))
    return decimal.Decimal(calendar.timegm(d.utctimetuple())) + decimal.Decimal(m[2] or '0')

try:
    sys.exit(0 if instant(sys.argv[1]) > instant(sys.argv[2]) else 1)
except (ValueError, OverflowError, decimal.InvalidOperation):
    sys.exit(1)
PY
}

if ! CM_CRD=$(oc get crd certificates.cert-manager.io --ignore-not-found -o name 2>/dev/null) \
   || ! ROUTE=$(oc get route ldaps -n ldap-testing --ignore-not-found \
          -o jsonpath='{.spec.host} {.spec.tls.termination} {.spec.port.targetPort}' 2>/dev/null); then
    ldaps_fail "could not read CRD certificates.cert-manager.io or Route ldaps — is the API reachable?"
elif [ -z "$CM_CRD" ]; then
    LDAPS_SKIPPED="cert-manager is not installed (Path A, plain LDAP)"
elif [ -z "$ROUTE" ]; then
    LDAPS_SKIPPED="Route ldaps is not deployed (oc apply -f 01-ldap-server.yaml)"
fi

if [ -n "$LDAPS_SKIPPED" ]; then
    echo "⏭️  skipped — ${LDAPS_SKIPPED}"
elif [ "$LDAPS_OK" -eq 1 ]; then
    PUBLIC_HOST=${ROUTE%% *}
    if [ "${ROUTE#* }" != "passthrough ldaps" ]; then
        ldaps_fail "Route 'ldaps' is '${ROUTE#* }', not 'passthrough ldaps' — only passthrough carries LDAP"
    else
        echo "✅ Route 'ldaps': ${PUBLIC_HOST}:443 → passthrough → Service port ldaps"
    fi

    # -verify_hostname is OpenSSL's; macOS /usr/bin/openssl is LibreSSL, which rejects it. Say so rather
    # than report a hostname failure that is really a tool failure.
    if ! openssl s_client -help 2>&1 | grep -q -- '-verify_hostname'; then
        ldaps_fail "$(openssl version) has no -verify_hostname — put OpenSSL first in PATH (brew install openssl)"
    else
        LDAPS_CA=$(mktemp)
        # The enterprise CA as an OpenShift client already trusts it; oc extract because the key has a dot.
        oc extract configmap/ca-config-map -n openshift-config --keys=ca.crt --to=- > "$LDAPS_CA" 2>/dev/null || true
        HANDSHAKE=$(openssl s_client -connect "${PUBLIC_HOST}:443" -servername "$PUBLIC_HOST" \
            -CAfile "$LDAPS_CA" -verify_hostname "$PUBLIC_HOST" -verify_return_error </dev/null 2>&1 || true)
        rm -f "$LDAPS_CA"
        if printf '%s\n' "$HANDSHAKE" | grep -q 'Verify return code: 0 (ok)'; then
            echo "✅ Served certificate verifies against openshift-config/ca-config-map as ${PUBLIC_HOST}"
        else
            ldaps_fail "Served certificate does NOT verify as ${PUBLIC_HOST}: $(printf '%s\n' "$HANDSHAKE" | grep -m1 'Verify return code' || echo 'no handshake')"
        fi

        SERVED=$(openssl s_client -connect "${PUBLIC_HOST}:443" -servername "$PUBLIC_HOST" </dev/null 2>/dev/null \
            | openssl x509 -noout -serial -ext subjectAltName 2>/dev/null || true)
        SANS=$(printf '%s\n' "$SERVED" | grep 'DNS:' | sed 's/^[[:space:]]*//' || true)
        echo "   SANs: ${SANS:-none}"
        for name in openldap-service.ldap-testing.svc openldap-service.ldap-testing.svc.cluster.local "$PUBLIC_HOST"; do
            printf '%s\n' "$SANS" | has_san "$name" || ldaps_fail "Served certificate has no SAN ${name}"
        done

        # slapd reads its certificate only at pod start, so after a renewal the Secret moves on and slapd
        # does not. 15-bootstrap-cert-manager-ca.sh apply compares the two serials and restarts slapd.
        SERVED_SERIAL=$(printf '%s\n' "$SERVED" | grep '^serial=' || true)
        SECRET_SERIAL=$(oc extract secret/openldap-certmanager-tls -n ldap-testing --keys=tls.crt --to=- 2>/dev/null \
            | openssl x509 -noout -serial 2>/dev/null || true)
        if [ -n "$SERVED_SERIAL" ] && [ "$SERVED_SERIAL" = "$SECRET_SERIAL" ]; then
            echo "✅ slapd serves the Secret's certificate (${SERVED_SERIAL})"
        else
            ldaps_fail "slapd serves ${SERVED_SERIAL:-nothing}, Secret openldap-certmanager-tls holds ${SECRET_SERIAL:-nothing} — run ./15-bootstrap-cert-manager-ca.sh apply"
        fi
    fi

    if [ -z "${LDAP_POD:-}" ]; then
        ldaps_fail "no Running openldap-server pod — the Keycloak bind and post-start GroupSync checks did not run"
    else
        # In the pod, on 389: this proves the account and its ACL grant; the TLS path is proved above. The
        # password goes in on stdin, never on a command line. userPassword is requested explicitly on BOTH
        # searches, so its absence means denied, not merely not asked for. ldapsearch's exit status is kept:
        # entries followed by a size or time limit error are an incomplete answer, not a pass.
        KEYCLOAK_BIND_DN="cn=keycloak-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com"
        KEYCLOAK_BIND_PASSWORD="${KEYCLOAK_BIND_PASSWORD:-keycloakbindpassword123}"   # lab value, ldap-keycloak-bind.ldif
        kc_search() {
            printf '%s' "$KEYCLOAK_BIND_PASSWORD" | kubectl exec -i -n ldap-testing "$LDAP_POD" -c openldap -- \
                ldapsearch -LLL -o ldif-wrap=no -x -H ldap://localhost:389 -D "$KEYCLOAK_BIND_DN" -y /dev/stdin "$@" 2>/dev/null
        }
        KC_SEARCH_OK=1
        KC_PEOPLE=$(kc_search -b "ou=People,dc=ephico2real,dc=com" "(objectClass=inetOrgPerson)" dn userPassword) || KC_SEARCH_OK=0
        KC_GROUPS=$(kc_search -b "ou=Groups,dc=ephico2real,dc=com" "(objectClass=groupOfNames)" dn userPassword) || KC_SEARCH_OK=0
        KC_N_PEOPLE=$(printf '%s\n' "$KC_PEOPLE" | grep -c '^dn:' || true)
        KC_N_GROUPS=$(printf '%s\n' "$KC_GROUPS" | grep -c '^dn:' || true)
        if printf '%s\n%s\n' "$KC_PEOPLE" "$KC_GROUPS" | grep -Eqi '^userPassword(;[^:]*)?:'; then
            ldaps_fail "keycloak-bind-serviceid was returned userPassword — rule {0} in configure-acls.ldif must not name it"
        elif [ "$KC_SEARCH_OK" -ne 1 ]; then
            ldaps_fail "keycloak-bind-serviceid: a search failed or was incomplete — create the account with ./40-setup-oauth-ldap-login.sh bind-account (on a running server with the older ACL: ldap-keycloak-bind.ldif, then configure-acls-keycloak-only.ldif)"
        elif [ "${KC_N_PEOPLE:-0}" -gt 0 ] && [ "${KC_N_GROUPS:-0}" -gt 0 ]; then
            echo "✅ keycloak-bind-serviceid reads ${KC_N_PEOPLE} people and ${KC_N_GROUPS} groups; userPassword withheld on both"
        else
            ldaps_fail "keycloak-bind-serviceid reads ${KC_N_PEOPLE:-0} people and ${KC_N_GROUPS:-0} groups — both must be > 0"
        fi

        # A lastSyncSuccessTime from before (or in the same instant as) slapd's start proves nothing about the
        # slapd running now.
        SLAPD_STARTED=$(kubectl get pod -n ldap-testing "$LDAP_POD" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="openldap")].state.running.startedAt}' 2>/dev/null || true)
        [ -n "${CRS:-}" ] || ldaps_fail "no GroupSync CRs — nothing shows a sync since slapd started"
        for cr in ${CRS:-}; do
            SYNCED=$(oc get groupsync "$cr" -n group-sync-operator -o jsonpath='{.status.lastSyncSuccessTime}' 2>/dev/null || true)
            if rfc3339_after "$SYNCED" "$SLAPD_STARTED"; then
                echo "✅ GroupSync '$cr' synced at ${SYNCED}, after slapd started (${SLAPD_STARTED})"
            else
                ldaps_fail "GroupSync '$cr' last success ${SYNCED:-never} is not after slapd started (${SLAPD_STARTED:-unknown}) — wait for its next sync, or ./60-force-groupsync.sh $cr"
            fi
        done
    fi
fi
echo

# ldap-local, the OAuth identity provider (40-setup-oauth-ldap-login.sh): a real token request, not "the
# provider is on the OAuth CR" — the only proof that login still works after slapd was recreated.
#   - a throwaway kubeconfig holding only this cluster's server and CA, never the current credentials, so
#     the session running this script is untouched;
#   - the password goes to oc login on stdin, never on a command line (oc reads one whitespace-free word
#     from a non-terminal stdin, so the password must have no spaces);
#   - the login must map to an ldap-local identity, not the HTPasswd provider;
#   - THIS CHECK WRITES: one OAuthAccessToken. A trap on EXIT, INT and TERM — installed before the login,
#     removed afterwards, with whatever traps were there before put back — revokes it (oc logout) and deletes
#     the kubeconfig on every path, an interrupt included. A revocation that fails is a failure, never
#     swallowed: the token would stay valid.
# Skipped, with a note, when oauth/cluster has no ldap-local provider (it is optional; see the README).
echo "🔑 ldap-local login:"
echo "--------------------"
LOGIN_STATE=ok
if ! LDAP_LOCAL_IDP=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.name=="ldap-local")].name}' 2>/dev/null); then
    echo "❌ could not read oauth/cluster"; LOGIN_STATE=failed; VERIFY_FAILED=1
elif [ -z "$LDAP_LOCAL_IDP" ]; then
    echo "⏭️  skipped — no ldap-local identity provider on oauth/cluster (./40-setup-oauth-ldap-login.sh apply)"
    LOGIN_STATE=skipped
else
    LDAP_LOCAL_USER="${LDAP_LOCAL_USER:-john.doe}"          # in the login gate group, ldap-oauth-login-gate.ldif
    LDAP_LOCAL_PASSWORD="${LDAP_LOCAL_PASSWORD:-Ldap123!}"  # lab value, ldap-oauth-login-gate.ldif
    LOGIN_DIR=""
    LOGIN_KC=""

    # Revokes the token if the throwaway kubeconfig holds one, then deletes the kubeconfig. Idempotent: an
    # INT runs it, and the EXIT that follows runs it again with nothing left to do. The token is read only
    # to test that it is there; it is never printed.
    login_cleanup() {
        local rc=0 token
        if [ -n "$LOGIN_KC" ] && [ -s "$LOGIN_KC" ]; then
            token=$(oc --kubeconfig="$LOGIN_KC" config view --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null) || token=""
            if [ -n "$token" ] && ! oc --kubeconfig="$LOGIN_KC" logout >/dev/null 2>&1; then
                echo "❌ could not revoke the OAuth token issued to ${LDAP_LOCAL_USER}; it stays valid until it expires. Remove it with:"
                echo "     oc get oauthaccesstokens -o jsonpath='{range .items[?(@.userName==\"${LDAP_LOCAL_USER}\")]}{.metadata.name}{\"\\n\"}{end}'"
                echo "     oc delete oauthaccesstoken <name>     # every name listed is one of ${LDAP_LOCAL_USER}'s tokens"
                rc=1
            fi
        fi
        if [ -n "$LOGIN_DIR" ]; then
            rm -rf "$LOGIN_DIR" || { echo "❌ could not remove ${LOGIN_DIR}"; rc=1; }
        fi
        LOGIN_DIR=""
        LOGIN_KC=""
        [ "$rc" -eq 0 ] || { LOGIN_STATE=failed; VERIFY_FAILED=1; }
        return "$rc"
    }
    login_on_exit() { local status=$?; login_cleanup || status=1; exit "$status"; }
    login_on_signal() { login_cleanup || true; exit "$1"; }    # the signal's own status wins; the ❌ is printed

    PREV_TRAPS=$(trap -p EXIT INT TERM)
    trap login_on_exit EXIT
    trap 'login_on_signal 130' INT
    trap 'login_on_signal 143' TERM

    LOGIN_DIR=$(mktemp -d)
    LOGIN_KC="${LOGIN_DIR}/kubeconfig"
    if ! oc config view --minify --flatten --raw -o json 2>/dev/null | python3 -c '
import json, sys
cluster = json.load(sys.stdin)["clusters"][0]
print(json.dumps({"apiVersion": "v1", "kind": "Config", "clusters": [cluster], "users": [],
                  "contexts": [{"name": "proof", "context": {"cluster": cluster["name"]}}],
                  "current-context": "proof"}))' > "$LOGIN_KC"; then
        echo "❌ could not read the current cluster's server and CA from the kubeconfig"; LOGIN_STATE=failed
    elif ! printf '%s\n' "$LDAP_LOCAL_PASSWORD" | oc --kubeconfig="$LOGIN_KC" login \
            --server="$(oc --kubeconfig="$LOGIN_KC" config view -o jsonpath='{.clusters[0].cluster.server}')" \
            --username="$LDAP_LOCAL_USER" >/dev/null 2>"${LOGIN_DIR}/login.err"; then
        echo "❌ ldap-local did not issue a token for ${LDAP_LOCAL_USER}: $(tail -1 "${LOGIN_DIR}/login.err")"
        LOGIN_STATE=failed
    elif [ "$(oc --kubeconfig="$LOGIN_KC" whoami 2>/dev/null)" != "$LDAP_LOCAL_USER" ]; then
        echo "❌ the token issued is not ${LDAP_LOCAL_USER}'s"; LOGIN_STATE=failed
    elif ! oc get user "$LDAP_LOCAL_USER" -o jsonpath='{.identities}' 2>/dev/null | grep -q '"ldap-local:'; then
        echo "❌ ${LDAP_LOCAL_USER} logged in, but has no ldap-local identity — another provider answered"; LOGIN_STATE=failed
    else
        echo "✅ ldap-local issued a token for ${LDAP_LOCAL_USER} (throwaway kubeconfig)"
    fi

    if login_cleanup && [ "$LOGIN_STATE" = ok ]; then
        echo "✅ token revoked and the throwaway kubeconfig removed"
    fi
    trap - EXIT INT TERM
    eval "$PREV_TRAPS"
    [ "$LOGIN_STATE" = ok ] || VERIFY_FAILED=1
fi
echo

# This used to print a ✓ for every line unconditionally — including a ✓ for the GroupSync CR it had
# reported as NOT found fifteen lines earlier — and then exit 0 regardless. A verification script that
# cannot fail is not a verification script. Each line now reflects what was actually observed, and the
# exit status follows.
echo "📄 Summary:"
echo "----------"
sum() { # label, then the test
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ✓ $label"; else echo "  ✗ $label"; VERIFY_FAILED=1; fi
}
sum "ConfigMap: ca-config-map-test (openshift-config)" oc get configmap ca-config-map-test -n openshift-config
sum "Secret: ldap-group-sync (group-sync-operator)"    oc get secret ldap-group-sync -n group-sync-operator
sum "Secret: ldap-secret (openshift-config)"           oc get secret ldap-secret -n openshift-config
if [ -n "${CRS:-}" ]; then echo "  ✓ GroupSync CRs: $(echo $CRS | tr '\n' ' ')"; else echo "  ✗ GroupSync CRs: none"; VERIFY_FAILED=1; fi
if [ -n "${LDAPS_SKIPPED:-}" ]; then echo "  • Public LDAPS: skipped — ${LDAPS_SKIPPED}"
elif [ "${LDAPS_OK:-0}" -eq 1 ]; then echo "  ✓ Public LDAPS: Route ldaps, certificate, serial, Keycloak bind, sync since slapd start"
else echo "  ✗ Public LDAPS: see the ❌ lines above"; fi
case "${LOGIN_STATE:-failed}" in
    ok)      echo "  ✓ ldap-local: a real token was issued" ;;
    skipped) echo "  • ldap-local: skipped — no ldap-local provider" ;;
    *)       echo "  ✗ ldap-local: see the ❌ line above" ;;
esac
echo "  • LDAP Server: ${RBAC_GROUPS:-0} app-ocp-rbac groups in the directory"
echo "  • OpenShift Groups synced: $(oc get groups --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo
if [ "${VERIFY_FAILED:-0}" -ne 0 ]; then
    echo "❌ one or more checks FAILED — see the ✗ lines above"
    exit 1
fi
echo "✅ all checks passed"
echo "📚 For detailed status: oc describe groupsync -n group-sync-operator"

