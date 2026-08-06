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
# the SECRET's name — the CR is "ldap-groupsync" — so it printed "NOT found" on a perfectly healthy lab.
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
    fi
else
    echo "❌ LDAP Server: Not running"
    echo "   Deploy with: ./30-manage-ldap-server.sh deploy-all"
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
echo "  • LDAP Server: ${RBAC_GROUPS:-0} app-ocp-rbac groups in the directory"
echo "  • OpenShift Groups synced: $(oc get groups --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo
if [ "${VERIFY_FAILED:-0}" -ne 0 ]; then
    echo "❌ one or more checks FAILED — see the ✗ lines above"
    exit 1
fi
echo "✅ all checks passed"
echo "📚 For detailed status: oc describe groupsync -n group-sync-operator"

