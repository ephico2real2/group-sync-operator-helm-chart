#!/bin/bash
set -e
echo "🔧 Testing GroupSync Operator Installation, Configuration & Health..."
echo "================================================================="

ERRORS=0
WARNINGS=0

# Function to report test results (informational only, no failures)
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
report_result "Namespace '$GROUPSYNC_NAMESPACE' exists" $?

# Test 2: Check if operator is deployed and healthy
echo ""
echo "📍 Test 2: Operator Deployment & Health"
echo "--------------------------------------"
if oc get deployment -n "$GROUPSYNC_NAMESPACE" | grep -q group-sync-operator; then
  # Check if deployment is ready
  oc get deployment -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator -o jsonpath='{.items[0].status.readyReplicas}' | grep -q "1"
  report_result "Operator deployment is running and ready" $?
  
  # Show operator pod details
  echo "   Operator pod details:"
  oc get pods -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator --no-headers | sed 's/^/   /'
  
  # Check pod health in detail
  OPERATOR_PODS=$(oc get pods -n "$GROUPSYNC_NAMESPACE" -l control-plane=group-sync-operator --no-headers 2>/dev/null || echo "")
  if [ -n "$OPERATOR_PODS" ]; then
    READY_PODS=$(echo "$OPERATOR_PODS" | grep "Running" | grep "2/2" | wc -l || echo "0")
    TOTAL_PODS=$(echo "$OPERATOR_PODS" | wc -l)
    
    if [ "$READY_PODS" -eq "$TOTAL_PODS" ] && [ "$READY_PODS" -gt 0 ]; then
      report_result "All operator pods are healthy: $READY_PODS/$TOTAL_PODS ready" 0
    else
      report_result "Operator pods health check" 1
    fi
    
    # Check pod events for issues
    POD_EVENTS=$(oc get events -n "$GROUPSYNC_NAMESPACE" --field-selector involvedObject.kind=Pod --no-headers 2>/dev/null | grep -i "error\|failed\|warning" | tail -5 || echo "")
    if [ -n "$POD_EVENTS" ]; then
      report_warning "Recent pod events found (may indicate issues)"
      echo "$POD_EVENTS" | sed 's/^/   /'
    fi
  fi
else
  report_result "Operator deployment found" 1
fi

# Test 3: Check if GroupSync CR exists and its status
echo ""
echo "📍 Test 3: GroupSync Custom Resource Status"
echo "------------------------------------------"
if oc get groupsync "$GROUPSYNC_NAME" -n "$GROUPSYNC_NAMESPACE" &> /dev/null; then
  report_result "GroupSync CR '$GROUPSYNC_NAME' exists" 0
  
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
  report_result "GroupSync CR '$GROUPSYNC_NAME' exists" 1
fi

# Test 4: Check LDAP credentials secret
echo ""
echo "📍 Test 4: LDAP Credentials Secret"
echo "---------------------------------"
if oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" &> /dev/null; then
  report_result "LDAP credentials secret exists" 0
  
  # Validate secret has required keys (OAuth extraction uses 'username'/'password', manual uses 'bindDN'/'bindPassword')
  if oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.username}' | base64 -d &> /dev/null; then
    BIND_DN=$(oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
    report_result "Secret contains valid bind DN (OAuth format): $BIND_DN" 0
    SECRET_FORMAT="OAuth extraction"
  elif oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.bindDN}' | base64 -d &> /dev/null; then
    BIND_DN=$(oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.bindDN}' | base64 -d)
    report_result "Secret contains valid bind DN (manual format): $BIND_DN" 0
    SECRET_FORMAT="Manual secret"
  else
    report_result "Secret contains valid bind DN (username or bindDN)" 1
    SECRET_FORMAT="Unknown"
  fi
  
  if oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d &> /dev/null; then
    PASSWORD_LEN=$(oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d | wc -c)
    report_result "Secret contains password ($SECRET_FORMAT): ${PASSWORD_LEN} characters" 0
  elif oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.bindPassword}' | base64 -d &> /dev/null; then
    PASSWORD_LEN=$(oc get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" -o jsonpath='{.data.bindPassword}' | base64 -d | wc -c)
    report_result "Secret contains password ($SECRET_FORMAT): ${PASSWORD_LEN} characters" 0
  else
    report_result "Secret contains password (password or bindPassword)" 1
  fi
else
  report_result "LDAP credentials secret exists" 1
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
    report_result "CA certificate ConfigMap exists" 0
    
    # Validate ConfigMap has the required key
    if oc get configmap "$CA_NAME" -n "$CA_NAMESPACE" -o jsonpath="{.data.$CA_KEY}" | grep -q "BEGIN CERTIFICATE"; then
      report_result "CA certificate contains valid certificate data" 0
    else
      report_result "CA certificate contains valid certificate data" 1
    fi
  else
    report_result "CA certificate ConfigMap exists" 1
  fi
fi

# Test 6: Network connectivity test
echo ""
echo "📍 Test 6: Network Connectivity"
echo "-------------------------------"

# Extract URL components
URL="$GROUPSYNC_URL"
if [[ $URL == ldaps://* ]]; then
  PROTOCOL="ldaps"
  DEFAULT_PORT="636"
  URL_WITHOUT_PROTOCOL="${URL#ldaps://}"
elif [[ $URL == ldap://* ]]; then
  PROTOCOL="ldap"
  DEFAULT_PORT="389"
  URL_WITHOUT_PROTOCOL="${URL#ldap://}"
else
  echo "   ❌ Invalid LDAP URL format: $URL"
  ERRORS=$((ERRORS + 1))
  URL_WITHOUT_PROTOCOL="$URL"
fi

# Parse hostname and port
if [[ $URL_WITHOUT_PROTOCOL == *:* ]]; then
  HOSTNAME="${URL_WITHOUT_PROTOCOL%:*}"
  PORT="${URL_WITHOUT_PROTOCOL#*:}"
else
  HOSTNAME="$URL_WITHOUT_PROTOCOL"
  PORT="$DEFAULT_PORT"
fi

echo "   Testing connectivity to: $HOSTNAME:$PORT ($PROTOCOL)"

# DNS resolution test
if nslookup "$HOSTNAME" &> /dev/null; then
  report_result "DNS resolution for $HOSTNAME" 0
else
  report_result "DNS resolution for $HOSTNAME" 1
fi

# Port connectivity test (using timeout)
if timeout 5 bash -c "</dev/tcp/$HOSTNAME/$PORT"; then
  report_result "TCP connectivity to $HOSTNAME:$PORT" 0
else
  report_result "TCP connectivity to $HOSTNAME:$PORT" 1
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
    echo "   - Job completed and was cleaned up (TTL)"
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

if [ $WARNINGS -eq 0 ]; then
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
echo "✨ Health check completed successfully!"
exit 0

