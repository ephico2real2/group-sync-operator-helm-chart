{{/*
Expand the name of the chart.
*/}}
{{- define "group-sync-operator-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "group-sync-operator-helm.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "group-sync-operator-helm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "group-sync-operator-helm.labels" -}}
helm.sh/chart: {{ include "group-sync-operator-helm.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "group-sync-operator-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "group-sync-operator-helm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "group-sync-operator-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
GroupSync spec body — shared by the primary (02-groupsync.yaml) and every custom
CR (custom-groupsync.yaml). The caller passes a config dict shaped exactly like
.Values.groupSync (schedule, providerName, url, insecure, ca, credentialsSecret,
rfc2307). Keeping one copy here means the two templates can never drift apart.
*/}}
{{/*
True when the provider needs CA material: an ldaps:// URL always does, and insecure=false does even
over plain ldap://. insecure only relaxes verification the operator performs itself; it cannot make
a TLS handshake trust an unknown root.
*/}}
{{- define "group-sync-operator-helm.needsCa" -}}
{{- if or (hasPrefix "ldaps://" (.url | default "")) (not .insecure) -}}true{{- end -}}
{{- end }}

{{- define "group-sync-operator-helm.groupsyncSpec" -}}
spec:
  schedule: {{ .schedule | quote }}
  providers:
    - name: {{ .providerName }}
      ldap:
        url: {{ include "group-sync-operator-helm.ldapUrl" . | quote }}
        insecure: {{ .insecure | default false }}
        prune: true
        {{- if include "group-sync-operator-helm.needsCa" . }}
        # Emitted for ldaps:// even when insecure is true — the handshake still needs the root.
        #
        # Field name comes from groupSync.ca.field. The CRD carries both `ca` and `caSecret` and
        # marks caSecret deprecated, but operator validation checks caSecret: with only `ca` set it
        # fails every reconcile with "caSecret must be specified when insecure=false". Both accept
        # kind ConfigMap|Secret and resolve namespace, so the body is identical either way.
        {{ .ca.field | default "caSecret" }}:
          kind: {{ .ca.kind | default "ConfigMap" }}
          name: {{ .ca.name }}
          key: {{ .ca.key | default "ca.crt" }}
          namespace: {{ .ca.namespace }}
        {{- end }}
        credentialsSecret:
          kind: Secret
          name: {{ .credentialsSecret.name }}
          namespace: {{ .credentialsSecret.namespace }}
        rfc2307:
          usersQuery:
            baseDN: {{ .rfc2307.usersQuery.baseDN | quote }}
            derefAliases: {{ .rfc2307.usersQuery.derefAliases | quote }}
            {{- if .rfc2307.usersQuery.filter }}
            filter: {{ .rfc2307.usersQuery.filter | quote }}
            {{- end }}
            pageSize: {{ .rfc2307.usersQuery.pageSize }}
            scope: {{ .rfc2307.usersQuery.scope | quote }}
            timeout: {{ .rfc2307.usersQuery.timeout }}

          groupsQuery:
            baseDN: {{ .rfc2307.groupsQuery.baseDN | quote }}
            derefAliases: {{ .rfc2307.groupsQuery.derefAliases | quote }}
            filter: {{ .rfc2307.groupsQuery.filter | quote }}
            pageSize: {{ .rfc2307.groupsQuery.pageSize }}
            scope: {{ .rfc2307.groupsQuery.scope | quote }}
            timeout: {{ .rfc2307.groupsQuery.timeout }}

          groupNameAttributes:
            - cn
          groupUIDAttribute: dn
          groupMembershipAttributes:
            - member
          userNameAttributes:
            - uid
          userUIDAttribute: dn
          tolerateMemberNotFoundErrors: true
          tolerateMemberOutOfScopeErrors: true
{{- end -}}

{{/*
Hash of the source CA's contents. Drives recreation of the copy: a changed source produces a
different hash, which changes the extraction Job's pod spec, so the Job re-runs and re-copies.

lookup reads the LIVE cluster, so this is populated during helm install/upgrade only. helm template
and --dry-run (and therefore an offline GitOps render) get an empty map and "unavailable" — Helm
cannot read a cluster it is not talking to. The Job stamps the same value on the copy, so what was
actually read is recorded on the object either way.

Hashes the configured sourceCa. When discoverFromOAuth finds a different name the Job logs it and
copies that one, but this trigger still follows the configured name.
*/}}
{{- define "group-sync-operator-helm.caSourceHash" -}}
{{- $c := .Values.oauthSecretExtraction.caCopy -}}
{{- $cm := lookup "v1" "ConfigMap" $c.sourceCa.namespace $c.sourceCa.name -}}
{{- if and $cm $cm.data -}}
{{- toYaml $cm.data | sha256sum | trunc 16 -}}
{{- else -}}
unavailable
{{- end -}}
{{- end }}

{{/*
The LDAP url for a provider. Returns .url when set; derives it from the cluster OAuth CR when empty.

The OAuth LDAP identity provider's url is an RFC 2255 LDAP URL — scheme://host:port/basedn?attrs?scope?filter
— so everything from the first / onwards is the search definition and belongs to authentication, not to
group sync. Only scheme://host:port is taken, which is exactly what the GroupSync provider wants, and it
carries ldap:// vs ldaps:// with it.

The first LDAP provider wins. A cluster with several normally points them all at one directory,
differing only in the basedn that is being stripped anyway.

lookup reads the LIVE cluster, so this resolves during helm install/upgrade only. With .url empty and
no cluster to read — helm template, --dry-run, an offline GitOps render — there is nothing to derive
from and the render fails rather than emitting a GroupSync with no url.
*/}}
{{- define "group-sync-operator-helm.ldapUrl" -}}
{{- if .url -}}
{{- .url -}}
{{- else -}}
{{- $found := "" -}}
{{- $oauth := lookup "config.openshift.io/v1" "OAuth" "" "cluster" -}}
{{- if $oauth -}}
{{- range $idp := ((($oauth.spec) | default dict).identityProviders | default list) -}}
{{- if and (eq (toString $idp.type) "LDAP") (not $found) -}}
{{- $found = regexFind "^ldaps?://[^/]+" ((($idp.ldap) | default dict).url | default "") -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "groupSync.url is empty and no LDAP url could be derived from the cluster OAuth CR.\n  Either set groupSync.url, or install against a cluster whose OAuth CR has an LDAP identity provider.\n  Note that `helm template` and --dry-run cannot read the cluster at all, so url must be set for those.") -}}
{{- end -}}
{{- $found -}}
{{- end -}}
{{- end }}
