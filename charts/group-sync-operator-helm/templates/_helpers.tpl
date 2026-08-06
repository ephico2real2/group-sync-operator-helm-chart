# Expand the name of the chart.
{{- define "group-sync-operator-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

# Create a default fully qualified app name.
# We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
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

# Create chart name and version as used by the chart label.
{{- define "group-sync-operator-helm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

# Common labels
{{- define "group-sync-operator-helm.labels" -}}
helm.sh/chart: {{ include "group-sync-operator-helm.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "group-sync-operator-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

# Selector labels
{{- define "group-sync-operator-helm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "group-sync-operator-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

# True when the provider needs CA material: an ldaps:// URL always does, and insecure=false does even
# over plain ldap://. insecure only relaxes verification the operator performs itself; it cannot make
# a TLS handshake trust an unknown root.
#
# The scheme is read from the RESOLVED url, not from .url. With .url empty the url comes from the cluster's
# OAuth CR at install time, so reading the raw field saw "" and concluded no CA was needed for what is in
# fact an ldaps:// endpoint — no caSecret on the CR, no CA preflight, no copy. That only surfaced with
# insecure=true, since insecure=false makes this true regardless of scheme.
#
# Deliberately ldapUrlOrEmpty and not ldapUrl: see the note above ldapUrlOrEmpty for why a fail cannot be
# reached from here. When nothing resolves, this falls back to the insecure flag alone — the pre-existing
# behaviour, unchanged.
{{- define "group-sync-operator-helm.needsCa" -}}
{{- if or (hasPrefix "ldaps://" (include "group-sync-operator-helm.ldapUrlOrEmpty" .)) (not .insecure) -}}true{{- end -}}
{{- end }}

# Points a config dict's ca block at the OpenShift-injected trust bundle, when trustedCA.injected is on.
#
# trustedCA.injected.enabled used to render a labelled empty ConfigMap and nothing else — the CR still
# pointed at the CA COPY, so the switch produced a bundle nobody read. It only looked like it worked
# because crc-injected-values.yaml also restates name, namespace, key and kind by hand. A switch that
# needs four companion values set manually is not a switch, and the failure is quiet: the operator loads
# the copy, or fails to find one, while a perfectly good 149-certificate bundle sits unused beside it.
#
# Resolved here rather than defaulted in values.yaml because groupSync.ca.name already HAS a default, so
# there is no way to tell "left alone" from "deliberately set to the same string".
#
# The key is ca-bundle.crt, not ca.crt: that is what OpenShift's injector writes into a ConfigMap carrying
# config.openshift.io/inject-trusted-cabundle, and looking for ca.crt in one finds nothing.
#
# The four caX helpers below are the single source of truth, and EVERY consumer must use them. There are
# more consumers than the CR: the extraction Job preflights the CA, the ClusterRole grants read on it, and
# both test pods verify it. Resolving it for the CR alone left those pointing at the copy — caught by
# ci/render-checks.py, which reported "Job preflights configmaps/ldap-trusted-ca ... with no get there"
# and "CA_NAME='ca-config-map-copy' but the CR's ca.name is 'ldap-trusted-ca'".
{{- define "group-sync-operator-helm.caKind" -}}
{{- if .Values.trustedCA.injected.enabled -}}ConfigMap{{- else -}}{{ .Values.groupSync.ca.kind | default "ConfigMap" }}{{- end -}}
{{- end }}

{{- define "group-sync-operator-helm.caName" -}}
{{- if .Values.trustedCA.injected.enabled -}}{{ .Values.trustedCA.injected.name }}{{- else -}}{{ .Values.groupSync.ca.name }}{{- end -}}
{{- end }}

{{- define "group-sync-operator-helm.caNamespace" -}}
{{- if .Values.trustedCA.injected.enabled -}}{{ .Values.groupSync.namespace }}{{- else -}}{{ .Values.groupSync.ca.namespace }}{{- end -}}
{{- end }}

{{- define "group-sync-operator-helm.caKey" -}}
{{- if .Values.trustedCA.injected.enabled -}}ca-bundle.crt{{- else -}}{{ .Values.groupSync.ca.key | default "ca.crt" }}{{- end -}}
{{- end }}

# Gates for the two hook Jobs, which used to be one.
#
# The CA preflight and copy lived INSIDE the extraction Job, so oauthSecretExtraction.enabled removed both.
# A cluster with no LDAP identity provider to extract a bind password FROM, but which still needs the CA
# copied into the operator's namespace, had no way to ask for that: caCopy.enabled read like a peer flag and
# behaved like a subordinate one. With extraction off the copy silently vanished while the CR went on naming
# ca-config-map-copy, and the only symptom was the operator reconciling forever on an object nobody created.
#
# caJobEnabled therefore does not turn on the CA work because extraction is on; it turns on because there IS
# CA work to do:
#   needsCa AND caCopy.enabled       the copy, with or without extraction
#   needsCa AND extraction.enabled   preflight only — what caCopy.enabled=false has always done
# Both false means the chart creates no CA object and runs no Job for one: the CA is yours to supply, and
# groupSync.ca must name something that already exists.
{{- define "group-sync-operator-helm.caJobEnabled" -}}
{{- if and (include "group-sync-operator-helm.needsCa" .Values.groupSync) (or .Values.oauthSecretExtraction.caCopy.enabled .Values.oauthSecretExtraction.enabled) -}}true{{- end -}}
{{- end }}

# True when EITHER hook Job renders. The ServiceAccount, its ClusterRole and the binding are shared, so they
# have to survive extraction being off — otherwise the CA Job renders with no identity to run as.
{{- define "group-sync-operator-helm.oauthJobsEnabled" -}}
{{- if or .Values.oauthSecretExtraction.enabled (include "group-sync-operator-helm.caJobEnabled" .) -}}true{{- end -}}
{{- end }}

# Metadata the hook Jobs stamp onto the two objects they create with `oc apply` — the credentials Secret and
# the CA copy. Emitted as shell arguments for `oc label --local` / `oc annotate --local`, so one definition
# serves both writers and stays in step with the labels Helm puts on ordinary templated resources.
#
# THIS DOES NOT MAKE HELM DELETE THEM. The meta.helm.sh annotations govern ADOPTION — whether a future
# `helm install`/`upgrade` may take over an object that already exists, instead of refusing with "exists and
# cannot be imported". `helm uninstall` deletes what is in the stored release manifest, and an object created
# imperatively inside a hook Job is not in it, stamped or not. The pre-delete Job in
# 01.8-hook-object-cleanup-job.yaml is what actually removes them; do not drop it believing this covers it.
#
# What the stamp does buy: the objects become selectable by release
# (`oc get secret,configmap -l app.kubernetes.io/instance=<release>`), their provenance sits beside the
# group-sync.redhat-cop.io/source annotations the CA copy already carries, and a later chart version can
# adopt either into a real template.
{{- define "group-sync-operator-helm.hookObjectLabels" -}}
"app.kubernetes.io/managed-by=Helm" "app.kubernetes.io/name={{ include "group-sync-operator-helm.name" . }}" "app.kubernetes.io/instance={{ .Release.Name }}" "helm.sh/chart={{ include "group-sync-operator-helm.chart" . }}"
{{- end }}

{{- define "group-sync-operator-helm.hookObjectAnnotations" -}}
"meta.helm.sh/release-name={{ .Release.Name }}" "meta.helm.sh/release-namespace={{ .Release.Namespace }}"
{{- end }}

# Both Jobs read the cluster OAuth CR, for different reasons, so the one cluster-scoped rule that grants it
# has to follow whichever of them actually calls the API:
#
#   extraction   resolves an empty bindDN or sourceSecret.name off the CR, at the top of its script
#   CA Job       resolves the source CA's NAME off the CR, when caCopy.discoverFromOAuth is on
#
# Gated too narrowly, the symptom is a Job calling an API it has no permission for: an earlier version nested
# this inside the needsCa and caCopy gates and measured 0 oauths rules against 2 `oc get oauth cluster` calls.
{{- define "group-sync-operator-helm.oauthCrRead" -}}
{{- if or (and .Values.oauthSecretExtraction.enabled (or (not .Values.oauthSecretExtraction.bindDN) (not .Values.oauthSecretExtraction.sourceSecret.name))) (and (include "group-sync-operator-helm.caJobEnabled" .) .Values.oauthSecretExtraction.caCopy.enabled .Values.oauthSecretExtraction.caCopy.discoverFromOAuth) -}}true{{- end -}}
{{- end }}

# The shared ClusterRole carries only what is genuinely cluster-scoped: namespaces, which only the extraction
# Job creates, and the OAuth CR. When neither is needed — a CA-copy-only install that does not discover from
# the OAuth CR — there is nothing left to grant, and rendering it anyway leaves an empty ClusterRole and a
# binding that confers nothing.
{{- define "group-sync-operator-helm.clusterRoleEnabled" -}}
{{- if or .Values.oauthSecretExtraction.enabled (include "group-sync-operator-helm.oauthCrRead" .) -}}true{{- end -}}
{{- end }}

# Applies the resolved CA to a config dict, for groupsyncSpec — which receives a dict shaped like
# .Values.groupSync and so cannot reach .Values.trustedCA itself. Reads the same four helpers, so the CR
# can never disagree with the Job, the RBAC or the test pods.
{{- define "group-sync-operator-helm.applyInjectedCa" -}}
{{- $root := index . 0 -}}
{{- $cfg := index . 1 -}}
{{- if $root.Values.trustedCA.injected.enabled -}}
{{- $_ := set $cfg.ca "kind" (include "group-sync-operator-helm.caKind" $root) -}}
{{- $_ := set $cfg.ca "name" (include "group-sync-operator-helm.caName" $root) -}}
{{- $_ := set $cfg.ca "namespace" (include "group-sync-operator-helm.caNamespace" $root) -}}
{{- $_ := set $cfg.ca "key" (include "group-sync-operator-helm.caKey" $root) -}}
{{- end -}}
{{- end }}

# GroupSync spec body — shared by the primary (02-groupsync.yaml) and every custom
# CR (custom-groupsync.yaml). The caller passes a config dict shaped exactly like
# .Values.groupSync (schedule, providerName, url, insecure, ca, credentialsSecret,
# rfc2307). Keeping one copy here means the two templates can never drift apart.
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

          # These seven come from values. They were written as fixed literals here while values.yaml
          # declared every one of them under groupSync.rfc2307, so setting groupMembershipAttributes to
          # uniqueMember for a groupOfUniqueNames directory, or userNameAttributes to sAMAccountName,
          # produced member and uid regardless. The defaults are the literals that were here.
          #
          # Attribute names are quoted: unquoted, a directory attribute called y, n, on or off would be
          # coerced to a boolean, and the CRD wants strings.
          groupNameAttributes:
            {{- range .rfc2307.groupNameAttributes | default (list "cn") }}
            - {{ . | quote }}
            {{- end }}
          groupUIDAttribute: {{ .rfc2307.groupUIDAttribute | default "dn" | quote }}
          groupMembershipAttributes:
            {{- range .rfc2307.groupMembershipAttributes | default (list "member") }}
            - {{ . | quote }}
            {{- end }}
          userNameAttributes:
            {{- range .rfc2307.userNameAttributes | default (list "uid") }}
            - {{ . | quote }}
            {{- end }}
          userUIDAttribute: {{ .rfc2307.userUIDAttribute | default "dn" | quote }}
          # hasKey, not `default true`: Helm's default treats false as empty, so an explicit false would
          # be turned back into true — the same class of silent override this block is fixing.
          tolerateMemberNotFoundErrors: {{ if hasKey .rfc2307 "tolerateMemberNotFoundErrors" }}{{ .rfc2307.tolerateMemberNotFoundErrors }}{{ else }}true{{ end }}
          tolerateMemberOutOfScopeErrors: {{ if hasKey .rfc2307 "tolerateMemberOutOfScopeErrors" }}{{ .rfc2307.tolerateMemberOutOfScopeErrors }}{{ else }}true{{ end }}
{{- end -}}

# Hash of the source CA's contents. Drives recreation of the copy: a changed source produces a
# different hash, which changes the extraction Job's pod spec, so the Job re-runs and re-copies.
#
# lookup reads the LIVE cluster, so this is populated during helm install/upgrade only. helm template
# and --dry-run (and therefore an offline GitOps render) get an empty map and "unavailable" — Helm
# cannot read a cluster it is not talking to. The Job stamps the same value on the copy, so what was
# actually read is recorded on the object either way.
#
# Hashes the configured sourceCa. When discoverFromOAuth finds a different name the Job logs it and
# copies that one, but this trigger still follows the configured name.
{{- define "group-sync-operator-helm.caSourceHash" -}}
{{- $c := .Values.oauthSecretExtraction.caCopy -}}
{{- $cm := lookup "v1" "ConfigMap" $c.sourceCa.namespace $c.sourceCa.name -}}
{{- if and $cm $cm.data -}}
{{- toYaml $cm.data | sha256sum | trunc 16 -}}
{{- else -}}
unavailable
{{- end -}}
{{- end }}

# The LDAP url for a provider. Returns .url when set; derives it from the cluster OAuth CR when empty.
#
# The OAuth LDAP identity provider's url is an RFC 2255 LDAP URL — scheme://host:port/basedn?attrs?scope?filter
# — so everything from the first / onwards is the search definition and belongs to authentication, not to
# group sync. Only scheme://host:port is taken, which is exactly what the GroupSync provider wants, and it
# carries ldap:// vs ldaps:// with it.
#
# The first LDAP provider wins. A cluster with several normally points them all at one directory,
# differing only in the basedn that is being stripped anyway.
#
# lookup reads the LIVE cluster, so this resolves during helm install/upgrade only. With .url empty and
# no cluster to read — helm template, --dry-run, an offline GitOps render — there is nothing to derive
# from and the render fails rather than emitting a GroupSync with no url.
#
# Resolution is split in two:
#
#   ldapUrlOrEmpty  resolves, or yields "". Used where the answer is advisory.
#   ldapUrl         resolves, or FAILS the render. Used where a url must exist — a GroupSync provider.
#
# The split exists because needsCa has to ask "what scheme is this?" from templates that render with no
# GroupSync CR at all (01.2, 01.5). With both groupSync.enabled and customGroupSyncs.enabled false the
# chart renders 20 objects including the extraction Job, and nothing resolves a url — so a fail reached
# from needsCa would break a configuration that renders today.
{{- define "group-sync-operator-helm.ldapUrlOrEmpty" -}}
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
{{- $found -}}
{{- end -}}
{{- end }}

{{- define "group-sync-operator-helm.ldapUrl" -}}
{{- $url := include "group-sync-operator-helm.ldapUrlOrEmpty" . -}}
{{- if not $url -}}
{{- fail (printf "groupSync.url is empty and no LDAP url could be derived from the cluster OAuth CR.\n  Either set groupSync.url, or install against a cluster whose OAuth CR has an LDAP identity provider.\n  Note that `helm template` and --dry-run cannot read the cluster at all, so url must be set for those.") -}}
{{- end -}}
{{- $url -}}
{{- end }}
