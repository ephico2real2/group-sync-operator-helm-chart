#!/bin/bash
# Health and configuration checks for the GroupSync operator, run as a `helm test` hook.
#
# Two severities, and the distinction is the whole point — it decides the exit code:
#
#   require    a precondition the operator cannot work without. Counted in ERRORS and FAILS the suite.
#   report_*   an observation that may be transient, environmental, or a deliberate choice. Counted in
#              WARNINGS and does NOT fail the suite.
#
# Every check used to be the second kind, and the script ended in an unconditional `exit 0`. Measured
# against a live cluster by breaking one input at a time, 7 of 8 broken configurations still printed
# "Health check completed successfully" and exited 0: a missing GroupSync CR, a missing credentials
# secret, a missing CA ConfigMap, a wrong CA key, a non-LDAP url, an unresolvable host, and a closed
# port. Only a missing namespace failed — and only because `set -e` aborted at Test 1, so no summary
# and no ❌ was printed at all.
#
# `set -e` is therefore deliberately absent. A diagnostic script has to run every check and then decide:
# under -e the first failing check aborted mid-run, skipping the remaining tests and the verdict. Its
# sibling ldap-connection-test.sh is built the same way, for the same reason.
set -o pipefail

echo "🔧 Testing GroupSync Operator Installation, Configuration & Health..."
echo "================================================================="

ERRORS=0
WARNINGS=0

# A precondition the operator cannot work without. Fails the suite.
require() {
  if [ "${2:-1}" -eq 0 ]; then
    echo "✅ $1"
  else
    echo "❌ $1"
    ERRORS=$((ERRORS + 1))
  fi
}

# An observation. Never fails the suite — see the header for which is which.
report_result() {
  if [ $2 -eq 0 ]; then
    echo "✅ $1"
  else
    echo "ℹ️  $1 (informational)"
    WARNINGS=$((WARNINGS + 1))
  fi
}

# Function to report informational messages
report_info() {
  echo "ℹ️  $1"
}

# Function to report warnings
report_warning() {
  echo "⚠️  $1"
  WARNINGS=$((WARNINGS + 1))
}

# Test 1: Check if namespace exists
echo ""
echo "📍 Test 1: Namespace Validation"
echo "------------------------------"
oc get namespace "$GROUPSYNC_NAMESPACE" &> /dev/null
require "Namespace '$GROUPSYNC_NAMESPACE' exists" $?

# Test 2: Check if operator is deployed and healthy
echo ""
echo "📍 Test 2: Operator Deployment & Health"
echo "--------------------------------------"
if oc get deployment -n "$GROUPSYNC_NAMESPACE" | grep -q group-sync-operator; then
  # Check if deployment is ready
  oc get deployment -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator -o jsonpath='{.items[0].status.readyReplicas}' | grep -q "1"
  require "Operator deployment is running and ready" $?
  
  # Show operator pod details
  echo "   Operator pod details:"
  oc get pods -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator --no-headers | sed 's/^/   /'
  
  # Check pod health in detail
  OPERATOR_PODS=$(oc get pods -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator --no-headers 2>/dev/null || echo "")
  if [ -n "$OPERATOR_PODS" ]; then
    READY_PODS=$(echo "$OPERATOR_PODS" | grep "Running" | grep "2/2" | wc -l || echo "0")
    TOTAL_PODS=$(echo "$OPERATOR_PODS" | wc -l)
    
    if [ "$READY_PODS" -eq "$TOTAL_PODS" ] && [ "$READY_PODS" -gt 0 ]; then
      require "All operator pods are healthy: $READY_PODS/$TOTAL_PODS ready" 0
    else
      require "Operator pods are healthy ($READY_PODS/$TOTAL_PODS ready)" 1
    fi
    
    # Check pod events for issues
    POD_EVENTS=$(oc get events -n "$GROUPSYNC_NAMESPACE" --field-selector involvedObject.kind=Pod --no-headers 2>/dev/null | grep -i "error\|failed\|warning" | tail -5 || echo "")
    if [ -n "$POD_EVENTS" ]; then
      report_warning "Recent pod events found (may indicate issues)"
      echo "$POD_EVENTS" | sed 's/^/   /'
    fi
  fi
else
  require "Operator deployment found in $GROUPSYNC_NAMESPACE" 1
fi

# Test 3: Check if GroupSync CR exists and its status
echo ""
echo "📍 Test 3: GroupSync Custom Resource Status"
echo "------------------------------------------"
if oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" &> /dev/null; then
  require "GroupSync CR '$GROUPSYNC_NAME' exists" 0

  # Check GroupSync configuration
  echo "   GroupSync configuration:"
  echo "   - URL: $GROUPSYNC_URL"
  echo "   - Insecure: $GROUPSYNC_INSECURE"
  echo "   - Schedule: $GROUPSYNC_SCHEDULE"
  echo "   - Groups Base DN: $GROUPS_BASE_DN"
  echo "   - Users Base DN: $USERS_BASE_DN"
  echo "   - Groups Filter: $GROUPS_FILTER"
  
  # Check GroupSync status conditions
  GROUPSYNC_STATUS=$(oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
  GROUPSYNC_MESSAGE=$(oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "No message")
  
  echo "   Current Status: $GROUPSYNC_STATUS"
  echo "   Message: $GROUPSYNC_MESSAGE"
  
        if [ "$GROUPSYNC_STATUS" = "ReconcileError" ]; then
      echo ""
      echo "   📋 Reconciliation Error Analysis:"
      echo "   ════════════════════════════════════"
      # Analyze common error patterns
      if echo "$GROUPSYNC_MESSAGE" | grep -qi "non-existent entry"; then
        echo "   🔍 Issue Type: LDAP Base DN or Connectivity"
        echo "   💡 Common Causes:"
        echo "      • Cross-namespace connectivity restrictions"
        echo "      • Incorrect LDAP Base DN configuration"
        echo "      • LDAP server not accessible from this namespace"
        echo "      • Network policies blocking LDAP traffic"
      elif echo "$GROUPSYNC_MESSAGE" | grep -qi "certificate"; then
        echo "   🔍 Issue Type: TLS/Certificate Problem"
        echo "   💡 Common Causes:"
        echo "      • Invalid or expired CA certificate"
        echo "      • Hostname mismatch in certificate"
        echo "      • TLS configuration issues"
        echo "      • CA certificate not properly mounted"
      elif echo "$GROUPSYNC_MESSAGE" | grep -qi "credentials\|authentication"; then
        echo "   🔍 Issue Type: Authentication Problem"
        echo "   💡 Common Causes:"
        echo "      • Incorrect bind DN or password"
        echo "      • LDAP server rejecting credentials"
        echo "      • Account locked or expired"
        echo "      • Insufficient LDAP permissions"
      elif echo "$GROUPSYNC_MESSAGE" | grep -qi "network\|connection"; then
        echo "   🔍 Issue Type: Network Connectivity"
        echo "   💡 Common Causes:"
        echo "      • LDAP server not reachable"
        echo "      • Firewall or network policy blocking access"
        echo "      • DNS resolution problems"
        echo "      • Port connectivity issues"
      else
        echo "   🔍 Issue Type: Unknown Reconciliation Error"
        echo "   💡 Recommendation: Check operator logs for detailed error information"
      fi
      echo "   ────────────────────────────────────"
      echo "   ✨ Note: This is informational - tests will continue"
    elif [ "$GROUPSYNC_STATUS" = "ReconcileSuccess" ] || [ "$GROUPSYNC_STATUS" = "Complete" ]; then
      echo "✅ GroupSync is operating successfully"
    else
      echo "ℹ️  GroupSync status: $GROUPSYNC_STATUS (monitoring)"
    fi
else
  require "GroupSync CR '$GROUPSYNC_NAME' exists" 1
fi

# Test 4: Check LDAP credentials secret
echo ""
echo "📍 Test 4: LDAP Credentials Secret"
echo "---------------------------------"
if oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" &> /dev/null; then
  require "LDAP credentials secret exists" 0
  
  # username and password ONLY. Those are the two keys the operator reads — secretUsernameKey and
  # secretPasswordKey in its source — and a missing one is not an error to it: getLdapCredentialValue
  # substitutes an empty string, so wrong key names give an anonymous bind rather than a failure.
  #
  # This used to accept bindDN/bindPassword as an alternative "manual format" and PASS on it. Those are
  # the OAuth identity provider's key names, on a DIFFERENT Secret in openshift-config that this chart
  # does not own; the operator never reads them. Passing on them told you a Secret was usable that the
  # operator cannot authenticate with.
  #
  # Asserted on the decoded VALUE, not on a pipeline's exit status. `oc get -o jsonpath='{.data.KEY}' |
  # base64 -d` exits 0 for a key that does not exist — jsonpath prints nothing and base64 decodes nothing
  # successfully — so the old form could not detect a missing key at all. Measured against this cluster,
  # it reported a key literally named definitely-not-a-key as present, which made the first branch always
  # win, left the bindDN branch unreachable, and passed a Secret with no username at all as valid with an
  # empty bind DN.
  secret_key() {
    oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" \
      -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null
  }
  WRONG_KEYS_HINT="The operator reads only username and password. bindDN and bindPassword are the OAuth
     identity provider's key names, on its own Secret in openshift-config, and are never read from this one."

  BIND_DN=$(secret_key username)
  if [ -n "$BIND_DN" ]; then
    require "Secret key username holds a bind DN: $BIND_DN" 0
  else
    require "Secret key username is present and non-empty" 1
    echo "   ${WRONG_KEYS_HINT}"
  fi

  BIND_PW=$(secret_key password)
  if [ -n "$BIND_PW" ]; then
    require "Secret key password holds a password: ${#BIND_PW} characters" 0
  else
    require "Secret key password is present and non-empty" 1
    echo "   ${WRONG_KEYS_HINT}"
  fi
else
  require "LDAP credentials secret exists in ${CREDENTIALS_SECRET_NAMESPACE}" 1
fi

# Test 5: Check CA ConfigMap (only for secure connections)
echo ""
echo "📍 Test 5: CA Certificate Configuration"
echo "--------------------------------------"
if [ "$GROUPSYNC_INSECURE" = "true" ]; then
  echo "   Skipping CA certificate check (insecure mode enabled)"
  report_result "CA certificate check (not required for insecure mode)" 0
else
  if oc get configmap "$CA_NAME" -n "$CA_NAMESPACE" &> /dev/null; then
    require "CA certificate ConfigMap ${CA_NAMESPACE}/${CA_NAME} exists" 0

    # Validate ConfigMap has the required key. jsonpath cannot address a key containing a dot — it reads
    # it as a path separator — so an injected bundle's ca-bundle.crt returns empty here and this check
    # would fail on a perfectly good ConfigMap. oc extract addresses the key literally.
    rm -rf /tmp/health-ca && mkdir -p /tmp/health-ca
    oc extract "configmap/${CA_NAME}" -n "$CA_NAMESPACE" --keys="$CA_KEY" \
       --to=/tmp/health-ca --confirm &> /dev/null
    if grep -q "BEGIN CERTIFICATE" "/tmp/health-ca/${CA_KEY}" 2>/dev/null; then
      require "CA contains certificate data: $(grep -c 'BEGIN CERTIFICATE' "/tmp/health-ca/${CA_KEY}") certificate(s) under key ${CA_KEY}" 0
    else
      require "CA contains certificate data under key ${CA_KEY}" 1
    fi
    rm -rf /tmp/health-ca
  else
    require "CA certificate ConfigMap ${CA_NAMESPACE}/${CA_NAME} exists" 1
  fi
fi

# Test 6: Network connectivity test
echo ""
echo "📍 Test 6: Network Connectivity"
echo "-------------------------------"

# Extract URL components
URL="$GROUPSYNC_URL"
URL_PARSED=yes
if [[ $URL == ldaps://* ]]; then
  PROTOCOL="ldaps"
  DEFAULT_PORT="636"
  URL_WITHOUT_PROTOCOL="${URL#ldaps://}"
elif [[ $URL == ldap://* ]]; then
  PROTOCOL="ldap"
  DEFAULT_PORT="389"
  URL_WITHOUT_PROTOCOL="${URL#ldap://}"
else
  require "url is ldap:// or ldaps:// — got '$URL'" 1
  URL_PARSED=no
fi

# The connectivity checks are skipped rather than run against a hostname parsed out of something that is
# not a URL. Testing 'https' as a hostname reports two more failures that say nothing the line above did
# not already say, and reading them costs whoever is debugging this real time.
if [ "$URL_PARSED" = no ]; then
  report_info "skipping DNS and TCP checks — there is no host to test until the url is a valid LDAP url"
else
  # Parse hostname and port
  if [[ $URL_WITHOUT_PROTOCOL == *:* ]]; then
    HOSTNAME="${URL_WITHOUT_PROTOCOL%:*}"
    PORT="${URL_WITHOUT_PROTOCOL#*:}"
  else
    HOSTNAME="$URL_WITHOUT_PROTOCOL"
    PORT="$DEFAULT_PORT"
  fi

  echo "   Testing connectivity to: $HOSTNAME:$PORT ($PROTOCOL)"

  # DNS resolution. getent first: nslookup is absent from some ose-cli variants, and a missing tool would
  # otherwise be indistinguishable from a name that does not resolve.
  if getent hosts "$HOSTNAME" &> /dev/null || nslookup "$HOSTNAME" &> /dev/null; then
    require "DNS resolution for $HOSTNAME" 0
  else
    require "DNS resolution for $HOSTNAME" 1
  fi

  # Port connectivity test (using timeout)
  if timeout 5 bash -c "</dev/tcp/$HOSTNAME/$PORT" &> /dev/null; then
    require "TCP connectivity to $HOSTNAME:$PORT" 0
  else
    require "TCP connectivity to $HOSTNAME:$PORT" 1
  fi
fi

# Test 7: GroupSync Operator Internal Sync Status
echo ""
echo "📍 Test 7: GroupSync Operator Internal Sync Status"
echo "-----------------------------------------------"

# The GroupSync operator performs internal synchronization, not via CronJobs
# Check the operator's internal sync status through the GroupSync CR status
if oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" &> /dev/null; then
  LAST_SYNC_TIME=$(oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "")
  SYNC_GENERATION=$(oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  
  if [ -n "$LAST_SYNC_TIME" ]; then
    echo "✅ GroupSync operator has performed synchronization"
    echo "   Last sync time: $LAST_SYNC_TIME"
    echo "   Observed generation: $SYNC_GENERATION"
  else
    echo "ℹ️  GroupSync operator internal sync status"
    echo "   No sync timestamp available (may be normal for new installation)"
    echo "   The operator performs internal synchronization based on the schedule: $GROUPSYNC_SCHEDULE"
  fi
else
  echo "⚠️  Cannot check internal sync status (GroupSync CR not found)"
fi

# Test 8: OpenShift Groups Synchronization
echo ""
echo "📍 Test 8: OpenShift Groups Synchronization"
echo "-------------------------------------------"

# Look for groups that match our expected pattern
SYNCED_GROUPS=$(oc get groups --no-headers 2>/dev/null | grep "app-ocp-rbac" || echo "")
if [ -n "$SYNCED_GROUPS" ]; then
  GROUP_COUNT=$(echo "$SYNCED_GROUPS" | wc -l)
  report_result "Synchronized OpenShift groups found: $GROUP_COUNT" 0
  echo "   Synchronized groups:"
  echo "$SYNCED_GROUPS" | sed 's/^/   /'
  
  # Check group membership
  echo ""
  echo "   Group membership details:"
  while IFS= read -r group_line; do
    GROUP_NAME=$(echo "$group_line" | awk '{print $1}')
    MEMBER_COUNT=$(oc get group "$GROUP_NAME" -o jsonpath='{.users}' 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")
    echo "   - $GROUP_NAME: $MEMBER_COUNT members"
  done <<< "$SYNCED_GROUPS"
else
  report_warning "No synchronized OpenShift groups found"
  echo "   This could be normal if:"
  echo "   - This is the first run and sync hasn't occurred yet"
  echo "   - LDAP connectivity issues prevent synchronization"
  echo "   - No groups match the configured filter"
fi

# Test 9: OAuth Secret Extraction Job Status (if enabled)
echo ""
echo "📍 Test 9: OAuth Secret Extraction Job"
echo "-------------------------------------"
if [ "$OAUTH_ENABLED" = "true" ]; then
  # Look for the OAuth secret extraction job with the correct naming pattern
  OAUTH_JOB=$(oc get jobs -n "$GROUPSYNC_NAMESPACE" --no-headers 2>/dev/null | grep "oauth-secret-extraction" | head -1 || echo "")
  if [ -n "$OAUTH_JOB" ]; then
    JOB_NAME=$(echo "$OAUTH_JOB" | awk '{print $1}')
    JOB_STATUS=$(echo "$OAUTH_JOB" | awk '{print $3}')
    echo "✅ OAuth secret extraction job found: $JOB_NAME"
    echo "   Job status: $JOB_STATUS"
    
    # Get more detailed status
    COMPLETION_TIME=$(oc get job "$JOB_NAME" -n "$GROUPSYNC_NAMESPACE" -o jsonpath='{.status.completionTime}' 2>/dev/null || echo "")
    if [ -n "$COMPLETION_TIME" ]; then
      echo "   Completion time: $COMPLETION_TIME"
      echo "   ✅ Job completed successfully"
    else
      echo "   ℹ️  Job may still be running or pending"
    fi
  else
    echo "ℹ️  OAuth secret extraction job not found"
    echo "   This could be normal if:"
    echo "   - a previous install's Job was replaced, or the namespace was recreated"
    echo "   - Job hasn't been triggered yet"
    echo "   - Job name pattern differs from expected"
  fi
else
  echo "ℹ️  OAuth secret extraction is disabled"
fi

# Test 10: Operator Logs Analysis
echo ""
echo "📍 Test 10: Operator Logs Analysis"
echo "--------------------------------"

RECENT_LOGS=$(oc logs -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator --tail=50 --since=10m 2>/dev/null || echo "")
if [ -n "$RECENT_LOGS" ]; then
  # Look for error patterns
  ERROR_LOGS=$(echo "$RECENT_LOGS" | grep -i "error\|failed\|panic" || echo "")
  if [ -n "$ERROR_LOGS" ]; then
    report_warning "Errors found in recent operator logs"
    echo "   Recent errors:"
    echo "$ERROR_LOGS" | tail -5 | sed 's/^/   /'
  else
    report_result "No errors in recent operator logs" 0
  fi
  
  # Look for successful sync operations
  SUCCESS_LOGS=$(echo "$RECENT_LOGS" | grep -i "sync.*success\|reconcile.*success\|completed" || echo "")
  if [ -n "$SUCCESS_LOGS" ]; then
    report_result "Successful operations found in logs" 0
  else
    report_warning "No recent successful operations in logs"
  fi
else
  report_warning "Unable to retrieve operator logs"
fi

# Test 11: Resource Usage and Performance
echo ""
echo "📍 Test 11: Resource Usage Analysis"
echo "---------------------------------"

OPERATOR_POD=$(oc get pods -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
if [ -n "$OPERATOR_POD" ]; then
  # Get resource usage if metrics are available
  POD_METRICS=$(oc adm top pod "$OPERATOR_POD" -n "$GROUPSYNC_NAMESPACE" --no-headers 2>/dev/null || echo "")
  if [ -n "$POD_METRICS" ]; then
    CPU_USAGE=$(echo "$POD_METRICS" | awk '{print $2}')
    MEMORY_USAGE=$(echo "$POD_METRICS" | awk '{print $3}')
    report_result "Resource usage: CPU $CPU_USAGE, Memory $MEMORY_USAGE" 0
  else
    report_warning "Resource metrics not available (metrics server may not be configured)"
  fi
  
  # Check pod restart count
  RESTART_COUNT=$(oc get pod "$OPERATOR_POD" -n "$GROUPSYNC_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
  if [ "$RESTART_COUNT" -eq 0 ]; then
    report_result "Operator pod stability: 0 restarts" 0
  else
    report_warning "Operator pod has restarted $RESTART_COUNT times"
  fi
fi

# Test 12: Configuration Validation
echo ""
echo "📍 Test 12: Configuration Validation"
echo "-----------------------------------"

# Validate schedule format
SCHEDULE="$GROUPSYNC_SCHEDULE"
if echo "$SCHEDULE" | grep -qE "^([0-9,\*/-]+\s+){4}[0-9,\*/-]+$"; then
  report_result "Schedule format is valid: $SCHEDULE" 0
else
  report_warning "Schedule format may be invalid: $SCHEDULE"
fi

# Check for common misconfigurations
if [ "$GROUPS_BASE_DN" = "$USERS_BASE_DN" ]; then
  report_warning "Groups and Users base DN are the same - this may be intentional but could cause issues"
fi

# Summary
echo ""
echo "📊 GroupSync Operator Health Summary"
echo "===================================="

if [ "$ERRORS" -gt 0 ]; then
  # Spelled out rather than ${WARNINGS:+...}, which fires on the string "0" because it is not empty.
  if [ "$WARNINGS" -gt 0 ]; then
    echo "❌ $ERRORS check(s) FAILED, plus $WARNINGS informational item(s)."
  else
    echo "❌ $ERRORS check(s) FAILED."
  fi
  echo ""
  echo "📋 Summary: the operator cannot work in this configuration"
  echo "   • Every ❌ above is a precondition the operator needs, not an observation"
  echo "   • Fix those first; the informational items may resolve on their own once they are"
elif [ "$WARNINGS" -eq 0 ]; then
  echo "🎉 Perfect! GroupSync operator is healthy and properly configured."
  echo ""
  echo "✅ System Status: All checks passed"
  echo "   • Operator is running without issues"
  echo "   • Configuration is valid"
  echo "   • Network connectivity is working"
  echo "   • No warnings or issues detected"
else
  echo "✅ GroupSync operator health check completed with $WARNINGS informational item(s)."
  echo ""
  echo "📋 Summary: The operator is functional"
  echo "   • Core functionality is working properly"
  echo "   • Some items may need attention (see details above)"
  echo "   • No critical failures detected"
fi

echo ""
echo "🔧 Recommended Next Steps:"
echo "─────────────────────────────"
echo "1. 🧪 Run LDAP connectivity test:"
echo "   helm test $RELEASE_NAME --logs | grep ldap-connection"
echo ""
echo "2. 📊 Monitor operator activity:"
echo "   kubectl logs -f -n $GROUPSYNC_NAMESPACE -l control-plane=group-sync-operator"
echo ""
echo "3. 👥 Check synchronized groups:"
echo "   kubectl get groups"
echo ""
echo "4. 🔍 Detailed GroupSync status:"
echo "   kubectl describe groupsync $GROUPSYNC_NAME -n $GROUPSYNC_NAMESPACE"

echo ""
# The exit code is the only part of this `helm test` hook that Helm itself reads, so it has to reflect
# the verdict rather than the fact that the script reached the end.
if [ "$ERRORS" -gt 0 ]; then
  echo "❌ Health check FAILED: $ERRORS precondition(s) not met."
  exit 1
fi
echo "✨ Health check completed successfully!"
exit 0

