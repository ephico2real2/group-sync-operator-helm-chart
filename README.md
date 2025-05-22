# Group Sync Operator Helm Chart

> **⚠️ IMPORTANT: OPENSHIFT ONLY** 
> 
> This Helm chart is designed **exclusively for OpenShift clusters**. It will not work on standard Kubernetes clusters as it depends on:
> 
> - OpenShift Operator Lifecycle Manager (OLM)
> - OpenShift's catalog sources and OperatorHub
> - OpenShift-specific APIs

This Helm chart deploys the Group Sync Operator and configures LDAP group synchronization in OpenShift environments.

## Adding the Helm Repository

```bash
# Add the Helm repository
helm repo add group-sync-operator https://ephico2real2.github.io/group-sync-operator-helm-chart

# Update your local Helm chart repository cache
helm repo update

# Search for the chart
helm search repo group-sync-operator-helm
```

## Overview

The chart deploys three main components:
1. Group Sync Operator (via OLM subscription)
2. Operator Group configuration
3. GroupSync Custom Resource for LDAP synchronization

## Prerequisites

- **OpenShift 4.x cluster** (Required - this chart does not work on standard Kubernetes)
- Helm 3.x
- Access to OpenShift's catalog sources (specifically community-operators in openshift-marketplace)
- OLM must be installed and functioning
- LDAP server details and credentials
- CA certificate for LDAPS connection

## Installation

```bash
# Create namespace
oc create namespace group-sync-operator

# Create LDAP credentials secret
oc create secret generic ldap-group-sync \
  --from-literal=bindDN='YOUR_BIND_DN' \
  --from-literal=bindPassword='YOUR_BIND_PASSWORD' \
  -n group-sync-operator

# Install the chart
helm install group-sync group-sync-operator/group-sync-operator-helm -n group-sync-operator
```

## Configuration

The following tables list the configurable parameters and their default values.

### GroupSync Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| groupSync.name | Name of the GroupSync resource | ldap-group-sync |
| groupSync.namespace | Target namespace | group-sync-operator |
| groupSync.schedule | Sync schedule (cron format) | "0/30 * * * *" |
| groupSync.providerName | LDAP provider name | ldap-git-ocp |
| groupSync.url | LDAP server URL | ldaps://ldap.ephicoreal2.net:636 |

### CA Certificate Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| groupSync.ca.name | ConfigMap name containing CA cert | ca-config-map |
| groupSync.ca.key | Key in ConfigMap for CA cert | ca.crt |
| groupSync.ca.namespace | Namespace of CA ConfigMap | openshift-config |

### Subscription Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| subscription.channel | OLM channel | alpha |
| subscription.watchNamespaces | Namespaces to watch | group-sync-operator,openshift-config |
| subscription.installPlanApproval | Install plan approval | Automatic |
| subscription.source | Operator source | community-operators |
| subscription.sourceNamespace | Source namespace | openshift-marketplace |

## Custom Values

To override the default values, create a `values.yaml` file and pass it to the helm install command:

```bash
helm install group-sync group-sync-operator/group-sync-operator-helm -n group-sync-operator -f values.yaml
```

## Notes

- The operator manages its own resource limits and scaling
- Deployment order is managed via ArgoCD sync waves
- Labels follow Kubernetes recommended standards
- LDAP queries use RFC2307 schema
- Group filtering is set to match 'app-git-*' patterns

## Upgrade Notes

When upgrading the chart, note that:
1. The operator upgrade is managed by OLM
2. Existing LDAP sync configurations will be preserved
3. ArgoCD sync waves ensure proper deployment order

```bash
helm upgrade group-sync group-sync-operator/group-sync-operator-helm -n group-sync-operator
```

## Troubleshooting

1. Verify the operator deployment:
```bash
oc get csv -n group-sync-operator
```

2. Check GroupSync status:
```bash
oc get groupsync -n group-sync-operator
```

3. View sync logs:
```bash
oc logs -l app.kubernetes.io/name=group-sync-chart -n group-sync-operator
```

## Source Code

The source code for this Helm chart is available at:
https://github.com/ephico2real2/group-sync-operator-helm-chart

The Group Sync Operator source code is available at:
https://github.com/redhat-cop/group-sync-operator

# group-sync-operator-helm-chart
