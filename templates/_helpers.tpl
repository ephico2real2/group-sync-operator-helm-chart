{{/*
Expand the name of the chart.
*/}}
{{- define "group-sync-operator-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
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
